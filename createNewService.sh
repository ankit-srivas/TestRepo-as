#!/usr/bin/env bash

set -e -o pipefail

scriptDir=${0%/*}

while [ $# != "0" ]; do
    case $1 in
        "?"|"-h"|"-help"|"--help")
            echo "Create a new git repository, initialize it with a helloworld app, add branch policies (master, develop), and run the build pipeline master then develop."
            echo "Usage: $0 --project <AzDevOpsProject> --service <my-new-service> --type <$($scriptDir/scaffold_app.sh --displaytypes)> --provider <azdo or github> [--devteam <Dev Team Name>] [--srcbranch <Branch Name>] [--lib] [--only-update-policies] [--no-policies] [--no-master-deployment] [--no-deployment]"
            echo "     --lib: generate a repo which only creates a package to be pushed to an artifact repository"
            echo "     --testService: generate a test service repo which only creates a test package and execute helm tests"
            echo "     --srcbranch: which branch to checkout ffrom the helloworld app to scaffold the new service. Default value: develop"
            echo "     --only-update-policies: update the repository branch policies, do nothing else"
            echo "     --no-policies: do not create branch policies"
            echo "     --no-deployment: do not create the deployment pipelines"
            echo "     --no-master-deployment: do not create the master branch deployment pipeline"
            echo "     (set then NO_SSH environment variable if you do not want to use ssh keys to authenticate with Azure DevOps)"
            exit 0
            ;;
        "--project")
            shift
            PROJECT="$1"
            ;;
        "--service")
            shift
            SERVICE_NAME="$1"
            ;;
        "--devteam")
            shift
            DEV_TEAM="$1"
            ;;
        "--type")
            shift
            SERVICE_TYPE="$1"
            ;;
        "--srcbranch")
            shift
            SRC_BRANCH="$1"
            ;;
        "--provider")
            shift
            PROVIDER="$1"
            ;;
        "--only-update-policies")
            ONLY_UPDATE_POLICIES=true
            ;;
        "--no-policies")
            NO_POLICIES=true
            ;;
        "--no-deployment")
            NO_DEPLOYMENT=true
            ;;
        "--no-master-deployment")
            NO_MASTER_DEPLOYMENT=true
            ;;
        "--lib")
            LIB_OPTION=--lib
            NO_DEPLOYMENT=true
            ;;
        "--testService")
            TEST_SERVICE_OPTION=--testService
            NO_DEPLOYMENT=true
            ;;
        *)
            echo "Unknown option: '$1'"
            exit 1
            ;;
    esac
    shift;
done

if [[ -z $SERVICE_NAME ]]; then
    echo "ERROR: --service is mandatory"
    exit 1
fi

if [[ ${#SERVICE_NAME} -gt 33 ]]; then
    echo "ERROR: Service name is too long (${#SERVICE_NAME})."
    echo "Max possible length is 33 characters, to accomodate PR temporary helm release names"
    echo "which are limited to 53 characters, and composed as <serviceName>-tmpUUUUUUUUpr123456"
    exit 1
fi

if [[ -z $SERVICE_TYPE ]]; then
    echo "ERROR: --type is mandatory"
    exit 1
fi

# Just make sure the type is supported
$scriptDir/scaffold_app.sh --checktype "$SERVICE_TYPE"
if [[ $? != 0 ]]; then
    exit 1
fi

if [[ -z $(echo $SERVICE_NAME | grep -E '^[-a-z0-9]+$') ]]; then
    echo "ERROR: The service name may only contain lowercase, numbers and hyphen characters. Example: my-new-service"
    exit 1
fi

if [[ -z $PROJECT ]]; then
    echo "ERROR: \$PROJECT must be defined (example: FFDC)"
    exit 1
fi

if [[ -z $PROVIDER ]]; then
    echo "ERROR: Git provider must be specified. Acceptable values are azdo or github"
    exit 1
fi

if [[ -z $SRC_BRANCH ]]; then
    SRC_BRANCH=develop
fi

# VARIABLES PROVIDED BY THE PROJECT DEFINITIONS:
#
# MANDATORY VARIABLES:
#     AZDO_ORG_URL       (example: https://fusionfabric.visualstudio.com)
#     GITHUB_ORG         (example: finastra-platform)
#     REQUIRED_REVIEWERS:
#         example: [
#              {
#                  "name": "Fusion-Operate",
#                  "path": "/azure-pipelines*.yml"
#              },
#              {
#                  "name": "Some Team"
#              },
#              {
#                  "name": "Architects",
#                  "creatorVoteCounts": true
#              }
#          ]
#
# OPTIONAL VARIABLES:
#     BUILD_PIPELINE_FOLDER_PATH (example: /Platform)
#     REPLACE_POLICIES           (example: true), default: true.
#        - true:  delete and recreate policies.
#        - false: don't create policies if some policies already exist
#    ONLY_UPDATE_POLICIES (true or not true. default: unset): implies
#    SRC_BRANCH (branch used to initialize repo, default: develop)

customTeamProjectDefinition=$scriptDir/projectDefinitions/$PROJECT--$DEV_TEAM
customProjectDefinition=$scriptDir/projectDefinitions/$PROJECT
defaultProjectDefinition=$scriptDir/projectDefinitions/__default__

if [[ -e $customTeamProjectDefinition ]]; then
    echo "Use $PROJECT Custom config for dev team $DEV_TEAM: $customTeamProjectDefinition"
    projectDefinition=$customTeamProjectDefinition
elif [[ -e $customProjectDefinition ]]; then
    echo "Use $PROJECT config: $customProjectDefinition"
    projectDefinition=$customProjectDefinition
else
    echo "No specific project definition, use default config: $defaultProjectDefinition"
    projectDefinition=$defaultProjectDefinition
fi

source $projectDefinition
AZDO_ORG_NAME=$(echo $AZDO_ORG_URL | perl -pe 's{https://(.*).visualstudio.com}{\1}; s{https://dev.azure.com/}{}')

case "$PROVIDER" in
    "azdo")
        REPOSITORY_TYPE=tfsgit
        REPOSITORY_NAME=${SERVICE_NAME}
        ;;
    "github")
        REPOSITORY_TYPE=github
        REPOSITORY_NAME=${GITHUB_ORG}/${PROJECT}-${SERVICE_NAME}
        ;;
    *)
        echo "ERROR: Please specify supported git provider: azdo or github"
        exit 1
        ;;
esac

if [[ -z $DEV_TEAM ]]; then
    echo "ERROR: \$DEV_TEAM must be defined"
    exit 1
fi

############################################

if [[ -z $REPLACE_POLICIES ]]; then
    REPLACE_POLICIES=true
fi

if [[ $ONLY_UPDATE_POLICIES == "true" ]]; then
    REPLACE_POLICIES=true
fi

function repoId {
    local repoInfos="$1"
    echo  $repoInfos | jq -r '.id'
}

function repoName {
    local repoInfos="$1"
    echo  $repoInfos | jq -r '.name'
}

CREATE_DEPLOY_PIPELINES=WeDontKnowYet

############################################

function createAzdoRepo {
    echo "Create git repo $SERVICE_NAME in Azure Repos" >&2
    set +e
    local repoInfos=$(az repos create --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$REPOSITORY_NAME")
    set -e
    if [[ -z $repoInfos ]]; then
        echo "Looking for an existing $REPOSITORY_NAME Git repo" >&2
        repoInfos=$(getAzdoRepo)
    fi
    local repoId=$(repoId "$repoInfos")
    echo "$repoInfos"
}

function createGithubRepo {
    local checkRepo=$(getGithubRepo)
    if [[ ! -z $checkRepo ]]; then
        echo "Git repo already created. Skip..." >&2
    else
        set +e
        echo "Create git repo ${REPOSITORY_NAME} in GitHub" >&2
        LOCATION=$(pwd)
        local tempGitDir=tempGitDir$$
        mkdir -p /tmp/${tempGitDir}
        cd /tmp/${tempGitDir}
        local createRepo=$(gh repo create "${REPOSITORY_NAME}" --private --confirm)
        gh repo view "${REPOSITORY_NAME}" >&2
        cd ${LOCATION}
        rm -Rf /tmp/${tempGitDir}
        set -e
    fi

    repoInfos=$(getGithubRepo)

    # local repoId=$(repoId "$repoInfos")
    echo "$repoInfos"
}

function getAzdoRepo {
    # echo "Get Azure DevOps repo $SERVICE_NAME" >&2
    local repoInfos=$(az repos show --org "$AZDO_ORG_URL" --project "$PROJECT" -r "$REPOSITORY_NAME")
    if [[ -z $repoInfos ]]; then
        echo "Can't find existing git repo $REPOSITORY_NAME" >&2
        exit 1
    fi
    echo "$repoInfos"
}

function getGithubRepo {
    local repoInfos=$(gh repo list ${GITHUB_ORG} --json id,name,sshUrl,url --jq ".[] | select(.name==\"${PROJECT}-${SERVICE_NAME}\")" --limit 1000)
    if [[ -z $repoInfos ]]; then
        echo "${REPOSITORY_NAME} repo not found" >&2
        return
    fi
    echo "$repoInfos"
}

function addGithubRepoTopic {
        echo "Add topic to GitHub repo" >&2
        local repoInfos="$1"
        local repoId=$(repoId "$repoInfos")
        local topics=$(echo ${PROJECT} | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        echo "repoId: $repoId" >&2
        echo "topics: $topics" >&2
        repoTopic=$(gh api graphql -f query='
        mutation($repositoryId:ID!,$topicNames:[String!]!) {
        updateTopics(input: {
            repositoryId: $repositoryId
            topicNames: $topicNames
        }) { clientMutationId }
        }' -f repositoryId="$repoId" -f topicNames="$topics")
        echo "List repository topics" >&2
        gh repo list ${GITHUB_ORG} --json id,name,repositoryTopics --jq ".[] | select(.name==\"${PROJECT}-${SERVICE_NAME}\")"
}

function populateAzdoRepo {
    local repoInfos="$1"
    local repoId=$(repoId "$repoInfos")
    local nbRef=$(az repos ref list --org "$AZDO_ORG_URL" --project "$PROJECT" --repository $repoId | jq length)
    if [[ $nbRef -gt 1 ]]; then
        echo "Git repo already populated. Skip..."
        return
    fi
    local scaffoldDir=scaffoldDir$$
    $scriptDir/scaffold_app.sh --provider "azdo" --project "$PROJECT" --name "$REPOSITORY_NAME" --type "$SERVICE_TYPE" --outputDir $scaffoldDir --srcbranch $SRC_BRANCH $LIB_OPTION $TEST_SERVICE_OPTION

    echo "Initlialize and push git repo"
    local remote
    if [[ $TOKEN ]]; then
        remote=$(echo $repoInfos | jq -r '.remoteUrl' | sed -e "s,://,://${TOKEN}@,")
    else
        if [[ $NO_SSH ]]; then
            remote=$(echo $repoInfos | jq -r '.remoteUrl')
        else
            remote=$(echo $repoInfos | jq -r '.sshUrl')
        fi
    fi
    cd $scaffoldDir
    if [[ -f azure-pipelines-master.yml ]]; then
        CREATE_DEPLOY_PIPELINES=yes
    else
        CREATE_DEPLOY_PIPELINES=no
    fi
    {
        git init > /dev/null
        if [[ -z $(git config user.email) ]]; then
            git config user.email "admin@azuredevops.com"
            git config user.name "Repo Initializer script"
        fi
        git remote add origin "$remote"
        git add -A
        git commit -m "Creation"
        git push -u origin --all
        # Seems we need a second commit to have the pipeline created
        git checkout -b develop
        git push --set-upstream origin develop
    }  2>&1 | perl -pe 's/^/   | /'
    if [[ $? != 0 ]]; then exit 1; fi
    cd - >/dev/null
    rm -rf $scaffoldDir
}

function populateGithubRepo {
    local repoInfos=$1
    local emptyRepo=$(gh repo list ${GITHUB_ORG} --json id,name,isEmpty --jq ".[] | select(.name==\"${PROJECT}-${SERVICE_NAME}\") | .isEmpty")
    if [[ "$emptyRepo" == "false" ]]; then
        echo "Git repo already populated. Skip..."
        return
    fi
    local scaffoldDir=scaffoldDir$$
    LOCATION=$(pwd)
    $scriptDir/scaffold_app.sh --provider "github" --project "$PROJECT" --name "$SERVICE_NAME" --type "$SERVICE_TYPE" --outputDir $scaffoldDir --srcbranch $SRC_BRANCH --codeowners "$CODEOWNERS" --consensus "$CONSENSUS" $LIB_OPTION $TEST_SERVICE_OPTION

    echo "Initlialize and push git repo" >&2
    cd $scaffoldDir
    local remote
    if [[ $GHTOKEN ]]; then
        remote=$(echo $repoInfos | jq -r '.url' | sed -e "s,://,://${GHTOKEN}@,")
    else
        if [[ $NO_SSH ]]; then
            remote=$(echo $repoInfos | jq -r '.url')
        else
            remote=$(echo $repoInfos | jq -r '.sshUrl')
        fi
    fi
    if [[ -f azure-pipelines-master.yml ]]; then
        CREATE_DEPLOY_PIPELINES=yes
    else
        CREATE_DEPLOY_PIPELINES=no
    fi
    {
        git init > /dev/null
        if [[ -z $(git config user.email) ]]; then
            git config user.email "admin@azuredevops.com"
            git config user.name "Repo Initializer script"
        fi
        git remote add origin "$remote"
        git add -A
        git commit -m "Creation"
        git push -u origin --all
        # Seems we need a second commit to have the pipeline created
        git checkout -b develop
        git push --set-upstream origin develop
    }  2>&1 | perl -pe 's/^/   | /'
    if [[ $? != 0 ]]; then exit 1; fi
    cd $LOCATION
    rm -rf $scaffoldDir
}

function shouldDeployPipelinesBeCreated {
    if [[ $CREATE_DEPLOY_PIPELINES != WeDontKnowYet ]]; then
        echo $CREATE_DEPLOY_PIPELINES
        return
    fi
    local scaffoldDir=scaffoldDir$$
    local remote
    case "$PROVIDER" in
        "azdo")
            if [[ $TOKEN ]]; then
                remote=https://${TOKEN}@${AZDO_ORG_NAME}.visualstudio.com/${PROJECT}/_git/${REPOSITORY_NAME}
            else
                if [[ $NO_SSH ]]; then
                    remote=https://${AZDO_ORG_NAME}.visualstudio.com/${PROJECT}/_git/${REPOSITORY_NAME}
                else
                    remote=${AZDO_ORG_NAME}@vs-ssh.visualstudio.com:v3/${AZDO_ORG_NAME}/${PROJECT}/${REPOSITORY_NAME}
                fi
            fi
            ;;
        "github")
            if [[ $GHTOKEN ]]; then
                remote=https://${GHTOKEN}@github.com/${REPOSITORY_NAME}

            else
                if [[ $NO_SSH ]]; then
                    remote=https://github.com/${REPOSITORY_NAME}
                else
                    remote=git@github.com:${REPOSITORY_NAME}
                fi
            fi
            ;;
        *)
            echo "ERROR: Please specify supported git provider: azdo or github"
            exit 1
            ;;
    esac

    git clone --quiet $remote $scaffoldDir
    if [[ -f $scaffoldDir/azure-pipelines-master.yml ]]; then
        CREATE_DEPLOY_PIPELINES=yes
    else
        CREATE_DEPLOY_PIPELINES=no
    fi
    rm -rf $scaffoldDir
    echo $CREATE_DEPLOY_PIPELINES
}

# # This build pipeline used to be created automatically by Azure DevOps when the repo content was pushed.
# # This functions waits for it to be created.
# # It seems however that AzDO behabior has changed and the pipeline is no longer created
# # So after 30 seconds, this function will try creating it
# function getBuildPipeline {
#     local count=0
#     local pipelineId
#     while [[ -z $pipelineId ]]; do
#         pipelineId=$(az pipelines list --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$SERVICE_NAME*"  --query "[?name=='$SERVICE_NAME' || name=='$SERVICE_NAME CI'].id" | jq -r '.[]')
#         if [[ $count -gt 100 ]]; then
#             echo "Can't find build pipeline. Abort" >&2
#             exit 1
#         fi
#         echo "wait for the build pipeline creation ($count sec)" >&2
#         count=$(($count+5))
#         sleep 5
#         if [[ $count = 30 ]]; then
#             echo "It looks like the pipeline won't be created automatically by AzDO, let's do it"  >&2
#             pipelineId=$(createBuildPipeline)
#             break
#         fi
#     done
#     if [[ $BUILD_PIPELINE_FOLDER_PATH ]]; then
#         local folderMsg="and pipeline path is $BUILD_PIPELINE_FOLDER_PATH"
#         local folderOption="--new-folder-path"
#         local folderOptionArg="$BUILD_PIPELINE_FOLDER_PATH"
#     fi
#     echo "Found Build pipeline: $pipelineId. Ensure pipeline name is $SERVICE_NAME $folderMsg: " >&2
#     az pipelines update --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --id $pipelineId --new-name "$SERVICE_NAME" $folderOption "$folderOptionArg" 1>/dev/null
#     echo $pipelineId
# }

function createBuildPipeline {
    local pipelineName="$SERVICE_NAME"
    local pipelineId=$(az pipelines list --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$pipelineName" | jq -r '.[].id')
    if [[ $pipelineId ]]; then
        echo "Pipeline $pipelineName already created. Skip... (id:$pipelineId)" >&2
        echo $pipelineId
        return
    fi
    if [[ $BUILD_PIPELINE_FOLDER_PATH ]]; then
        local folderMsg="with path $BUILD_PIPELINE_FOLDER_PATH"
        local folderOption="--folder-path"
        local folderOptionArg="$BUILD_PIPELINE_FOLDER_PATH"
    fi
    echo "Create build pipeline: $pipelineName $folderMsg" >&2
    case "$PROVIDER" in
        "azdo")
            local pipelineBody=$(az pipelines create --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$pipelineName" --repository "$REPOSITORY_NAME" --repository-type "$REPOSITORY_TYPE" --skip-run --branch master --yaml-path azure-pipelines.yml $folderOption "$folderOptionArg")
            ;;
        "github")
            local githubServiceConnectionId=$(az devops service-endpoint list --organization ${AZDO_ORG_URL} --project ${PROJECT} | jq -r ".[] | select(.name==\"${GITHUB_ORG}\") | .id")
            local pipelineBody=$(az pipelines create --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$pipelineName" --repository "$REPOSITORY_NAME" --repository-type "$REPOSITORY_TYPE" --service-connection $githubServiceConnectionId --skip-run --branch master --yaml-path azure-pipelines.yml $folderOption "$folderOptionArg")
            ;;
        *)
            echo "ERROR: Please specify supported git provider: azdo or github"
            exit 1
            ;;
    esac

    pipelineBody=$(echo $pipelineBody | jq -r '.repository.properties.reportBuildStatus="true"') # Allows to see the pipeline status for each commit (this is only enabled automatically for build pipelines created by Azdo when populating a repo)
    pipelineId=$(echo $pipelineBody | jq -r '.id')
    az rest --resource 499b84ac-1321-427f-aa17-267ca6975798 --method put --uri "https://dev.azure.com/$AZDO_ORG_NAME/$PROJECT/_apis/build/definitions/$pipelineId?api-version=5.1" --body "$pipelineBody"  1>/dev/null
    echo $pipelineId
}

function createDeployPipeline {
    local deployBranch=$1 # develop | master
    local pipelineName="$SERVICE_NAME-$deployBranch"
    local pipelineId=$(az pipelines list --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$pipelineName" | jq -r '.[].id')
    if [[ $pipelineId ]]; then
        echo "Pipeline $pipelineName already created. Skip... (id:$pipelineId)"
        return
    fi
    if [[ $DEPLOY_PIPELINE_FOLDER_PATH ]]; then
        local folderMsg="with path $DEPLOY_PIPELINE_FOLDER_PATH"
        local folderOption="--folder-path"
        local folderOptionArg="$DEPLOY_PIPELINE_FOLDER_PATH"
    fi
    echo "Create deployment pipeline: $pipelineName $folderMsg"
    case "$PROVIDER" in
        "azdo")
            local pipelineBody=$(az pipelines create --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$pipelineName" --repository "$REPOSITORY_NAME" --repository-type "$REPOSITORY_TYPE" --skip-run --branch refs/heads/$deployBranch --yaml-path azure-pipelines-$deployBranch.yml $folderOption "$folderOptionArg")
            ;;
        "github")
            local githubServiceConnectionId=$(az devops service-endpoint list --organization ${AZDO_ORG_URL} --project ${PROJECT} | jq -r ".[] | select(.name==\"${GITHUB_ORG}\") | .id")
            local pipelineBody=$(az pipelines create --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --name "$pipelineName" --repository "$REPOSITORY_NAME" --repository-type "$REPOSITORY_TYPE" --service-connection $githubServiceConnectionId --skip-run --branch refs/heads/$deployBranch --yaml-path azure-pipelines-$deployBranch.yml $folderOption "$folderOptionArg")
            ;;
        *)
            echo "ERROR: Please specify supported git provider: azdo or github"
            exit 1
            ;;
    esac

    pipelineBody=$(echo $pipelineBody | jq -r '.repository.properties.reportBuildStatus="true"') # Allows to see the pipeline status for each commit (this is only enabled automatically for build pipelines created by Azdo when populating a repo)
    pipelineId=$(echo $pipelineBody | jq -r '.id')
    az rest --resource 499b84ac-1321-427f-aa17-267ca6975798 --method put --uri "https://dev.azure.com/$AZDO_ORG_NAME/$PROJECT/_apis/build/definitions/$pipelineId?api-version=5.1" --body "$pipelineBody"  1>/dev/null
}

function removeEmptyPipelineFolder {
    local pipelinesInFolder=$(az pipelines list --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --query "[?path=='\\$SERVICE_NAME'].name" | jq -r '.[]')
    if [[ -z $pipelinesInFolder ]]; then
        echo "Delete empty folder $SERVICE_NAME"
        az pipelines folder delete --only-show-errors --org "$AZDO_ORG_URL" --project "$PROJECT" --yes --path "\\$SERVICE_NAME"
    else
        echo "Won't delete folder $SERVICE_NAME which contains the following pipelines:"
        echo "$pipelinesInFolder" | perl -pe 's/^/   - /'
    fi
}

function doesGitHubTeamExist {
    local TEAM_NAME="$1"
    teamId=$(gh api graphql --paginate -f query='
        query checkTeam($org:String!, $endCursor: String) {
            organization(login: $org) {
            teams(first: 100, after: $endCursor) {
                nodes {
                    name,
                    id
                }
                pageInfo {
                    hasNextPage
                    endCursor
                }
            }
            }
        }' -f org="$GITHUB_ORG" --jq ".data.organization.teams.nodes.[] | select(.name==\"$TEAM_NAME\") | .id")
    echo $teamId
}

function addGitHubTeamToRepo {
    local REPO_NAME="$1"
    local TEAM_NAME="$2"
    local PERMISSION="$3"
    team_id=$(doesGitHubTeamExist $TEAM_NAME)
    if [ ! -z $team_id ]; then
        team_slug=$(echo ${TEAM_NAME} | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        echo "adding $PERMISSION permissions for $REPO_NAME repo to $TEAM_NAME team" >&2
        gh api --method PUT -H "Accept: application/vnd.github.v3+json" "/orgs/$GITHUB_ORG/teams/$team_slug/repos/$GITHUB_ORG/$REPO_NAME" -f "permission=$PERMISSION"
    else
        echo "Team $TEAM_NAME not found" >&2
    fi
}

################# Set branch policies #################
function createGithubBranchRule {
    local repoInfos="$1"
    local branch="$2"
    local repoId=$(repoId "$repoInfos")
    local repoName=$(repoName "$repoInfos")

    case $branch in
        */\*) matchKind=Prefix; branch=$(echo $branch | tr -d '/*') ;;
        *\**) echo "ERROR: Unsupported branch policy scope: '$branch'"; exit 1 ;;
        *) matchKind=exact ;;
    esac

    requiresApprovingReviews=true
    requiresCodeOwnerReviews=true
    dismissesStaleReviews=true
    requiredApprovingReviewCount=$MIN_NB_REVIEWERS
    requiresStatusChecks=true
    requiresStrictStatusChecks=true
    isAdminEnforced=true
    requiresConversationResolution=true
    requiredStatusCheckContexts="$SERVICE_NAME"

    branchRuleId=$(gh api graphql -f query='
        query checkBranchRules($org:String!,$repo:String!) {
            repository(owner:$org, name:$repo) {
            branchProtectionRules(first: 100) {
                nodes {
                    pattern,
                    id
                    }
                }
            }
        }' -f org="$GITHUB_ORG" -f repo="$repoName" --jq ".data.repository.branchProtectionRules.nodes.[] | select(.pattern==\"$branch\") | .id")

    if [ ! -z $branchRuleId ]; then
        echo "Matching branch rule for \"$branch\" pattern already exist: $branchRuleId. Updating..." >&2
        branchRule=$(gh api graphql -f query='
        mutation($branchRuleId:ID!,$branch:String!,$requiresApprovingReviews:Boolean!,$requiredApprovingReviewCount:Int!,$dismissesStaleReviews:Boolean!,$requiresCodeOwnerReviews:Boolean!,$isAdminEnforced:Boolean!,$requiresConversationResolution:Boolean!,$requiresStatusChecks:Boolean!,$requiresStrictStatusChecks:Boolean!,$requiredStatusCheckContexts:[String!]) {
        updateBranchProtectionRule(input: {
            branchProtectionRuleId: $branchRuleId
            pattern: $branch
            requiresApprovingReviews: $requiresApprovingReviews
            requiredApprovingReviewCount: $requiredApprovingReviewCount
            dismissesStaleReviews: $dismissesStaleReviews
            requiresCodeOwnerReviews: $requiresCodeOwnerReviews
            isAdminEnforced: $isAdminEnforced
            requiresConversationResolution: $requiresConversationResolution
            requiresStatusChecks: $requiresStatusChecks
            requiresStrictStatusChecks: $requiresStrictStatusChecks
            requiredStatusCheckContexts: $requiredStatusCheckContexts
        }) { clientMutationId }
        }' -f branchRuleId="$branchRuleId" -f branch="$branch" -F requiresApprovingReviews=$requiresApprovingReviews -F requiredApprovingReviewCount=$requiredApprovingReviewCount -F dismissesStaleReviews=$dismissesStaleReviews -F requiresCodeOwnerReviews=$requiresCodeOwnerReviews -F isAdminEnforced=$isAdminEnforced -F requiresConversationResolution=$requiresConversationResolution -F requiresStatusChecks=$requiresStatusChecks -F requiresStrictStatusChecks=$requiresStrictStatusChecks -F requiredStatusCheckContexts=$requiredStatusCheckContexts)
    else
        echo "Matching branch rule for \"$branch\" pattern does not exist. Creating..." >&2
        branchRule=$(gh api graphql -f query='
        mutation($repositoryId:ID!,$branch:String!,$requiresApprovingReviews:Boolean!,$requiredApprovingReviewCount:Int!,$dismissesStaleReviews:Boolean!,$requiresCodeOwnerReviews:Boolean!,$isAdminEnforced:Boolean!,$requiresConversationResolution:Boolean!,$requiresStatusChecks:Boolean!,$requiresStrictStatusChecks:Boolean!,$requiredStatusCheckContexts:[String!]) {
        createBranchProtectionRule(input: {
            repositoryId: $repositoryId
            pattern: $branch
            requiresApprovingReviews: $requiresApprovingReviews
            requiredApprovingReviewCount: $requiredApprovingReviewCount
            dismissesStaleReviews: $dismissesStaleReviews
            requiresCodeOwnerReviews: $requiresCodeOwnerReviews
            isAdminEnforced: $isAdminEnforced
            requiresConversationResolution: $requiresConversationResolution
            requiresStatusChecks: $requiresStatusChecks
            requiresStrictStatusChecks: $requiresStrictStatusChecks
            requiredStatusCheckContexts: $requiredStatusCheckContexts
        }) { clientMutationId }
        }' -f repositoryId="$repoId" -f branch="$branch" -F requiresApprovingReviews=$requiresApprovingReviews -F requiredApprovingReviewCount=$requiredApprovingReviewCount -F dismissesStaleReviews=$dismissesStaleReviews -F requiresCodeOwnerReviews=$requiresCodeOwnerReviews -F isAdminEnforced=$isAdminEnforced -F requiresConversationResolution=$requiresConversationResolution -F requiresStatusChecks=$requiresStatusChecks -F requiresStrictStatusChecks=$requiresStrictStatusChecks -F requiredStatusCheckContexts=$requiredStatusCheckContexts)
    fi
}

function getPolicyScope {
    local repoInfos="$1"
    local branch="$2"
    local repoId=$(repoId "$repoInfos")
    echo "$SERVICE_NAME git repo id: $repoId" >&2
    local matchKind
    case $branch in
        */\*) matchKind=Prefix; branch=$(echo $branch | tr -d '/*') ;;
        *\**) echo "ERROR: Unsupported branch policy scope: '$branch'"; exit 1 ;;
        *) matchKind=exact ;;
    esac

    cat << SCOPE
[
            {
                "repositoryId": "$repoId",
                "refName": "refs/heads/$branch",
                "matchKind": "$matchKind"
            }
        ]
SCOPE
}

function createNoLabelPolicyConfig {
    local scope="$1"
    cat << END_OF_POLICY
{
    "isEnabled": true,
    "isBlocking": true,
    "type": {
        "displayName": "Status",
        "id": "cbdc66da-9728-4af8-aada-9a5a32e4a226"
    },
    "settings": {
        "statusGenre": "ci-service",
        "statusName": "no-label-alteration",
        "invalidateOnSourceUpdate": false,
        "policyApplicability": 1,
        "scope": $scope
    }
}
END_OF_POLICY
}

function createMinNbApproversPolicyConfig {
    local scope="$1"
    local minNbApprovers="$2"
    cat << END_OF_POLICY
{
    "isEnabled": true,
    "isBlocking": true,
    "type": {
        "displayName": "Minimum number of reviewers",
        "id": "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"
    },
    "settings": {
        "minimumApproverCount": $minNbApprovers,
        "creatorVoteCounts": false,
        "allowDownvotes": false,
        "resetOnSourcePush": true,
        "scope": $scope
    }
}
END_OF_POLICY
}

function createResolvedCommentsPolicyConfig {
    local scope="$1"
    cat << END_OF_POLICY
{
    "isEnabled": true,
    "isBlocking": true,
    "type": {
        "displayName": "Comment requirements",
        "id": "c6a1889d-b943-4856-b76f-9e46bb6b0df2"
    },
    "settings": {
        "scope": $policyScope
    }
}
END_OF_POLICY
}

function createRequiredReviewerPolicyConfig {
    local scope="$1"
    local reviewer="$2" # Group name (ex: "App Management"), or user email
    local creatorVoteCounts="$3" # true|false
    local paths="$4" # list of paths to apply the policy on, separated by ";"
    local filenamePatterns='["/azure-pipelines.yml"]'
    echo "Retrieve $reviewer id" >&2
    local id
    case "$reviewer" in
        *@*) id=$(az devops user show --org "$AZDO_ORG_URL"  --user "$reviewer" | jq -r '.id');;
        */*)
             local reviewerProject=${reviewer%/*}
             local reviewer=${reviewer#*/}
             id=$(az devops team show --org "$AZDO_ORG_URL" --project "$reviewerProject" --team "$reviewer" | jq -r '.id');;
        *  ) id=$(az devops team show --org "$AZDO_ORG_URL" --project "$PROJECT"         --team "$reviewer" | jq -r '.id');;
    esac
    echo "$reviewer id: $id" >&2
    case "$paths" in
        "") filenamePatterns="";;
        "null") filenamePatterns="";;
        *) filenamePatterns=$(echo "$paths" | sed -e 's/^/"filenamePatterns": ["/' -e 's/;/", "/g' -e 's/$/"],/');;
    esac
    case "$creatorVoteCounts" in
        true) ;;
        *) creatorVoteCounts=false;;
    esac
    cat << END_OF_POLICY
{
    "isEnabled": true,
    "isBlocking": true,
    "type": {
        "displayName": "Required reviewers",
        "id": "fd2167ab-b0be-447a-8ec8-39368250530e"
    },
    "settings": {
        $filenamePatterns
        "addedFilesOnly": false,
        "creatorVoteCounts": $creatorVoteCounts,
        "minimumApproverCount": 1,
        "requiredReviewerIds": [
            "$id"
        ],
        "scope": $policyScope
    }
}
END_OF_POLICY
}

function createMergeStrategyPolicyConfig {
    local scope="$1"
    local allowNoFastForward="$2"
    local allowSquash="$3"
    local allowRebase="$4"
    local allowRebaseMerge="$5"
    cat << END_OF_POLICY
{
    "isEnabled": true,
    "isBlocking": true,
    "type": {
        "displayName": "Require a merge strategy",
        "id": "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"
    },
    "settings": {
        "useSquashMerge": false,
        "allowNoFastForward": $allowNoFastForward,
        "allowSquash": $allowSquash,
        "allowRebase": $allowRebase,
        "allowRebaseMerge": $allowRebaseMerge,
        "scope": $policyScope
    }
}
END_OF_POLICY
}

function createBuildPolicyConfig {
    local scope="$1"
    local pipelineId="$2"
    cat << END_OF_POLICY
{
    "isEnabled": true,
    "isBlocking": true,
    "type": {
        "displayName": "Build",
        "id": "0609b952-1397-4640-95ec-e00a01b2c241"
    },
    "settings": {
        "buildDefinitionId": $pipelineId,
        "displayName": null,
        "filenamePatterns": [
            "/*",
            "!/azure-pipelines-develop.yml",
            "!/azure-pipelines-master.yml"
        ],
        "manualQueueOnly": false,
        "queueOnSourceUpdateOnly": true,
        "validDuration": 2160.0,
        "scope": $policyScope
    }
}
END_OF_POLICY
}

function branchPolicyFile {
    local branch="$1"
    local topic="$2"
    echo policy_$$_$(echo $branch | tr -cd '[:alnum:]_-')_$topic.json
}

function createAllRequiredReviewerPolicyConfigs {
    local scope="$1"
    local branch="$2"
    local json_required_reviewers="$3"
    nbPolicies=$(echo $json_required_reviewers | jq length)
    for (( c=0; c<$nbPolicies; c++ )); do
        local data=$(echo $json_required_reviewers | jq -r ".[$c]")
        local reviewer=$(echo $data | jq -r '.name')
        local creatorVoteCounts=$(echo $data | jq -r '.creatorVoteCounts')
        local path=$(echo $data | jq -r '.path')
        if [[ $reviewer ]]; then
            createRequiredReviewerPolicyConfig "$scope" "$reviewer" $creatorVoteCounts "$path" > $(branchPolicyFile "$branch" required_reviewer_$c)
        fi
    done
}

function createPolicy {
    local config=$1
    echo "Create branch policy from config $config"
    az repos policy create --org "$AZDO_ORG_URL" --project "$PROJECT" --config $config > /dev/null
}

function createPolicies {
    for config in policy_$$_*.json; do
        createPolicy $config
    done
    rm policy_$$_*.json
}

function areTherePolicies {
    local repoInfos="$1"
    local repoId=$(repoId "$repoInfos")
    local nbPolicies=0
    local branch
    for branch in $POLICY_BRANCHES; do
        local nb=$(az repos policy list --org "$AZDO_ORG_URL" --project "$PROJECT" --repository-id $repoId --branch "refs/heads/$branch" | jq length)
        local nbPolicies=$(($nbPolicies+$nb))
    done
    if [[ $nbPolicies -gt 0 ]]; then
        echo yes
    fi
}

function deletePolicies {
    local repoInfos="$1"
    local repoId=$(repoId "$repoInfos")
    local branch
    for branch in $POLICY_BRANCHES; do
        local policyIds=$(az repos policy list --org "$AZDO_ORG_URL" --project "$PROJECT" --repository-id $repoId --branch "refs/heads/$branch" | jq -r '.[].id')
        for policyId in $policyIds; do
            echo "Delete policy $policyId"
            az repos policy delete --org "$AZDO_ORG_URL" --project "$PROJECT" --yes --id $policyId
        done
    done
}

function createOrUpdatePolicies {
    local repoInfos="$1"
    if [[ $SERVICE_TYPE != "deployment" ]]; then
        local pipelineId="$2"
    fi
    if [[ $REPLACE_POLICIES == "true" ]]; then
        deletePolicies "$repoInfos"
    elif [[ $(areTherePolicies "$repoInfos") ]]; then
        echo "Policies already exist. Won't recreate them"
        return
    fi
    local branch
    for branch in $POLICY_BRANCHES; do
        local policyScope=$(getPolicyScope "$repoInfos" $branch)
        if [[ $REQUIRED_REVIEWERS ]]; then
        createAllRequiredReviewerPolicyConfigs "$policyScope" $branch "$REQUIRED_REVIEWERS"
            createNoLabelPolicyConfig "$policyScope" > $(branchPolicyFile "$branch" no_label)
        fi
        if [[ $MIN_NB_REVIEWERS && $MIN_NB_REVIEWERS != 0 ]]; then
            createMinNbApproversPolicyConfig "$policyScope" "$MIN_NB_REVIEWERS" > $(branchPolicyFile "$branch" min_nb_approvers)
        fi
        if [[ $SERVICE_TYPE != "deployment" ]]; then
            createBuildPolicyConfig "$policyScope" "$pipelineId" > $(branchPolicyFile "$branch" build)
        fi
        createResolvedCommentsPolicyConfig "$policyScope" > $(branchPolicyFile "$branch" resolved_comments)
        createMergeStrategyPolicyConfig "$policyScope" "$ALLOW_NO_FAST_FORWARD" "$ALLOW_SQUASH" "$ALLOW_REBASE" "$ALLOW_REBASE_MERGE" > $(branchPolicyFile "$branch" merge_strategy)
    done
    createPolicies
}

function queueBuild {
    local pipelineId="$1"
    local branch="$2"
    local openInBrowser="$3"
    if [[ $openInBrowser = "true" ]]; then
        local openOption="--open"
    fi
    echo "Queue build on ${branch##*/}" >&2
    local buildInfo=$(az pipelines build queue --org "$AZDO_ORG_URL" --project "$PROJECT" --definition-name "$SERVICE_NAME" --branch $branch $openOption)
    local buildId=$(echo "$buildInfo" | jq -r '.id')
    echo $buildId
}

function queueMasterBuild {
    local pipelineId="$1"
    queueBuild $pipelineId refs/heads/master true
    echo "Please grant this new pipeline permissions to access required resources (it should open in your browser)" >&2
}

function queueDevelopBuild {
    local pipelineId="$1"
    local buildIdMaster="$2"
    echo "Waiting for the master branch sonar scan to be completed" >&2
    while [[ $status != completed ]]; do
        sleep 10
        status=$(az rest --resource 499b84ac-1321-427f-aa17-267ca6975798 --method get --uri "https://dev.azure.com/$AZDO_ORG_NAME/$PROJECT/_apis/build/builds/$buildIdMaster/timeline?api-version=6.0" --query "records[?name=='Build script'||name=='Run SonarQube Analysis with quality gate'].state" -o tsv)
        echo "    Sonar scan status: $status" >&2
    done
    queueBuild $pipelineId refs/heads/develop
}

function waitForBuildsCompletion {
    local buildIdMaster="$1"
    local buildIdDevelop="$2"

    echo "Waiting for builds completion..."
    local resultMaster=null
    local resultDevelop=null
    local count=0
    while [[ $resultMaster == "null" ]] || [[ $resultDevelop == "null" ]]; do
        count=$(($count+1))
        if [[ $count == 30 ]]; then
            echo "Builds still not completed. Let's continue"
            break
        fi
        sleep 60
        echo "    ... $count min"
        if [[ $buildIdMaster != null ]]; then
            resultMaster=$(az pipelines build show --org "$AZDO_ORG_URL" --project "$PROJECT" --id $buildIdMaster | jq -r '.result')
            if [[ $resultMaster != "null" ]]; then
                echo "Build on master completed: $resultMaster"
                buildIdMaster=null
            fi
        fi
        if [[ $buildIdDevelop != null ]]; then
            resultDevelop=$(az pipelines build show --org "$AZDO_ORG_URL" --project "$PROJECT" --id $buildIdDevelop | jq -r '.result')
            if [[ $resultDevelop != "null" ]]; then
                echo "Build on develop completed: $resultDevelop"
                buildIdDevelop=null
            fi
        fi
    done
}

case "$PROVIDER" in
    "azdo")
        if [[ $ONLY_UPDATE_POLICIES == "true" ]]; then
            repoInfos=$(getAzdoRepo)
            if [[ $SERVICE_TYPE != "deployment" ]]; then
                pipelineId=$(createBuildPipeline)
            else
                echo "Skipping creation of build pipeline"
            fi
            createOrUpdatePolicies "$repoInfos" "$pipelineId"
        else
            repoInfos=$(createAzdoRepo)
            populateAzdoRepo "$repoInfos"
            if [[ $SERVICE_TYPE != "deployment" ]]; then
                pipelineId=$(createBuildPipeline)
            else
                echo "Skipping creation of build pipeline"
            fi
            removeEmptyPipelineFolder
            if [[ $NO_DEPLOYMENT != "true" ]]; then
                if [[ $(shouldDeployPipelinesBeCreated) = yes ]]; then
                    createDeployPipeline develop
                    if [[ $NO_MASTER_DEPLOYMENT != "true" ]]; then
                        createDeployPipeline master
                    fi
                fi
            fi
            if [ $SERVICE_TYPE != "deployment" ] && [ $SERVICE_TYPE != "trigger" ]; then
                buildIdMaster=$(queueMasterBuild $pipelineId)
            else
                echo "Skipping queueing of master build pipeline"
            fi
            if [[ $NO_POLICIES != "true" ]]; then
                createOrUpdatePolicies "$repoInfos" "$pipelineId"
            fi
            if [ $SERVICE_TYPE != "deployment" ] && [ $SERVICE_TYPE != "trigger" ]; then
                buildIdDevelop=$(queueDevelopBuild $pipelineId $buildIdMaster)
                waitForBuildsCompletion $buildIdMaster $buildIdDevelop
            else
                echo "Skipping queueing of develop build pipeline"
            fi
        fi
        ;;
    "github")
        if [[ -z $(doesGitHubTeamExist "$DEV_TEAM") ]]; then
            echo "ERROR: Specified $DEV_TEAM dev team cannot be found in $GITHUB_ORG organization"
            exit 1
        fi

        if [[ -z $(doesGitHubTeamExist "$ARCHITECT_TEAM") ]]; then
            echo "ERROR: Specified $ARCHITECT_TEAM architect team cannot be found in $GITHUB_ORG organization"
            exit 1
        fi
        if [[ $ONLY_UPDATE_POLICIES == "true" ]]; then
            repoInfos=$(getGithubRepo)
            if [[ $SERVICE_TYPE != "deployment" ]]; then
                pipelineId=$(createBuildPipeline)
            else
                echo "Skipping creation of build pipeline" >&2
            fi
            for policy_branch in $POLICY_BRANCHES; do
                createGithubBranchRule "$repoInfos" "$policy_branch"
            done
        else
            repoInfos=$(createGithubRepo)
            populateGithubRepo "$repoInfos"
            removeEmptyPipelineFolder
            addGithubRepoTopic "$repoInfos"
            if [[ $SERVICE_TYPE != "deployment" ]]; then
                pipelineId=$(createBuildPipeline)
            else
                echo "Skipping creation of build pipeline"
            fi
            addGitHubTeamToRepo "${PROJECT}-${SERVICE_NAME}" "FusionOperatePipelines-User" "push"
            addGitHubTeamToRepo "${PROJECT}-${SERVICE_NAME}" "FusionOperateInsights-User" "pull"
            addGitHubTeamToRepo "${PROJECT}-${SERVICE_NAME}" "${PROJECT}-Architect" "maintain"
            addGitHubTeamToRepo "${PROJECT}-${SERVICE_NAME}" "${PROJECT}-Developer" "push"
            addGitHubTeamToRepo "${PROJECT}-${SERVICE_NAME}" "${PROJECT}-ProductOwner" "triage"
            addGitHubTeamToRepo "${PROJECT}-${SERVICE_NAME}" "${PROJECT}-Stakeholder" "triage"
            if [[ $NO_DEPLOYMENT != "true" ]]; then
                if [[ $(shouldDeployPipelinesBeCreated) = yes ]]; then
                    createDeployPipeline develop
                    if [[ $NO_MASTER_DEPLOYMENT != "true" ]]; then
                        createDeployPipeline master
                    fi
                fi
            fi
            if [ $SERVICE_TYPE != "deployment" ] && [ $SERVICE_TYPE != "trigger" ]; then
                buildIdMaster=$(queueMasterBuild $pipelineId)
            else
                echo "Skipping queueing of master build pipeline"
            fi
            if [ $SERVICE_TYPE != "deployment" ] && [ $SERVICE_TYPE != "trigger" ]; then
                buildIdDevelop=$(queueDevelopBuild $pipelineId $buildIdMaster)
                waitForBuildsCompletion $buildIdMaster $buildIdDevelop
            else
                echo "Skipping queueing of develop build pipeline"
            fi
            if [[ $NO_POLICIES != "true" ]]; then
                for policy_branch in $POLICY_BRANCHES; do
                    createGithubBranchRule "$repoInfos" "$policy_branch"
                done
            fi
        fi
        ;;
    *)
        echo "ERROR: Please specify supported git provider: azdo or github"
        exit 1
        ;;
esac

echo "DONE"

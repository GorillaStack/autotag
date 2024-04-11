#!/usr/bin/env bash

set -e

BoldText=$(tput bold)
NormalText=$(tput sgr0)

function build-package () {
  local BUILD_TYPE="$1"

  if [ -n "$DEV_MODE" ] ; then
    npm run test
    npm run lint
  fi

  npm run compile

  cp package.json lib/
  npm install --no-optional --omit=dev --prefix lib/

  (
    cd lib
    zip -x\*.zip -qr9 "autotag-${BUILD_TYPE}.zip" -- *
  )
}

function upload-package () {
  local BUILD_TYPE="$1"

  echo "Uploading '${TEMP_DIR}/lib/autotag-${BUILD_TYPE}.zip' to 's3://${S3_BUCKET}/${S3_PATH}'"

  aws s3 cp $S3_AWS_CREDENTIALS -- "lib/autotag-${BUILD_TYPE}.zip" "s3://${S3_BUCKET}/${S3_PATH}"
}

function manage-bucket () {

  local ACTION="$1"
#  local CAPITALIZED_ACTION="${ACTION^}"

  BUCKET_OWNER=$(aws s3api list-buckets $S3_AWS_CREDENTIALS | jq -r '.Buckets[] | select(.Name == "'$S3_BUCKET'")')

  if [[ -n $BUCKET_OWNER ]] ; then # S3 Bucket exists

    if [ "$ACTION" == 'create' ] ; then

      echo "The ${S3_BUCKET} S3 Bucket already exists, skipping bucket create"

    elif [ "$ACTION" == 'delete' ] ; then

      echo -e "\nThe ${S3_BUCKET} S3 Bucket still exists, delete this bucket manually if it won't be used again."

#    elif [ "$ACTION" == 'delete' ] ; then
#
#      echo "The ${S3_BUCKET} S3 Bucket exists, deleting bucket"
#
#      while true ; do
#        read -rp "Are you user you want to delete the ${S3_BUCKET} S3 Bucket (yes/no)? " DELETE_BUCKET_ANSWER
#        if [[ $DELETE_BUCKET_ANSWER =~ ^(Yes|yes)$ ]] ; then
#          break
#        else
#          echo "Retaining the ${S3_BUCKET} S3 Bucket"
#          return
#        fi
#      done
#
#      echo "Deleting the ${S3_BUCKET} S3 Bucket..."
#
#      aws s3api delete-bucket $S3_AWS_CREDENTIALS --bucket "$S3_BUCKET" --region "$MAIN_STACK_AWS_REGION"
    fi
  else
    if [ "$ACTION" == 'create' ] ; then
      echo "The ${S3_BUCKET} S3 Bucket does not exist for this profile, creating bucket"

      echo "Creating the ${S3_BUCKET} secure S3 Bucket with all public access blocked..."

      if [ "$MAIN_STACK_AWS_REGION" != 'us-east-1' ] ; then
        local LOCATION_CONSTRAINT="--create-bucket-configuration LocationConstraint=$MAIN_STACK_AWS_REGION"
      fi

      aws s3api create-bucket $S3_AWS_CREDENTIALS --bucket "$S3_BUCKET" --region "$MAIN_STACK_AWS_REGION" $LOCATION_CONSTRAINT
      # block all public access to the new S3 bucket
      aws s3api put-public-access-block $S3_AWS_CREDENTIALS --bucket "$S3_BUCKET" --region "$MAIN_STACK_AWS_REGION" \
          --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    fi
  fi

  if [ "$ACTION" == 'create' ] ; then
    # check if the configuration requires a S3 bucket policy to allow cross-account access
    if [ "$AWS_CREDENTIALS" != "$S3_AWS_CREDENTIALS" ]; then
      AWS_ACCOUNT_ID=$(aws sts get-caller-identity $AWS_CREDENTIALS | jq -r '.Account')
      S3_ACCOUNT_ID=$(aws sts get-caller-identity $S3_AWS_CREDENTIALS | jq -r '.Account')

      if [ "$AWS_ACCOUNT_ID" != "$S3_ACCOUNT_ID" ] ; then
        set +e
        S3_BUCKET_POLICY=$(aws s3api get-bucket-policy $S3_AWS_CREDENTIALS --bucket "$S3_BUCKET" --output text 2> /dev/null | jq )
        if [ -n "$S3_BUCKET_POLICY" ] ; then
          S3_BUCKET_POLICY_ACCESS_EXISTS=$(echo "$S3_BUCKET_POLICY" | jq -r '.Statement[] | select(.Principal.AWS | contains("'$AWS_ACCOUNT_ID'"))' 2> /dev/null)
        fi
        set -e

        if [ -n "$S3_BUCKET_POLICY" ] && [ -z "$S3_BUCKET_POLICY_ACCESS_EXISTS" ] ; then
          S3_BUCKET_POLICY_STATEMENT=$(cat <<EOF
{
    "Sid": "AllowAccountId${AWS_ACCOUNT_ID}",
    "Effect": "Allow",
    "Principal": {
        "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root"
    },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
}
EOF
          )

          # append the new account to the existing bucket policy
          S3_BUCKET_POLICY_UPDATED=$(echo "$S3_BUCKET_POLICY" | jq -r '.Statement += ['"$S3_BUCKET_POLICY_STATEMENT"']')

        elif [ -z "$S3_BUCKET_POLICY" ] ; then # this is a brand new bucket policy
          S3_BUCKET_POLICY_UPDATED=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Id": "Policy1475613436714",
    "Statement": [
        {
            "Sid": "AllowAccountId${AWS_ACCOUNT_ID}",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
        }
    ]
}
EOF
          )
        fi

        if [ -n "$S3_BUCKET_POLICY_UPDATED" ] ; then
          echo "Adding AWS account ID ${AWS_ACCOUNT_ID} to the ${S3_BUCKET} S3 Bucket policy to allow cross-account access"
          echo -e "Applying UPDATED Bucket Policy: \n$S3_BUCKET_POLICY_UPDATED\n"

          aws s3api put-bucket-policy $S3_AWS_CREDENTIALS --bucket "$S3_BUCKET" --policy "$S3_BUCKET_POLICY_UPDATED"
        fi
      fi
    fi
  fi
}

function select-release-version () {
  if [ -z "$RELEASE_VERSION" ] ; then
    local GITHUB_RELEASES
    local LATEST_VERSION
    GITHUB_RELEASES=$(curl -sS "$GITHUB_API_RELEASES_URL")
    LATEST_VERSION=$(curl -sS "$GITHUB_API_LATEST_URL" | jq -r '.name')

    while true ; do
      read -rp "Which release version would you like to deploy? [$LATEST_VERSION]: " RELEASE_VERSION
      if [[ $(echo "$GITHUB_RELEASES" | jq -er ".[] | select(.name==\"$RELEASE_VERSION\")") ]] ; then
        break
      elif [[ -z "$RELEASE_VERSION" ]] ; then
        RELEASE_VERSION="$LATEST_VERSION"
        break
      else
        echo -e "\nCouldn't find release version '$RELEASE_VERSION' on GitHub"

        echo "Here is the list of release versions:"
        echo "$GITHUB_RELEASES" | jq -r '.[].name'
        echo
        continue
      fi
    done
  elif [ "$RELEASE_VERSION" == 'latest' ]; then
    RELEASE_VERSION=$(curl -sS "$GITHUB_API_LATEST_URL" | jq -r '.name')
  fi
}

function cf-parameters () {
  # If we rename or delete parameters from the CF template, do not remove them from this list,
  # logic below keeps this list backward-compatible for older CF templates
  CF_PARAMETERS=$(cat <<EOF
    [
      {
        "ParameterKey": "CodeS3Bucket",
        "ParameterValue": "$S3_BUCKET"
      },
      {
        "ParameterKey": "CodeS3Path",
        "ParameterValue": "$S3_PATH"
      },
      {
        "ParameterKey": "AutoTagDebugLogging",
        "ParameterValue": "$LOG_LEVEL_DEBUG"
      },
      {
        "ParameterKey": "AutoTagTagsCreateTime",
        "ParameterValue": "$CREATE_TIME"
      },
      {
        "ParameterKey": "AutoTagTagsInvokedBy",
        "ParameterValue": "$INVOKED_BY"
      },
      {
        "ParameterKey": "LogRetentionInDays",
        "ParameterValue": "$LOG_RETENTION_DAYS"
      },
      {
        "ParameterKey": "CustomTags",
        "ParameterValue": "${CUSTOM_TAGS//\"/\\\"}"
      }
    ]
EOF
  )

  TEMPLATE_PARAMETER_KEYS=$(echo "$MAIN_TEMPLATE" | jq -r '.Parameters | [keys[]]')

  # For backward-compatibility remove any CF_PARAMETERS that don't exist in the MAIN_TEMPLATE that has been selected
  CF_PARAMETERS=$(echo "$CF_PARAMETERS" | jq --argjson tpk "$TEMPLATE_PARAMETER_KEYS" -r '[.[] | select( .[] as $in | $tpk | index($in))]')
}

function wait-for-stack () {

  local STACK_PREFIX="$1"
  local STACK_NAME="$2"
  local STACK_AWS_REGION="$3"

  echo "${STACK_PREFIX} CloudFormation Stack in $STACK_AWS_REGION has been created, waiting for completion..."

  STACK_STATUS_COMMAND=(aws cloudformation describe-stacks $AWS_CREDENTIALS --stack-name "$STACK_NAME" --region "$STACK_AWS_REGION")

  STACK_STATUS=$(${STACK_STATUS_COMMAND[@]} | jq -r '.Stacks[].StackStatus')

  until [[ $STACK_STATUS =~ ^(CREATE|UPDATE)_COMPLETE$ ]] || [[ -z "$STACK_STATUS" ]] ; do

    echo "${STACK_PREFIX} CloudFormation Stack Status: $STACK_STATUS"

    sleep 30
    STACK_STATUS=$(${STACK_STATUS_COMMAND[@]} | jq -r '.Stacks[].StackStatus')
  done

  echo "${STACK_PREFIX} CloudFormation Stack completed with Status: $STACK_STATUS"
}

function manage-stacks () {

  local ACTION="$1"
  local MANAGE_RELEASE_VERSION="$2"
  local TEMP_DIR

  # Deploy Main CloudFormation Template

  if [ "$ACTION" == "create" ] ; then
    TEMP_DIR=$(mktemp -d)
    RELEASES=$(curl -sS "$GITHUB_API_RELEASES_URL")
    RELEASE_COMMIT=$(curl -sS "${GITHUB_API_TAG_URL}/${MANAGE_RELEASE_VERSION}" | jq -r '.object.sha')
    RELEASE_URL_QUERY=$(cat <<EOF
      .[] | select(.name = "$MANAGE_RELEASE_VERSION") |
      .assets[] | select( .name == "autotag-$MANAGE_RELEASE_VERSION.zip") |
      .browser_download_url
EOF
    )
    RELEASE_ZIP_FILE_URL=$(echo "$RELEASES" | jq -r "$RELEASE_URL_QUERY")

    echo "Initializing AutoTag release version $MANAGE_RELEASE_VERSION"

    (
      cd "$TEMP_DIR"
      if ! [[ $(aws s3 ls $S3_AWS_CREDENTIALS "s3://$S3_BUCKET/releases/autotag-$MANAGE_RELEASE_VERSION.zip") ]] ; then
        curl -sS -LO "$RELEASE_ZIP_FILE_URL" # Download the release ZIP
        aws s3 cp $S3_AWS_CREDENTIALS "autotag-$MANAGE_RELEASE_VERSION.zip" "s3://$S3_BUCKET/releases/autotag-$MANAGE_RELEASE_VERSION.zip"
      fi
    )

    rm -rf "$TEMP_DIR"

    ZIP_FILE="autotag-$MANAGE_RELEASE_VERSION.zip"
    S3_PATH="releases/$ZIP_FILE"

    # TODO: this doesn't work before v0.5.1 because the JSON template wasn't in the repo
    MAIN_TEMPLATE=$(curl -sS ${GITHUB_URL}/${RELEASE_COMMIT}/cloud_formation/event_multi_region_template/autotag_event_main-template.json)

    echo "Creating the Main CloudFormation Stack..."

    cf-parameters

    aws cloudformation create-stack \
      $AWS_CREDENTIALS \
      --template-body "$MAIN_TEMPLATE" \
      --stack-name "$MAIN_STACK_NAME" \
      --region "$MAIN_STACK_AWS_REGION" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameters "$CF_PARAMETERS"

    wait-for-stack 'Main' "$MAIN_STACK_NAME" "$MAIN_STACK_AWS_REGION"

  elif [ "$ACTION" == "delete" ] ; then

    echo "Deleting the Main CloudFormation Stack"

    aws cloudformation delete-stack \
      $AWS_CREDENTIALS \
      --stack-name "$MAIN_STACK_NAME" \
      --region "$MAIN_STACK_AWS_REGION"
  fi

  # Deploy Collector CloudFormation Template

  [[ -z $ACTIVE_REGIONS ]] && ACTIVE_REGIONS=$(aws ec2 describe-regions $AWS_CREDENTIALS --region "$MAIN_STACK_AWS_REGION" | jq -r '.Regions | sort_by(.RegionName) | .[].RegionName')

  for REGION in $ACTIVE_REGIONS ; do

    if [ "$ACTION" == "create" ] ; then

      echo "Creating the Collector CloudFormation Stack in $REGION..."

      COLLECTOR_TEMPLATE=$(curl -sS ${GITHUB_URL}/${RELEASE_COMMIT}/cloud_formation/event_multi_region_template/autotag_event_collector-template.json)

      aws cloudformation create-stack \
        $AWS_CREDENTIALS \
        --template-body "$COLLECTOR_TEMPLATE" \
        --stack-name "$COLLECTOR_STACK_NAME" \
        --region "$REGION" \
        --capabilities CAPABILITY_IAM \
        --parameters \
            ParameterKey=MainAwsRegion,ParameterValue=$MAIN_STACK_AWS_REGION

    elif [ "$ACTION" == "delete" ] ; then

      echo "Deleting the Collector CloudFormation Stack in $REGION"

      aws cloudformation delete-stack \
        $AWS_CREDENTIALS \
        --stack-name "$COLLECTOR_STACK_NAME" \
        --region "$REGION"
    fi
  done

  if [ "$ACTION" == "delete" ] ; then
    wait-for-stack 'Main' "$MAIN_STACK_NAME" "$MAIN_STACK_AWS_REGION"
  fi

  for REGION in $ACTIVE_REGIONS ; do
    wait-for-stack 'Collector' "$COLLECTOR_STACK_NAME" "$REGION"
  done
}

# create a way to deploy a release to existing stacks
function update-stacks () {

  local UPDATE_RELEASE_VERSION="$1"
  local TEMP_DIR
  TEMP_DIR=$(mktemp -d)

  if [ "$UPDATE_RELEASE_VERSION" == 'master' ] ; then
    ZIP_FILE="autotag-master-$(date +%s).zip"
    S3_PATH="master-build/$ZIP_FILE"

    (
      cd "$TEMP_DIR"
      git clone --depth 1 "https://github.com/$REPO_NAME.git"
      echo

      cd auto-tag
      npm install

      build-package  'master'
      upload-package 'master'
    )

  elif [ "$UPDATE_RELEASE_VERSION" == 'local' ] ; then
    ZIP_FILE="autotag-local-$(date +%s).zip"
    S3_PATH="local-build/$ZIP_FILE"

    build-package  'local'
    upload-package 'local'

  else # this should be a release version
    RELEASES=$(curl -sS "$GITHUB_API_RELEASES_URL")
    RELEASE_COMMIT=$(curl -sS "${GITHUB_API_TAG_URL}/${UPDATE_RELEASE_VERSION}" | jq -r '.object.sha')
    RELEASE_URL_QUERY=$(cat <<EOF
      .[] | select(.name = "$UPDATE_RELEASE_VERSION") |
      .assets[] | select( .name == "autotag-$UPDATE_RELEASE_VERSION.zip") |
      .browser_download_url
EOF
    )
    RELEASE_ZIP_FILE_URL=$(echo "$RELEASES" | jq -r "$RELEASE_URL_QUERY")

    echo "Initializing AutoTag release version $UPDATE_RELEASE_VERSION"

    (
      cd "$TEMP_DIR"
      if ! [[ $(aws s3 ls $S3_AWS_CREDENTIALS "s3://$S3_BUCKET/releases/autotag-$UPDATE_RELEASE_VERSION.zip") ]] ; then
        curl -sS -LO "$RELEASE_ZIP_FILE_URL" # Download the release ZIP
        aws s3 cp $S3_AWS_CREDENTIALS "autotag-$UPDATE_RELEASE_VERSION.zip" "s3://$S3_BUCKET/releases/autotag-$UPDATE_RELEASE_VERSION.zip"
      fi
    )

    ZIP_FILE="autotag-$UPDATE_RELEASE_VERSION.zip"
    S3_PATH="releases/$ZIP_FILE"
  fi

  rm -rf "$TEMP_DIR"

  if [ "$UPDATE_RELEASE_VERSION" == 'master' ] ; then
    MAIN_TEMPLATE=$(curl -sS "${GITHUB_URL}/master/cloud_formation/event_multi_region_template/autotag_event_main-template.json")
    COLLECTOR_TEMPLATE=$(curl -sS "${GITHUB_URL}/master/cloud_formation/event_multi_region_template/autotag_event_collector-template.json")
  elif [ "$UPDATE_RELEASE_VERSION" == 'local' ] ; then
    MAIN_TEMPLATE=$(<cloud_formation/event_multi_region_template/autotag_event_main-template.json)
    COLLECTOR_TEMPLATE=$(<cloud_formation/event_multi_region_template/autotag_event_collector-template.json)
  else # this should be a release version
    MAIN_TEMPLATE=$(curl -sS "${GITHUB_URL}/${RELEASE_COMMIT}/cloud_formation/event_multi_region_template/autotag_event_main-template.json")
    COLLECTOR_TEMPLATE=$(curl -sS "${GITHUB_URL}/${RELEASE_COMMIT}/cloud_formation/event_multi_region_template/autotag_event_collector-template.json")
  fi

  echo "Updating the Main CloudFormation Stack..."

  cf-parameters

  MAIN_STACK_FAIL_FILE=$(mktemp)

  set +e
  2> "$MAIN_STACK_FAIL_FILE" \
  aws cloudformation update-stack \
    $AWS_CREDENTIALS \
    --template-body "$MAIN_TEMPLATE" \
    --stack-name "$MAIN_STACK_NAME" \
    --region "$MAIN_STACK_AWS_REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters "$CF_PARAMETERS"

  set -e
  MAIN_STACK_FAILURE=$(<$MAIN_STACK_FAIL_FILE)
  rm -f "$MAIN_STACK_FAIL_FILE"

  MAIN_STACK_FAILURE_PATTERN="^.*ValidationError.*No updates are to be performed\.$"

  if [[ -n $MAIN_STACK_FAILURE ]] && [[ ! "$MAIN_STACK_FAILURE" =~ $MAIN_STACK_FAILURE_PATTERN ]] ; then
    echo "$MAIN_STACK_FAILURE"
    exit 1
  fi

  wait-for-stack 'Main' "$MAIN_STACK_NAME" "$MAIN_STACK_AWS_REGION"

  [[ -z $ACTIVE_REGIONS ]] && ACTIVE_REGIONS=$(aws ec2 describe-regions $AWS_CREDENTIALS --region "$MAIN_STACK_AWS_REGION" | jq -r '.Regions[].RegionName')

  for REGION in $ACTIVE_REGIONS ; do

    echo "Updating the Collector CloudFormation Stack in $REGION..."

    COLLECTOR_STACK_FAIL_FILE=$(mktemp)

    set +e
    2> "$COLLECTOR_STACK_FAIL_FILE" \
    aws cloudformation update-stack \
      $AWS_CREDENTIALS \
      --template-body "$COLLECTOR_TEMPLATE" \
      --stack-name "$COLLECTOR_STACK_NAME" \
      --region "$REGION" \
      --capabilities CAPABILITY_IAM \
      --parameters \
          ParameterKey=MainAwsRegion,ParameterValue=$MAIN_STACK_AWS_REGION

    set -e
    COLLECTOR_STACK_FAILURE=$(<$COLLECTOR_STACK_FAIL_FILE)
    rm -f "$COLLECTOR_STACK_FAIL_FILE"

    COLLECTOR_STACK_FAILURE_PATTERN="^.*ValidationError.*No updates are to be performed\.$"

    if [[ -n $COLLECTOR_STACK_FAILURE ]] && [[ ! "$COLLECTOR_STACK_FAILURE" =~ $COLLECTOR_STACK_FAILURE_PATTERN ]] ; then
      echo "$COLLECTOR_STACK_FAILURE"
      exit 1
    fi
  done

  for REGION in $ACTIVE_REGIONS ; do
    wait-for-stack 'Collector' "$COLLECTOR_STACK_NAME" "$REGION"
  done
}


function print-header () {
  echo -e "******\n****** ${BoldText}${1}${NormalText}\n******\n"
}

function command_exists () {
    type "$1" &> /dev/null ;
}

function check-min-dependencies () {

  if [ "${BASH_VERSINFO[0]}" -lt "$MIN_BASH_VERSION" ] || [[ "${BASH_VERSINFO[0]}" -eq "$MIN_BASH_VERSION" && "${BASH_VERSINFO[1]}" -lt "$MIN_BASH_MINOR_VERSION" ]] ; then
    echo "Bash version $BASH_VERSION is unsupported, Bash must be at version $MIN_BASH_VERSION.$MIN_BASH_MINOR_VERSION or greater."
    exit 1
  fi

  # detect platform
  if [[ $(uname | cut -d_ -f1) == 'Darwin' ]] ; then
    PLATFORM='macos'
  elif command_exists 'yum' ; then
    PLATFORM='redhat'
  elif command_exists 'apt' ; then
    PLATFORM='debian'
  else
    echo "Supported platform not detected: macOS, redhat, debian/ubuntu"
    echo -e "Install the dependencies manually: jq, aws-cli, git, npm, and zip\n"
    return 0
  fi

  # checking for jq
  if ! command_exists 'jq' ; then
    echo "Command 'jq' is missing, installing it now..."

    if [ "$PLATFORM" == 'macos' ] ; then
      if command_exists 'brew' ; then
        brew install jq
      else
        echo "Error: Install Homebrew (https://brew.sh) and try again."
        exit 1
      fi
    elif [ "$PLATFORM" == 'redhat' ] ; then
      sudo yum install -y jq
    elif [ "$PLATFORM" == 'debian' ] ; then
      sudo apt install -y jq
    fi
  fi

  # checking for the aws cli
  if ! command_exists 'aws' ; then
    echo "Command 'aws' is missing, installing it now..."

    if command_exists 'pip3' ; then
      if [ "$PLATFORM" == 'macos' ] ; then
        pip3 install awscli --user
      elif [ "$PLATFORM" == 'debian' ] ; then
        sudo apt install -y awscli
      elif [ "$PLATFORM" == 'redhat' ] ; then
        sudo pip3 install awscli
      fi
    else
      if command_exists 'python3' ; then
        if [ "$PLATFORM" == 'macos' ] ; then
          curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
          python3 /tmp/get-pip.py
          rm -f /tmp/get-pip.py
          pip3 install awscli --user
        elif [ "$PLATFORM" == 'debian' ] ; then
          sudo apt install -y awscli
        elif [ "$PLATFORM" == 'redhat' ] ; then
          curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
          sudo python3 /tmp/get-pip.py
          rm -f /tmp/get-pip.py
          sudo pip3 install awscli
        fi
      else
        echo "Error: Install python and try again."
        exit 1
      fi
    fi
  fi
  echo
}

function check-build-dependencies () {
  # checking for git
  if ! command_exists 'git' ; then
    echo "Command 'git' is missing, installing it now..."

    if [ "$PLATFORM" == 'macos' ] ; then
      if command_exists 'brew' ; then
        brew install git
      else
        echo "Error: Install Homebrew (https://brew.sh) and try again."
        exit 1
      fi
    elif [ "$PLATFORM" == 'redhat' ] ; then
      sudo yum install -y git
    elif [ "$PLATFORM" == 'debian' ] ; then
      sudo apt install -y git
    fi
  fi

  # checking for npm
  if ! command_exists 'npm' ; then
    echo "Command 'npm' is missing, installing it now..."

    if [ "$PLATFORM" == 'macos' ] ; then
      if command_exists 'brew' ; then
        brew install npm
      else
        echo "Error: Install Homebrew (https://brew.sh) and try again."
        exit 1
      fi
    elif [ "$PLATFORM" == 'redhat' ] ; then
      if command_exists 'amazon-linux-extras' ; then
        sudo amazon-linux-extras install -y epel
        sudo yum install -y npm
      else
        sudo yum install -y npm
      fi
    elif [ "$PLATFORM" == 'debian' ] ; then
      sudo apt install -y npm
    fi
  fi

  # checking for zip
  if ! command_exists 'zip' ; then
    echo "Command 'zip' is missing, installing it now..."

    if [ "$PLATFORM" == 'macos' ] ; then
      if command_exists 'brew' ; then
        brew install zip
      else
        echo "Error: Install Homebrew (https://brew.sh) and try again."
        exit 1
      fi
    elif [ "$PLATFORM" == 'redhat' ] ; then
      sudo yum install -y zip
    elif [ "$PLATFORM" == 'debian' ] ; then
      sudo apt install -y zip
    fi
  fi
}

function show-help {
  cat <<- EOF
Usage: $(basename "$0") [options] <command>

Commands:
    create                    Create the AutoTag infrastructure
    delete                    Delete the AutoTag infrastructure
    update-release            Update the AutoTag infrastructure with a specific release version
    update-master             Update the AutoTag infrastructure with the latest from the master branch
    update-local              Update the AutoTag infrastructure with the local source code

Options:
    -h   --help                  Show this screen
    -r   --region                The primary AWS region where the main CloudFormation stack will be deployed
    -p   --profile               The main AWS credential profile
    -s3bu --s3-bucket            The S3 bucket where the code package will be uploaded
    -s3pr --s3-profile           A separate AWS credential profile to upload code packages to the S3 Bucket
    -rv   --release-version      The release version to deploy, e.g. '0.5.2' or 'latest'
    -cr   --collector-regions    Regions where the collector CloudFormation stack will be deployed (space separated)

    -lr   --log-retention-days   The number of days to retain the Lambda Function's logs (default: 90)
    -ld   --log-level-debug      Enable the debug logging for the Lambda Function
    -dct  --disable-create-time  Disable the 'CreateTime' tagging for all AWS resources
    -dib  --disable-invoked-by   Disable the 'InvokedBy' tagging for all AWS resources
    -ct   --custom-tags          Define custom tags in a JSON document

EOF
  exit 0
}

PARAMS=''
ACTIVE_REGIONS=''
while (( "$#" )); do
  case "$1" in
    -h|--help)
      show-help
      ;;
    -p|--profile)
      export PROFILE=$2
      shift 2
      ;;
    -r|--region)
      export MAIN_STACK_AWS_REGION=$2
      shift 2
      ;;
    -s3pr|--s3-profile)
      export S3_PROFILE=$2
      shift 2
      ;;
    -s3bu|--s3-bucket)
      export S3_BUCKET=$2
      shift 2
      ;;
    -rv|--release-version)
      export RELEASE_VERSION=$2
      shift 2
      ;;
    -cr|--collector-regions)
      while [[ $2 != -* && $# -gt 1 ]]; do
        ACTIVE_REGIONS="$ACTIVE_REGIONS $2"
        shift
      done
      ACTIVE_REGIONS="${ACTIVE_REGIONS#"${ACTIVE_REGIONS%%[![:space:]]*}"}"
      shift
      ;;
    -lr|--log-retention-days)
      export LOG_RETENTION_DAYS=$2
      shift 2
      ;;
    -ld|--log-level-debug)
      export LOG_LEVEL_DEBUG=Enabled
      shift 1
      ;;
    -dct|--disable-create-time)
      export CREATE_TIME=Disabled
      shift 1
      ;;
    -dib|--disable-invoked-by)
      export INVOKED_BY=Disabled
      shift 1
      ;;
    -ct|--custom-tags)
      export CUSTOM_TAGS="$2"
      shift 2
      ;;
    -d|--dev)
      export DEV_MODE=true
      shift 1
      ;;
    -b|--no-banner)
      export NO_BANNER=true
      shift 1
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*|--*=) # unsupported flags
      echo "Error: Unsupported flag $1" >&2
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done
# set positional arguments in their proper place
eval set -- "$PARAMS"
PARAMS=($PARAMS)
COMMAND=${PARAMS[0]}

# no command params were sent or help
if [[ -z $PARAMS ]] || [ "$COMMAND" == 'help' ] ; then
  show-help
fi

if [[ -z "$NO_BANNER" ]] ; then
  cat << "EOF"
    _______       __         _______
   |   _   .--.--|  |_.-----|       .---.-.-----.
   |.  1   |  |  |   _|  _  |.|   | |  _  |  _  |
   |.  _   |_____|____|_____`-|.  |-|___._|___  |
   |:  |   |                  |:  |       |_____|
   |::.|:. |                  |::.|
   `--- ---'                  `---'

EOF
fi

MIN_BASH_VERSION='4'
MIN_BASH_MINOR_VERSION='3'
REPO_NAME='GorillaStack/auto-tag'
MAIN_STACK_NAME='AutoTag'
COLLECTOR_STACK_NAME="${MAIN_STACK_NAME}-Collector"

GITHUB_URL="https://raw.githubusercontent.com/$REPO_NAME"
GITHUB_API_RELEASES_URL="https://api.github.com/repos/$REPO_NAME/releases"
GITHUB_API_LATEST_URL="https://api.github.com/repos/$REPO_NAME/releases/latest"
GITHUB_API_TAG_URL="https://api.github.com/repos/$REPO_NAME/git/ref/tags"

# primary credentials
[ -n "$PROFILE" ] && AWS_CREDENTIALS="--profile $PROFILE"

# separate S3 credentials
if [ -n "$S3_PROFILE" ] ; then
  S3_AWS_CREDENTIALS="--profile $S3_PROFILE"
else
  S3_AWS_CREDENTIALS="$AWS_CREDENTIALS"
fi

# CF template defaults
[ -z "$LOG_RETENTION_DAYS" ] && export LOG_RETENTION_DAYS=90
[ -z "$LOG_LEVEL_DEBUG" ]    && export LOG_LEVEL_DEBUG=Disabled
[ -z "$CREATE_TIME" ] && export CREATE_TIME=Enabled
[ -z "$INVOKED_BY" ]  && export INVOKED_BY=Enabled
[ -z "$CUSTOM_TAGS" ] && export CUSTOM_TAGS=''

check-min-dependencies

if [ "$COMMAND" == 'create' ] ; then
  print-header 'Create Stacks'
  select-release-version
  manage-bucket 'create'
  manage-stacks 'create' "$RELEASE_VERSION"

elif [ "$COMMAND" == 'delete' ] ; then
  print-header  'Delete Stacks'
  manage-stacks 'delete'
  manage-bucket 'delete'

elif [ "$COMMAND" == 'update-release' ] ; then
  print-header 'Update Stacks with a git release'
  select-release-version
  update-stacks "$RELEASE_VERSION"

elif [ "$COMMAND" == 'update-master' ] ; then
  check-build-dependencies
  print-header  'Update Stacks from master'
  update-stacks 'master'

elif [ "$COMMAND" == 'update-local' ] ; then
  check-build-dependencies
  print-header  'Update Stacks from the local repo'
  update-stacks 'local'

fi

echo "The AutoTag deployment is complete"

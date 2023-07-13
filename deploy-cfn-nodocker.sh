#!/bin/bash

get_short_term_credentials() {
    AWS_ACCESS_KEY=$(grep -A6 "\[${SHORT_AWS_PROFILE}\]" ~/.aws/credentials | grep aws_access_key_id | awk '{print $NF}')
    AWS_SECRET_KEY=$(grep -A6 "\[${SHORT_AWS_PROFILE}\]" ~/.aws/credentials | grep aws_secret_access_key | awk '{print $NF}')
    AWS_SECURITY_TOKEN=$(grep -A6 "\[${SHORT_AWS_PROFILE}\]" ~/.aws/credentials | grep aws_session_token | awk '{print $NF}')
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY
    AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY
    AWS_SESSION_TOKEN=$AWS_SECURITY_TOKEN
    export AWS_ACCESS_KEY AWS_SECRET_KEY AWS_SECURITY_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

get_long_term_credentials() {
    AWS_ACCESS_KEY=$(grep -A2 "\[${LONG_AWS_PROFILE}\]" ~/.aws/credentials | grep aws_access_key_id | awk '{print $NF}')
    AWS_SECRET_KEY=$(grep -A2 "\[${LONG_AWS_PROFILE}\]" ~/.aws/credentials | grep aws_secret_access_key | awk '{print $NF}')
    AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY
    AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY
    export AWS_ACCESS_KEY AWS_SECRET_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

get_aws_account_name() {
  local aws_account_id=$(get_aws_account_id)
  local account_name=$(cat accounts.json \
    | jq --arg id "${aws_account_id}" -r '.Accounts[] | select(.Id==$id) | .Name')
  echo "${account_name}"
}

get_aws_account_id() {
  local aws_account_name=$1
  local account_id=$(cat accounts.json \
    | jq --arg name "${aws_account_name}" -r '.Accounts[] | select(.Name==$name) | .Id')
  echo "${account_id}"
}

get_aws_account_rolename() {
  local aws_account_name=$1
  local role_name=$(cat accounts.json \
    | jq --arg name "${aws_account_name}" -r '.Accounts[] | select(.Name==$name) | .RoleName')
  echo "${role_name}"
}

assume_role() {
    local AWS_ACCOUNT_ID=$(get_aws_account_id "${AWS_ACCOUNT}")
    echo "Using $AWS_ACCOUNT_ID AWS Account ID"
    local AWS_ROLE_TO_ASSUME=$(get_aws_account_rolename "${AWS_ACCOUNT}")

    local ROLE_ARN_TO_ASSUME="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AWS_ROLE_TO_ASSUME}"
    local IDENTITY_SESSION=$(aws sts get-caller-identity | jq -r '.Arn' | awk -F'/' '{print $NF}')
    local ROLE_SESSION_NAME="${IDENTITY_SESSION}@$(date +%s)"
    local LOCAL_PROFILE=()
    if [ "z${LONG_AWS_PROFILE}" != "z" ]; then
      LOCAL_PROFILE+=("--profile")
      LOCAL_PROFILE+=("${LONG_AWS_PROFILE}")
    fi
    local ASSUMED_CREDENTIALS=$(aws sts assume-role ${LOCAL_PROFILE[@]} --region us-west-1 \
        --role-arn "${ROLE_ARN_TO_ASSUME}" \
        --role-session-name "${ROLE_SESSION_NAME}")

    # AWS CLI
    AWS_ACCESS_KEY_ID=$(echo ${ASSUMED_CREDENTIALS} | jq -r '.Credentials.AccessKeyId')
    AWS_SECRET_ACCESS_KEY=$(echo ${ASSUMED_CREDENTIALS} | jq -r '.Credentials.SecretAccessKey')
    AWS_SESSION_TOKEN=$(echo ${ASSUMED_CREDENTIALS} | jq -r '.Credentials.SessionToken')
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    echo "Assumed AWS_ACCESS_KEY_ID is $AWS_ACCESS_KEY_ID"
}

launch() {
    local SCRIPT_ACTION=$1
    local CFN_CONFIG=$2
    cd sceptre/

    local STACK_NAME=$(echo ${CFN_CONFIG} | cut -d'.' -f1)

    if [ "z${SCRIPT_ACTION}" == "zdeploy" ]; then
        ACTION="launch -y"
    elif [ "z${SCRIPT_ACTION}" == "zdestroy" ]; then
        ACTION="delete -y"
    elif [ "z${SCRIPT_ACTION}" == "zgenerate" ]; then
        ACTION="generate"
    else
      echo "Invalid action. You need to define action as"
      echo "$0 -n <action>"
      echo "Where valid actions are choice of deploy, destroy, generate."
    fi

    if [ "z${DRY_RUN}" == "z" -o "z${DRY_RUN}" == "zfalse" ]; then
        echo "[Calling:]"
        echo "sceptre \
          ${ARG_ARRAY[@]} \
          ${ACTION} ${CFN_CONFIG}"
        sceptre \
          "${ARG_ARRAY[@]}" \
          ${ACTION} ${CFN_CONFIG}
    fi
    EXIT_STATUS=$?
    cd ../
    exit ${EXIT_STATUS}

}

parse_arguments() {
    while (( "$#" )); do
      case "$1" in
        -a|--account)
          AWS_ACCOUNT=$2
          shift 2
          ;;
        -l|--long-term-profile)
          LONG_AWS_PROFILE=$2
          # Only a user would have long term profile.
          # User would need to assume the role called user_assumerole
          AWS_ROLE_TO_ASSUME=user_assumerole
          shift 2
          ;;
        -s|--short-term-profile)
          SHORT_AWS_PROFILE=$2
          shift 2
          ;;
        -e|--extra-vars)
          ARG_ARRAY+=("--var" "${2}")
          shift 2
          ;;
        -f|--var-file)
          ARG_ARRAY+=("--var-file" "./vars/${2}")
          shift 2
          ;;
        -n|--action)
          SCRIPT_ACTION=$2
          shift 2
          ;;
        -i|--item)
          CFN_CONFIG=$2
          shift 2
          ;;
        -d|--dry-run)
          DRY_RUN=$2
          shift 2
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
}

get_template() {
  local TEMPLATE_VER=0.1.7
  local CURRENT_DIR=$(pwd)
  curl -L -s "https://github.com/harisfauzi/shared-sceptre-template/archive/refs/tags/v${TEMPLATE_VER}.tar.gz" | tar xzf -
  (cd "${CURRENT_DIR}/shared-sceptre-template-${TEMPLATE_VER}/templates"; tar cf - .) | (cd "${CURRENT_DIR}/sceptre/templates"; tar xf -)
  rm -rf "shared-sceptre-template-${TEMPLATE_VER}/"
}

main() {

    # SWITCH_ACCOUNT=1
    parse_arguments $@
    if [ "z$AWS_ACCOUNT" != "z" ]; then
        # Call assume_role to switch AWS account
        assume_role
    elif [ "z$SHORT_AWS_PROFILE" != "z" ]; then
        get_short_term_credentials
    elif [ "z$LONG_AWS_PROFILE" != "z" ]; then
        get_long_term_credentials
    fi

    get_template
    launch "${SCRIPT_ACTION}" "${CFN_CONFIG}"

}

main "$@"

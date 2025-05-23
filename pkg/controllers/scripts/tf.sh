#!/bin/bash -e
set -o errexit

function fixssh {
  mkdir -p /tmp/.ssh/
  if stat "$I3_SSH"/* >/dev/null 2>/dev/null; then
    cp -Lr "$I3_SSH"/* /tmp/.ssh/
    chmod -R 0600 /tmp/.ssh/*
  fi
}

function join_by {
  local d="$1" f=${2:-$(</dev/stdin)};
  if [[ -z "$f" ]]; then return 1; fi
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  else
    join_by "$d" $f
  fi
}

function version_gt_or_eq {
  if [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]; then
    return 0
  else
    return 1
  fi
}

# Start by fixing ssh in case another task left it in a bad state
fixssh

if [[ -s "$AWS_WEB_IDENTITY_TOKEN_FILE" ]] && [[ -n "$AWS_ROLE_ARN" ]]; then
  # Terraform's go-getter has a problem with IRSA roles. The irsa-tokengen
  # freezes the credentials from IRSA to static AWS_ACCESS_KEY_ID creds.
  # These creds are only valid for a short period of time, 1 hour.
  #
  # If the command irsa-tokengen fails, the script should exit
  temp="$(mktemp)"
  irsa-tokengen > "$temp" || exit $?
  export $(cat "$temp")
fi
terraform_version=$(terraform version | head -n1 |sed "s/^.*v//")
module=""
if ! version_gt_or_eq "0.15.0" "$terraform_version"; then
  module="."
fi

cd "$I3_MAIN_MODULE"
out="$I3_ROOT_PATH"/generations/$I3_GENERATION
mkdir -p "$out"
vardir="$out/tfvars"
vars=
if [[ $(ls $vardir | wc -l) -gt 0 ]]; then
  vars="-var-file $(find $vardir -type f | sort -n | join_by ' -var-file ')"
fi

case "$I3_TASK" in
    init | init-delete)
        terraform init $module 2>&1 #| tee "$out"/"$I3_TASK".out
        ;;
    plan)
        terraform plan $vars -out tfplan $module 2>&1 #| tee "$out"/"$I3_TASK".out
        ;;
    plan-delete)
        terraform plan $vars -destroy -out tfplan $module 2>&1 #| tee "$out"/"$I3_TASK".out
        ;;
    apply | apply-delete)
        terraform apply tfplan 2>&1 #| tee "$out"/"$I3_TASK".out
        ;;
esac
status=${PIPESTATUS[0]}
if [[ $status -gt 0 ]];then exit $status;fi

if [[ "$I3_TASK" == "apply" ]] && [[ "$I3_SAVE_OUTPUTS" == "true" ]]; then
  # On sccessful apply, save outputs as k8s-secret
  data=$(mktemp)
  printf '[
    {"op":"replace","path":"/data","value":{}}
  ]' > "$data"
  t=$(mktemp)
  include=( $(echo "$I3_OUTPUTS_TO_INCLUDE" | tr "," " ") )
  omit=( $(echo "$I3_OUTPUTS_TO_OMIT" | tr "," " ") )
  jsonoutput=$(terraform output -json)
  keys=( $(jq -r '.|keys[]' <<< $jsonoutput) )
  for key in ${keys[@]}; do
    if [[ "${#include[@]}" -gt 0 ]] && [[ ! " ${include[*]} " =~ " $key " ]]; then
      echo "Skipping $key"
      continue
    fi
    if [[ "${#omit[@]}" -gt 0 ]] && [[ " ${omit[*]} " =~ " $key " ]]; then
      echo "Omitting $key"
      continue
    fi
    b64value=$(jq -j --arg key $key '.[$key].value' <<< $jsonoutput|base64|tr -d '[:space:]')
    jq -Mc --arg key "$key" --arg value "$b64value" '. += [
      {"op":"add","path":"/data/\($key)","value":"\($value)"}
    ]' "$data" > "$t"
    cp "$t" "$data"
  done
  kubectl patch secret "$I3_OUTPUTS_SECRET_NAME" --type json --patch-file "$data"
fi

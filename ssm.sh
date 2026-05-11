#!/usr/bin/env bash
set -eo pipefail

# A bunch of text colors for echoing
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NOC='\033[0m'


# Checks if a value exists in an array
# Usage: elementIn "some_value" "${VALUES[@]}"; [[ #? -eq 0 ]] && echo "EXISTS!" || echo "DOESNT EXIST! :("
elementIn () {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

printUsage () {
    set -e
    cat <<EOF
AWS SSM parameter injection in Helm value files

This plugin provides the ability to encode AWS SSM parameter paths into your
value files to store in version control or just generally less secure places.

During installation or upgrade, the parameters are replaced with their actual values
and passed on to Tiller.

Usage:
Simply use helm as you would normally, but add 'ssm' before any command,
the plugin will automatically search for values with the pattern:

    {{ssm /path/to/parameter aws-region}}

and replace them with their decrypted value.
Note: You must have IAM access to the parameters you're trying to decrypt, and their KMS key.
Note #2: Wrap the template with quotes, otherwise helm will confuse the brackets for json, and will fail rendering.
Note #3: Currently, helm-ssm does not work when the value of the parameter is in the default chart values.

E.g:
helm ssm install stable/docker-registry --values value-file1.yaml -f value-file2.yaml

value-file1.yaml:
---
secrets:
  haSharedSecret: "{{ssm /mgmt/docker-registry/shared-secret us-east-1}}"
  htpasswd: "{{ssm /mgmt/docker-registry/htpasswd us-east-1}}"
---

Prefix:
If your SSM parameters have a preset you can specify it at run time using the -p or --prefix flags followed by a string

E.g:
helm ssm install stable/docker-registry --values value-file1.yaml -f value-file2.yaml -p "/some/prefix/path"

Optional parameters:
Append the literal word 'optional' to a placeholder to mark it as non-fatal —
if the parameter does not exist in SSM, the placeholder is replaced with an
empty string and a warning is logged instead of aborting the run.

    {{ssm /maybe/missing us-east-1 optional}}

The flag also works with the global -r/--region override:

    {{ssm /maybe/missing optional}}    # requires -r/--region to be set
EOF
    exit 0
}


# Handle dependencies
# AWS cli
if ! [[ -x "$(command -v aws)" ]]; then
    echo -e "${RED}[ERROR] aws cli is not installed." >&2
    exit 1
fi
# jq (used to parse aws ssm get-parameters JSON responses)
if ! [[ -x "$(command -v jq)" ]]; then
    echo -e "${RED}[ERROR] jq is not installed." >&2
    exit 1
fi
# bash 4+ (associative arrays)
if (( BASH_VERSINFO[0] < 4 )); then
    echo -e "${RED}[ERROR] bash 4 or newer required (found ${BASH_VERSION})." >&2
    exit 1
fi


# get the first command (install\list\template\etc...)
cmd="$1"

# "helm ssm/helm ssm help/helm ssm -h/helm ssm --help"
if [[ $# -eq 0 || "$cmd" == "help" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
    printUsage
fi

# if the command is not "install" or "upgrade", or just a single command (no value files is a given in this case), pass the args to the regular helm command
if [[ $# -eq 1 || ( "$cmd" != "install" && "$cmd" != "upgrade" ) ]]; then
    set +e # disable fail-fast
    helm "$*"
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[SSM]${NOC} Helm exited with a non 0 code - this is most likely not a problem with the SSM plugin, but a problem with Helm itself." >&2
    fi

    exit ${EXIT_CODE} # exit with the same error code as the command
fi


VALUE_FILES=() # An array of paths to value files
OPTIONS=() # An array of all the other options given
PREFIX="" # prefix to use when fetching SSM Parameters (optional)
GLOBAL_REGION="" # region override to use when fetching SSM Parameters (optional)
while [[ "$#" -gt 0 ]]
do
    case "$1" in
    -h|--help)
        echo "usage!" # TODO proper usage
        exit 0
        ;;
    -f|--values)
        if [ $# -gt 1 ]; then # if we werent given just an empty '-f' option
            VALUE_FILES+=($2) # then add the path to the array
        fi
        ;;
    -p|--prefix)
        if [ $# -gt 1 ]; then # if we werent given just an empty '-p' option
            PREFIX=$2 # then add the path to the array
        fi
        ;;
    -c|--colour)
        if [ $# -gt 1 ]; then # if we werent given just an empty '-c' option
            COLOUR=$2 # then add the path to the array
        fi
        ;;
    -r|--region)
        if [ $# -gt 1 ]; then # if we werent given just an empty '-r' option
            GLOBAL_REGION=$2 # then add the path to the array
        fi
        ;;
    *)
        if [ "$1" != "${PREFIX}" -a "$1" != "${COLOUR}" -a  "$1" != "${GLOBAL_REGION}" ]; then
          # we go over each options, and if the option isnt a value file or prefix, we add it to the options array
          set +e # we turn off fast-fail because the check of if the array contains a value returns exit code 0 or 1 depending on the result
          elementIn "$1" "${VALUE_FILES[@]}"
          [[ $? -eq 1 ]] && OPTIONS+=($1)
          set -e # when we're finished with the check, we turn on fast-fail
        fi
        ;;
    esac
    shift
done

echo -e "${GREEN}[SSM]${NOC} Options: ${OPTIONS[@]}"
echo -e "${GREEN}[SSM]${NOC} Value files: ${VALUE_FILES[@]}"

if [[ -n ${PREFIX} ]]; then
    echo -e "${GREEN}[SSM]${NOC} Prefix: ${PREFIX}"
fi

if [[ -n ${GLOBAL_REGION} ]]; then
    echo -e "${GREEN}[SSM]${NOC} Region: ${GLOBAL_REGION}"
fi

set +e # we disable fail-dast because we want to give the user a proper error message in case we cant read the value file
MERGED_TEXT=""
for FILEPATH in "${VALUE_FILES[@]}"; do
    echo -e "${GREEN}[SSM]${NOC} Reading ${FILEPATH}"

    if [[ ! -f ${FILEPATH} ]]; then
        echo -e "${RED}[SSM]${NOC} Error: open ${FILEPATH}: no such file or directory" >&2
        exit 1
    fi

    VALUE=$(cat ${FILEPATH} 2> /dev/null) # read the content of the values file silently (without outputing an error in case it fails)
    EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        echo -e "${RED}[SSM]${NOC} Error: open ${FILEPATH}: failed to read contents" >&2
        exit 1
    fi

    VALUE=$(echo -e "${VALUE}" | sed s/\%/\%\%/g) # we turn single % to %% to escape percent signs
    printf -v MERGED_TEXT "${MERGED_TEXT}\n${VALUE}" # We concat the files together with a newline in between using printf and put output into variable MERGED_TEXT
done

PARAMETERS=$(echo -e "${MERGED_TEXT}" | grep -Eo "\{\{ssm [^\}]+\}\}") # Look for {{ssm /path/to/param us-east-1}} patterns, delete empty lines
PARAMETERS_LENGTH=$(echo "${PARAMETERS}" | grep -v '^$' | wc -l | xargs)
if [ "${PARAMETERS_LENGTH}" != 0 ]; then
    echo -e "${GREEN}[SSM]${NOC} Found $(echo "${PARAMETERS}" | grep -v '^$' | wc -l | xargs) parameters"
    echo -e "${GREEN}[SSM]${NOC} Parameters: \n${PARAMETERS[@]}"
else
    echo -e "${GREEN}[SSM]${NOC} No parameters were found, continuing..."
fi
echo -e "==============================================="


set +e

# --- Pre-fetch phase -----------------------------------------------------
# Resolve every (name, region) up front in batches of up to ten via
# `aws ssm get-parameters --names ...`. This collapses N sequential
# get-parameter invocations (each paying Python CLI cold-start plus an
# HTTPS round-trip) into ceil(N/10) calls per region. SSM_CACHE is keyed
# by "${name}|${region}".

declare -A SSM_CACHE=()
declare -A SSM_FETCH_NAMES_BY_REGION=()

while read -r PARAM_STRING; do
    [ -z "${PARAM_STRING}" ] && continue
    PF_CLEANED=$(echo ${PARAM_STRING:2} | rev | cut -c 3- | rev)
    PF_RAW_PATH=$(echo ${PF_CLEANED:2} | cut -d' ' -f 2)
    if [[ -n ${GLOBAL_REGION} ]]; then
        PF_REGION=${GLOBAL_REGION}
    else
        PF_REGION=$(echo ${PF_CLEANED:2} | cut -d' ' -f 3)
    fi
    # When the user writes `{{ssm /path optional}}` with no global region,
    # token 3 is the literal flag, not a region. Fail loudly instead of
    # calling AWS with `--region optional`.
    if [[ "${PF_REGION}" == "optional" ]]; then
        echo -e "${RED}[SSM]${NOC} Error: 'optional' flag found in the region slot of '${PARAM_STRING}'. Either supply -r/--region or write '{{ssm /path <region> optional}}'." >&2
        exit 1
    fi
    if [[ ! -f ${PREFIX} ]]; then
        PF_PLAIN_NAME="${PREFIX}${PF_RAW_PATH}"
    else
        PF_PLAIN_NAME="${PF_RAW_PATH}"
    fi
    SSM_FETCH_NAMES_BY_REGION["${PF_REGION}"]+=" ${PF_PLAIN_NAME}"
    if [[ -n ${COLOUR} ]]; then
        SSM_FETCH_NAMES_BY_REGION["${PF_REGION}"]+=" ${PREFIX}/${COLOUR}${PF_RAW_PATH}"
    fi
done <<< "${PARAMETERS}"

for PF_REGION in "${!SSM_FETCH_NAMES_BY_REGION[@]}"; do
    [ -z "${PF_REGION}" ] && continue

    declare -A PF_SEEN=()
    PF_DEDUPED=()
    for PF_NAME in ${SSM_FETCH_NAMES_BY_REGION[${PF_REGION}]}; do
        [ -z "${PF_NAME}" ] && continue
        if [ -z "${PF_SEEN[${PF_NAME}]:-}" ]; then
            PF_SEEN["${PF_NAME}"]=1
            PF_DEDUPED+=("${PF_NAME}")
        fi
    done
    unset PF_SEEN

    PF_TOTAL=${#PF_DEDUPED[@]}
    PF_INDEX=0
    while (( PF_INDEX < PF_TOTAL )); do
        PF_BATCH=("${PF_DEDUPED[@]:${PF_INDEX}:10}")
        PF_INDEX=$(( PF_INDEX + 10 ))

        PF_RESPONSE=$(aws ssm get-parameters --with-decryption \
            --names "${PF_BATCH[@]}" --region "${PF_REGION}" --output json 2>&1)
        PF_EXIT=$?
        if [[ ${PF_EXIT} -ne 0 ]]; then
            echo -e "${RED}[SSM]${NOC} Error: get-parameters failed in region ${PF_REGION}: ${PF_RESPONSE}" >&2
            exit 1
        fi

        # Emit name/value pairs separated by NUL bytes so that values
        # containing newlines, tabs, or backslashes (PEM certificates, SSH
        # keys, JSON blobs, etc.) survive the boundary intact. `@tsv` would
        # have escaped them into literal `\n`/`\t`/`\\` sequences.
        while IFS= read -r -d '' PF_NAME && IFS= read -r -d '' PF_VALUE; do
            [ -z "${PF_NAME}" ] && continue
            SSM_CACHE["${PF_NAME}|${PF_REGION}"]="${PF_VALUE}"
        done < <(echo "${PF_RESPONSE}" | jq -j '.Parameters[] | "\(.Name)\u0000\(.Value)\u0000"')
    done
done

echo -e "${GREEN}[SSM]${NOC} Pre-fetched ${#SSM_CACHE[@]} parameter(s) across ${#SSM_FETCH_NAMES_BY_REGION[@]} region(s)"

# --- Substitution phase --------------------------------------------------
# Each placeholder is now a cache lookup. COLOUR-mode behaviour is
# preserved: prefer the colour-prefixed name, fall back to the plain
# prefix; if neither resolved, error out with the same shape of message
# as before.

while read -r PARAM_STRING; do
    [ -z "${PARAM_STRING}" ] && continue # if parameter is empty for some reason

    CLEANED_PARAM_STRING=$(echo ${PARAM_STRING:2} | rev | cut -c 3- | rev) # we cut the '{{' and '}}' at the beginning and end
    PARAM_PATH=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 2) # {{ssm */param/path* us-east-1}}

    if [[ -n ${GLOBAL_REGION} ]]; then
        REGION=${GLOBAL_REGION} # Use region provided to cli
    else
        REGION=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 3) # {{ssm /param/path *us-east-1*}}
    fi
    if [[ "${REGION}" == "optional" ]]; then
        echo -e "${RED}[SSM]${NOC} Error: 'optional' flag found in the region slot of '${PARAM_STRING}'. Either supply -r/--region or write '{{ssm /path <region> optional}}'." >&2
        exit 1
    fi

    # Detect trailing `optional` flag. Works whether it appears as token 3
    # (with -r) or token 4 (with an explicit region in the placeholder).
    IS_OPTIONAL=0
    for TRAILING_TOKEN in $(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 3-); do
        if [[ "${TRAILING_TOKEN}" == "optional" ]]; then
            IS_OPTIONAL=1
            break
        fi
    done

    if [[ ! -f ${PREFIX} ]]; then
        PARAM_PATH="${PREFIX}${PARAM_PATH}"
    fi

    if [[ -n ${COLOUR} ]]; then
        echo -e "colour: ${COLOUR}"
        PARAM_PATH_COLOUR=$(echo ${CLEANED_PARAM_STRING:2} | cut -d' ' -f 2) # {{ssm */param/path* us-east-1}}
        PARAM_PATH_COLOUR="${PREFIX}/${COLOUR}${PARAM_PATH_COLOUR}"
        echo -e "full path: ${PARAM_PATH_COLOUR}"

        if [[ -n "${SSM_CACHE["${PARAM_PATH_COLOUR}|${REGION}"]+x}" ]]; then
            PARAM_OUTPUT="${SSM_CACHE["${PARAM_PATH_COLOUR}|${REGION}"]}"
            EXIT_CODE=0
        elif [[ -n "${SSM_CACHE["${PARAM_PATH}|${REGION}"]+x}" ]]; then
            PARAM_OUTPUT="${SSM_CACHE["${PARAM_PATH}|${REGION}"]}"
            EXIT_CODE=0
        else
            PARAM_OUTPUT="ParameterNotFound: ${PARAM_PATH_COLOUR} or ${PARAM_PATH}"
            EXIT_CODE=1
        fi
    else
        if [[ -n "${SSM_CACHE["${PARAM_PATH}|${REGION}"]+x}" ]]; then
            PARAM_OUTPUT="${SSM_CACHE["${PARAM_PATH}|${REGION}"]}"
            EXIT_CODE=0
        else
            PARAM_OUTPUT="ParameterNotFound: ${PARAM_PATH}"
            EXIT_CODE=1
        fi
    fi

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        if [[ ${IS_OPTIONAL} -eq 1 ]]; then
            echo -e "${YELLOW}[SSM]${NOC} Optional parameter not found, substituting empty string: ${PARAM_PATH} (region: ${REGION})" >&2
            PARAM_OUTPUT=""
        else
            echo -e "${RED}[SSM]${NOC} Error: Could not get parameter: ${PARAM_PATH}. REGION: ${REGION} AWS cli output: ${PARAM_OUTPUT}" >&2
            exit 1
        fi
    fi

    MERGED_TEXT=$(echo -e "${MERGED_TEXT//${PARAM_STRING}/${PARAM_OUTPUT}}")
done <<< "${PARAMETERS}"

set +e
echo -e "${MERGED_TEXT}" | helm "${OPTIONS[@]}" --values -
EXIT_CODE=$?
if [[ ${EXIT_CODE} -ne 0 ]]; then
    echo -e "${RED}[SSM]${NOC} Helm exited with a non 0 code - this is most likely not a problem with the SSM plugin, but a problem with Helm itself." >&2
    exit ${EXIT_CODE}
fi

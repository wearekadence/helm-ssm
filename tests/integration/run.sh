#!/usr/bin/env bash
# Integration tests for ssm.sh. Spins up parameters in a running LocalStack
# instance, runs ssm.sh against fixture values files, and asserts on the
# rendered YAML emitted to stdin (captured via a fake `helm` shim on PATH).
#
# Requires: aws cli v2, jq, bash 4+, a reachable LocalStack with SSM enabled.
# Skips cleanly if LOCALSTACK_ENDPOINT is unreachable.

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_DIR="${REPO_ROOT}/tests/integration"
SHIM_DIR="${TEST_DIR}/bin"

: "${LOCALSTACK_ENDPOINT:=http://localhost:4566}"
: "${AWS_REGION:=us-east-1}"
: "${AWS_ACCESS_KEY_ID:=test}"
: "${AWS_SECRET_ACCESS_KEY:=test}"
export AWS_ENDPOINT_URL_SSM="${LOCALSTACK_ENDPOINT}"
export AWS_ENDPOINT_URL="${LOCALSTACK_ENDPOINT}"
export AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export PATH="${SHIM_DIR}:${PATH}"

if ! curl -fsS --max-time 3 "${LOCALSTACK_ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
    echo "LocalStack not reachable at ${LOCALSTACK_ENDPOINT} — skipping integration tests."
    exit 0
fi

PASS=0
FAIL=0
CURRENT_TEST=""

declare -a SEEDED_PARAMS=()  # entries are "name|region"

cleanup_seeded() {
    local entry name region
    for entry in "${SEEDED_PARAMS[@]:-}"; do
        [ -z "${entry}" ] && continue
        name="${entry%%|*}"
        region="${entry##*|}"
        aws ssm delete-parameter --name "${name}" --region "${region}" >/dev/null 2>&1 || true
    done
    SEEDED_PARAMS=()
}
trap cleanup_seeded EXIT

put_param() {
    local name="$1" value="$2" region="${3:-${AWS_REGION}}" type="${4:-String}"
    aws ssm put-parameter --name "${name}" --value "${value}" --type "${type}" \
        --overwrite --region "${region}" >/dev/null
    SEEDED_PARAMS+=("${name}|${region}")
}

start_test() {
    CURRENT_TEST="$1"
    # Snapshot FAIL so end_test can tell whether any assertion in this block
    # bumped it. Without this, PASS would always increment regardless of
    # in-test failures, giving a misleading summary.
    TEST_FAIL_BASELINE=$FAIL
    echo "==> ${CURRENT_TEST}"
}

end_test() {
    if (( FAIL == TEST_FAIL_BASELINE )); then
        PASS=$((PASS + 1))
    fi
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    if grep -qF -- "${needle}" <<<"${haystack}"; then
        echo "    ✔ contains: ${needle}"
    else
        FAIL=$((FAIL + 1))
        echo "    ✘ MISSING: ${needle}"
        echo "    --- captured output ---"
        printf '%s\n' "${haystack}" | sed 's/^/    | /'
        echo "    --- end ---"
        return 1
    fi
}

assert_eq() {
    local expected="$1" actual="$2" label="${3:-value}"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "    ✔ ${label}: ${actual}"
    else
        FAIL=$((FAIL + 1))
        echo "    ✘ ${label}: expected '${expected}', got '${actual}'"
        return 1
    fi
}

run_ssm() {
    # Run ssm.sh; capture both streams. Always returns the raw output for
    # caller-side assertion, plus the exit code in $RUN_EXIT. The script
    # runs without `set -e` so that failing assertions don't abort the
    # whole suite — see the FAIL counter and final summary instead.
    cd "${REPO_ROOT}"
    RUN_OUTPUT=$(./ssm.sh "$@" 2>&1)
    RUN_EXIT=$?
}

# ---------------------------------------------------------------- tests --

start_test "single parameter substitution"
put_param "/it/single/p1" "hello-world"
cat >/tmp/it_values_single.yaml <<EOF
secret: "{{ssm /it/single/p1 us-east-1}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_single.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'secret: "hello-world"' "${RUN_OUTPUT}"
assert_contains "Pre-fetched 1 parameter(s) across 1 region(s)" "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "batched call counts: 25 params across two regions in 3 calls"
# 15 in us-east-1 → ⌈15/10⌉ = 2 GetParameters calls
# 10 in eu-west-1 → ⌈10/10⌉ = 1 GetParameters call
# Expected total: 3 batched calls (vs 25 under the old per-param implementation)
PLACEHOLDERS=""
for i in $(seq 1 15); do
    put_param "/it/multi/us/p${i}" "us-v${i}" us-east-1
    PLACEHOLDERS+="  k_us_${i}: \"{{ssm /it/multi/us/p${i} us-east-1}}\""$'\n'
done
for i in $(seq 1 10); do
    put_param "/it/multi/eu/p${i}" "eu-v${i}" eu-west-1
    PLACEHOLDERS+="  k_eu_${i}: \"{{ssm /it/multi/eu/p${i} eu-west-1}}\""$'\n'
done
{
    echo "values:"
    printf '%s' "${PLACEHOLDERS}"
} >/tmp/it_values_multi.yaml

# Snapshot LocalStack log line count to count GetParameters calls during this run.
SNAPSHOT_OK=0
LS_CONTAINER="${LOCALSTACK_CONTAINER:-helm-ssm-localstack}"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${LS_CONTAINER}"; then
    BEFORE=$(docker logs "${LS_CONTAINER}" 2>&1 | grep -c "GetParameters " || true)
    BEFORE_SINGLES=$(docker logs "${LS_CONTAINER}" 2>&1 | grep -c "GetParameter " || true)
    SNAPSHOT_OK=1
fi

run_ssm install testrelease ./tests/testchart --values /tmp/it_values_multi.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
for i in $(seq 1 15); do
    assert_contains "k_us_${i}: \"us-v${i}\"" "${RUN_OUTPUT}"
done
for i in $(seq 1 10); do
    assert_contains "k_eu_${i}: \"eu-v${i}\"" "${RUN_OUTPUT}"
done
assert_contains "Pre-fetched 25 parameter(s) across 2 region(s)" "${RUN_OUTPUT}"

if [[ "${SNAPSHOT_OK}" == "1" ]]; then
    AFTER=$(docker logs "${LS_CONTAINER}" 2>&1 | grep -c "GetParameters " || true)
    AFTER_SINGLES=$(docker logs "${LS_CONTAINER}" 2>&1 | grep -c "GetParameter " || true)
    DELTA_BATCH=$(( AFTER - BEFORE ))
    DELTA_SINGLES=$(( AFTER_SINGLES - BEFORE_SINGLES ))
    assert_eq "3" "${DELTA_BATCH}" "batched GetParameters call count"
    assert_eq "0" "${DELTA_SINGLES}" "singleton GetParameter call count"
else
    echo "    (skipping API call-count assertions — LocalStack container '${LS_CONTAINER}' not visible)"
fi
end_test
cleanup_seeded

start_test "global prefix flag"
put_param "/it/prefixed/inner" "from-prefix"
cat >/tmp/it_values_prefix.yaml <<EOF
secret: "{{ssm /inner us-east-1}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_prefix.yaml --prefix /it/prefixed
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'secret: "from-prefix"' "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "SecureString is decrypted"
put_param "/it/secure/p1" "shhh-its-a-secret" us-east-1 SecureString
cat >/tmp/it_values_secure.yaml <<EOF
secret: "{{ssm /it/secure/p1 us-east-1}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_secure.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'secret: "shhh-its-a-secret"' "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "missing parameter exits non-zero"
cat >/tmp/it_values_missing.yaml <<EOF
secret: "{{ssm /it/does/not/exist us-east-1}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_missing.yaml
assert_eq "1" "${RUN_EXIT}" "exit code"
assert_contains "Could not get parameter" "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "multi-line SecureString preserves newlines (PEM-style)"
PEM_VALUE=$'-----BEGIN CERTIFICATE-----\nMIIDazCCAlOgAwIBAgIULineTwo\nLineThreeOfTheCert\n-----END CERTIFICATE-----'
put_param "/it/multiline/cert" "${PEM_VALUE}" us-east-1 SecureString
cat >/tmp/it_values_pem.yaml <<'EOF'
secret: |
  {{ssm /it/multiline/cert us-east-1}}
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_pem.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains "-----BEGIN CERTIFICATE-----" "${RUN_OUTPUT}"
assert_contains "MIIDazCCAlOgAwIBAgIULineTwo" "${RUN_OUTPUT}"
assert_contains "LineThreeOfTheCert" "${RUN_OUTPUT}"
assert_contains "-----END CERTIFICATE-----" "${RUN_OUTPUT}"
# The literal two-character sequence backslash-n must NOT appear — that
# would mean jq @tsv (or similar) had escaped newlines instead of preserving
# them as real bytes.
if grep -qF '\n-----' <<<"${RUN_OUTPUT}"; then
    FAIL=$((FAIL + 1))
    echo "    ✘ multiline value contains literal '\\n' escape — newlines were corrupted"
else
    echo "    ✔ no literal '\\n' escape — newlines preserved as actual bytes"
fi
# BEGIN and END must land on different lines in the rendered output.
BEGIN_LINE=$(grep -n "BEGIN CERTIFICATE" <<<"${RUN_OUTPUT}" | head -1 | cut -d: -f1)
END_LINE=$(grep -n "END CERTIFICATE" <<<"${RUN_OUTPUT}" | head -1 | cut -d: -f1)
if [[ -n "${BEGIN_LINE}" && -n "${END_LINE}" && "${BEGIN_LINE}" != "${END_LINE}" ]]; then
    echo "    ✔ BEGIN at line ${BEGIN_LINE}, END at line ${END_LINE}"
else
    FAIL=$((FAIL + 1))
    echo "    ✘ BEGIN line=${BEGIN_LINE}, END line=${END_LINE} — expected on different lines"
fi
end_test
cleanup_seeded

start_test "optional flag: missing param substitutes empty string"
cat >/tmp/it_values_optional_missing.yaml <<EOF
a: "{{ssm /it/optional/does-not-exist us-east-1 optional}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_optional_missing.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'a: ""' "${RUN_OUTPUT}"
assert_contains "Optional parameter not found" "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "optional flag: present param resolves normally"
put_param "/it/optional/present" "i-exist"
cat >/tmp/it_values_optional_present.yaml <<EOF
a: "{{ssm /it/optional/present us-east-1 optional}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_optional_present.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'a: "i-exist"' "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "optional flag: mixed required + missing-optional in one file"
put_param "/it/optional/mixed-required" "required-value"
cat >/tmp/it_values_optional_mixed.yaml <<EOF
required: "{{ssm /it/optional/mixed-required us-east-1}}"
maybe: "{{ssm /it/optional/mixed-missing us-east-1 optional}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_optional_mixed.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'required: "required-value"' "${RUN_OUTPUT}"
assert_contains 'maybe: ""' "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "optional flag: works with global -r/--region (no inline region)"
cat >/tmp/it_values_optional_global_region.yaml <<EOF
maybe: "{{ssm /it/optional/missing-with-r optional}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_optional_global_region.yaml -r us-east-1
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'maybe: ""' "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "optional flag in region slot without -r errors clearly"
cat >/tmp/it_values_optional_no_region.yaml <<EOF
maybe: "{{ssm /it/optional/missing-no-region optional}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_optional_no_region.yaml
assert_eq "1" "${RUN_EXIT}" "exit code"
assert_contains "'optional' flag found in the region slot" "${RUN_OUTPUT}"
end_test
cleanup_seeded

start_test "duplicate placeholder dedupes in pre-fetch"
put_param "/it/dup/p1" "dup-value"
cat >/tmp/it_values_dup.yaml <<EOF
a: "{{ssm /it/dup/p1 us-east-1}}"
b: "{{ssm /it/dup/p1 us-east-1}}"
c: "{{ssm /it/dup/p1 us-east-1}}"
EOF
run_ssm install testrelease ./tests/testchart --values /tmp/it_values_dup.yaml
assert_eq "0" "${RUN_EXIT}" "exit code"
assert_contains 'a: "dup-value"' "${RUN_OUTPUT}"
assert_contains 'b: "dup-value"' "${RUN_OUTPUT}"
assert_contains 'c: "dup-value"' "${RUN_OUTPUT}"
assert_contains "Pre-fetched 1 parameter(s) across 1 region(s)" "${RUN_OUTPUT}"
end_test
cleanup_seeded

# --------------------------------------------------------------- summary --
echo
echo "================================="
echo "  passed: ${PASS}"
echo "  failed: ${FAIL}"
echo "================================="
if (( FAIL > 0 )); then
    exit 1
fi

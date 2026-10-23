#!/usr/bin/env bash
# © Broadcom. All Rights Reserved.
# The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: Apache-2.0

# Enable the inventory on an exclusively allocated WCP testbed. Requires the
# Supervisor admin kubeconfig exported by setup-testbed-env.sh, jq, and yq v4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../../test/e2e/vmservice/config/in-progress-features.yaml"
KUBE_CONFIG="${KUBECONFIG:-}"
NAMESPACE=vmware-system-vmop
DEPLOYMENT=vmware-system-vmop-controller-manager
CONTAINER=manager
CAP_RESOURCE=capabilities.iaas.vmware.com
CAP_NAME=supervisor-capabilities
TIMEOUT=600
DRY_RUN=false
MUTATION_STARTED=false
FAILURE_REASON="Feature enablement failed; see pod logs."

usage() {
    cat <<'EOF'
Usage: enable-in-progress-features.sh [OPTIONS]

Enable all FSS/capability entries in the YAML on a dedicated WCP testbed.
Capabilities must exist and the operator must use Supervisor async upgrade.

Options:
  --config PATH      Feature inventory (default: vmservice/config/in-progress-features.yaml)
  --kubeconfig PATH  Supervisor admin kubeconfig (default: $KUBECONFIG)
  --timeout SECONDS  Timeout for activation and, separately, rollout (default: 600)
  --dry-run          Validate YAML and print switches without contacting the testbed
  -h, --help         Show this help

Examples (from the repository root):
  ./hack/e2e/enable-in-progress-features.sh --dry-run
  source ./hack/e2e/setup-testbed-env.sh ./testbedInfo.json
  ./hack/e2e/enable-in-progress-features.sh

The script enables capabilityOverride switches too. It patches capability spec
and waits for platform activation, then sets VM Operator FSS environment values
to true and rolls out the operator. It preserves platform activation rules.
Only VM Operator environment FSSs are represented by kind: vmop-env; this does
not change vCenter FSSs or provision underlying infrastructure. Failed activation
is an error. Settings remain enabled after completion; there is no rollback.
Failures are reported through TEST_CALLBACK_URL when set. Successful enablement
leaves result reporting to the test runner. Dry runs do not send callbacks.
EOF
}

die() { FAILURE_REASON="$*"; printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

on_exit() {
    local rc=$?
    trap - EXIT
    if [[ ${rc} -ne 0 && "${MUTATION_STARTED}" == true ]]; then
        printf 'Feature enablement failed; some settings may already be enabled. No automatic rollback was performed.\n' >&2
    fi
    # This step runs before run-e2e.sh, so it must report its own failures.
    # Use one EXIT handler for both explicit errors and set -e failures, and
    # preserve the original exit status even if callback delivery fails.
    if [[ ${rc} -ne 0 && "${DRY_RUN}" != true && -n "${TEST_CALLBACK_URL:-}" ]]; then
        if [[ -r "${SCRIPT_DIR}/callback.sh" ]] &&
            command -v jq >/dev/null && command -v curl >/dev/null; then
            (
                # shellcheck source=./callback.sh
                source "${SCRIPT_DIR}/callback.sh" &&
                report_callback "Failed" "${FAILURE_REASON}"
            ) || printf 'WARNING: Could not report feature enablement failure to UTS.\n' >&2
        else
            printf 'WARNING: Cannot report failure: callback.sh, jq, or curl is unavailable.\n' >&2
        fi
    fi
    exit "${rc}"
}
trap on_exit EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config|--kubeconfig|--timeout)
            [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"
            case "$1" in
                --config) CONFIG="$2" ;;
                --kubeconfig) KUBE_CONFIG="$2" ;;
                --timeout) TIMEOUT="$2" ;;
            esac
            shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
done
[[ "${TIMEOUT}" =~ ^[1-9][0-9]*$ && ${#TIMEOUT} -le 6 ]] || die "--timeout must be a positive integer of at most six digits"
[[ -r "${CONFIG}" ]] || die "Cannot read feature inventory: ${CONFIG}"
for tool in jq yq; do
    command -v "${tool}" >/dev/null || die "Required command not found: ${tool}"
done
[[ "$(yq --version)" == *" version v4."* ]] || die "Mike Farah yq v4 is required"

# Keep entries as arrays until validation, so duplicate YAML mapping keys cannot
# silently hide a feature. No shell evaluation is used for values from YAML.
FAILURE_REASON="Failed to read or validate the feature inventory; see pod logs."
INVENTORY="$(yq -o=json eval 'to_entries' "${CONFIG}" | jq -es '
    if length != 1 or (.[0] | type) != "array" then
        error("expected one YAML mapping document")
    else .[0] end
    | if ([.[].key] | length) != ([.[].key] | unique | length) then
        error("duplicate top-level YAML key")
    else from_entries end
')"
FEATURE_ENTRIES="$(yq -o=json eval '.features | to_entries' "${CONFIG}")"
jq -en --argjson doc "${INVENTORY}" --argjson entries "${FEATURE_ENTRIES}" '
    def named($pattern): type == "string" and test($pattern);
    ($doc.schemaVersion == 1) and
    (($doc.features | type) == "object") and
    (($entries | length) > 0) and
    (([$entries[].key] | length) == ([$entries[].key] | unique | length)) and
    all($entries[];
        (.key | named("^[a-z][a-z0-9-]*$")) and
        (.value | type == "object" and .lifecycle == "in-progress" and
            (if .kind == "supervisor-capability" then
                (.name | named("^supports_[A-Za-z0-9_]+$")) and
                (has("capabilityOverride") | not)
            elif .kind == "vmop-env" then
                (.name | named("^FSS_[A-Z0-9_]+$")) and
                (if has("capabilityOverride") then
                    (.capabilityOverride | named("^supports_[A-Za-z0-9_]+$"))
                 else true end)
            else false end))) and
    (([$entries[].value | [.kind, .name]] | length) ==
     ([$entries[].value | [.kind, .name]] | unique | length))
' >/dev/null || die "Invalid feature inventory: require schemaVersion 1, unique features, supported kinds/names, and lifecycle: in-progress"

CAPABILITIES="$(jq -c '[.features[] |
    if .kind == "supervisor-capability" then .name
    else .capabilityOverride // empty end] | unique' <<<"${INVENTORY}")"
ENV_NAMES="$(jq -c '[.features[] | select(.kind == "vmop-env") | .name] | unique' <<<"${INVENTORY}")"
CAP_COUNT="$(jq length <<<"${CAPABILITIES}")"
ENV_COUNT="$(jq length <<<"${ENV_NAMES}")"
log "Inventory: ${CAP_COUNT} capability switches (including overrides), ${ENV_COUNT} VM Operator FSS variables."
jq -nr --argjson caps "${CAPABILITIES}" --argjson envs "${ENV_NAMES}" '
    ($caps[] | "  capability: \(.)=true"), ($envs[] | "  vmop-env: \(.)=true")'
if [[ "${DRY_RUN}" == true ]]; then
    log "Dry run complete: YAML validated; testbed access and activation were not checked."
    exit 0
fi

command -v kubectl >/dev/null || die "Required command not found: kubectl"
[[ -n "${KUBE_CONFIG}" && -r "${KUBE_CONFIG}" ]] || die "Set KUBECONFIG to the Supervisor admin kubeconfig, or use --kubeconfig"
kube() { kubectl --kubeconfig="${KUBE_CONFIG}" --request-timeout=30s "$@"; }
get_deployment() { kube -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" -o json; }
get_capabilities() { kube get "${CAP_RESOURCE}" "${CAP_NAME}" -o json; }

FAILURE_REASON="Failed to inspect the VM Operator deployment; see pod logs."
DEPLOYMENT_JSON="$(get_deployment)"
jq -e --arg container "${CONTAINER}" '
    (.spec.paused != true) and ((.spec.replicas // 1) > 0) and
    ([.spec.template.spec.containers[] | select(.name == $container)] | length == 1)
' <<<"${DEPLOYMENT_JSON}" >/dev/null || die "Expected a running, unpaused deployment with one ${CONTAINER} container"

if [[ "${CAP_COUNT}" -gt 0 ]]; then
    # This operator reads these capabilities from the CR only in async mode.
    jq -e --arg container "${CONTAINER}" '
        [.spec.template.spec.containers[] | select(.name == $container) |
         .env[]? | select(.name == "FSS_WCP_SUPERVISOR_ASYNC_UPGRADE") |
         select(.valueFrom == null) | .value | ascii_downcase] as $values |
        ($values | length == 1) and
        ($values[0] == "true" or $values[0] == "1" or $values[0] == "t")
    ' <<<"${DEPLOYMENT_JSON}" >/dev/null || die "Operator must have literal FSS_WCP_SUPERVISOR_ASYNC_UPGRADE=true; the legacy ConfigMap does not activate this inventory"

    FAILURE_REASON="Failed to inspect Supervisor capabilities; see pod logs."
    CAP_JSON="$(get_capabilities)"
    MISSING="$(jq -r --argjson names "${CAPABILITIES}" '
        .spec.supervisor as $spec | $names[] as $name |
        select([$spec[]? | select(.name == $name)] | length != 1) | $name
    ' <<<"${CAP_JSON}")"
    [[ -z "${MISSING}" ]] || die "Capabilities absent or duplicated in ${CAP_NAME}: ${MISSING}"
    kube auth can-i patch "${CAP_RESOURCE}/${CAP_NAME}" --quiet || die "Kubeconfig cannot patch Supervisor capabilities"
fi
kube -n "${NAMESPACE}" auth can-i patch "deployments.apps/${DEPLOYMENT}" --quiet || die "Kubeconfig cannot patch VM Operator deployment"

pending_capabilities() {
    jq -r --argjson names "${CAPABILITIES}" '
        . as $cr | $names[] as $name |
        select(([$cr.spec.supervisor[]? | select(.name == $name and .enabled == true)] | length) != 1 or
               $cr.status.supervisor[$name].activated != true) | $name
    '
}

if [[ "${CAP_COUNT}" -gt 0 ]]; then
    # Test resourceVersion so another writer cannot reorder the list or have its
    # changes overwritten between the GET and PATCH. A conflict fails the run.
    CAP_PATCH="$(jq -c --argjson names "${CAPABILITIES}" '
        [{op: "test", path: "/metadata/resourceVersion", value: .metadata.resourceVersion}] +
        [.spec.supervisor | to_entries[] |
         select(.value.name as $name | $names | index($name)) |
         select(.value.enabled != true) |
         {op: "add", path: ("/spec/supervisor/" + (.key | tostring) + "/enabled"), value: true}]
    ' <<<"${CAP_JSON}")"
    if [[ "$(jq length <<<"${CAP_PATCH}")" -gt 1 ]]; then
        log "Requesting Supervisor capability enablement..."
        MUTATION_STARTED=true
        FAILURE_REASON="Failed to enable Supervisor capabilities; see pod logs."
        kube patch "${CAP_RESOURCE}" "${CAP_NAME}" --type=json --patch="${CAP_PATCH}"
    fi

    log "Waiting up to ${TIMEOUT}s for effective capability activation..."
    FAILURE_REASON="Failed while waiting for capability activation; see pod logs."
    DEADLINE=$((SECONDS + TIMEOUT))
    while true; do
        CAP_JSON="$(get_capabilities)"
        PENDING="$(pending_capabilities <<<"${CAP_JSON}")"
        [[ -n "${PENDING}" ]] || break
        if (( SECONDS >= DEADLINE )); then
            jq -r --argjson names "${CAPABILITIES}" '
                . as $cr | .spec.supervisor[] |
                select(.name as $name | $names | index($name)) |
                select(.enabled != true or $cr.status.supervisor[.name].activated != true) |
                "  \(.name): enabled=\(.enabled), activated=\($cr.status.supervisor[.name].activated // false), rule=\(.activatedWhenRule // .activationRule // "<none>")"
            ' <<<"${CAP_JSON}" >&2
            die "Timed out waiting for capability activation. Resolve the platform prerequisites/activation controller before rerunning. VM Operator FSSs have not been patched."
        fi
        REMAINING=$((DEADLINE - SECONDS))
        sleep "$((REMAINING < 5 ? REMAINING : 5))"
    done
fi

# Patch only the selected container env entries, preserving other settings. The
# annotation guarantees a new rollout after activation even if envs were true.
FAILURE_REASON="Failed to configure VM Operator FSS variables; see pod logs."
DEPLOYMENT_JSON="$(get_deployment)"
DEPLOYMENT_PATCH="$(jq -cn --argjson envs "${ENV_NAMES}" --arg container "${CONTAINER}" \
    --arg stamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')-$$" \
    --arg rv "$(jq -r .metadata.resourceVersion <<<"${DEPLOYMENT_JSON}")" '
    {metadata: {resourceVersion: $rv}, spec: {template: {
        metadata: {annotations: {"vmoperator.vmware.com/in-progress-features-enabled-at": $stamp}},
        spec: {containers: [{name: $container, env: [$envs[] | {name: ., value: "true", valueFrom: null}]}]}
    }}}
')"
log "Setting VM Operator FSS variables and rolling out ${NAMESPACE}/${DEPLOYMENT}..."
MUTATION_STARTED=true
kube -n "${NAMESPACE}" patch deployment "${DEPLOYMENT}" --type=strategic --patch="${DEPLOYMENT_PATCH}"
FAILURE_REASON="VM Operator rollout failed after feature enablement; see pod logs."
kubectl --kubeconfig="${KUBE_CONFIG}" --request-timeout="${TIMEOUT}s" -n "${NAMESPACE}" \
    rollout status "deployment/${DEPLOYMENT}" --timeout="${TIMEOUT}s"

FAILURE_REASON="Failed to verify enabled features after VM Operator rollout; see pod logs."
DEPLOYMENT_JSON="$(get_deployment)"
jq -e --arg container "${CONTAINER}" --argjson names "${ENV_NAMES}" '
    [.spec.template.spec.containers[] | select(.name == $container) | .env[]?] as $envs |
    all($names[]; . as $name |
        ([$envs[] | select(.name == $name and .value == "true" and .valueFrom == null)] | length) == 1)
' <<<"${DEPLOYMENT_JSON}" >/dev/null || die "VM Operator FSS values changed during rollout"
if [[ "${CAP_COUNT}" -gt 0 ]]; then
    CAP_JSON="$(get_capabilities)"
    PENDING="$(pending_capabilities <<<"${CAP_JSON}")"
    [[ -z "${PENDING}" ]] || die "Capabilities are no longer enabled/activated: ${PENDING}"
fi
log "Enabled and verified ${CAP_COUNT} capability switches and ${ENV_COUNT} VM Operator FSS variables; rollout completed."

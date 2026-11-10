#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C

readonly EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-lab-node-01}"

failures=0

info() {
  printf 'INFO: %s\n' "$*"
}

pass() {
  printf 'PASS: %s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

declare -Ar EXPECTED_STORAGE_CLASSES=(
  ["linkding/linkding-data-pvc"]="local-path"
  ["audiobookshelf/audiobookshelf-audiobooks-pvc"]="local-path-retain"
  ["audiobookshelf/audiobookshelf-config-pvc"]="local-path-retain"
  ["audiobookshelf/audiobookshelf-metadata-pvc"]="local-path-retain"
  ["audiobookshelf/audiobookshelf-podcasts-pvc"]="local-path-retain"
)

declare -Ar EXPECTED_WORKLOADS=(
  ["linkding/linkding-data-pvc"]="deployment/linkding"
  ["audiobookshelf/audiobookshelf-audiobooks-pvc"]="deployment/audiobookshelf"
  ["audiobookshelf/audiobookshelf-config-pvc"]="deployment/audiobookshelf"
  ["audiobookshelf/audiobookshelf-metadata-pvc"]="deployment/audiobookshelf"
  ["audiobookshelf/audiobookshelf-podcasts-pvc"]="deployment/audiobookshelf"
)

info "Starting persistent-volume inventory"
info "Timestamp: $(date --utc '+%Y-%m-%dT%H:%M:%SZ')"

if [[ "$EUID" -ne 0 ]]; then
  fail "This script must run as root using sudo"
  printf '\nPVC inventory result: FAILED\n' >&2
  exit 1
fi

if ((BASH_VERSINFO[0] < 4)); then
  fail "Bash 4 or newer is required for associative arrays"
  printf '\nPVC inventory result: FAILED\n' >&2
  exit 1
fi

actual_hostname="$(hostname --short)"

if [[ "$actual_hostname" == "$EXPECTED_HOSTNAME" ]]; then
  pass "Expected host confirmed: ${actual_hostname}"
else
  fail "Expected host ${EXPECTED_HOSTNAME}, found ${actual_hostname}"
fi

if ! command -v k3s >/dev/null 2>&1; then
  fail "Required command is missing: k3s"
  printf '\nPVC inventory result: FAILED\n' >&2
  exit 1
fi

if ! k3s kubectl get --raw='/readyz' >/dev/null 2>&1; then
  fail "Kubernetes API did not report ready"
  printf '\nPVC inventory result: FAILED\n' >&2
  exit 1
fi

pass "Kubernetes API reports ready"

printf '\nCurrent persistent-volume claims:\n\n'

k3s kubectl get pvc --all-namespaces

pvc_rows="$(
  k3s kubectl get pvc --all-namespaces \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.storageClassName}{"|"}{.spec.volumeName}{"\n"}{end}'
)"

declare -A ACTUAL_PHASES=()
declare -A ACTUAL_STORAGE_CLASSES=()
declare -A ACTUAL_VOLUMES=()

while IFS='|' read -r namespace pvc phase storage_class volume; do
  if [[ -z "$namespace" || -z "$pvc" ]]; then
    continue
  fi

  pvc_id="${namespace}/${pvc}"

  if [[ -n "${ACTUAL_PHASES[$pvc_id]+present}" ]]; then
    fail "Duplicate PVC identity discovered: ${pvc_id}"
    continue
  fi

  ACTUAL_PHASES["$pvc_id"]="$phase"
  ACTUAL_STORAGE_CLASSES["$pvc_id"]="$storage_class"
  ACTUAL_VOLUMES["$pvc_id"]="$volume"

  if [[ -z "${EXPECTED_STORAGE_CLASSES[$pvc_id]+expected}" ]]; then
    fail "Unknown PVC is not covered by the backup plan: ${pvc_id}"
  fi
done <<<"$pvc_rows"

mapfile -t expected_pvc_ids < <(
  printf '%s\n' "${!EXPECTED_STORAGE_CLASSES[@]}" | sort
)

for pvc_id in "${expected_pvc_ids[@]}"; do
  namespace="${pvc_id%%/*}"
  pvc="${pvc_id#*/}"

  if [[ -z "${ACTUAL_PHASES[$pvc_id]+present}" ]]; then
    fail "Expected PVC is missing: ${pvc_id}"
    continue
  fi

  if [[ "${ACTUAL_PHASES[$pvc_id]}" == "Bound" ]]; then
    pass "PVC is Bound: ${pvc_id}"
  else
    fail "PVC is not Bound: ${pvc_id} (${ACTUAL_PHASES[$pvc_id]})"
  fi

  expected_storage_class="${EXPECTED_STORAGE_CLASSES[$pvc_id]}"
  actual_storage_class="${ACTUAL_STORAGE_CLASSES[$pvc_id]}"

  if [[ "$actual_storage_class" == "$expected_storage_class" ]]; then
    pass "StorageClass is expected for ${pvc_id}: ${actual_storage_class}"
  else
    fail "Unexpected StorageClass for ${pvc_id}: expected ${expected_storage_class}, found ${actual_storage_class}"
  fi

  if [[ -n "${ACTUAL_VOLUMES[$pvc_id]}" ]]; then
    pass "PVC has a bound volume: ${pvc_id}"
  else
    fail "PVC has no bound volume: ${pvc_id}"
  fi

  workload="${EXPECTED_WORKLOADS[$pvc_id]}"
  workload_type="${workload%%/*}"
  workload_name="${workload#*/}"

  if ! mounted_claims="$(
    k3s kubectl \
      --namespace "$namespace" \
      get "$workload_type" "$workload_name" \
      -o jsonpath='{range .spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
      2>/dev/null
  )"; then
    fail "Unable to inspect expected workload: ${namespace}/${workload}"
    continue
  fi

  if grep --fixed-strings --line-regexp --quiet "$pvc" <<<"$mounted_claims"; then
    pass "PVC is declared by ${namespace}/${workload}: ${pvc}"
  else
    fail "PVC is not declared by ${namespace}/${workload}: ${pvc}"
  fi
done

expected_count="${#EXPECTED_STORAGE_CLASSES[@]}"
actual_count="${#ACTUAL_PHASES[@]}"

info "Expected PVC count: ${expected_count}"
info "Actual PVC count: ${actual_count}"

if ((actual_count != expected_count)); then
  fail "Actual PVC count does not match the backup inventory"
fi

printf '\nPVC inventory summary: %d failure(s)\n' "$failures"

if ((failures > 0)); then
  printf 'PVC inventory result: FAILED\n' >&2
  exit 1
fi

printf 'PVC inventory result: PASSED\n'

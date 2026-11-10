#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C

readonly EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-lab-node-01}"

readonly K3S_DB_DIR="/var/lib/rancher/k3s/server/db"
readonly K3S_TOKEN_FILE="/var/lib/rancher/k3s/server/token"
readonly K3S_CONFIG_DIR="/etc/rancher/k3s"
readonly K3S_STORAGE_DIR="/var/lib/rancher/k3s/storage"
readonly K3S_SERVICE_FILE="/etc/systemd/system/k3s.service"
readonly -a K3S_ENV_FILES=(
  "/etc/default/k3s"
  "/etc/sysconfig/k3s"
  "/etc/systemd/system/k3s.service.env"
)
readonly BACKUP_PARENT_DIR="/var/backups"
readonly SPACE_MULTIPLIER=2
readonly SPACE_BUFFER_BYTES=1073741824

failures=0
warnings=0

info() {
  printf 'INFO: %s\n' "$*"
}

pass() {
  printf 'PASS: %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
  warnings=$((warnings + 1))
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

check_command() {
  local command_name="$1"

  if command -v "$command_name" >/dev/null 2>&1; then
    pass "Required command is available: ${command_name}"
  else
    fail "Required command is missing: ${command_name}"
  fi
}

check_directory() {
  local directory="$1"
  local description="$2"

  if [[ -d "$directory" ]]; then
    pass "${description}: ${directory}"
  else
    fail "${description} is missing: ${directory}"
  fi
}

check_nonempty_file() {
  local file="$1"
  local description="$2"

  if [[ -s "$file" ]]; then
    pass "${description}: ${file}"
  else
    fail "${description} is missing or empty: ${file}"
  fi
}

check_optional_file() {
  local file="$1"
  local description="$2"

  if [[ -s "$file" ]]; then
    pass "${description} exists and contains configuration: ${file}"
  elif [[ -f "$file" ]]; then
    info "${description} exists but is empty: ${file}"
  elif [[ -e "$file" ]]; then
    fail "${description} exists but is not a regular file: ${file}"
  else
    info "${description} is not present: ${file}"
  fi
}

format_bytes() {
  numfmt --to=iec --suffix=B "$1"
}

info "Starting homelab backup pre-flight checks"
info "Timestamp: $(date --utc '+%Y-%m-%dT%H:%M:%SZ')"

if [[ "$EUID" -ne 0 ]]; then
  fail "This script must run as root using sudo"
  printf '\nPre-flight result: FAILED\n' >&2
  exit 1
fi

pass "Script is running as root"

required_commands=(
  awk
  date
  df
  du
  flock
  hostname
  k3s
  numfmt
  sha256sum
  systemctl
  tar
  timedatectl
)

for command_name in "${required_commands[@]}"; do
  check_command "$command_name"
done

if ((failures > 0)); then
  printf '\nPre-flight result: FAILED\n' >&2
  printf 'Resolve missing commands before continuing.\n' >&2
  exit 1
fi

actual_hostname="$(hostname --short)"

if [[ "$actual_hostname" == "$EXPECTED_HOSTNAME" ]]; then
  pass "Expected host confirmed: ${actual_hostname}"
else
  fail "Expected host ${EXPECTED_HOSTNAME}, found ${actual_hostname}"
fi

if systemctl is-active --quiet k3s; then
  pass "K3s service is active"
else
  fail "K3s service is not active"
fi

api_response="$(
  k3s kubectl get --raw='/readyz' 2>/dev/null || true
)"

if [[ "$api_response" == "ok" ]]; then
  pass "Kubernetes API reports ready"
else
  fail "Kubernetes API did not report ready"
fi

node_ready_status="$(
  k3s kubectl get node "$EXPECTED_HOSTNAME" \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || true
)"

if [[ "$node_ready_status" == "True" ]]; then
  pass "Control-plane node reports Ready"
else
  fail "Control-plane node does not report Ready"
fi

check_directory \
  "$K3S_DB_DIR" \
  "K3s datastore directory"

check_nonempty_file \
  "$K3S_TOKEN_FILE" \
  "K3s server token"

check_directory \
  "$K3S_CONFIG_DIR" \
  "K3s configuration directory"

check_directory \
  "$K3S_STORAGE_DIR" \
  "K3s local-path storage directory"

check_nonempty_file \
  "$K3S_SERVICE_FILE" \
  "K3s systemd service file"

for environment_file in "${K3S_ENV_FILES[@]}"; do
  check_optional_file \
    "$environment_file" \
    "Optional K3s environment file"
done

if [[ -d "$BACKUP_PARENT_DIR" && -w "$BACKUP_PARENT_DIR" ]]; then
  pass "Backup parent directory exists and is writable: ${BACKUP_PARENT_DIR}"
else
  fail "Backup parent directory is missing or not writable: ${BACKUP_PARENT_DIR}"
fi

ntp_status="$(
  timedatectl show \
    --property=NTPSynchronized \
    --value \
    2>/dev/null || true
)"

if [[ "$ntp_status" == "yes" ]]; then
  pass "System clock is synchronized"
else
  warn "System clock does not report as synchronized"
fi

if [[ -d "$K3S_DB_DIR" && -d "$K3S_STORAGE_DIR" ]]; then
  source_bytes="$(
    du -sb "$K3S_DB_DIR" "$K3S_STORAGE_DIR" 2>/dev/null |
      awk '{ total += $1 } END { print total }'
  )"

  free_bytes="$(
    df \
      --output=avail \
      --block-size=1 \
      "$BACKUP_PARENT_DIR" |
      awk 'NR == 2 { print $1 }'
  )"

  if [[ "$source_bytes" =~ ^[0-9]+$ && "$free_bytes" =~ ^[0-9]+$ ]]; then
    required_bytes=$(((source_bytes * SPACE_MULTIPLIER) + SPACE_BUFFER_BYTES))

    info "Estimated source data: $(format_bytes "$source_bytes")"
    info "Required free space: $(format_bytes "$required_bytes")"
    info "Available free space: $(format_bytes "$free_bytes")"

    if ((free_bytes >= required_bytes)); then
      pass "Sufficient backup staging space is available"
    else
      fail "Insufficient backup staging space is available"
    fi
  else
    fail "Unable to calculate backup source size or free space"
  fi
else
  fail "Disk-space calculation skipped because source directories are missing"
fi

printf '\n'
printf 'Pre-flight summary: %d failure(s), %d warning(s)\n' \
  "$failures" \
  "$warnings"

if ((failures > 0)); then
  printf 'Pre-flight result: FAILED\n' >&2
  exit 1
fi

printf 'Pre-flight result: PASSED\n'

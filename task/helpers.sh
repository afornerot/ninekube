#!/bin/bash

# ─── KUBECONFIG ──────────────────────────────────────────────────────────────────
[ -f /etc/rancher/k3s/k3s.yaml ] && export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ─── COLORS ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── OUTPUT HELPERS ──────────────────────────────────────────────────────────────
ok()     { echo -e "  ${GREEN}✔${NC} $1"; }
ko()     { echo -e "  ${RED}✘${NC} $1"; }
warn()   { echo -e "  ${YELLOW}○${NC} $1"; }
info()   { echo -e "  ${YELLOW}…${NC} $1"; }
dim()    { echo -e "  ${DIM}$1${NC}"; }
bold()   { echo -e "${BOLD}$1${NC}"; }
hint()   { echo -e "  ${DIM}→ $1${NC}"; }

header() {
  local title="$1"
  echo ""
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────┐${NC}"
  printf "${BOLD}${CYAN}│  %-40s│${NC}\n" "$title"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────┘${NC}"
  echo ""
}

section() {
  local title="$1"
  echo -e "  ${BOLD}$title${NC}"
}

done_ok()   { echo ""; echo -e "  ${GREEN}${BOLD}DONE${NC} ${GREEN}— $1${NC}"; echo ""; }
done_warn() { echo ""; echo -e "  ${YELLOW}${BOLD}DONE${NC} ${YELLOW}— $1${NC}"; echo ""; }
done_ko()   { echo ""; echo -e "  ${RED}${BOLD}FAILED${NC} ${RED}— $1${NC}"; echo ""; }

indent() { sed 's/^/    /'; }

# ─── MANIFEST HELPERS ──────────────────────────────────────────────────────────
# Apply a manifest from stdin heredoc. Usage:
#   apply_manifest <<EOF
#   apiVersion: v1
#   kind: ConfigMap
#   ...
#   EOF
apply_manifest() {
  local tmpfile
  tmpfile=$(mktemp --suffix=.yaml)
  cat > "$tmpfile"
  kubectl apply -f "$tmpfile" 2>&1 | indent
  rm -f "$tmpfile"
}

# Ensure namespace exists
ensure_namespace() {
  local ns="${1:-nine}"
  kubectl create namespace "$ns" --dry-run=client -o yaml 2>&1 | kubectl apply -f - 2>&1 | indent
}

# ─── PROJECT PATHS ───────────────────────────────────────────────────────────────
NINEKUBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${NINEKUBE_DIR}/base"
CONFIG_DIR="${NINEKUBE_DIR}/.ninekube"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"

# ─── CONFIG FILE OPERATIONS ──────────────────────────────────────────────────────
# Read value from .ninekube/config.yaml, return default if not found
config_get() {
  local key="$1" default="$2"
  if [ -f "$CONFIG_FILE" ]; then
    local val
    val=$(grep "^${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | sed "s/^${key}: *//")
    [ -n "$val" ] && echo "$val" && return
  fi
  echo "$default"
}

# Write value to .ninekube/config.yaml
config_set() {
  local key="$1" value="$2"
  mkdir -p "$CONFIG_DIR"
  if [ -f "$CONFIG_FILE" ] && grep -q "^${key}:" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$CONFIG_FILE"
  else
    echo "${key}: ${value}" >> "$CONFIG_FILE"
  fi
}

# Read value from base YAML manifests (key: "value" or key: value)
base_val() {
  local file="$1" key="$2"
  grep "${key}:" "${BASE_DIR}/${file}" 2>/dev/null | head -1 \
    | sed "s/.*${key}: *//" | sed 's/^"//' | sed 's/"$//'
}

# ─── PROMPTS ─────────────────────────────────────────────────────────────────────
# Ask for a value with default ( Enter to keep )
ask_value() {
  local msg="$1" current="$2"
  echo -e -n "  ${BOLD}${CYAN}?${NC} ${msg} ${BOLD}[${current}]${NC} " >&2
  read -r answer
  [ -z "$answer" ] && answer="$current"
  echo "$answer"
}

# Ask for a value with min/max length validation (re-prompts on invalid input)
ask_value_constrained() {
  local msg="$1" current="$2" min="${3:-1}" max="${4:-999}"
  local answer="$current"
  while true; do
    echo -e -n "  ${BOLD}${CYAN}?${NC} ${msg} ${BOLD}[${current}]${NC} " >&2
    read -r input
    [ -n "$input" ] && answer="$input"
    if [ ${#answer} -ge "$min" ] && [ ${#answer} -le "$max" ]; then
      echo "$answer"
      return
    fi
    echo -e "  ${RED}ERROR:${NC} Value must be between ${min} and ${max} characters (current: ${#answer})" >&2
  done
}

# Ask Y/N question (returns 0 for yes, 1 for no)
ask_yn() {
  local msg="$1"
  echo -e -n "  ${BOLD}${CYAN}?${NC} ${msg} ${BOLD}[Y/n]${NC} " >&2
  read -r answer
  [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
}

# ─── KUBERNETES HELPERS ──────────────────────────────────────────────────────────
# Get first pod name matching a label selector in a namespace
k8s_pod() {
  local ns="$1" label="$2"
  kubectl get pod -n "$ns" -l "$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Get pod phase matching a label selector
k8s_pod_phase() {
  local ns="$1" label="$2"
  kubectl get pod -n "$ns" -l "$label" -o jsonpath='{.items[0].status.phase}' 2>/dev/null
}

# Wait for a pod to be Running
k8s_wait_pod() {
  local ns="$1" label="$2" timeout="${3:-60}"
  for i in $(seq 1 "$timeout"); do
    local phase
    phase=$(k8s_pod_phase "$ns" "$label")
    [ "$phase" = "Running" ] && return 0
    sleep 2
  done
  return 1
}

# Detect deployment name by service label (works with/without overlay prefix)
# Usage: k8s_detect_deploy <namespace> <service-name>
k8s_detect_deploy() {
  local ns="$1" service="$2"
  kubectl get deploy -n "$ns" -l "app.kubernetes.io/name=${service}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Wait for pod to be running and return its name
# Usage: k8s_ensure_pod <namespace> <service-name> [timeout]
k8s_ensure_pod() {
  local ns="$1" service="$2" timeout="${3:-120}"
  if ! k8s_wait_pod "$ns" "app.kubernetes.io/name=${service}" "$timeout"; then
    return 1
  fi
  k8s_pod "$ns" "app.kubernetes.io/name=${service}"
}

# Exec a command in a service pod
# Usage: k8s_exec <namespace> <service-name> -- <command...>
k8s_exec() {
  local ns="$1" service="$2"
  shift 2
  local pod
  pod=$(k8s_pod "$ns" "app.kubernetes.io/name=${service}")
  if [ -z "$pod" ]; then
    return 1
  fi
  kubectl exec -n "$ns" "$pod" -- "$@"
}

# Wait for a command to succeed (retries)
# Usage: k8s_wait_ready <namespace> <service-name> <description> <timeout> -- <command...>
k8s_wait_ready() {
  local ns="$1" service="$2" desc="$3" timeout="$4"
  shift 4
  for i in $(seq 1 "$timeout"); do
    if k8s_exec "$ns" "$service" -- "$@" 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# Apply a ConfigMap only if its content has changed
# Compares a local file against the deployed ConfigMap key, applies if different
# Usage: k8s_apply_configmap <namespace> <configmap-name> <data-key> <local-file>
k8s_apply_configmap() {
  local ns="$1" cm_name="$2" data_key="$3" local_file="$4"
  local current
  current=$(kubectl get configmap "$cm_name" -n "$ns" \
    -o jsonpath="{.data.${data_key}}" 2>/dev/null)
  local desired
  desired=$(cat "$local_file")
  if [ "$desired" = "$current" ]; then
    return 1  # unchanged
  fi
  # Build and apply
  local tmpyaml
  tmpyaml=$(mktemp --suffix=.yaml)
  cat > "$tmpyaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${cm_name}
  namespace: ${ns}
data:
  ${data_key}: |
EOF
  while IFS= read -r line || [ -n "$line" ]; do
    printf "    %s\n" "$line" >> "$tmpyaml"
  done < "$local_file"
  kubectl apply -f "$tmpyaml" 2>&1
  rm -f "$tmpyaml"
  return 0  # changed
}

# Generate enabled-services/kustomization.yaml from symlinks
generate_enabled_kustomization() {
  local enabled_dir="${BASE_DIR}/enabled-services"
  mkdir -p "${enabled_dir}"
  local kust_file="${enabled_dir}/kustomization.yaml"

  local services=()
  for link in "${enabled_dir}"/*/; do
    [ -L "${link%/}" ] || continue
    services+=("$(basename "${link%/}")")
  done

  cat > "${kust_file}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
EOF

  if [ ${#services[@]} -eq 0 ]; then
    cat > "${enabled_dir}/noop.yaml" <<NOOP
apiVersion: v1
kind: ConfigMap
metadata:
  name: enabled-services-state
  namespace: nine
data: {}
NOOP
    echo "  - noop.yaml" >> "${kust_file}"
  else
    rm -f "${enabled_dir}/noop.yaml"
    for svc in "${services[@]}"; do
      echo "  - ${svc}" >> "${kust_file}"
    done
  fi
}

# Generate base/.env from .ninekube/config.yaml (called before kustomize builds)
generate_env() {
  local domain
  domain=$(config_get domain 'nine.local')
  local email
  email=$(config_get email "admin@${domain}")

  cat > "${BASE_DIR}/.env" <<EOF
DOMAIN=${domain}
MINIO_HOST=minio.${domain}
CLUSTER_EMAIL=${email}
EOF
}

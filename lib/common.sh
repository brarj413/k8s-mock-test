# shellcheck shell=bash
# Shared helpers for the k8s-mock-test scripts. Source it; don't run it.
# Bash 3.2 compatible (macOS): no associative arrays, mapfile or ${v,,}.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- config ------------------------------------------------------------------

# config.local.env (git-ignored) is read before config.env, and both only set
# variables that are still unset, so: environment > config.local.env > defaults.
load_config() {
  # shellcheck source=/dev/null
  [ -f "$ROOT_DIR/config.local.env" ] && . "$ROOT_DIR/config.local.env"
  # shellcheck source=../config.env
  . "$ROOT_DIR/config.env"
}

# --- output ------------------------------------------------------------------

if [ -t 1 ]; then
  C_BOLD=$'\033[1m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_RESET=$'\033[0m'
else
  C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_RESET=""
fi

log()  { printf '%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%sWARN:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is required but not in PATH"
  done
}

# --- cluster access ------------------------------------------------------------

k() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}

h() {
  if [ -n "${KUBE_CONTEXT:-}" ]; then helm --kube-context "$KUBE_CONTEXT" "$@"; else helm "$@"; fi
}

check_cluster() {
  k version >/dev/null 2>&1 || die "cannot reach the cluster (KUBECONFIG=${KUBECONFIG:-~/.kube/config} context=${KUBE_CONTEXT:-current})"
  info "cluster: $(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')${KUBE_CONTEXT:+ (context $KUBE_CONTEXT)}"
}

# --- GPU catalog -------------------------------------------------------------

GPU_VARS="GPU_NAME GPU_PRODUCT GPU_COUNT GPU_MEMORY_MIB GPU_FAMILY GPU_COMPUTE_MAJOR
GPU_COMPUTE_MINOR NODE_ARCH NODE_CPU NODE_MEMORY"

# Fails unless every type in GPU_TYPES has a catalog file.
check_gpu_types() {
  local t f known=""
  [ -n "$GPU_TYPES" ] || die "GPU_TYPES is empty"
  for f in "$ROOT_DIR"/gpus/*.env; do
    f=${f##*/}
    known="$known ${f%.env}"
  done
  for t in $GPU_TYPES; do
    [ -f "$ROOT_DIR/gpus/$t.env" ] || die "unknown GPU type '$t' (known:$known)"
  done
}

# Loads gpus/<type>.env into the GPU_* / NODE_* variables.
load_gpu() {
  local v
  for v in $GPU_VARS; do unset "$v"; done
  # shellcheck source=/dev/null
  . "$ROOT_DIR/gpus/$1.env"
  # shellcheck disable=SC2034 # used by lib/render.sh
  GPU_TYPE="$1"
}

# --- waiting -----------------------------------------------------------------

# wait_until <timeout-seconds> <description> <command...>: polls every 5s.
wait_until() {
  local timeout="$1" what="$2" waited=0
  shift 2
  until "$@" >/dev/null 2>&1; do
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 5
    waited=$((waited + 5))
  done
  if [ -n "$what" ]; then info "$what"; fi
}

# "600s" -> 600
seconds() { echo "${1%s}"; }

# --- test results ------------------------------------------------------------

RESULTS=""
FAILURES=0

# record <PASS|FAIL> <gpu type> <check> [detail]
record() {
  local status="$1" type="$2" check="$3" detail="${4:-}"
  RESULTS="${RESULTS}${status}|${type}|${check}|${detail}
"
  if [ "$status" = PASS ]; then
    printf '    %sPASS%s %-6s %s %s\n' "$C_GREEN" "$C_RESET" "$type" "$check" "${detail:+($detail)}"
  else
    FAILURES=$((FAILURES + 1))
    printf '    %sFAIL%s %-6s %s %s\n' "$C_RED" "$C_RESET" "$type" "$check" "${detail:+($detail)}"
  fi
}

# Prints the summary table and exits non-zero when anything failed.
finish() {
  local total
  total=$(printf '%s' "$RESULTS" | grep -c '|' || true)
  echo
  log "Summary: $((total - FAILURES))/$total checks passed"
  printf '%s' "$RESULTS" | awk -F'|' 'NF >= 3 { printf "    %-4s  %-6s  %s%s\n", $1, $2, $3, ($4 == "" ? "" : "  (" $4 ")") }'
  [ "$FAILURES" -eq 0 ] || exit 1
}

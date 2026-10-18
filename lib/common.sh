# shellcheck shell=bash disable=SC2034
# (SC2034: variables here are consumed by lab.sh and the scenario files.)
# Shared helpers for lab.sh and every scenario.
# Kept bash 3.2 compatible so the lab also runs on macOS.

CLUSTER="trouble-lab"
CTX="kind-${CLUSTER}"
CP="${CLUSTER}-control-plane"
W1="${CLUSTER}-worker"
W2="${CLUSTER}-worker2"

STATE_DIR="${LAB_ROOT}/.lab"
BACKUP_DIR="${STATE_DIR}/backup"
NODE_BACKUP="/root/.lab-backup"   # inside node containers, never inside a manifest dir

METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"

# Images used by scenarios. Preloaded into the nodes by `./lab.sh up` (best effort).
PRELOAD_IMAGES="nginx:1.27-alpine busybox:1.36 curlimages/curl:8.10.1 redis:7.2-alpine python:3.12-alpine"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

info() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
warn() { printf '%s !%s  %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s x%s  %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# Every kubectl call the lab makes is pinned to the lab cluster,
# whatever your current context is (never touches EKS or prod by accident).
k() { kubectl --context "$CTX" "$@"; }

# ---------------------------------------------------------------- checks ---
CHECK_FAILED=0
pass() { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
fail() { printf '  %s✘%s %s\n' "$RED" "$RESET" "$*"; CHECK_FAILED=1; }
expect() {   # expect "<description>" <command> [args...]
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# ------------------------------------------------------------- queries ---
wait_until() {   # wait_until <seconds> <command> [args...]
  local limit="$1" waited=0; shift
  while [ "$waited" -lt "$limit" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

deploy_ready() {   # deploy_ready <ns> <deploy> <min-ready>
  local r
  r="$(k -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [ "${r:-0}" -ge "${3:-1}" ] 2>/dev/null
}

wait_deploy() { k -n "$1" rollout status "deploy/$2" --timeout="${3:-180s}" >/dev/null 2>&1 || true; }

image_matches() {  # image_matches <ns> <deploy> <extended-regex>
  k -n "$1" get deploy "$2" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -Eq "$3"
}

first_pod() {      # first Running pod matching a label selector
  k -n "$1" get pod -l "$2" --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

pod_sh() {         # pod_sh <ns> <selector> "<shell command>"
  local ns="$1" sel="$2" p; shift 2
  p="$(first_pod "$ns" "$sel")"
  [ -n "$p" ] || return 1
  k -n "$ns" exec "$p" -- sh -c "$*"
}

latest_log_has() { # latest_log_has <ns> <deploy> <text>
  k -n "$1" logs "deploy/$2" --tail=1 2>/dev/null | grep -q "$3"
}

node_ready() {
  [ "$(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

node_schedulable() {
  [ "$(k get node "$1" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)" != "true" ]
}

cp_ready() {       # cp_ready <component>  e.g. kube-scheduler
  [ "$(k -n kube-system get pod -l component="$1" \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]
}

api_ready() { [ "$(k get --raw=/readyz 2>/dev/null)" = "ok" ]; }

# ---------------------------------------------------------- namespaces ---
ns_apply()  { k create namespace "$1" --dry-run=client -o yaml | k apply -f - >/dev/null; }
ns_delete() { k delete namespace "$1" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
ns_fresh() {
  if [ "$(k get ns "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Terminating" ]; then
    k wait --for=delete "ns/$1" --timeout=180s >/dev/null 2>&1 || return 1
  fi
  ns_apply "$1"
}

# ---------------------------------------------------------------- nodes ---
# Back up a file inside a node container. Only the FIRST copy is kept,
# so re-running a scenario never overwrites the pristine original.
node_backup() {    # node_backup <node> <file>
  docker exec "$1" sh -c 'mkdir -p "$1" && b="$1/$(basename "$2")" && { [ -f "$b" ] || cp -p "$2" "$b"; }' \
    _ "$NODE_BACKUP" "$2"
}

# Restore it. Returns 0 only if the live file differed and was replaced.
node_restore() {   # node_restore <node> <file>
  docker exec "$1" sh -c 'b="$1/$(basename "$2")"; [ -f "$b" ] || exit 1; cmp -s "$b" "$2" && exit 1; cp -p "$b" "$2"' \
    _ "$NODE_BACKUP" "$2"
}

# -------------------------------------------------------------- toolbox ---
# A long-running busybox pod used by checks. Pinned to the control-plane with
# nodeName, so it keeps working even when scheduling or workers are broken.
ensure_toolbox() {
  ns_apply lab-system
  local phase
  phase="$(k -n lab-system get pod toolbox -o jsonpath='{.status.phase}' 2>/dev/null)"
  if [ -n "$phase" ] && [ "$phase" != "Running" ] && [ "$phase" != "Pending" ]; then
    k -n lab-system delete pod toolbox --wait=true >/dev/null 2>&1
    phase=""
  fi
  if [ -z "$phase" ]; then
    k -n lab-system apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: toolbox
  labels:
    app: toolbox
spec:
  nodeName: ${CP}
  tolerations:
    - operator: Exists
  terminationGracePeriodSeconds: 1
  containers:
    - name: toolbox
      image: busybox:1.36
      imagePullPolicy: IfNotPresent
      command: ["sleep", "2147483647"]
EOF
  fi
  k -n lab-system wait --for=condition=Ready pod/toolbox --timeout=120s >/dev/null 2>&1 \
    || { warn "toolbox pod is not Ready; some checks may fail"; return 1; }
}

toolbox() { k -n lab-system exec toolbox -- sh -c "$*"; }
http_ok()  { toolbox "wget -q -T 4 -O /dev/null '$1'"; }
http_get() { toolbox "wget -q -T 4 -O - '$1'"; }

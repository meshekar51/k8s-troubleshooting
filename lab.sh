#!/usr/bin/env bash
# Kubernetes troubleshooting lab — injects production-style faults into a kind
# cluster and prints only the incident ticket. You find and fix the cause.
set -u

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$LAB_ROOT/lib/common.sh"
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
LOG="$STATE_DIR/lab.log"

usage() {
  cat <<EOF

${BOLD}Kubernetes troubleshooting lab${RESET}

  ./lab.sh up              create the kind cluster '${CLUSTER}' and lab add-ons
  ./lab.sh list            list all incidents and your progress
  ./lab.sh start <ID>      inject a fault and print the incident ticket
  ./lab.sh ticket          re-print the active ticket
  ./lab.sh check           verify whether the active incident is resolved
  ./lab.sh reset [ID|all]  undo the active (or given / every) scenario
  ./lab.sh down            delete the cluster and local lab state

  Example: ./lab.sh start L1-01

EOF
}

norm_id()   { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
active_id() { cat "$STATE_DIR/active" 2>/dev/null || true; }
log_mark()  { printf '\n=== %s  %s %s ===\n' "$(date '+%F %T')" "$1" "$2" >>"$LOG"; }

load_scenario() {
  local f="$LAB_ROOT/scenarios/$1.sh"
  [ -f "$f" ] || die "Unknown scenario '$1'. Run ./lab.sh list"
  unset -f scenario_preflight scenario_break scenario_check scenario_reset ticket 2>/dev/null
  ID=""; LEVEL=""; TITLE=""
  # shellcheck disable=SC2034  # consumed by the scenario functions
  NS=""
  # shellcheck source=/dev/null
  . "$f"
}

has_context() { kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX"; }

require_cluster() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
  command -v docker  >/dev/null 2>&1 || die "docker is not installed"
  docker inspect "$CP" >/dev/null 2>&1 || die "Cluster '$CLUSTER' not found. Run ./lab.sh up first."
  has_context || die "kubectl context '$CTX' is missing; the cluster looks half-created. Run: ./lab.sh down && ./lab.sh up"
}

context_hint() {
  local cur
  cur="$(kubectl config current-context 2>/dev/null || true)"
  [ "$cur" = "$CTX" ] || warn "Your kubectl context is '${cur:-none}'. Switch first: kubectl config use-context $CTX"
}

print_ticket() {
  local bar="────────────────────────────────────────────────────────────────────"
  printf '\n%s┌%s%s\n' "$CYAN" "$bar" "$RESET"
  printf '%s│%s %sINCIDENT %s%s  ·  %s  ·  %s\n' "$CYAN" "$RESET" "$BOLD" "$ID" "$RESET" "$LEVEL" "$TITLE"
  printf '%s├%s%s\n' "$CYAN" "$bar" "$RESET"
  ticket | while IFS= read -r line; do printf '%s│%s %s\n' "$CYAN" "$RESET" "$line"; done
  printf '%s└%s%s\n\n' "$CYAN" "$bar" "$RESET"
}

# ------------------------------------------------------------------ up ---
MIN_FREE_GB=10

# Warn about the host conditions that most often make `kind create cluster` time out.
preflight_host() {
  local others avail_mb inst
  others="$(kind get clusters 2>/dev/null | grep -vx "$CLUSTER" | tr '\n' ' ')"
  if [ -n "$others" ]; then
    warn "Other kind clusters are running: ${others}— each multi-node cluster needs ~3-4 GB RAM. Remove unused ones: kind delete cluster --name <name>"
  fi
  if [ -r /proc/meminfo ]; then
    avail_mb="$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)"
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 3500 ]; then
      warn "Only ${avail_mb} MB RAM available; a 3-node kind cluster needs ~3.5 GB."
    fi
  fi
  if [ -r /proc/sys/fs/inotify/max_user_instances ]; then
    inst="$(cat /proc/sys/fs/inotify/max_user_instances)"
    if [ "$inst" -lt 512 ]; then
      warn "fs.inotify.max_user_instances=${inst} is low for kind. Fix: sysctl -w fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
    fi
  fi
}

cmd_up() {
  local b minor img root free_gb issues=0
  for b in docker kind kubectl; do
    command -v "$b" >/dev/null 2>&1 || die "'$b' is required but not installed"
  done
  docker info >/dev/null 2>&1 || die "Docker daemon not reachable (is it running? is your user in the docker group?)"

  minor="$(kind version 2>/dev/null | sed -n 's/^kind v0\.\([0-9][0-9]*\)\..*/\1/p')"
  if [ -n "$minor" ] && [ "$minor" -lt 25 ]; then
    warn "$(kind version | awk '{print $2}') detected — kind v0.25+ is required (NetworkPolicy enforcement)."
  fi

  if docker inspect "$CP" >/dev/null 2>&1; then
    info "Cluster '$CLUSTER' already exists — checking it is healthy"
    has_context || kind export kubeconfig --name "$CLUSTER" >/dev/null 2>&1 || true
    if ! has_context || ! wait_until 60 api_ready; then
      die "Cluster '$CLUSTER' exists but its API does not answer (interrupted 'up', or an L3 incident in progress).
     Fix with:  ./lab.sh down && ./lab.sh up     (or ./lab.sh reset if an incident is active)"
    fi
  else
    root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
    free_gb="$(df -Pk "${root:-/var/lib/docker}" 2>/dev/null | awk 'NR==2 {print int($4 / 1048576)}')"
    if [ -n "$free_gb" ] && [ "$free_gb" -lt "$MIN_FREE_GB" ] && [ -z "${LAB_SKIP_DISK_CHECK:-}" ]; then
      die "Only ${free_gb} GB free under ${root:-/var/lib/docker}; the lab needs ~${MIN_FREE_GB} GB.
     Free space or grow the disk, then re-run.   (Override: LAB_SKIP_DISK_CHECK=1 ./lab.sh up)"
    fi
    preflight_host
    info "Creating kind cluster '$CLUSTER' (1 control-plane + 2 workers). Takes 2-4 min, don't interrupt it."
    if [ -n "${KIND_NODE_IMAGE:-}" ]; then
      kind create cluster --name "$CLUSTER" --config "$LAB_ROOT/kind-config.yaml" --image "$KIND_NODE_IMAGE" \
        || die "kind create cluster failed (usual causes: low RAM, inotify limits, another cluster eating resources — see warnings above). Clean up with: ./lab.sh down"
    else
      kind create cluster --name "$CLUSTER" --config "$LAB_ROOT/kind-config.yaml" \
        || die "kind create cluster failed (usual causes: low RAM, inotify limits, another cluster eating resources — see warnings above). Clean up with: ./lab.sh down"
    fi
  fi
  kubectl config use-context "$CTX" >/dev/null 2>&1 || true

  info "Waiting for nodes to be Ready"
  k wait --for=condition=Ready nodes --all --timeout=240s >/dev/null 2>&1 \
    || die "Nodes are not Ready after 4 minutes. Inspect with: kubectl get nodes ; docker ps -a"

  info "Preloading images into the nodes (best effort)"
  for img in $PRELOAD_IMAGES; do
    if docker pull -q "$img" >/dev/null 2>&1 && kind load docker-image "$img" --name "$CLUSTER" >/dev/null 2>&1; then
      printf '    %s\n' "$img"
    else
      warn "could not preload $img — nodes will pull it on demand"
      issues=$((issues + 1))
    fi
  done

  info "Installing metrics-server"
  if k apply -f "$METRICS_SERVER_URL" >/dev/null 2>&1; then
    if ! k -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' \
        | grep -q kubelet-insecure-tls; then
      k -n kube-system patch deploy metrics-server --type=json \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' >/dev/null
    fi
  else
    warn "metrics-server install failed (needed by one L2 scenario)"
    issues=$((issues + 1))
  fi

  info "Starting the lab toolbox pod"
  ensure_toolbox || issues=$((issues + 1))

  if [ "$issues" -eq 0 ]; then
    printf '\n%sLab ready.%s Next: ./lab.sh list\n\n' "$GREEN" "$RESET"
  else
    printf '\n%sLab is up with %s warning(s) above.%s Fix them and re-run ./lab.sh up (safe to repeat).\n\n' \
      "$YELLOW" "$issues" "$RESET"
  fi
}

# ---------------------------------------------------------------- list ---
cmd_list() {
  local active f total=0 solved=0
  active="$(active_id)"
  printf '\n%s%-7s %-4s %-46s %s%s\n' "$BOLD" "ID" "LVL" "INCIDENT" "STATUS" "$RESET"
  for f in "$LAB_ROOT"/scenarios/*.sh; do
    total=$((total + 1))
    (
      # shellcheck source=/dev/null
      . "$f"
      st=""
      grep -qx "$ID" "$STATE_DIR/solved" 2>/dev/null && st="${GREEN}✔ solved${RESET}"
      [ "$ID" = "$active" ] && st="${YELLOW}▶ active${RESET}"
      printf '%-7s %-4s %-46s %s\n' "$ID" "$LEVEL" "$TITLE" "$st"
    )
  done
  [ -f "$STATE_DIR/solved" ] && solved="$(sort -u "$STATE_DIR/solved" | grep -c .)"
  printf '\n%s%s / %s solved%s\n\n' "$DIM" "$solved" "$total" "$RESET"
}

# --------------------------------------------------------------- start ---
cmd_start() {
  [ $# -ge 1 ] || die "Usage: ./lab.sh start <ID>   (see ./lab.sh list)"
  require_cluster
  local id active
  id="$(norm_id "$1")"
  active="$(active_id)"
  if [ -n "$active" ] && [ "$active" != "$id" ]; then
    die "$active is still active. Run ./lab.sh reset before starting another incident."
  fi
  load_scenario "$id"

  if [ "$active" = "$id" ]; then
    info "Restarting $id from scratch"
    log_mark reset "$id"; scenario_reset >>"$LOG" 2>&1
  fi
  if command -v scenario_preflight >/dev/null 2>&1; then scenario_preflight || exit 1; fi

  ensure_toolbox
  echo "$id" >"$STATE_DIR/active"
  date +%s >"$STATE_DIR/started"

  info "Preparing incident $id — this can take up to 2 minutes..."
  log_mark start "$id"
  if ! scenario_break >>"$LOG" 2>&1; then
    warn "Fault injection hit an error. Details in .lab/lab.log (contains spoilers)."
  fi
  print_ticket
  context_hint
  printf "When you think it's fixed:  %s./lab.sh check%s\n\n" "$BOLD" "$RESET"
}

# -------------------------------------------------------------- ticket ---
cmd_ticket() {
  local id
  id="$(norm_id "${1:-$(active_id)}")"
  [ -n "$id" ] || die "No active incident. Start one with ./lab.sh start <ID>"
  load_scenario "$id"
  print_ticket
}

# --------------------------------------------------------------- check ---
cmd_check() {
  require_cluster
  local id secs took=""
  id="$(norm_id "${1:-$(active_id)}")"
  [ -n "$id" ] || die "No active incident. Start one with ./lab.sh start <ID>"
  load_scenario "$id"
  ensure_toolbox >/dev/null 2>&1

  printf '\n%sChecking %s — %s%s\n' "$BOLD" "$ID" "$TITLE" "$RESET"
  CHECK_FAILED=0
  scenario_check

  if [ "$CHECK_FAILED" -eq 0 ]; then
    grep -qx "$ID" "$STATE_DIR/solved" 2>/dev/null || echo "$ID" >>"$STATE_DIR/solved"
    if [ "$(active_id)" = "$ID" ] && [ -f "$STATE_DIR/started" ]; then
      secs=$(( $(date +%s) - $(cat "$STATE_DIR/started") ))
      took=" in $((secs / 60))m $((secs % 60))s"
    fi
    printf '\n%s✔ RESOLVED%s%s. Clean up with ./lab.sh reset, then start the next one.\n\n' "$GREEN" "$RESET" "$took"
  else
    printf '\n%s✘ NOT RESOLVED YET%s — keep digging. (Some checks need ~15s after a fix to settle.)\n\n' "$RED" "$RESET"
    return 1
  fi
}

# --------------------------------------------------------------- reset ---
reset_one() {
  load_scenario "$1"
  info "Resetting $1"
  log_mark reset "$1"
  scenario_reset >>"$LOG" 2>&1 || warn "reset of $1 reported errors (see .lab/lab.log)"
  if [ "$(active_id)" = "$1" ]; then rm -f "$STATE_DIR/active" "$STATE_DIR/started"; fi
}

cmd_reset() {
  require_cluster
  local arg id f
  arg="$(norm_id "${1:-}")"
  if [ "$arg" = "ALL" ]; then
    for f in "$LAB_ROOT"/scenarios/*.sh; do reset_one "$(basename "$f" .sh)"; done
  else
    id="${arg:-$(active_id)}"
    [ -n "$id" ] || die "Nothing is active. Use ./lab.sh reset <ID> or ./lab.sh reset all"
    reset_one "$id"
  fi
  info "Done"
}

# ---------------------------------------------------------------- down ---
cmd_down() {
  command -v kind >/dev/null 2>&1 || die "kind is not installed"
  kind delete cluster --name "$CLUSTER"
  rm -rf "$STATE_DIR"
  info "Cluster and lab state removed"
}

case "${1:-}" in
  up)        cmd_up ;;
  list|ls)   cmd_list ;;
  start)     shift; cmd_start "$@" ;;
  ticket)    shift; cmd_ticket "$@" ;;
  check)     shift; cmd_check "$@" ;;
  reset)     shift; cmd_reset "$@" ;;
  down)      cmd_down ;;
  *)         usage ;;
esac

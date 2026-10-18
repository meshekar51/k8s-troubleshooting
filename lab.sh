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

require_cluster() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
  command -v docker  >/dev/null 2>&1 || die "docker is not installed"
  docker inspect "$CP" >/dev/null 2>&1 || die "Cluster '$CLUSTER' not found. Run ./lab.sh up first."
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
cmd_up() {
  local b minor img
  for b in docker kind kubectl; do
    command -v "$b" >/dev/null 2>&1 || die "'$b' is required but not installed"
  done
  docker info >/dev/null 2>&1 || die "Docker daemon not reachable (is it running? is your user in the docker group?)"

  minor="$(kind version 2>/dev/null | sed -n 's/^kind v0\.\([0-9][0-9]*\)\..*/\1/p')"
  if [ -n "$minor" ] && [ "$minor" -lt 25 ]; then
    warn "$(kind version | awk '{print $2}') detected — kind v0.25+ is required (NetworkPolicy enforcement)."
  fi

  if docker inspect "$CP" >/dev/null 2>&1; then
    info "Cluster '$CLUSTER' already exists"
  else
    info "Creating kind cluster '$CLUSTER' (1 control-plane + 2 workers)"
    if [ -n "${KIND_NODE_IMAGE:-}" ]; then
      kind create cluster --name "$CLUSTER" --config "$LAB_ROOT/kind-config.yaml" --image "$KIND_NODE_IMAGE" \
        || die "kind create cluster failed"
    else
      kind create cluster --name "$CLUSTER" --config "$LAB_ROOT/kind-config.yaml" \
        || die "kind create cluster failed"
    fi
  fi
  kubectl config use-context "$CTX" >/dev/null 2>&1 || true

  info "Waiting for nodes to be Ready"
  k wait --for=condition=Ready nodes --all --timeout=240s >/dev/null 2>&1 || warn "not all nodes are Ready yet"

  info "Preloading images into the nodes (best effort)"
  for img in $PRELOAD_IMAGES; do
    if docker pull -q "$img" >/dev/null 2>&1 && kind load docker-image "$img" --name "$CLUSTER" >/dev/null 2>&1; then
      printf '    %s\n' "$img"
    else
      warn "could not preload $img — nodes will pull it on demand"
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
  fi

  info "Starting the lab toolbox pod"
  ensure_toolbox
  printf '\n%sLab ready.%s Next: ./lab.sh list\n\n' "$GREEN" "$RESET"
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

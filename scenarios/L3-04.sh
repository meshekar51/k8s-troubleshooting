# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-04"
LEVEL="L3"
TITLE="Worker node went NotReady"
NS=""
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Monitoring alert
Scope    : node trouble-lab-worker

trouble-lab-worker went NotReady a few minutes ago and has not come
back. Nobody rebooted it. Pods that were there are being marked as
unavailable.

Done when
  - trouble-lab-worker is Ready
  - the node agent on it is running and stays running
EOF
}

_w1_down() { ! node_ready "$W1"; }

scenario_break() {
  node_backup "$W1" "$KUBELET_CONFIG" || return 1
  docker exec "$W1" sed -i \
    's#clientCAFile: /etc/kubernetes/pki/ca.crt#clientCAFile: /etc/kubernetes/pki/ca-bundle.crt#' "$KUBELET_CONFIG"
  docker exec "$W1" grep -q 'ca-bundle.crt' "$KUBELET_CONFIG" || return 1
  docker exec "$W1" systemctl restart kubelet
  wait_until 150 _w1_down
}

_kubelet_active() { docker exec "$W1" systemctl is-active --quiet kubelet; }

_kubelet_stable() {
  _kubelet_active || return 1
  sleep 10
  _kubelet_active
}

scenario_check() {
  expect "trouble-lab-worker is Ready"         node_ready "$W1"
  expect "node agent is running and stable"    _kubelet_stable
}

scenario_reset() {
  if node_restore "$W1" "$KUBELET_CONFIG" || ! _kubelet_active; then
    docker exec "$W1" systemctl restart kubelet
    wait_until 120 node_ready "$W1"
  fi
  return 0
}

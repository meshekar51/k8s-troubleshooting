# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-10"
LEVEL="L3"
TITLE="Worker2 keeps evicting pods"
NS="media"
KUBELET_CONFIG="/var/lib/kubelet/config.yaml"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Media team
Scope    : node trouble-lab-worker2

Pods on trouble-lab-worker2 keep getting Evicted and the node refuses
new work. Our `transcoder` replicas all piled up on the other worker.
The host machine itself looks healthy.

Done when
  - trouble-lab-worker2 is Ready, healthy and accepts pods again
  - deployment/transcoder has 4/4 pods Ready
EOF
}

_pressure() {
  k get node "$W2" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null
}
_under_pressure() { [ "$(_pressure)" = "True" ]; }
_no_pressure()    { [ "$(_pressure)" = "False" ]; }
_no_taint()       { ! k get node "$W2" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null | grep -q pressure; }

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: transcoder
  labels:
    app: transcoder
spec:
  replicas: 4
  selector:
    matchLabels:
      app: transcoder
  template:
    metadata:
      labels:
        app: transcoder
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: transcoder
      containers:
        - name: transcoder
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
  wait_deploy "$NS" transcoder 120s

  node_backup "$W2" "$KUBELET_CONFIG" || return 1
  docker exec -i "$W2" bash -s <<'EOF'
set -e
f=/var/lib/kubelet/config.yaml
if grep -q 'nodefs.available' "$f"; then
  sed -i -E 's#^([[:space:]]*nodefs\.available:).*#\1 "99%"#' "$f"
elif grep -q '^evictionHard:' "$f"; then
  sed -i '/^evictionHard:/a\  nodefs.available: "99%"' "$f"
else
  printf 'evictionHard:\n  nodefs.available: "99%%"\n' >>"$f"
fi
systemctl restart kubelet
EOF
  wait_until 150 _under_pressure
}

scenario_check() {
  expect "trouble-lab-worker2 is Ready"                 node_ready "$W2"
  expect "trouble-lab-worker2 reports healthy conditions"   _no_pressure
  expect "trouble-lab-worker2 accepts pods again"       _no_taint
  expect "deployment/transcoder has 4 Ready pods"       deploy_ready "$NS" transcoder 4
}

scenario_reset() {
  if node_restore "$W2" "$KUBELET_CONFIG"; then
    docker exec "$W2" systemctl restart kubelet
    wait_until 120 _no_pressure
  fi
  k delete pods -A --field-selector=status.phase=Failed --ignore-not-found 2>/dev/null || true
  ns_delete "$NS"
}

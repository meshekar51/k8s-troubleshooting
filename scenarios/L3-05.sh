# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-05"
LEVEL="L3"
TITLE="Apps can't reach each other"
NS="gateway"
COREFILE_BAK="${BACKUP_DIR}/Corefile"

ticket() {
  cat <<'EOF'
Priority : P1                 Reported by: Multiple teams
Scope    : whole cluster (example workload: namespace gateway)

Since this morning, apps across the cluster fail when calling other
services. In namespace gateway, `edge` logs "upstream api unreachable"
although the `api` pods are healthy. Calling a pod IP directly works.

Done when
  - edge reaches http://api again
  - http://api.gateway.svc.cluster.local works from any namespace
EOF
}

_apply_corefile() {
  k -n kube-system create configmap coredns --from-file=Corefile="$1" --dry-run=client -o yaml | k apply -f -
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  labels:
    app: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge
  labels:
    app: edge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: edge
  template:
    metadata:
      labels:
        app: edge
    spec:
      containers:
        - name: edge
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                if wget -q -T 3 -O /dev/null http://api; then
                  echo "$(date '+%H:%M:%S') upstream api ok"
                else
                  echo "$(date '+%H:%M:%S') upstream api unreachable"
                fi
                sleep 5
              done
EOF
  wait_deploy "$NS" api 120s

  [ -s "$COREFILE_BAK" ] || k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' >"$COREFILE_BAK"
  [ -s "$COREFILE_BAK" ] || return 1
  sed 's/kubernetes cluster\.local /kubernetes cluster.locl /' "$COREFILE_BAK" >"$STATE_DIR/.cf"
  if ! grep -q 'cluster\.locl' "$STATE_DIR/.cf"; then rm -f "$STATE_DIR/.cf"; return 1; fi
  _apply_corefile "$STATE_DIR/.cf"
  rm -f "$STATE_DIR/.cf"
  k -n kube-system rollout restart deploy/coredns
  k -n kube-system rollout status deploy/coredns --timeout=120s
}

scenario_check() {
  expect "edge reaches http://api"                           pod_sh "$NS" app=edge 'wget -q -T 3 -O /dev/null http://api'
  expect "http://api.gateway.svc.cluster.local works cluster-wide" http_ok "http://api.gateway.svc.cluster.local"
}

scenario_reset() {
  if [ -s "$COREFILE_BAK" ] &&
     [ "$(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')" != "$(cat "$COREFILE_BAK")" ]; then
    _apply_corefile "$COREFILE_BAK"
    k -n kube-system rollout restart deploy/coredns
    k -n kube-system rollout status deploy/coredns --timeout=120s
  fi
  ns_delete "$NS"
}

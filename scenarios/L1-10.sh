# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-10"
LEVEL="L1"
TITLE="Status page keeps restarting"
NS="status"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: SRE
Namespace: status

`statuspage` pods restart constantly. They serve traffic for a few
seconds, then get killed and come back.

Done when
  - deployment/statuspage has 2/2 pods Ready
  - the container keeps its health checks
  - no restarts during a 20-second observation window
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: statuspage
  labels:
    app: statuspage
spec:
  replicas: 2
  selector:
    matchLabels:
      app: statuspage
  template:
    metadata:
      labels:
        app: statuspage
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 2
EOF
}

_has_liveness() {
  [ -n "$(k -n "$NS" get deploy statuspage -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' 2>/dev/null)" ]
}

_restarts() {
  k -n "$NS" get pod -l app=statuspage \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null \
    | awk '{s += $1} END {print s + 0}'
}

_stable() {
  local before after
  before="$(_restarts)"
  sleep 20
  after="$(_restarts)"
  [ "$before" = "$after" ]
}

scenario_check() {
  expect "deployment/statuspage has 2 Ready pods" deploy_ready "$NS" statuspage 2
  expect "container keeps its health checks"      _has_liveness
  printf '  %s… watching restarts for 20s%s\n' "$DIM" "$RESET"
  expect "no restarts in 20 seconds"              _stable
}

scenario_reset() { ns_delete "$NS"; }

# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-06"
LEVEL="L1"
TITLE="Report worker restart loop"
NS="reports"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: Reporting team
Namespace: reports

`report-worker` restarts every few seconds. The RESTARTS column keeps
climbing and no reports are produced.

Done when
  - deployment/report-worker has 1/1 pod Ready and its logs say "worker ready"
  - the container still has resource limits
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-worker
  labels:
    app: report-worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: report-worker
  template:
    metadata:
      labels:
        app: report-worker
    spec:
      containers:
        - name: worker
          image: python:3.12-alpine
          imagePullPolicy: IfNotPresent
          command: ["python", "-u", "-c"]
          args:
            - |
              import time
              print("loading report cache...")
              cache = b"x" * (160 * 1024 * 1024)
              print("cache warmed, worker ready")
              while True:
                  time.sleep(30)
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 96Mi
EOF
}

_has_limit() {
  [ -n "$(k -n "$NS" get deploy report-worker -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)" ]
}

scenario_check() {
  expect "deployment/report-worker has 1 Ready pod" deploy_ready "$NS" report-worker 1
  expect "worker logs say it is ready"              latest_log_has "$NS" report-worker "worker ready"
  expect "container still has resource limits"      _has_limit
}

scenario_reset() { ns_delete "$NS"; }

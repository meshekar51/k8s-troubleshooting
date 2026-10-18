# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-03"
LEVEL="L1"
TITLE="Analytics API stuck after config change"
NS="analytics"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: Data platform team
Namespace: analytics

After this morning's config change to `report-api`, its pods have been
sitting there for 30 minutes and never start.

Done when
  - deployment/report-api has 2/2 pods Ready
  - the container still declares resource requests
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-api
  labels:
    app: report-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: report-api
  template:
    metadata:
      labels:
        app: report-api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "500"
              memory: 64Mi
            limits:
              cpu: "500"
              memory: 128Mi
EOF
}

_has_requests() {
  [ -n "$(k -n "$NS" get deploy report-api -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)" ]
}

scenario_check() {
  expect "deployment/report-api has 2 Ready pods"         deploy_ready "$NS" report-api 2
  expect "container still declares resource requests"      _has_requests
}

scenario_reset() { ns_delete "$NS"; }

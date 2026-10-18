# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-09"
LEVEL="L3"
TITLE="Namespace stuck Terminating"
NS="legacy-billing"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: CI/CD team
Namespace: legacy-billing

We deleted namespace legacy-billing during decommissioning. It has been
Terminating ever since, and the CI job that recreates it fresh is
blocked.

Done when
  - legacy-billing is no longer stuck (gone, or recreated and Active)
  - nothing from the old namespace is left orphaned in the API
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: billing-archive-lock
  finalizers:
    - billing.lab.io/archive-protection
data:
  owner: billing-archiver
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: billing-ui
  labels:
    app: billing-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: billing-ui
  template:
    metadata:
      labels:
        app: billing-ui
    spec:
      containers:
        - name: ui
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
  wait_deploy "$NS" billing-ui 90s
  k delete namespace "$NS" --wait=false
  sleep 10
}

_not_stuck() {
  [ "$(k get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Terminating" ]
}

_no_orphans() {
  if k get namespace "$NS" >/dev/null 2>&1; then
    [ -z "$(k -n "$NS" get configmap billing-archive-lock -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]
  else
    ! k -n "$NS" get configmap billing-archive-lock >/dev/null 2>&1
  fi
}

scenario_check() {
  expect "legacy-billing is not stuck Terminating"      _not_stuck
  expect "no orphaned objects left from the old namespace" _no_orphans
}

scenario_reset() {
  k -n "$NS" patch configmap billing-archive-lock --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  ns_delete "$NS"
}

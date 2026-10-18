# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-06"
LEVEL="L2"
TITLE="Sandbox deployment creates no pods"
NS="sandbox"

ticket() {
  cat <<'EOF'
Priority : P4                 Reported by: Developer (self-service)
Namespace: sandbox

`kubectl apply` of `sandbox-app` succeeded and the deployment exists,
but it shows 0/2 and not a single pod ever appears — not even Pending.

Done when
  - deployment/sandbox-app has 2/2 pods Ready
  - safeguards in the namespace are kept unchanged
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "10"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sandbox-app
  labels:
    app: sandbox-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sandbox-app
  template:
    metadata:
      labels:
        app: sandbox-app
    spec:
      containers:
        - name: app
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
}

_quota_kept() {
  [ "$(k -n "$NS" get resourcequota compute-quota -o jsonpath='{.spec.hard.limits\.cpu}' 2>/dev/null)" = "4" ] &&
  [ "$(k -n "$NS" get resourcequota compute-quota -o jsonpath='{.spec.hard.limits\.memory}' 2>/dev/null)" = "4Gi" ]
}

scenario_check() {
  expect "deployment/sandbox-app has 2 Ready pods"  deploy_ready "$NS" sandbox-app 2
  expect "namespace safeguards unchanged"           _quota_kept
}

scenario_reset() { ns_delete "$NS"; }

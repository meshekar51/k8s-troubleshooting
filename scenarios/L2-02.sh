# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-02"
LEVEL="L2"
TITLE="Profile pods never become Ready"
NS="profile"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Identity team
Namespace: profile

`profile` pods show Running but 0/1 READY, and the profile page is
down. Nothing in the app logs looks wrong.

Done when
  - deployment/profile has 3/3 pods Ready
  - http://profile.profile.svc.cluster.local returns HTTP 200 from inside the cluster
  - the container keeps its health checks
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: profile
  labels:
    app: profile
spec:
  replicas: 3
  selector:
    matchLabels:
      app: profile
  template:
    metadata:
      labels:
        app: profile
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: profile
spec:
  selector:
    app: profile
  ports:
    - port: 80
      targetPort: http
EOF
}

_has_readiness() {
  [ -n "$(k -n "$NS" get deploy profile -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)" ]
}

scenario_check() {
  expect "deployment/profile has 3 Ready pods"                deploy_ready "$NS" profile 3
  expect "http://profile.profile.svc.cluster.local answers 200" http_ok "http://profile.profile.svc.cluster.local"
  expect "container keeps its health checks"                   _has_readiness
}

scenario_reset() { ns_delete "$NS"; }

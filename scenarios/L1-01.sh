# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-01"
LEVEL="L1"
TITLE="Storefront release never came up"
NS="storefront"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Storefront team
Namespace: storefront

We rolled out the `web` deployment 20 minutes ago. None of its pods
have started and the storefront is down.

Done when
  - deployment/web has 2/2 pods Ready
  - it still serves nginx 1.27
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpnie
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
EOF
}

scenario_check() {
  expect "deployment/web has 2 Ready pods"       deploy_ready "$NS" web 2
  expect "deployment/web runs an nginx 1.27 image" image_matches "$NS" web '^nginx:1\.27'
}

scenario_reset() { ns_delete "$NS"; }

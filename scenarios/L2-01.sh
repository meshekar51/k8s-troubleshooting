# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-01"
LEVEL="L2"
TITLE="Search API refuses connections"
NS="search"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Frontend team
Namespace: search

`search-api` pods are Running and healthy, yet every request to
http://search-api.search.svc.cluster.local fails.

Done when
  - http://search-api.search.svc.cluster.local returns HTTP 200 from inside the cluster
  - the service is still exposed on port 80
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: search-api
  labels:
    app: search-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: search-api
  template:
    metadata:
      labels:
        app: search-api
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
  name: search-api
spec:
  selector:
    app: search-api
  ports:
    - name: http
      port: 80
      targetPort: 8080
EOF
}

_port80() { [ "$(k -n "$NS" get svc search-api -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)" = "80" ]; }

scenario_check() {
  expect "http://search-api.search.svc.cluster.local answers 200" http_ok "http://search-api.search.svc.cluster.local"
  expect "service/search-api still listens on port 80"            _port80
}

scenario_reset() { ns_delete "$NS"; }

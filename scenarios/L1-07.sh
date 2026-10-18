# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-07"
LEVEL="L1"
TITLE="Catalog service unreachable"
NS="catalog"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Web team
Namespace: catalog

The `catalog` pods are Running, but every app that calls
http://catalog.catalog.svc.cluster.local gets nothing back.

Done when
  - http://catalog.catalog.svc.cluster.local returns HTTP 200 from inside the cluster
  - deployment/catalog still has 2/2 pods Ready
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog
  labels:
    app: catalog
spec:
  replicas: 2
  selector:
    matchLabels:
      app: catalog
      tier: backend
  template:
    metadata:
      labels:
        app: catalog
        tier: backend
    spec:
      containers:
        - name: catalog
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: catalog
spec:
  selector:
    app: catalog-api
  ports:
    - port: 80
      targetPort: 80
EOF
}

scenario_check() {
  expect "http://catalog.catalog.svc.cluster.local answers 200" http_ok "http://catalog.catalog.svc.cluster.local"
  expect "deployment/catalog has 2 Ready pods"                  deploy_ready "$NS" catalog 2
}

scenario_reset() { ns_delete "$NS"; }

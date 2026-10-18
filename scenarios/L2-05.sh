# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-05"
LEVEL="L2"
TITLE="Shop frontend can't reach backend"
NS="shop"

ticket() {
  cat <<'EOF'
Priority : P1                 Reported by: Shop on-call
Namespace: shop

Since last night's change window the `frontend` can no longer reach
`backend` (its logs show "backend unreachable"). Both deployments are
Running and nobody touched the application code.

Done when
  - frontend reaches http://backend
  - safeguards in the namespace are kept
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  labels:
    app: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
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
  name: backend
spec:
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: web
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                if wget -q -T 3 -O /dev/null http://backend; then
                  echo "$(date '+%H:%M:%S') backend ok"
                else
                  echo "$(date '+%H:%M:%S') backend unreachable"
                fi
                sleep 5
              done
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      app: backend-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 80
EOF
}

_isolated() { ! http_ok "http://backend.shop.svc.cluster.local"; }

scenario_check() {
  expect "frontend reaches http://backend"             pod_sh "$NS" app=frontend 'wget -q -T 3 -O /dev/null http://backend'
  expect "namespace safeguards kept"                   _isolated
}

scenario_reset() { ns_delete "$NS"; }

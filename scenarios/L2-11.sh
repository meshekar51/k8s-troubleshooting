# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-11"
LEVEL="L2"
TITLE="Reviews pods stuck initializing"
NS="reviews"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: Reviews team
Namespace: reviews

The `reviews` deployment never finishes starting. Its database
`reviews-db` is up and healthy.

Done when
  - deployment/reviews has 2/2 pods Ready
  - reviews still verifies its database is reachable before starting
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-db
  labels:
    app: reviews-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: reviews-db
  template:
    metadata:
      labels:
        app: reviews-db
    spec:
      containers:
        - name: redis
          image: redis:7.2-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-db
spec:
  selector:
    app: reviews-db
  ports:
    - port: 6379
      targetPort: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews
  labels:
    app: reviews
spec:
  replicas: 2
  selector:
    matchLabels:
      app: reviews
  template:
    metadata:
      labels:
        app: reviews
    spec:
      initContainers:
        - name: wait-for-db
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              until nslookup reviews-database.reviews.svc.cluster.local 2>/dev/null | grep -q '^Name:'; do
                echo "waiting for database..."
                sleep 3
              done
              echo "database found"
      containers:
        - name: web
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
}

_has_init() {
  [ -n "$(k -n "$NS" get deploy reviews -o jsonpath='{.spec.template.spec.initContainers[0].name}' 2>/dev/null)" ]
}

scenario_check() {
  expect "deployment/reviews has 2 Ready pods"    deploy_ready "$NS" reviews 2
  expect "deployment/reviews-db has 1 Ready pod"  deploy_ready "$NS" reviews-db 1
  expect "reviews still checks its database first" _has_init
}

scenario_reset() { ns_delete "$NS"; }

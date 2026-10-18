# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-07"
LEVEL="L3"
TITLE="Cart can't talk to Redis"
NS="cart"

ticket() {
  cat <<'EOF'
Priority : P1                 Reported by: Checkout on-call
Namespace: cart

Checkout is failing: `cart-api` can't use its Redis cache. All pods
show Running.

Done when
  - cart-api gets PONG from Redis at redis:6379
  - Redis still requires a password
  - safeguards in the namespace are kept
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: redis-auth
type: Opaque
stringData:
  password: c4rt-r3dis-2026
---
apiVersion: v1
kind: Secret
metadata:
  name: cart-redis-credentials
type: Opaque
stringData:
  password: c4rt-r3dis-2024
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7.2-alpine
          imagePullPolicy: IfNotPresent
          args: ["--requirepass", "$(REDIS_PASSWORD)"]
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-auth
                  key: password
          ports:
            - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6380
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cart-api
  labels:
    app: cart-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cart-api
  template:
    metadata:
      labels:
        app: cart-api
    spec:
      containers:
        - name: api
          image: redis:7.2-alpine
          imagePullPolicy: IfNotPresent
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: cart-redis-credentials
                  key: password
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                out=$(timeout 12 redis-cli -h redis -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning ping 2>&1)
                rc=$?
                if [ $rc -eq 124 ] || [ $rc -eq 143 ]; then out="no reply within 12s"; fi
                echo "$(date '+%H:%M:%S') redis ping -> ${out:-no output}"
                sleep 5
              done
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cart-api-to-redis
spec:
  podSelector:
    matchLabels:
      app: cart-api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: redis
      ports:
        - protocol: TCP
          port: 6379
EOF
}

_pong() {
  # shellcheck disable=SC2016  # $REDIS_PASSWORD must expand inside the pod
  pod_sh "$NS" app=cart-api 'timeout 5 redis-cli -h redis -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning ping' \
    | grep -q PONG
}

_auth_required() { pod_sh "$NS" app=redis 'redis-cli ping' | grep -q NOAUTH; }

_egress_restricted() {
  k -n "$NS" get networkpolicy \
    -o jsonpath='{range .items[*]}{.spec.podSelector}{" "}{.spec.policyTypes}{"\n"}{end}' 2>/dev/null \
    | grep -E '^\{\} ' | grep -q Egress
}

scenario_check() {
  expect "cart-api gets PONG from redis:6379"  _pong
  expect "Redis still requires a password"     _auth_required
  expect "namespace safeguards kept"           _egress_restricted
}

scenario_reset() { ns_delete "$NS"; }

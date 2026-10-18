# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-12"
LEVEL="L2"
TITLE="Feature flag change not live"
NS="features"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Product team
Namespace: features

An hour ago we enabled `new_checkout` in ConfigMap `feature-flags`
(kubectl shows new_checkout=true). The app still serves the old value:

    http://storefront-flags.features.svc.cluster.local/flags.conf
    -> new_checkout=false

Done when
  - every request to that URL returns new_checkout=true
  - the ConfigMap stays the source of truth for the flag
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: feature-flags
data:
  flags.conf: |
    new_checkout=false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront-flags
  labels:
    app: storefront-flags
spec:
  replicas: 2
  selector:
    matchLabels:
      app: storefront-flags
  template:
    metadata:
      labels:
        app: storefront-flags
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          volumeMounts:
            - name: flags
              mountPath: /usr/share/nginx/html/flags.conf
              subPath: flags.conf
      volumes:
        - name: flags
          configMap:
            name: feature-flags
---
apiVersion: v1
kind: Service
metadata:
  name: storefront-flags
spec:
  selector:
    app: storefront-flags
  ports:
    - port: 80
      targetPort: 80
EOF
  wait_deploy "$NS" storefront-flags 120s
  k -n "$NS" patch configmap feature-flags --type merge -p '{"data":{"flags.conf":"new_checkout=true\n"}}'
}

_all_true() {
  local i out
  for i in 1 2 3 4 5 6; do
    out="$(http_get "http://storefront-flags.features.svc.cluster.local/flags.conf")" || return 1
    echo "$out" | grep -q '^new_checkout=true' || return 1
  done
}

_cm_true() {
  k -n "$NS" get configmap feature-flags -o jsonpath='{.data.flags\.conf}' 2>/dev/null | grep -q '^new_checkout=true'
}

scenario_check() {
  expect "every request returns new_checkout=true" _all_true
  expect "ConfigMap feature-flags says new_checkout=true" _cm_true
}

scenario_reset() { ns_delete "$NS"; }

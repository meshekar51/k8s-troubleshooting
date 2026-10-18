# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-04"
LEVEL="L1"
TITLE="Checkout pods never start"
NS="checkout"

ticket() {
  cat <<'EOF'
Priority : P1                 Reported by: Payments on-call
Namespace: checkout

Checkout was redeployed and none of the new `checkout` pods have
started. Customers cannot pay.

Done when
  - deployment/checkout has 2/2 pods Ready
  - the app gets its payment gateway URL from the team's existing config
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-config
data:
  PAYMENT_GATEWAY: "https://pay.internal.example"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout
  labels:
    app: checkout
spec:
  replicas: 2
  selector:
    matchLabels:
      app: checkout
  template:
    metadata:
      labels:
        app: checkout
    spec:
      containers:
        - name: checkout
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          env:
            - name: PAYMENT_GATEWAY
              valueFrom:
                configMapKeyRef:
                  name: checkout-configs
                  key: PAYMENT_GATEWAY
EOF
}

_gateway_ok() {
  [ "$(pod_sh "$NS" app=checkout 'printenv PAYMENT_GATEWAY')" = "https://pay.internal.example" ]
}

scenario_check() {
  expect "deployment/checkout has 2 Ready pods"               deploy_ready "$NS" checkout 2
  expect "PAYMENT_GATEWAY inside the pod has the expected URL" _gateway_ok
}

scenario_reset() { ns_delete "$NS"; }

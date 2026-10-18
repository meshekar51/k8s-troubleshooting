# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-08"
LEVEL="L3"
TITLE="Ledger deployment silently fails"
NS="ledger"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Ledger team
Namespace: ledger

`ledger-api` has shown 0/2 for an hour. No pods at all, not even
Pending, and no errors from `kubectl apply`. Other teams deploy to
their namespaces without problems.

Done when
  - deployment/ledger-api has 2/2 pods Ready
  - namespace ledger keeps its labels
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k label namespace "$NS" compliance=pci --overwrite
  k apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: pci-policy-check
webhooks:
  - name: pods.pci-policy.lab.io
    admissionReviewVersions: ["v1"]
    sideEffects: None
    failurePolicy: Fail
    timeoutSeconds: 5
    clientConfig:
      service:
        namespace: pci-system
        name: pci-validator
        path: /validate
        port: 443
    namespaceSelector:
      matchLabels:
        compliance: pci
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
EOF
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger-api
  labels:
    app: ledger-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ledger-api
  template:
    metadata:
      labels:
        app: ledger-api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
}

_labels_kept() {
  [ "$(k get namespace "$NS" -o jsonpath='{.metadata.labels.compliance}' 2>/dev/null)" = "pci" ]
}

scenario_check() {
  expect "deployment/ledger-api has 2 Ready pods" deploy_ready "$NS" ledger-api 2
  expect "namespace ledger keeps its labels"      _labels_kept
}

scenario_reset() {
  k delete validatingwebhookconfiguration pci-policy-check --ignore-not-found
  ns_delete "$NS"
}

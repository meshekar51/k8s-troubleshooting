# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-02"
LEVEL="L1"
TITLE="Invoice worker won't start"
NS="billing"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Billing team
Namespace: billing

The new `invoice-worker` deployment never processes anything. Invoices
are piling up in the queue.

Done when
  - deployment/invoice-worker has 1/1 pod Ready
  - its logs show it processing invoices
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: invoice-worker
  labels:
    app: invoice-worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: invoice-worker
  template:
    metadata:
      labels:
        app: invoice-worker
    spec:
      containers:
        - name: worker
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["/bin/shh", "-c"]
          args:
            - |
              while true; do
                echo "processing invoices batch $(date +%s)"
                sleep 15
              done
EOF
}

scenario_check() {
  expect "deployment/invoice-worker has 1 Ready pod" deploy_ready "$NS" invoice-worker 1
  expect "worker logs show invoices being processed" latest_log_has "$NS" invoice-worker "processing invoices"
}

scenario_reset() { ns_delete "$NS"; }

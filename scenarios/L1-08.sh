# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-08"
LEVEL="L1"
TITLE="Scale-up for the sale didn't happen"
NS="inventory"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: E-commerce on-call
Namespace: inventory

We scaled `inventory` to 4 replicas ahead of tonight's sale.
Only 1 replica is actually running.

Done when
  - deployment/inventory has 4/4 pods Ready
  - both worker nodes accept new workloads
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory
  labels:
    app: inventory
spec:
  replicas: 1
  selector:
    matchLabels:
      app: inventory
  template:
    metadata:
      labels:
        app: inventory
    spec:
      containers:
        - name: inventory
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
  wait_deploy "$NS" inventory 120s
  k cordon "$W1"
  k cordon "$W2"
  k -n "$NS" scale deploy inventory --replicas=4
}

scenario_check() {
  expect "deployment/inventory has 4 Ready pods"   deploy_ready "$NS" inventory 4
  expect "$W1 accepts new workloads"                node_schedulable "$W1"
  expect "$W2 accepts new workloads"                node_schedulable "$W2"
}

scenario_reset() {
  k uncordon "$W1"
  k uncordon "$W2"
  ns_delete "$NS"
}

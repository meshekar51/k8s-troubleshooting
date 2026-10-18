# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-10"
LEVEL="L2"
TITLE="Node drain hangs forever"
NS="accounts"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: Platform team (maintenance)
Namespace: accounts

We need to patch node trouble-lab-worker, but this never finishes:

    kubectl drain trouble-lab-worker --ignore-daemonsets --delete-emptydir-data

The tier-1 `accounts-api` runs on that node.

Done when
  - the node can be drained (prove it, then uncordon it again)
  - accounts-api is back to 2/2 Ready
  - accounts-api keeps every safeguard it has today (fix, don't delete)
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: accounts-api
  labels:
    app: accounts-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: accounts-api
  template:
    metadata:
      labels:
        app: accounts-api
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: accounts-api
              topologyKey: kubernetes.io/hostname
      containers:
        - name: api
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: accounts-api
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: accounts-api
EOF
  wait_deploy "$NS" accounts-api 120s
}

_disruption_possible() {
  local a
  for a in $(k -n "$NS" get pdb -o jsonpath='{.items[*].status.disruptionsAllowed}' 2>/dev/null); do
    [ "$a" -ge 1 ] 2>/dev/null && return 0
  done
  return 1
}

_pdb_kept() { [ -n "$(k -n "$NS" get pdb -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" ]; }

scenario_check() {
  expect "accounts-api has 2 Ready pods"                 deploy_ready "$NS" accounts-api 2
  expect "trouble-lab-worker is uncordoned again"        node_schedulable "$W1"
  expect "accounts-api safeguards kept"                  _pdb_kept
  expect "one accounts-api pod can be evicted safely"    _disruption_possible
}

scenario_reset() {
  k uncordon "$W1" 2>/dev/null || true
  ns_delete "$NS"
}

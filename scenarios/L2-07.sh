# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-07"
LEVEL="L2"
TITLE="Search indexer never schedules"
NS="indexer"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: Search team
Namespace: indexer

`indexer` must only run on SSD-backed nodes. Its pods have been
Pending since the rollout.

Done when
  - deployment/indexer has 2/2 pods Ready
  - every indexer pod runs on an SSD node
  - node settings owned by the infra team stay unchanged
EOF
}

scenario_break() {
  k label node "$W2" disktype=ssd --overwrite
  k taint node "$W2" dedicated=indexer:NoSchedule --overwrite
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: indexer
  labels:
    app: indexer
spec:
  replicas: 2
  selector:
    matchLabels:
      app: indexer
  template:
    metadata:
      labels:
        app: indexer
    spec:
      nodeSelector:
        disktype: ssd
      tolerations:
        - key: dedicated
          operator: Equal
          value: indexing
          effect: NoSchedule
      containers:
        - name: indexer
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
}

_taint_kept() {
  k get node "$W2" -o jsonpath='{range .spec.taints[*]}{.key}={.value}:{.effect}{"\n"}{end}' 2>/dev/null \
    | grep -qx 'dedicated=indexer:NoSchedule' || return 1
  [ "$(k get node "$W2" -o jsonpath='{.metadata.labels.disktype}' 2>/dev/null)" = "ssd" ] || return 1
  [ -z "$(k get node "$W1" -o jsonpath='{.metadata.labels.disktype}' 2>/dev/null)" ]
}

_on_reserved_node() {
  local n found=0
  for n in $(k -n "$NS" get pod -l app=indexer -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null); do
    found=1
    [ "$n" = "$W2" ] || return 1
  done
  [ "$found" -eq 1 ]
}

scenario_check() {
  expect "deployment/indexer has 2 Ready pods"   deploy_ready "$NS" indexer 2
  expect "all indexer pods run on an SSD node"   _on_reserved_node
  expect "infra-owned node settings unchanged"   _taint_kept
}

scenario_reset() {
  ns_delete "$NS"
  k taint node "$W2" dedicated- 2>/dev/null || true
  k label node "$W1" disktype- 2>/dev/null || true
  k label node "$W2" disktype- 2>/dev/null || true
}

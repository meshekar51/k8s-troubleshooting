# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-01"
LEVEL="L3"
TITLE="No new pods start anywhere"
NS="rollout"
SCHED_MANIFEST="/etc/kubernetes/manifests/kube-scheduler.yaml"

ticket() {
  cat <<'EOF'
Priority : P1                 Reported by: Every team, all at once
Scope    : whole cluster (example workload: namespace rollout)

Since about 10 minutes ago no new pod starts in any namespace.
Workloads that were already running are fine. deployment/hello in
namespace rollout is one example.

Done when
  - the cluster component responsible is healthy again
  - deployment/hello has 2/2 pods Ready
EOF
}

scenario_break() {
  node_backup "$CP" "$SCHED_MANIFEST" || return 1
  docker exec "$CP" sed -i \
    's#--kubeconfig=/etc/kubernetes/scheduler.conf$#--kubeconfig=/etc/kubernetes/scheduler.config#' "$SCHED_MANIFEST"
  docker exec "$CP" grep -q 'scheduler.config' "$SCHED_MANIFEST" || return 1
  sleep 25
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
  labels:
    app: hello
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: hello
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
}

scenario_check() {
  expect "responsible cluster component is healthy" cp_ready kube-scheduler
  expect "deployment/hello has 2 Ready pods"        deploy_ready "$NS" hello 2
}

scenario_reset() {
  if node_restore "$CP" "$SCHED_MANIFEST"; then wait_until 120 cp_ready kube-scheduler; fi
  ns_delete "$NS"
}

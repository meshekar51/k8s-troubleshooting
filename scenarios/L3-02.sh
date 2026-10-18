# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-02"
LEVEL="L3"
TITLE="Deployments create nothing"
NS="reporting"
KCM_MANIFEST="/etc/kubernetes/manifests/kube-controller-manager.yaml"

ticket() {
  cat <<'EOF'
Priority : P1                 Reported by: Release engineering
Scope    : whole cluster (example workload: namespace reporting)

`kubectl apply` of deployment/dashboard succeeded. It shows 0/2 and
there are no pods at all — not even Pending. Other teams report the
same for anything new they deploy.

Done when
  - the cluster component responsible is healthy again
  - deployment/dashboard has 2/2 pods Ready
EOF
}

scenario_break() {
  node_backup "$CP" "$KCM_MANIFEST" || return 1
  docker exec "$CP" sed -i -E \
    's#(image: [^[:space:]]*kube-controller-manager:[^[:space:]]+)#\1-hotfix#' "$KCM_MANIFEST"
  docker exec "$CP" grep -q 'kube-controller-manager:.*-hotfix' "$KCM_MANIFEST" || return 1
  sleep 25
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dashboard
  labels:
    app: dashboard
spec:
  replicas: 2
  selector:
    matchLabels:
      app: dashboard
  template:
    metadata:
      labels:
        app: dashboard
    spec:
      containers:
        - name: dashboard
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
}

scenario_check() {
  expect "responsible cluster component is healthy" cp_ready kube-controller-manager
  expect "deployment/dashboard has 2 Ready pods"    deploy_ready "$NS" dashboard 2
}

scenario_reset() {
  if node_restore "$CP" "$KCM_MANIFEST"; then wait_until 120 cp_ready kube-controller-manager; fi
  ns_delete "$NS"
}

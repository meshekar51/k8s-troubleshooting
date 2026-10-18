# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-06"
LEVEL="L3"
TITLE="New service unreachable, old ones fine"
NS="pricing"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Pricing team
Scope    : namespace pricing (maybe more)

We launched the new `pricing` service today. Its pods are Running and
Ready, but http://pricing.pricing.svc.cluster.local never answers.
Every older service in the cluster keeps working normally.

Done when
  - http://pricing.pricing.svc.cluster.local returns HTTP 200 from inside the cluster
  - the cluster is healthy enough that the NEXT new service will work too
EOF
}

scenario_break() {
  k -n kube-system patch daemonset kube-proxy --type merge \
    -p '{"spec":{"template":{"spec":{"nodeSelector":{"node.kubernetes.io/network-tier":"edge"}}}}}'
  k -n kube-system wait --for=delete pod -l k8s-app=kube-proxy --timeout=120s
  sleep 5
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pricing
  labels:
    app: pricing
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pricing
  template:
    metadata:
      labels:
        app: pricing
    spec:
      containers:
        - name: pricing
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: pricing
spec:
  selector:
    app: pricing
  ports:
    - port: 80
      targetPort: 80
EOF
  wait_deploy "$NS" pricing 120s
}

_proxy_on_every_node() {
  local nodes running
  nodes="$(k get nodes --no-headers 2>/dev/null | grep -c .)"
  running="$(k -n kube-system get pods -l k8s-app=kube-proxy --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c .)"
  [ "$nodes" -gt 0 ] && [ "$running" -eq "$nodes" ]
}

scenario_check() {
  expect "http://pricing.pricing.svc.cluster.local answers 200" http_ok "http://pricing.pricing.svc.cluster.local"
  expect "the next new service will work too"                  _proxy_on_every_node
}

scenario_reset() {
  k -n kube-system patch daemonset kube-proxy --type=json \
    -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/node.kubernetes.io~1network-tier"}]' 2>/dev/null || true
  k label nodes --all node.kubernetes.io/network-tier- 2>/dev/null || true
  k -n kube-system rollout status daemonset/kube-proxy --timeout=120s || true
  ns_delete "$NS"
}

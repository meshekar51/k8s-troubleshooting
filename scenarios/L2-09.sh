# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-09"
LEVEL="L2"
TITLE="Autoscaler never scales"
NS="traffic"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Gateway team
Namespace: traffic

`api-gateway` has a HorizontalPodAutoscaler, but during yesterday's
traffic spike it never added a single pod.

Done when
  - the api-gateway autoscaler reports a current CPU utilisation value
  - it still scales api-gateway on CPU between 2 and 6 replicas
EOF
}

scenario_preflight() {
  deploy_ready kube-system metrics-server 1 \
    || die "metrics-server is not Ready in kube-system. Run ./lab.sh up first (lab setup issue, not part of the puzzle)."
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  labels:
    app: api-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
    spec:
      containers:
        - name: gateway
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-gateway
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-gateway
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
EOF
}

_hpa_sees_cpu() {
  [ -n "$(k -n "$NS" get hpa api-gateway -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)" ]
}

_hpa_shape() {
  [ "$(k -n "$NS" get hpa api-gateway -o jsonpath='{.spec.scaleTargetRef.name}/{.spec.minReplicas}/{.spec.maxReplicas}/{.spec.metrics[0].resource.name}' 2>/dev/null)" = "api-gateway/2/6/cpu" ]
}

scenario_check() {
  expect "autoscaler reports current CPU utilisation" _hpa_sees_cpu
  expect "autoscaler still targets api-gateway on CPU, 2–6 replicas" _hpa_shape
}

scenario_reset() { ns_delete "$NS"; }

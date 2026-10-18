# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-08"
LEVEL="L2"
TITLE="Order processor can't reach inventory"
NS="fulfilment"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Fulfilment team
Namespace: fulfilment

`order-processor` logs keep saying "inventory unreachable". The
`inventory` pods are healthy and other apps reach them fine.

Done when
  - order-processor reaches http://inventory
  - deployment/inventory still has 2/2 pods Ready
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
  replicas: 2
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
---
apiVersion: v1
kind: Service
metadata:
  name: inventory
spec:
  selector:
    app: inventory
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-processor
  labels:
    app: order-processor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-processor
  template:
    metadata:
      labels:
        app: order-processor
    spec:
      dnsPolicy: "None"
      dnsConfig:
        nameservers:
          - 1.1.1.1
        searches:
          - fulfilment.svc.cluster.local
          - svc.cluster.local
          - cluster.local
        options:
          - name: ndots
            value: "5"
      containers:
        - name: processor
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                if wget -q -T 3 -O /dev/null http://inventory; then
                  echo "$(date '+%H:%M:%S') inventory reachable"
                else
                  echo "$(date '+%H:%M:%S') inventory unreachable"
                fi
                sleep 5
              done
EOF
}

scenario_check() {
  expect "order-processor reaches http://inventory" pod_sh "$NS" app=order-processor 'wget -q -T 3 -O /dev/null http://inventory'
  expect "deployment/inventory has 2 Ready pods"    deploy_ready "$NS" inventory 2
}

scenario_reset() { ns_delete "$NS"; }

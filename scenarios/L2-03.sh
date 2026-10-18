# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-03"
LEVEL="L2"
TITLE="Cache store stuck Pending"
NS="data"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Data team
Namespace: data

We deployed the `cache-store` Redis with persistent storage.
Its pod has been Pending ever since.

Done when
  - deployment/cache-store has 1/1 pod Ready
  - its data directory /data is backed by a Bound persistent volume
  - the pod can write to /data
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cache-data
spec:
  storageClassName: fast-ssd
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cache-store
  labels:
    app: cache-store
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: cache-store
  template:
    metadata:
      labels:
        app: cache-store
    spec:
      containers:
        - name: redis
          image: redis:7.2-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: cache-data
EOF
}

_data_on_pvc() {
  local claim phase
  claim="$(k -n "$NS" get deploy cache-store \
    -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}' 2>/dev/null)"
  [ -n "$claim" ] || return 1
  phase="$(k -n "$NS" get pvc "$claim" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$phase" = "Bound" ]
}

scenario_check() {
  expect "deployment/cache-store has 1 Ready pod"        deploy_ready "$NS" cache-store 1
  expect "/data is backed by a Bound persistent volume"  _data_on_pvc
  expect "pod can write to /data"                        pod_sh "$NS" app=cache-store 'touch /data/.lab-probe'
}

scenario_reset() { ns_delete "$NS"; }

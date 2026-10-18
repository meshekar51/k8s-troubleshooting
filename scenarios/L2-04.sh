# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L2-04"
LEVEL="L2"
TITLE="Config sync job failing"
NS="platform"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: Platform team
Namespace: platform

`config-sync` reads the ConfigMaps in its own namespace through the
Kubernetes API every 10 seconds. It has never succeeded since it was
deployed.

Done when
  - config-sync logs "sync ok"
  - config-sync is not over-privileged (it must not be able to read Secrets)
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: config-sync
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-reader
rules:
  - apiGroups: [""]
    resources: ["configmap"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: config-sync-reader
subjects:
  - kind: ServiceAccount
    name: config-sync
    namespace: platform
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: configmap-reader
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-settings
data:
  LOG_LEVEL: info
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: config-sync
  labels:
    app: config-sync
spec:
  replicas: 1
  selector:
    matchLabels:
      app: config-sync
  template:
    metadata:
      labels:
        app: config-sync
    spec:
      serviceAccountName: config-sync
      containers:
        - name: sync
          image: curlimages/curl:8.10.1
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              SA=/var/run/secrets/kubernetes.io/serviceaccount
              while true; do
                code=$(curl -s -o /tmp/resp -w '%{http_code}' --cacert $SA/ca.crt \
                  -H "Authorization: Bearer $(cat $SA/token)" \
                  https://kubernetes.default.svc/api/v1/namespaces/platform/configmaps)
                if [ "$code" = "200" ]; then
                  echo "$(date '+%H:%M:%S') sync ok"
                else
                  echo "$(date '+%H:%M:%S') sync failed: HTTP $code $(head -c 200 /tmp/resp | tr -d '\n')"
                fi
                sleep 10
              done
EOF
}

_sa() { k auth can-i "$1" "$2" -n "$NS" --as=system:serviceaccount:platform:config-sync 2>/dev/null; }
_cannot_read_secrets() { _sa get secrets | grep -q '^no' && _sa list secrets | grep -q '^no'; }

scenario_check() {
  expect "config-sync logs 'sync ok'"           latest_log_has "$NS" config-sync "sync ok"
  expect "config-sync cannot read Secrets"      _cannot_read_secrets
}

scenario_reset() { ns_delete "$NS"; }

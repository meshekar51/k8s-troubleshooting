# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-05"
LEVEL="L1"
TITLE="Orders API stuck creating"
NS="orders"

ticket() {
  cat <<'EOF'
Priority : P2                 Reported by: Orders team
Namespace: orders

`orders-api` pods were created 15 minutes ago and are still not running.
The orders endpoint is down.

Done when
  - deployment/orders-api has 2/2 pods Ready
  - the pods can read the database password the team already stored
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: orders-db-credentials
type: Opaque
stringData:
  username: orders
  password: Sup3r-S3cret
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-api
  labels:
    app: orders-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: orders-api
  template:
    metadata:
      labels:
        app: orders-api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          volumeMounts:
            - name: db-creds
              mountPath: /etc/db
              readOnly: true
      volumes:
        - name: db-creds
          secret:
            secretName: orders-db-credential
EOF
}

_password_ok() {
  [ "$(pod_sh "$NS" app=orders-api 'cat /etc/db/password')" = "Sup3r-S3cret" ]
}

scenario_check() {
  expect "deployment/orders-api has 2 Ready pods"           deploy_ready "$NS" orders-api 2
  expect "/etc/db/password in the pod holds the stored secret" _password_ok
}

scenario_reset() { ns_delete "$NS"; }

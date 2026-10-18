# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L1-09"
LEVEL="L1"
TITLE="Notifier pods refuse to start"
NS="notifications"

ticket() {
  cat <<'EOF'
Priority : P3                 Reported by: Messaging team
Namespace: notifications

The `notifier` deployment went out with today's release.
Its pods never start.

Done when
  - deployment/notifier has 2/2 pods Ready
  - it still runs exactly nginx:1.27
EOF
}

scenario_break() {
  ns_fresh "$NS"
  k -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notifier
  labels:
    app: notifier
spec:
  replicas: 2
  selector:
    matchLabels:
      app: notifier
  template:
    metadata:
      labels:
        app: notifier
    spec:
      containers:
        - name: notifier
          image: nginx:1.27
          imagePullPolicy: Never
          ports:
            - containerPort: 80
EOF
}

scenario_check() {
  expect "deployment/notifier has 2 Ready pods" deploy_ready "$NS" notifier 2
  expect "it runs exactly nginx:1.27"           image_matches "$NS" notifier '^nginx:1\.27$'
}

scenario_reset() { ns_delete "$NS"; }

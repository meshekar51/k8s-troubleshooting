# shellcheck shell=bash disable=SC2034,SC2154
# SPOILER: this file injects the fault. Don't read it before solving.
ID="L3-03"
LEVEL="L3"
TITLE="kubectl can't reach the cluster"
NS=""
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"

ticket() {
  cat <<'EOF'
Priority : P1                 Reported by: Everyone using kubectl
Scope    : whole cluster

Since about 5 minutes ago every kubectl command against the cluster
fails or hangs. Applications that were already running still serve
traffic. No one admits to changing anything.

Done when
  - the Kubernetes API answers again (kubectl get --raw=/readyz -> ok)
EOF
}

scenario_break() {
  node_backup "$CP" "$APISERVER_MANIFEST" || return 1
  docker exec "$CP" sed -i \
    's#--etcd-servers=https://127.0.0.1:2379#--etcd-servers=https://127.0.0.1:2397#' "$APISERVER_MANIFEST"
  docker exec "$CP" grep -q '127.0.0.1:2397' "$APISERVER_MANIFEST" || return 1
  sleep 30
}

scenario_check() {
  expect "Kubernetes API answers /readyz" api_ready
}

scenario_reset() {
  if node_restore "$CP" "$APISERVER_MANIFEST"; then wait_until 180 api_ready; fi
  return 0
}

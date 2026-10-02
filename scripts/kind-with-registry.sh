#!/usr/bin/env bash
# Create a kind cluster wired to a local registry.
# Adapted from the pattern documented by the kind project.
set -euo pipefail

CLUSTER="${1:-supply-chain-lab}"
REGISTRY="${2:-localhost:5001}"
REG_NAME="kind-registry"
REG_PORT="${REGISTRY##*:}"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "  cluster '${CLUSTER}' already exists, reusing"
else
  if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
    echo "  starting local registry on :${REG_PORT}"
    docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" \
      --name "${REG_NAME}" registry:2 >/dev/null
  fi

  cat <<EOF | kind create cluster --name "${CLUSTER}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
EOF

  REG_DIR="/etc/containerd/certs.d/${REGISTRY}"
  for node in $(kind get nodes --name "${CLUSTER}"); do
    docker exec "${node}" mkdir -p "${REG_DIR}"
    cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REG_DIR}/hosts.toml"
[host."http://${REG_NAME}:5000"]
EOF
  done

  if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
    docker network connect "kind" "${REG_NAME}"
  fi

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
fi

kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null
echo "  context: kind-${CLUSTER}"

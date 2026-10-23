#!/usr/bin/env bash
# Container path: KWOK fake nodes with fake GPUs from fake-gpu-operator.
#
# Needs nothing but a control plane: KWOK simulates the nodes and the pods on
# them, and fake-gpu-operator gives each node its nvidia.com/gpu capacity and
# GPU labels. Creates KWOK_NODES_PER_TYPE nodes per type in GPU_TYPES.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/render.sh
. "$ROOT_DIR/lib/render.sh"
load_config
check_gpu_types
require_tools kubectl helm

log "Checking the cluster"
check_cluster
timeout_s=$(seconds "$TIMEOUT")

log "Installing KWOK $KWOK_VERSION"
kwok_url="https://github.com/kubernetes-sigs/kwok/releases/download/$KWOK_VERSION"
k apply -f "$kwok_url/kwok.yaml" >/dev/null
k apply -f "$kwok_url/stage-fast.yaml" >/dev/null
k -n kube-system rollout status deployment/kwok-controller --timeout="$TIMEOUT"

log "Installing fake-gpu-operator $FGO_VERSION (pools: $GPU_TYPES)"
values=$(mktemp "${TMPDIR:-/tmp}/fgo-values.XXXXXX")
trap 'rm -f "$values"' EXIT
render_fgo_values >"$values"
h upgrade --install fake-gpu-operator "$FGO_CHART" --version "$FGO_VERSION" \
  --namespace "$FGO_NAMESPACE" --create-namespace -f "$values" --wait --timeout "$TIMEOUT" >/dev/null
info "release fake-gpu-operator deployed in $FGO_NAMESPACE"

log "Creating $KWOK_NODES_PER_TYPE fake node(s) per GPU type"
for t in $GPU_TYPES; do
  load_gpu "$t"
  for i in $(seq 1 "$KWOK_NODES_PER_TYPE"); do
    render_kwok_node "kwok-$t-$i" | k apply -f - >/dev/null
  done
  info "$t: kwok-$t-1..$KWOK_NODES_PER_TYPE ($GPU_COUNT x $GPU_NAME each)"
done

log "Waiting for fake-gpu-operator to give every node its GPUs"
for t in $GPU_TYPES; do
  load_gpu "$t"
  for i in $(seq 1 "$KWOK_NODES_PER_TYPE"); do
    node="kwok-$t-$i"
    k wait --for=condition=Ready "node/$node" --timeout="$TIMEOUT" >/dev/null
    gpus() { [ "$(k get node "$1" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')" = "$GPU_COUNT" ]; }
    wait_until "$timeout_s" "$node: nvidia.com/gpu=$GPU_COUNT" gpus "$node" ||
      die "$node never got nvidia.com/gpu=$GPU_COUNT; check: kubectl -n $FGO_NAMESPACE get pods"
  done
done

echo
k get nodes -l app.kubernetes.io/part-of=k8s-mock-test,type=kwok \
  -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.k8s-mock-test/gpu-type,ARCH:.metadata.labels.kubernetes\.io/arch,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,GPUS:.status.allocatable.nvidia\.com/gpu,MEMORY_MIB:.metadata.labels.nvidia\.com/gpu\.memory'
echo
log "Done. Run the checks with: make container-test"

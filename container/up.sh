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
# Fake pod and node addresses outside the cluster's real ranges.
k -n kube-system patch deployment kwok-controller --type=json -p "[{\"op\": \"replace\",
  \"path\": \"/spec/template/spec/containers/0/args\", \"value\": [
  \"--config=/root/.kwok/kwok.yaml\", \"--node-ip=$KWOK_NODE_IP\", \"--cidr=$KWOK_POD_CIDR\"]}]" >/dev/null
k -n kube-system rollout status deployment/kwok-controller --timeout="$TIMEOUT"
info "fake pod IPs from $KWOK_POD_CIDR, fake node IP $KWOK_NODE_IP"

log "Installing fake-gpu-operator $FGO_VERSION (pools: $GPU_TYPES)"
values=$(mktemp "${TMPDIR:-/tmp}/fgo-values.XXXXXX")
trap 'rm -f "$values"' EXIT
render_fgo_values >"$values"
h upgrade --install fake-gpu-operator "$FGO_CHART" --version "$FGO_VERSION" \
  --namespace "$FGO_NAMESPACE" --create-namespace -f "$values" --wait --timeout "$TIMEOUT" >/dev/null
info "release fake-gpu-operator deployed in $FGO_NAMESPACE"

# fake-gpu-operator builds a node's topology (GPUs, otherDevices) once, when it
# first sees the node, and never rewrites it. After a pool change (another GPU
# count, InfiniBand added or removed) existing fake nodes keep the old one, so
# drop each stale per-node topology and restart status-updater to rebuild it.
topology_matches() {
  local cm
  cm=$(k -n "$FGO_NAMESPACE" get configmap "topology-$1" -o jsonpath='{.data.topology\.yml}' 2>/dev/null) || return 0
  [ -n "$cm" ] || return 0
  echo "$cm" | grep -qx "gpuProduct: $GPU_PRODUCT" || return 1
  [ "$(echo "$cm" | grep -c -- '- id: ')" = "$GPU_COUNT" ] || return 1
  if [ "$IB_COUNT" -gt 0 ]; then
    echo "$cm" | grep -A1 -- "- name: $IB_RESOURCE\$" | grep -q "count: $IB_COUNT\$"
  else
    ! echo "$cm" | grep -q '^otherDevices:'
  fi
}
stale=""
for t in $GPU_TYPES; do
  load_gpu "$t"
  for i in $(seq 1 "$KWOK_NODES_PER_TYPE"); do
    topology_matches "kwok-$t-$i" || stale="$stale kwok-$t-$i"
  done
done
if [ -n "$stale" ]; then
  log "Rebuilding the fake-gpu-operator topology of existing nodes:$stale"
  for n in $stale; do
    k -n "$FGO_NAMESPACE" delete configmap "topology-$n" --ignore-not-found >/dev/null
  done
  k -n "$FGO_NAMESPACE" rollout restart deployment/status-updater >/dev/null
  k -n "$FGO_NAMESPACE" rollout status deployment/status-updater --timeout="$TIMEOUT"
fi

log "Creating $KWOK_NODES_PER_TYPE fake node(s) per GPU type"
for t in $GPU_TYPES; do
  load_gpu "$t"
  for i in $(seq 1 "$KWOK_NODES_PER_TYPE"); do
    render_kwok_node "kwok-$t-$i" | k apply -f - >/dev/null
  done
  info "$t: kwok-$t-1..$KWOK_NODES_PER_TYPE ($GPU_COUNT x $GPU_NAME each)"
done

log "Waiting for fake-gpu-operator to give every node its GPUs and InfiniBand"
for t in $GPU_TYPES; do
  load_gpu "$t"
  for i in $(seq 1 "$KWOK_NODES_PER_TYPE"); do
    node="kwok-$t-$i"
    k wait --for=condition=Ready "node/$node" --timeout="$TIMEOUT" >/dev/null
    gpus() { [ "$(k get node "$1" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')" = "$GPU_COUNT" ]; }
    wait_until "$timeout_s" "$node: nvidia.com/gpu=$GPU_COUNT" gpus "$node" ||
      die "$node never got nvidia.com/gpu=$GPU_COUNT; check: kubectl -n $FGO_NAMESPACE get pods"
    if [ "$IB_COUNT" -gt 0 ]; then
      ib() { [ "$(k get node "$1" -o jsonpath="$(allocatable_path "$IB_RESOURCE")")" = "$IB_COUNT" ]; }
      wait_until "$timeout_s" "$node: $IB_RESOURCE=$IB_COUNT" ib "$node" ||
        die "$node never got $IB_RESOURCE=$IB_COUNT; check: kubectl -n $FGO_NAMESPACE logs deploy/kwok-gpu-device-plugin"
    fi

    # fake-gpu-operator's KWOK exporter drops a label update that hits a write
    # conflict (likely while a new node is still being updated by other
    # controllers) and only relabels when the node's topology ConfigMap
    # changes, so touch that ConfigMap until the labels land.
    labelled() { [ "$(k get node "$1" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}')" = "$GPU_PRODUCT" ]; }
    waited=0
    until labelled "$node"; do
      [ "$waited" -ge "$timeout_s" ] &&
        die "$node never got nvidia.com/gpu.product=$GPU_PRODUCT; check: kubectl -n $FGO_NAMESPACE logs deploy/nvidia-dcgm-exporter-kwok"
      if [ "$waited" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
        k -n "$FGO_NAMESPACE" annotate configmap "topology-$node" \
          k8s-mock-test/relabel="$(date +%s)" --overwrite >/dev/null 2>&1 || true
      fi
      sleep 5
      waited=$((waited + 5))
    done
    info "$node: nvidia.com/gpu.product=$GPU_PRODUCT"
  done
done

echo
columns='NODE:.metadata.name,TYPE:.metadata.labels.k8s-mock-test/gpu-type,ARCH:.metadata.labels.kubernetes\.io/arch,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product,GPUS:.status.allocatable.nvidia\.com/gpu,MEMORY_MIB:.metadata.labels.nvidia\.com/gpu\.memory'
[ -n "$IB_RESOURCE" ] && columns="$columns,IB:.status.allocatable.${IB_RESOURCE//./\\.}"
k get nodes -l app.kubernetes.io/part-of=k8s-mock-test,type=kwok -o custom-columns="$columns"
echo
log "Done. Run the checks with: make container-test"

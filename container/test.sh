#!/usr/bin/env bash
# Container path checks, per GPU type:
#   nodes       KWOK_NODES_PER_TYPE fake nodes are Ready
#   capacity    each advertises nvidia.com/gpu = GPU_COUNT
#   ib capacity each advertises IB_RESOURCE = IB_COUNT (when IB_RESOURCE is set)
#   labels      nvidia.com/gpu.product / .count match the catalog
#   1-gpu pod   a pod asking for 1 GPU (and 1 IB) runs on a node of the type
#   full node   a pod asking for every GPU (and IB) of a node runs
#   too many    a pod asking for GPU_COUNT+1 GPUs stays Pending (Insufficient)
#   too many ib a pod asking for IB_COUNT+1 IB stays Pending (Insufficient)
# The pods of a type run one at a time, so a single node per type is enough.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/render.sh
. "$ROOT_DIR/lib/render.sh"
load_config
check_gpu_types
require_tools kubectl

log "Checking the cluster"
check_cluster
ns="$CONTAINER_TEST_NAMESPACE"
k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null

log "Checking fake nodes"
for t in $GPU_TYPES; do
  load_gpu "$t"
  nodes=$(k get nodes -l "k8s-mock-test/gpu-type=$t,type=kwok" -o name | wc -l | tr -d ' ')
  ready=$(k get nodes -l "k8s-mock-test/gpu-type=$t,type=kwok" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True || true)
  if [ "$nodes" -eq "$KWOK_NODES_PER_TYPE" ] && [ "$ready" -eq "$nodes" ]; then
    record PASS "$t" "nodes" "$ready/$KWOK_NODES_PER_TYPE Ready"
  else
    record FAIL "$t" "nodes" "$ready Ready of $nodes, want $KWOK_NODES_PER_TYPE"
  fi

  bad=""
  for n in $(k get nodes -l "k8s-mock-test/gpu-type=$t,type=kwok" -o jsonpath='{.items[*].metadata.name}'); do
    got=$(k get node "$n" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
    [ "$got" = "$GPU_COUNT" ] || bad="$bad $n=$got"
  done
  if [ -z "$bad" ]; then record PASS "$t" "capacity" "nvidia.com/gpu=$GPU_COUNT"; else record FAIL "$t" "capacity" "want $GPU_COUNT:$bad"; fi

  if [ "$IB_COUNT" -gt 0 ]; then
    bad=""
    for n in $(k get nodes -l "k8s-mock-test/gpu-type=$t,type=kwok" -o jsonpath='{.items[*].metadata.name}'); do
      got=$(k get node "$n" -o jsonpath="$(allocatable_path "$IB_RESOURCE")")
      [ "$got" = "$IB_COUNT" ] || bad="$bad $n=${got:-none}"
    done
    if [ -z "$bad" ]; then record PASS "$t" "ib capacity" "$IB_RESOURCE=$IB_COUNT"; else record FAIL "$t" "ib capacity" "want $IB_COUNT:$bad"; fi
  fi

  bad=""
  for n in $(k get nodes -l "k8s-mock-test/gpu-type=$t,type=kwok" -o jsonpath='{.items[*].metadata.name}'); do
    product=$(k get node "$n" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}')
    count=$(k get node "$n" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.count}')
    [ "$product" = "$GPU_PRODUCT" ] && [ "$count" = "$GPU_COUNT" ] || bad="$bad $n=$product/$count"
  done
  if [ -z "$bad" ]; then record PASS "$t" "labels" "$GPU_PRODUCT x$GPU_COUNT"; else record FAIL "$t" "labels" "want $GPU_PRODUCT/$GPU_COUNT:$bad"; fi
done

delete_pod() { k -n "$ns" delete pod "$1" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true; }
# unsched <pod> <resource>: the scheduler reports Insufficient <resource>.
unsched() {
  k -n "$ns" get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' |
    grep -q "Insufficient $2"
}

# expect_pending <type> <check> <pod> <resource> <amount>
expect_pending() {
  if wait_until 60 "" unsched "$3" "$4" && [ "$(k -n "$ns" get pod "$3" -o jsonpath='{.status.phase}')" = Pending ]; then
    record PASS "$1" "$2" "Pending: Insufficient $4 for $5"
  else
    record FAIL "$1" "$2" "phase=$(k -n "$ns" get pod "$3" -o jsonpath='{.status.phase} {.status.conditions[?(@.type=="PodScheduled")].message}')"
  fi
  delete_pod "$3"
}

log "Scheduling test pods"
for t in $GPU_TYPES; do
  load_gpu "$t"
  k -n "$ns" delete pods -l "k8s-mock-test/gpu-type=$t" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true

  # <name>:<gpus>:<ib>
  for case in "1gpu:1:$((IB_COUNT > 0 ? 1 : 0))" "full:$GPU_COUNT:$IB_COUNT"; do
    name=${case%%:*} rest=${case#*:}
    gpus=${rest%%:*} ib=${rest#*:}
    p="$t-$name"
    what="$gpus GPU(s)"
    [ "$ib" -gt 0 ] && what="$what + $ib $IB_RESOURCE"
    render_gpu_pod "$p" "$ns" "$gpus" "$ib" | k apply -f - >/dev/null
    if k -n "$ns" wait --for=jsonpath='{.status.phase}'=Running "pod/$p" --timeout=120s >/dev/null 2>&1; then
      node=$(k -n "$ns" get pod "$p" -o jsonpath='{.spec.nodeName}')
      ntype=$(k get node "$node" -o jsonpath='{.metadata.labels.k8s-mock-test/gpu-type}')
      if [ "$ntype" = "$t" ]; then
        record PASS "$t" "$name pod" "$what, Running on $node"
      else
        record FAIL "$t" "$name pod" "Running on $node, a '$ntype' node"
      fi
    else
      record FAIL "$t" "$name pod" "not Running: $(k -n "$ns" get pod "$p" -o jsonpath='{.status.phase} {.status.conditions[?(@.type=="PodScheduled")].message}')"
    fi
    delete_pod "$p"
  done

  render_gpu_pod "$t-too-many" "$ns" $((GPU_COUNT + 1)) | k apply -f - >/dev/null
  expect_pending "$t" "too-many pod" "$t-too-many" nvidia.com/gpu $((GPU_COUNT + 1))

  if [ "$IB_COUNT" -gt 0 ]; then
    render_gpu_pod "$t-too-many-ib" "$ns" 1 $((IB_COUNT + 1)) | k apply -f - >/dev/null
    expect_pending "$t" "too-many-ib pod" "$t-too-many-ib" "$IB_RESOURCE" $((IB_COUNT + 1))
  fi
done

finish

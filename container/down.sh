#!/usr/bin/env bash
# Removes everything container/up.sh created: test pods, KWOK nodes,
# fake-gpu-operator and (KEEP_KWOK=1 to skip) the KWOK controller.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
load_config
require_tools kubectl helm

log "Checking the cluster"
check_cluster

log "Deleting test pods and fake nodes"
k delete namespace "$CONTAINER_TEST_NAMESPACE" --ignore-not-found --wait=false >/dev/null
k delete nodes -l app.kubernetes.io/part-of=k8s-mock-test,type=kwok --ignore-not-found >/dev/null

log "Uninstalling fake-gpu-operator"
if h status fake-gpu-operator -n "$FGO_NAMESPACE" >/dev/null 2>&1; then
  h uninstall fake-gpu-operator -n "$FGO_NAMESPACE" --wait >/dev/null
fi
k delete namespace "$FGO_NAMESPACE" --ignore-not-found --wait=false >/dev/null

if [ "${KEEP_KWOK:-0}" != 1 ]; then
  log "Removing KWOK $KWOK_VERSION"
  kwok_url="https://github.com/kubernetes-sigs/kwok/releases/download/$KWOK_VERSION"
  k delete -f "$kwok_url/stage-fast.yaml" --ignore-not-found >/dev/null
  k delete -f "$kwok_url/kwok.yaml" --ignore-not-found >/dev/null
fi
log "Done"

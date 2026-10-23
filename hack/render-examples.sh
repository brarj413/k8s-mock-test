#!/usr/bin/env bash
# Writes container/examples/ from the same renderers the scripts use, so the
# examples always match what container/up.sh and container/test.sh deploy.
# CI fails when they are out of date; re-run this after changing gpus/*.env or
# lib/render.sh.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
# shellcheck source=../lib/render.sh
. "$ROOT_DIR/lib/render.sh"
load_config
check_gpu_types

out="$ROOT_DIR/container/examples"
rm -rf "$out"
mkdir -p "$out"

render_fgo_values >"$out/fake-gpu-operator-values.yaml"
for t in $GPU_TYPES; do
  load_gpu "$t"
  mkdir -p "$out/$t"
  render_kwok_node "kwok-$t-1" >"$out/$t/kwok-node.yaml"
  render_gpu_pod "$t-1gpu" default 1 >"$out/$t/pod-1gpu.yaml"
  render_gpu_pod "$t-full-node" default "$GPU_COUNT" >"$out/$t/pod-full-node.yaml"
done
echo "wrote $(find "$out" -name '*.yaml' | wc -l | tr -d ' ') files to container/examples/"

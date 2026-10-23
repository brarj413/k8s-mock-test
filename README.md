# k8s-mock-test

Test GPU workloads on a Kubernetes cluster that has no GPUs. The suite mocks five
NVIDIA GPU types, H100, H200, B200, GB200 and GB300, on simulated nodes, so
schedulers, quotas, node selectors and GPU-aware tooling can be exercised on a
plain CPU cluster, down to a single control-plane node.

## What it builds

```
                 control plane (any CPU cluster, kind works)
 ┌──────────────────────────────────────────────────────────────────────┐
 │  KWOK controller         fake-gpu-operator                           │
 │  (simulates nodes        (status-updater, kwok-gpu-device-plugin,    │
 │   and pod lifecycles)     status exporter)                           │
 └──────────────────────────────────────────────────────────────────────┘
        │ creates per GPU type (default 2 each)
        ▼
  kwok-h100-1  kwok-h100-2  kwok-h200-1 ... kwok-gb300-2     (fake nodes)
  nvidia.com/gpu: 8 | 8 | 8 | 4 | 4                          (fake GPUs)
  nvidia.com/gpu.product, .count, .memory, .family labels
```

- **KWOK** ([kubernetes-sigs/kwok](https://github.com/kubernetes-sigs/kwok))
  adds nodes without kubelets and moves pods scheduled onto them to `Running`.
- **fake-gpu-operator** ([run-ai/fake-gpu-operator](https://github.com/run-ai/fake-gpu-operator))
  puts every node labelled `run.ai/simulated-gpu-node-pool=<type>` in a pool,
  gives it `nvidia.com/gpu` capacity, and sets the GPU Feature Discovery labels
  workloads select on.

Pods on fake nodes are simulated: they get scheduled, take GPUs from the node's
capacity and reach `Running`, but no container process starts. The suite tests
everything up to and including scheduling, not code running on a GPU.

## Mocked GPU types

| Type | `nvidia.com/gpu.product` | GPUs per node | GPU memory (MiB) | Node arch | Node CPU / memory |
|---|---|---|---|---|---|
| `h100` | `NVIDIA-H100-80GB-HBM3` | 8 | 81920 | amd64 | 224 / 2Ti |
| `h200` | `NVIDIA-H200` | 8 | 143771 | amd64 | 224 / 2Ti |
| `b200` | `NVIDIA-B200` | 8 | 184320 | amd64 | 224 / 2Ti |
| `gb200` | `NVIDIA-GB200` | 4 | 190464 | arm64 | 144 / 960Gi |
| `gb300` | `NVIDIA-GB300` | 4 | 284672 | arm64 | 144 / 960Gi |

Each type is one file in [`gpus/`](gpus). GB200 and GB300 model one NVL72
compute tray (Grace is arm64), so their nodes carry
`kubernetes.io/arch=arm64`. Every node also gets `nvidia.com/gpu.family` and
`nvidia.com/gpu.compute.major` / `.minor`. To add a type, copy a file in
`gpus/`, then run `make examples`.

## Prerequisites

- A Kubernetes cluster you can be cluster-admin on. One control-plane node is
  enough; [kind](https://kind.sigs.k8s.io/) works:

  ```bash
  kind create cluster --name mock-gpu
  ```

- `kubectl`, `helm` 3.8+, `make` and bash. macOS's bash 3.2 is fine.
- Network access from the cluster to `ghcr.io` and from your machine to
  `github.com`, for the KWOK manifests and the fake-gpu-operator chart and
  images.

## Quick start

```bash
make container-up
```

```bash
make container-test
```

```bash
make container-down
```

`container-up` installs KWOK and fake-gpu-operator, creates the fake nodes and
waits until each one advertises its GPUs:

```
NODE          TYPE    ARCH    PRODUCT                 GPUS   MEMORY_MIB
kwok-b200-1   b200    amd64   NVIDIA-B200             8      184320
kwok-gb200-1  gb200   arm64   NVIDIA-GB200            4      190464
kwok-h100-1   h100    amd64   NVIDIA-H100-80GB-HBM3   8      81920
...
```

## What `make container-test` checks

For every type in `GPU_TYPES`:

| Check | Pass condition |
|---|---|
| nodes | `KWOK_NODES_PER_TYPE` fake nodes exist and are `Ready` |
| capacity | each advertises `nvidia.com/gpu` equal to the catalog count |
| labels | `nvidia.com/gpu.product` and `nvidia.com/gpu.count` match the catalog |
| 1gpu pod | a pod asking for 1 GPU runs on a node of that type |
| full pod | a pod asking for all of a node's GPUs runs |
| too-many pod | a pod asking for one GPU more than a node has stays `Pending` with `Insufficient nvidia.com/gpu` |

It prints a PASS/FAIL line per check and a summary, and exits non-zero on any
failure. A type's pods run one at a time and are deleted afterwards, so one
fake node per type is enough. Besides `nvidia.com/gpu.product`, the test pods
select the suite's `k8s-mock-test/gpu-type` label, so a real node with a
leftover product label can't attract them.

## Writing your own tests

Select a GPU type the way a workload on a real cluster would, by the GPU
Feature Discovery label, and tolerate the KWOK taint:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: train
spec:
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H200
  tolerations:
    - key: kwok.x-k8s.io/node
      operator: Equal
      value: fake
      effect: NoSchedule
  containers:
    - name: cuda
      image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["sleep", "infinity"]
      resources:
        limits:
          nvidia.com/gpu: 8
```

[`container/examples/`](container/examples) has a node, a 1-GPU pod and a
full-node pod for each type, plus the generated fake-gpu-operator values. They
come from the same renderers the scripts use ([`lib/render.sh`](lib/render.sh)).
CI fails if they drift, so re-run `make examples` after changing `gpus/` or
`lib/render.sh`.

## Configuration

Defaults live in [`config.env`](config.env). Override any of them from the
environment, or in a git-ignored `config.local.env`
(see [`config.local.env.example`](config.local.env.example)):

```bash
GPU_TYPES="h100 gb200" KWOK_NODES_PER_TYPE=10 make container-up
```

| Variable | Default | Meaning |
|---|---|---|
| `KUBE_CONTEXT` | current context | kubectl / helm context |
| `GPU_TYPES` | `h100 h200 b200 gb200 gb300` | Types to mock |
| `KWOK_NODES_PER_TYPE` | `2` | Fake nodes per type |
| `KWOK_VERSION` | `v0.7.0` | KWOK release |
| `KWOK_POD_CIDR` | `198.18.0.0/16` | IPs KWOK gives pods on fake nodes |
| `KWOK_NODE_IP` | `198.19.0.1` | IP KWOK gives the fake nodes |
| `FGO_VERSION` | `0.2.1` | fake-gpu-operator chart version |
| `FGO_NAMESPACE` | `fake-gpu-operator` | Its namespace |
| `CONTAINER_TEST_NAMESPACE` | `mock-gpu-containers` | Where test pods run |
| `TIMEOUT` | `600s` | Per-wait timeout |

## Running on a shared cluster

Fake nodes are visible to everything in the cluster, not just these tests.
Check these before running the suite on a cluster other people use:

- **DaemonSets that tolerate every taint** (`operator: Exists` with no key,
  typical of CNI agents, kube-proxy, node exporters) get a simulated pod on
  every fake node. List them first:

  ```bash
  kubectl get ds -A -o json | jq -r '.items[] | select(any(.spec.template.spec.tolerations[]?; .operator=="Exists" and (.key // "")=="")) | "\(.metadata.namespace)/\(.metadata.name)"'
  ```

  Controllers behind them may also act on the new nodes: a CNI controller can
  reserve addresses for them, and Prometheus will report the node exporter
  targets on them as down. All of this goes away with `make container-down`.
- **IP ranges:** KWOK's defaults give fake pods addresses from `10.0.0.1/24`,
  and fake nodes the controller's own pod IP, which can duplicate real ones.
  The suite moves them to `KWOK_POD_CIDR` and `KWOK_NODE_IP`, by default in
  `198.18.0.0/15`, a range reserved for benchmarking. Pick another range if
  your cluster uses that one.
- **A real NVIDIA GPU Operator:** it sees the fake nodes' GPU labels and
  manages its own labels on them. On stage-loki it set
  `nvidia.com/gpu.present=false` on every fake node. Its DaemonSets don't
  tolerate the KWOK taint, so none of its pods land there. The generated values
  turn off fake-gpu-operator's real-node DaemonSets (device plugin, MIG faker)
  and its `nvidia` RuntimeClass. Its status exporter DaemonSet stays on, because the
  KWOK labels come from the same component. It selects nodes the GPU Operator
  labels `nvidia.com/gpu.deploy.dcgm-exporter=true`, so it would run beside the
  real DCGM exporter on real GPU nodes. See fake-gpu-operator's
  [mixed real + fake](https://github.com/run-ai/fake-gpu-operator#-mixed-real--fake-gpu-nodes)
  notes.
- **Footprint:** `KWOK_NODES_PER_TYPE=1` or a smaller `GPU_TYPES` keeps the
  number of fake nodes down.

## CI

[`.github/workflows/ci.yaml`](.github/workflows/ci.yaml) runs on every push and
pull request:

- **lint:** `bash -n` and shellcheck, and checks the examples are up to date.
- **validate:** `kubeconform -strict` on the examples, and `helm template`
  of fake-gpu-operator with the generated values.
- **e2e-container:** a single-node kind cluster running `make container-up`,
  `make container-test` and `make container-down`.

## Not covered yet

- **KubeVirt VMs with passed-through GPUs** on real CPU workers. Not part of
  this suite yet.
- **Code that calls NVML or CUDA inside the pod.** Pods on fake nodes don't
  execute. For in-pod `nvidia-smi` on real CPU nodes, see NVIDIA's
  [nvml-mock](https://github.com/NVIDIA/k8s-test-infra/tree/main/deployments/nvml-mock)
  (Mokka), or fake-gpu-operator's
  [mock backend](https://github.com/run-ai/fake-gpu-operator/blob/main/docs/mock-backend.md).
- **DRA** (`resource.k8s.io`). fake-gpu-operator can publish ResourceSlices for
  KWOK nodes (`kwokDraPlugin`); this suite uses the `nvidia.com/gpu` extended
  resource.

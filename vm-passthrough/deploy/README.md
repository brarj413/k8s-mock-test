# Fake H200 + ConnectX-7 VFIO passthrough on a real CPU node

Deployable node setup that makes a CPU worker present, over VFIO, a fake HGX
H200 board with InfiniBand:

| Devices per node | PCI ID | Class | Advertised as | By |
|---|---|---|---|---|
| 8 × NVIDIA H200 | `10de:2335` | `0x0302` 3D controller | `nvidia.com/GH100_H200_SXM_141GB` | GPU Operator sandbox device plugin |
| 4 × NVSwitch | `10de:22a3` | `0x0680` bridge | `nvidia.com/GH100_H100_NVSWITCH` | GPU Operator sandbox device plugin |
| 8 × ConnectX-7 | `15b3:1021` | `0x0207` InfiniBand controller | `mellanox.com/connectx7` | KubeVirt device plugin |

A throwaway host-bridge filler sits at PCI slot 0, which `vfio-pci` leaves
alone (see `fake-pci-multidev.py` for why). After setup,
`kubectl describe node <node>` shows all three resources under Capacity and
Allocatable, and a KubeVirt VM can pass all 20 through.

> **This touches the kernel of a shared node.** It builds and loads the
> out-of-tree `fake-iommu` and `fake-pci` modules, and sets
> `vfio_iommu_type1 allow_unsafe_interrupts=1`, which relaxes VFIO interrupt
> isolation **node-wide**, for every workload on the box including real tenant
> VMs. The fake IOMMU claims only its synthetic PCI domain (`0xfaca`) and leaves
> real devices alone, and the modules are the ones KubeVirt's own e2e uses, but
> a module bug could still disrupt the node. Pick a node whose owner accepts
> that, ideally a drained or lightly loaded one. Guest GPUs and HCAs have no
> memory regions, so the VM sees the PCI devices but no driver can use them.

## How it works

- **`fake-pci-multidev.py`** rewrites kubevirtci's `fake-pci.c` to emit three
  device groups (GPUs, optional NVSwitches, InfiniBand HCAs), each with its own
  vendor / device / class. With `num_switches` and `num_ib` unset it is
  identical to upstream.
- **`setup.sh`** builds `fake-iommu` + the rewritten `fake-pci` for the node's
  kernel, loads them, binds every device on domain `0xfaca` to `vfio-pci`, and
  re-binds every 30s. Env vars (see `h200-ib-vfio.yaml`) set the counts and IDs.
- **`h200-ib-vfio.yaml`** runs `setup.sh` as a privileged DaemonSet on nodes
  labelled `k8s-mock-test/vfio=h200-ib`.
- **`test-vm.yaml`** is a VM that requests all 8 GPUs and 8 HCAs.

## Prerequisites

- The node runs Linux with kernel ≥ 5.14, with headers available (the node's
  own, or installable in the builder image — Ubuntu/Debian or RHEL-family).
- KubeVirt installed, with `HostDevices` enabled and `permittedHostDevices`
  entries for `10de:2335 → nvidia.com/GH100_H200_SXM_141GB` and
  `15b3:1021 → mellanox.com/connectx7` (the ConnectX-7 entry with
  `externalResourceProvider: false`).
- The NVIDIA GPU Operator with `sandboxWorkloads.enabled: true`, for the H200s.

## Deploy

```bash
export KUBECONFIG=...            # the target cluster
NODES="<worker-1> <worker-2>"     # the CPU workers to mimic H200 nodes
```

Put the GPU nodes in VM-passthrough mode first, so the GPU Operator advertises
the H200s through its sandbox plugin instead of installing a driver on them:

```bash
for n in $NODES; do kubectl label node "$n" nvidia.com/gpu.workload.config=vm-passthrough --overwrite; done
```

Create the namespace and the scripts ConfigMap, then the DaemonSet:

```bash
kubectl create namespace vfio-passthrough --dry-run=client -o yaml | kubectl apply -f -
kubectl -n vfio-passthrough create configmap h200-ib-vfio-scripts \
  --from-file=setup.sh --from-file=fake-pci-multidev.py \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f h200-ib-vfio.yaml
```

Select the nodes (this starts the module build and load):

```bash
for n in $NODES; do kubectl label node "$n" k8s-mock-test/vfio=h200-ib --overwrite; done
kubectl -n vfio-passthrough rollout status ds/h200-ib-vfio --timeout=15m
kubectl -n vfio-passthrough logs -l app=h200-ib-vfio --tail=20
```

The log ends with 20 bound devices: 8 `10de:2335 class=0x030200`,
4 `10de:22a3 class=0x068000` and 8 `15b3:1021 class=0x020700`, each
`driver=vfio-pci`, plus the slot-0 filler (`1b36:0008`) left unbound.

## Verify

The GPU Operator's sandbox device plugin only scans at start, so restart it on
the nodes after the devices appear:

```bash
kubectl -n gpu-operator delete pod -l app=nvidia-sandbox-device-plugin-daemonset \
  --field-selector "spec.nodeName in ($(echo $NODES | tr ' ' ,))" 2>/dev/null || \
  kubectl -n gpu-operator delete pod -l app=nvidia-sandbox-device-plugin-daemonset
```

```bash
for n in $NODES; do
  kubectl get node "$n" -o jsonpath='{.metadata.name}: GH100_H200='\
'{.status.allocatable.nvidia\.com/GH100_H200_SXM_141GB} NVSWITCH='\
'{.status.allocatable.nvidia\.com/GH100_H100_NVSWITCH} connectx7='\
'{.status.allocatable.mellanox\.com/connectx7}{"\n"}'
done
```

Each node should report `GH100_H200=8 NVSWITCH=4 connectx7=8`. Then optionally
boot the VM:

```bash
kubectl apply -f test-vm.yaml
kubectl -n vfio-passthrough logs -l kubevirt.io/domain=h200-ib-test \
  -c guest-console-log | sed -n '/PASSTHROUGH CHECK/,/END PASSTHROUGH/p'
```

## Clean up

The setup is meant to stay and survives reboots (the DaemonSet rebuilds and
reloads the modules). To remove it:

```bash
kubectl -n vfio-passthrough delete vm h200-ib-test --ignore-not-found
kubectl label node $NODES k8s-mock-test/vfio- nvidia.com/gpu.workload.config-
kubectl delete -f h200-ib-vfio.yaml
```

Then unload the modules from a shell on each node (or reboot it):

```bash
rmmod fake_pci && rmmod fake_iommu
echo 0 > /sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts
```

```bash
kubectl delete namespace vfio-passthrough
```

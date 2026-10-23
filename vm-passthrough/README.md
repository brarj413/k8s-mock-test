# VM GPU passthrough without GPUs: a reference

This is a reference, not part of the automated suite. It explains how to try
KubeVirt GPU passthrough with fake PCI devices using
[kubevirtci](https://github.com/kubevirt/kubevirtci)'s upstream tooling, and
which settings and labels the NVIDIA GPU Operator needs to drive VM
passthrough. Nothing in this repo sets it up for you.

**Run the fake-device part only in a throwaway kubevirtci cluster.** kubevirtci
builds its Kubernetes nodes as VMs and loads its fake-device kernel modules
inside those VMs, not on your machine or on real cluster nodes. The fake IOMMU
can't isolate device interrupts, so kubevirtci's node setup relaxes VFIO's
interrupt-isolation check inside those node VMs. That is fine for a disposable
test cluster and not something to do on shared or production nodes. Review the
upstream scripts and run your own safety checks before using any of this.

## What it can and can't test

| | Fake PCIe (kubevirtci) | Real GPUs |
|---|---|---|
| Devices on the node's PCI bus, any vendor:device ID | ✓ | ✓ |
| Bound to `vfio-pci`, own IOMMU groups | ✓ | ✓ |
| Advertised to Kubernetes, scheduled with a VM | ✓ | ✓ |
| VM starts with the devices passed through; guest sees them in `lspci` | ✓ | ✓ |
| NVIDIA driver, `nvidia-smi`, CUDA inside the guest | ✗ (no memory regions, no DMA) | ✓ |

## Part 1: fake VFIO devices with kubevirtci

Upstream documentation:
[cluster-up/cluster/vfio-gpu](https://github.com/kubevirt/kubevirtci/tree/main/cluster-up/cluster/vfio-gpu).
Read it first; this section only summarises it.

### Prerequisites (from upstream)

- A Linux x86_64 machine with KVM and nested virtualization. kubevirtci's
  `k8s-*` providers run each Kubernetes node as a VM.
- `docker` or `podman`, `kubectl`, `helm`, `git`, `make`.
- At least 8 GiB per node VM (`KUBEVIRT_MEMORY_SIZE=8192M`). Cluster-up fails
  below that when fake VFIO is on.
- A provider that supports it: `k8s-1.36` and `k8s-1.37` ship
  `config_vfio_cluster.sh`.

### Bring up a cluster with fake devices

```bash
git clone https://github.com/kubevirt/kubevirtci.git
cd kubevirtci

export KUBEVIRT_PROVIDER=k8s-1.36
export KUBEVIRT_USE_FAKE_VFIO=true
export KUBEVIRT_MEMORY_SIZE=8192M
export FAKE_PCI_DEVICES=8
export FAKE_IOMMU=true

make cluster-up
```

`make cluster-up` creates the cluster, and with `KUBEVIRT_USE_FAKE_VFIO=true`
it also runs the provider's `config_vfio_cluster.sh` on each worker VM:

- builds and loads the `fake-iommu` and `fake-pci` modules;
- binds the fake devices to `vfio-pci`;
- labels the nodes `fake-vfio-capable=true`;
- installs a DRA example driver (`vfio-gpu.example.com`) that publishes them.

### Example: devices that look like H200s

The fake devices default to a synthetic ID (`e1a5:d0c5`). The node setup also
reads `FAKE_PCI_VENDOR_ID` and `FAKE_PCI_DEVICE_ID`, which `config_vfio_cluster.sh`
passes through, so they can carry a real GPU's identity. For the H200 SXM
141GB (`10de:2335` in [pci.ids](https://pci-ids.ucw.cz/read/PC/10de/2335)),
set these before `make cluster-up`:

```bash
export FAKE_PCI_VENDOR_ID=0x10de
export FAKE_PCI_DEVICE_ID=0x2335
```

### What each board puts on the host's PCI bus

What a faithful fake of each GPU type should present, per node. It uses the
same catalog as the container suite, and the PCI names come from
[pci.ids](https://pci-ids.ucw.cz/read/PC/10de).

| Type | Board | GPUs per node | GPU PCI ID | NVSwitches per node | NVSwitch PCI ID |
|---|---|---|---|---|---|
| H100 | HGX H100 | 8 | `10de:2330` GH100 [H100 SXM5 80GB] | 4 | `10de:22a3` GH100 [H100 NVSwitch] |
| H200 | HGX H200 | 8 | `10de:2335` GH100 [H200 SXM 141GB] | 4 | `10de:22a3` GH100 [H100 NVSwitch] |
| B200 | HGX B200 | 8 | `10de:2901` GB100 [B200] | 0 | none: its NVLink 5 switch chips aren't PCIe devices on the host |
| GB200 | NVL72 compute tray (arm64) | 4 | `10de:2941` GB100 [HGX GB200] | 0 | none: the switches are in separate NVLink switch trays |
| GB300 | NVL72 compute tray (arm64) | 4 | `10de:31c2` GB110 [GB300] | 0 | none: the switches are in separate NVLink switch trays |

So a full HGX H100 or H200 node has 12 NVIDIA PCI devices (8 GPUs and
4 NVSwitches), an HGX B200 node has 8, and a GB200 or GB300 tray has 4.

The GPU Operator's sandbox device plugin names each resource after the
device's pci.ids entry. A plugin image with an older pci.ids may not know the
newer IDs:

| Type | GPU resource | NVSwitch resource |
|---|---|---|
| H100 | `nvidia.com/GH100_H100_SXM5_80GB` | `nvidia.com/GH100_H100_NVSWITCH` |
| H200 | `nvidia.com/GH100_H200_SXM_141GB` | `nvidia.com/GH100_H100_NVSWITCH` |
| B200 | `nvidia.com/GB100_B200` | none |
| GB200 | `nvidia.com/GB100_HGX_GB200` | none |
| GB300 | `nvidia.com/GB110_GB300` | none |

kubevirtci's `fake-pci` creates every device with the same ID, so it can model
a board's GPUs but not the NVSwitches beside them.

### Check and clean up

```bash
./cluster-up/kubectl.sh get nodes -l fake-vfio-capable=true
```

```bash
make cluster-down
```

To use the devices from a VM, follow KubeVirt's own DRA host-device tests and
docs. kubevirtci's flow exposes them through DRA, not through the GPU
Operator.

## Part 2: what the NVIDIA GPU Operator needs for VM passthrough

This is the GPU Operator's
[GPU Operator with KubeVirt](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-kubevirt.html)
workflow. On real GPUs it's the supported path. With fake devices it's not
something upstream tests: it worked on a shared test cluster, but the
GPU Operator's validator and VFIO manager expect real hardware.

### 1. Turn on sandbox workloads in the ClusterPolicy

```yaml
spec:
  sandboxWorkloads:
    enabled: true
    defaultWorkload: container   # nodes without a workload label stay container nodes
```

### 2. Label each VM-passthrough node

| Label | Set by | Meaning |
|---|---|---|
| `nvidia.com/gpu.workload.config=vm-passthrough` | you | This node's GPUs go to VMs (`container`, `vm-passthrough` or `vm-vgpu`) |
| `feature.node.kubernetes.io/pci-10de.present=true` | NFD | NFD found an NVIDIA display / 3D / accelerator class device |
| `nvidia.com/gpu.present=true` | GPU Operator | Derived from the NFD label; the operator acts on this node |
| `nvidia.com/gpu.deploy.vfio-manager=true` | GPU Operator | Binds the node's NVIDIA devices to `vfio-pci` |
| `nvidia.com/gpu.deploy.sandbox-device-plugin=true` | GPU Operator | Advertises them as `nvidia.com/<device name>` |
| `nvidia.com/gpu.deploy.sandbox-validator=true` | GPU Operator | Checks the `vfio-pci` binding |

```bash
kubectl label node <node> nvidia.com/gpu.workload.config=vm-passthrough
```

Set the workload label **before** the node has NVIDIA devices. With
`defaultWorkload: container`, an unlabelled node with GPUs gets the container
stack, including the NVIDIA driver container.

The sandbox device plugin names resources after the device's pci.ids entry,
for example `nvidia.com/GH100_H200_SXM_141GB` and
`nvidia.com/GH100_H100_NVSWITCH`. It only looks for devices when it starts, so
restart its pod on the node after the devices change.

### 3. Permit the devices in KubeVirt

`externalResourceProvider: true` tells KubeVirt that the GPU Operator's plugin,
not KubeVirt's own, advertises the resource:

```yaml
apiVersion: kubevirt.io/v1
kind: KubeVirt
spec:
  configuration:
    developerConfiguration:
      featureGates: [HostDevices]
    permittedHostDevices:
      pciHostDevices:
        - pciVendorSelector: "10de:2335"
          resourceName: nvidia.com/GH100_H200_SXM_141GB
          externalResourceProvider: true
        - pciVendorSelector: "10de:22a3"
          resourceName: nvidia.com/GH100_H100_NVSWITCH
          externalResourceProvider: true
```

### 4. Ask for them in a VM

GPUs go under `gpus`, NVSwitches under `hostDevices`:

```yaml
spec:
  template:
    spec:
      domain:
        devices:
          gpus:
            - {name: gpu0, deviceName: nvidia.com/GH100_H200_SXM_141GB}
          hostDevices:
            - {name: nvswitch0, deviceName: nvidia.com/GH100_H100_NVSWITCH}
```

`kubectl describe node <node>` shows the counts under Capacity and
Allocatable, for example `nvidia.com/GH100_H200_SXM_141GB: 8`.

## Seen on a shared test cluster

These came from a test with fake H200s on one node of a shared test cluster. They are
specific to that cluster's KubeVirt build and CNI, but worth checking on
yours:

- `kubevirt-plugin-sidecar-subpath-policy` (KubeVirt `v1.9.1-test`) rejected
  launcher pods for `containerDisk` VMs. A DataVolume root disk works.
- The default `bridge` binding failed with "no gateway address found in routes
  for eth0". `masquerade` works.
- From inside a masquerade VM, the cluster DNS service IP timed out while
  CoreDNS's pod IPs and public resolvers worked.
- The GPU Operator's VFIO manager left already-bound devices bound, and the
  sandbox device plugin advertised them once restarted.

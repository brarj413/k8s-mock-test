#!/usr/bin/env bash
# Fake NVIDIA GPU + Mellanox InfiniBand PCIe devices for KubeVirt / GPU Operator
# VFIO passthrough tests, with no real hardware. Runs in a privileged, hostPID
# pod (the h200-ib-vfio DaemonSet) on a node labelled for it.
#
# Builds kubevirtci's fake-iommu + fake-pci kernel modules for the running
# kernel (fake-pci rewritten by fake-pci-multidev.py to emit three device
# groups), loads them so FAKE_PCI_DEVICES GPUs (FAKE_PCI_DEVICE_ID, class
# 0x0302) and FAKE_PCI_IB InfiniBand HCAs (FAKE_PCI_IB_DEVICE_ID / _VENDOR_ID,
# class 0x0207) appear on PCI domain FAKE_PCI_DOMAIN, binds them to vfio-pci,
# then re-checks the binding every 30s.
#
# Idempotent: with the modules loaded in the wanted layout it only rebinds; a
# different layout is reloaded, but never while a process (QEMU) holds one of
# the fake VFIO groups. MODE=teardown unbinds and unloads. BUILD_ONLY=1 builds
# and exits without touching the kernel.
#
# WARNING: this loads out-of-tree modules and (with ALLOW_UNSAFE_INTERRUPTS)
# relaxes VFIO interrupt isolation node-wide. Run only on a node whose owner
# accepts that. See README.md.
set -euo pipefail

KUBEVIRTCI_SHA="${KUBEVIRTCI_SHA:-89939d00ea5c6234ff1476b8fcd7655fe46e54ce}"
NUM="${FAKE_PCI_DEVICES:-8}"
VENDOR="${FAKE_PCI_VENDOR_ID:-0x10de}"
DEVICE="${FAKE_PCI_DEVICE_ID:-0x2335}"          # GH100 [H200 SXM 141GB]
NUM_SW="${FAKE_PCI_SWITCHES:-0}"
SWITCH="${FAKE_PCI_SWITCH_ID:-0x22a3}"
NUM_IB="${FAKE_PCI_IB:-8}"
IB_VENDOR="${FAKE_PCI_IB_VENDOR_ID:-0x15b3}"     # Mellanox
IB_DEVICE="${FAKE_PCI_IB_DEVICE_ID:-0x1021}"     # ConnectX-7
IB_CLASS="${FAKE_PCI_IB_CLASS:-0x0207}"          # InfiniBand controller
DOMAIN="${FAKE_PCI_DOMAIN:-0xfaca}"
ALLOW_UNSAFE="${ALLOW_UNSAFE_INTERRUPTS:-true}"
MODE="${MODE:-setup}"
DOM_HEX=$(printf '%04x' "$DOMAIN")
KVER=$(uname -r)

log() { echo "[h200-ib-vfio] $*"; }
die() { echo "[h200-ib-vfio] ERROR: $*" >&2; exit 1; }
loaded() { grep -q "^$1 " /proc/modules; }
param() { cat "/sys/module/fake_pci/parameters/$1" 2>/dev/null || echo "-"; }
host() { nsenter -t 1 -m -- "$@"; }

# Expose the node's own kernel headers at /usr/src (Debian header packages
# include each other by absolute path, so symlink rather than use the mount).
link_host_headers() {
  local d
  [ -d /host/usr/src ] || return 0
  mkdir -p /usr/src
  for d in /host/usr/src/*; do
    [ -e "$d" ] || continue
    [ -e "/usr/src/$(basename "$d")" ] || ln -s "$d" "/usr/src/$(basename "$d")"
  done
}

kernel_build_dir() {
  local d
  for d in "/usr/src/linux-headers-$KVER" "/usr/src/kernels/$KVER" "/lib/modules/$KVER/build"; do
    [ -f "$d/Makefile" ] && { echo "$d"; return 0; }
  done
  return 1
}

install_build_deps() {
  local want=1
  link_host_headers
  kernel_build_dir >/dev/null && want=0
  if command -v apt-get >/dev/null; then
    local pkgs="build-essential curl ca-certificates kmod python3 libelf-dev"
    [ "$want" = 1 ] && pkgs="$pkgs linux-headers-$KVER"
    apt-get update -qq
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs >/dev/null
  elif command -v dnf >/dev/null || command -v yum >/dev/null; then
    local pm pkgs="gcc make curl tar gzip kmod python3 elfutils-libelf-devel"
    pm=$(command -v dnf || command -v yum)
    [ "$want" = 1 ] && pkgs="$pkgs kernel-devel-$KVER"
    # shellcheck disable=SC2086
    "$pm" install -y -q $pkgs >/dev/null
  else
    die "builder image has neither apt-get nor dnf/yum; set a matching image"
  fi
}

build() {
  local kdir src
  log "building fake-iommu + fake-pci for $KVER (kubevirtci ${KUBEVIRTCI_SHA:0:12})"
  install_build_deps
  kdir=$(kernel_build_dir) || die "no kernel headers for $KVER"
  log "kernel build tree: $kdir"

  rm -rf /build && mkdir -p /build && cd /build
  src="kubevirtci-${KUBEVIRTCI_SHA}/cluster-up/cluster/vfio-gpu"
  curl -fsSL "https://codeload.github.com/kubevirt/kubevirtci/tar.gz/${KUBEVIRTCI_SHA}" |
    tar xz --strip-components=4 "${src}/fake-iommu" "${src}/fake-pci"

  # compat.h references RHEL_RELEASE_VERSION(...) unconditionally; define a
  # harmless fallback so a non-RHEL kernel's preprocessor accepts the #if.
  if ! grep -q '^#define RHEL_RELEASE_VERSION' fake-iommu/compat.h; then
    awk '/^#if LINUX_VERSION_CODE < KERNEL_VERSION\(5, 14, 0\)/ && !d {
           print "#ifndef RHEL_RELEASE_VERSION"
           print "#define RHEL_RELEASE_VERSION(a, b) (((a) << 8) + (b))"
           print "#endif"; d=1 } { print }' fake-iommu/compat.h >compat.h.new
    mv compat.h.new fake-iommu/compat.h
  fi

  # Rewrite fake-pci to emit the GPU + switch + IB groups.
  python3 /scripts/fake-pci-multidev.py fake-pci/fake-pci.c

  make -s -C fake-iommu KDIR="$kdir"
  make -s -C fake-pci KDIR="$kdir"
  log "built: $(ls fake-iommu/*.ko fake-pci/*.ko | tr '\n' ' ')"
}

groups_in_use() {
  local dev grp
  for dev in /sys/bus/pci/devices/${DOM_HEX}:*; do
    [ -e "$dev/iommu_group" ] || continue
    grp=$(basename "$(readlink "$dev/iommu_group")")
    ls -l /proc/[0-9]*/fd 2>/dev/null | grep -q " -> /dev/vfio/${grp}$" && echo "$grp"
  done
  # Never fail: the last grep returns non-zero when no group is in use, which
  # under `set -e` would otherwise abort the caller's `busy=$(groups_in_use)`.
  return 0
}

set_unsafe_interrupts() {
  local f set=0
  for f in /sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts \
           /sys/module/iommufd/parameters/allow_unsafe_interrupts; do
    [ -w "$f" ] && { echo "$1" >"$f"; set=1; }
  done
  [ "$set" = 1 ] || log "no allow_unsafe_interrupts parameter present"
}

load_pci() {
  insmod /build/fake-pci/fake-pci.ko \
    "num_devices=${NUM}" "pci_domain=${DOMAIN}" "vendor_id=${VENDOR}" "device_id=${DEVICE}" \
    "num_switches=${NUM_SW}" "switch_device_id=${SWITCH}" \
    "num_ib=${NUM_IB}" "ib_vendor_id=${IB_VENDOR}" "ib_device_id=${IB_DEVICE}" "ib_class=${IB_CLASS}"
  log "fake_pci loaded: ${NUM}x${VENDOR}:${DEVICE} + ${NUM_SW}x switch + ${NUM_IB}x${IB_VENDOR}:${IB_DEVICE}"
}

bind_all() {
  local dev bdf drv
  for dev in /sys/bus/pci/devices/${DOM_HEX}:*; do
    [ -e "$dev" ] || continue
    bdf=$(basename "$dev")
    drv=$(basename "$(readlink "$dev/driver" 2>/dev/null)" 2>/dev/null || true)
    [ "$drv" = vfio-pci ] && continue
    [ -n "$drv" ] && echo "$bdf" >"$dev/driver/unbind"
    echo vfio-pci >"$dev/driver_override"
    echo "$bdf" >/sys/bus/pci/drivers_probe
    log "bound $bdf to vfio-pci (was: ${drv:-none})"
  done
}

status() {
  local dev
  for dev in /sys/bus/pci/devices/${DOM_HEX}:*; do
    [ -e "$dev" ] || continue
    echo "  $(basename "$dev") $(cat "$dev/vendor"):$(cat "$dev/device") class=$(cat "$dev/class")" \
      "iommu_group=$(basename "$(readlink "$dev/iommu_group" 2>/dev/null)" 2>/dev/null)" \
      "driver=$(basename "$(readlink "$dev/driver" 2>/dev/null)" 2>/dev/null)"
  done
}

teardown() {
  local busy dev
  busy=$(groups_in_use)
  [ -z "$busy" ] || die "VFIO groups in use: $(echo "$busy"); stop the VMs using them first"
  for dev in /sys/bus/pci/devices/${DOM_HEX}:*; do
    [ -e "$dev/driver" ] && basename "$dev" >"$dev/driver/unbind"
  done
  loaded fake_pci && { rmmod fake_pci && log "fake_pci unloaded"; }
  loaded fake_iommu && { rmmod fake_iommu && log "fake_iommu unloaded"; }
  set_unsafe_interrupts 0
  log "teardown complete"
}

[ "${BUILD_ONLY:-0}" = 1 ] && { build; exit 0; }
[ "$MODE" = teardown ] && { teardown; exit 0; }

host modprobe vfio-pci
host modprobe vfio_iommu_type1 2>/dev/null || true
if [ "$ALLOW_UNSAFE" = true ]; then
  set_unsafe_interrupts 1
  log "allow_unsafe_interrupts enabled (fake IOMMU cannot isolate MSIs)"
else
  log "ALLOW_UNSAFE_INTERRUPTS=$ALLOW_UNSAFE: VMs will fail with 'Failed to set iommu for container'"
fi

want="$NUM $NUM_SW $NUM_IB $((DEVICE)) $((IB_DEVICE))"
have="$(param num_devices) $(param num_switches) $(param num_ib) $(param device_id) $(param ib_device_id)"
if loaded fake_pci && [ "$want" = "$have" ]; then
  log "fake_pci already loaded with the wanted layout; skipping build"
else
  build
  loaded fake_iommu || insmod /build/fake-iommu/fake-iommu.ko "target_domain=${DOMAIN}"
  if loaded fake_pci; then
    busy=$(groups_in_use)
    if [ -n "$busy" ]; then
      log "NOT reloading fake_pci: VFIO groups in use ($busy); stop those VMs and restart this pod"
    else
      log "reloading fake_pci (layout changed)"
      rmmod fake_pci
      load_pci
    fi
  else
    load_pci
  fi
fi

bind_all
log "fake devices:"
status
touch /tmp/ready
while true; do sleep 30; bind_all; done

#!/usr/bin/env python3
"""Rewrite kubevirtci's fake-pci.c to emit up to three device groups.

The upstream module creates `num_devices` identical PCI devices. This rewrite
puts a throwaway host-bridge filler at slot 0, then the GPUs, then two optional
groups, each with its own vendor / device / class / subsystem:

    slot 0                                  filler host bridge (1b36:0008)
    [1 .. num_devices]                      GPUs
    (num_devices .. +num_switches]          NVSwitches (switch_* params)
    (.. +num_ib]                            IB HCAs    (ib_* params)

The filler occupies slot 0 because on some kernels (seen on 5.15) the device at
PCI devfn 0 — the slot real systems reserve for the host bridge — never gets an
IOMMU group and so fails `vfio-pci` probe with -EINVAL. Parking a device nobody
counts there lets every GPU and HCA land on a slot that binds. It is class
0x0600 (host bridge), which `vfio-pci` ignores, and matches no device plugin.

It edits in place, anchoring on exact upstream strings so it fails loudly if
the base file changes. Usage: fake-pci-multidev.py path/to/fake-pci.c
"""
import sys

path = sys.argv[1]
t = open(path).read()


def sub(old, new):
    global t
    n = t.count(old)
    if n != 1:
        sys.exit("fake-pci-multidev: expected 1 match, got %d for:\n%s" % (n, old))
    t = t.replace(old, new)


PARAMS = '''
/* fake-h200-ib-vfio: extra device groups after the GPUs, each with its own
 * vendor/device/class/subsystem, for NVSwitches and InfiniBand HCAs beside
 * the GPUs. num_switches / num_ib default to 0, so with neither set the
 * module behaves exactly as upstream. */
static unsigned int num_switches;
module_param(num_switches, uint, 0444);
static unsigned int switch_vendor_id = 0x10de;
module_param(switch_vendor_id, uint, 0444);
static unsigned int switch_device_id = 0x22a3;
module_param(switch_device_id, uint, 0444);
static unsigned int switch_class = 0x0680;
module_param(switch_class, uint, 0444);
static unsigned int switch_subsys_id = 0x1796;
module_param(switch_subsys_id, uint, 0444);
static unsigned int num_ib;
module_param(num_ib, uint, 0444);
static unsigned int ib_vendor_id = 0x15b3;
module_param(ib_vendor_id, uint, 0444);
static unsigned int ib_device_id = 0x1021;
module_param(ib_device_id, uint, 0444);
static unsigned int ib_class = 0x0207;
module_param(ib_class, uint, 0444);
static unsigned int ib_subsys_id = 0x0051;
module_param(ib_subsys_id, uint, 0444);
'''

# 1. Add the module parameters after the last upstream one.
sub(
    '         "PCI subsystem ID to emulate (default 0xd0c5, synthetic)");\n',
    '         "PCI subsystem ID to emulate (default 0xd0c5, synthetic)");\n' + PARAMS,
)

# 2. Widen the slot bound check: filler at 0, then the three groups.
sub(
    "    if (slot >= num_devices)\n",
    "    if (slot >= 1 + num_devices + num_switches + num_ib)\n",
)

# 3. Validate the total device count (including the filler).
sub(
    "    if (num_devices == 0 || num_devices > FAKE_PCI_MAX_DEVICES) {",
    "    if (num_devices == 0 ||\n"
    "        1 + num_devices + num_switches + num_ib > FAKE_PCI_MAX_DEVICES) {",
)

# 4. Allocate room for the filler and every group.
sub(
    "    fpci.devices = kcalloc(num_devices, sizeof(*fpci.devices), GFP_KERNEL);",
    "    fpci.devices = kcalloc(1 + num_devices + num_switches + num_ib,\n"
    "                           sizeof(*fpci.devices), GFP_KERNEL);",
)

# 5. Initialise each device. Slot 0 is the filler; slots 1.. are GPUs, then
#    switches, then IB. fake_pci_init_config lays down the GPU defaults, which
#    the switch / IB / filler slots override.
sub(
    "    for (i = 0; i < num_devices; i++)\n"
    "        fake_pci_init_config(&fpci.devices[i]);\n",
    "    for (i = 0; i < 1 + num_devices + num_switches + num_ib; i++) {\n"
    "        u8 *c = fpci.devices[i].config;\n"
    "\n"
    "        fake_pci_init_config(&fpci.devices[i]);\n"
    "        if (i == 0) {\n"
    "            STORE_LE16(&c[PCI_VENDOR_ID], 0x1b36);\n"
    "            STORE_LE16(&c[PCI_DEVICE_ID], 0x0008);\n"
    "            STORE_LE16(&c[PCI_CLASS_DEVICE], 0x0600);\n"
    "            STORE_LE16(&c[PCI_SUBSYSTEM_VENDOR_ID], 0x1b36);\n"
    "            STORE_LE16(&c[PCI_SUBSYSTEM_ID], 0x0008);\n"
    "        } else if (i > num_devices + num_switches) {\n"
    "            STORE_LE16(&c[PCI_VENDOR_ID], ib_vendor_id);\n"
    "            STORE_LE16(&c[PCI_DEVICE_ID], ib_device_id);\n"
    "            STORE_LE16(&c[PCI_CLASS_DEVICE], ib_class);\n"
    "            STORE_LE16(&c[PCI_SUBSYSTEM_VENDOR_ID], ib_vendor_id);\n"
    "            STORE_LE16(&c[PCI_SUBSYSTEM_ID], ib_subsys_id);\n"
    "        } else if (i > num_devices) {\n"
    "            STORE_LE16(&c[PCI_VENDOR_ID], switch_vendor_id);\n"
    "            STORE_LE16(&c[PCI_DEVICE_ID], switch_device_id);\n"
    "            STORE_LE16(&c[PCI_CLASS_DEVICE], switch_class);\n"
    "            STORE_LE16(&c[PCI_SUBSYSTEM_VENDOR_ID], switch_vendor_id);\n"
    "            STORE_LE16(&c[PCI_SUBSYSTEM_ID], switch_subsys_id);\n"
    "        }\n"
    "    }\n",
)

open(path, "w").write(t)
print("fake-pci-multidev: patched %s" % path)

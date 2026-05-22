## Prerequisites

- Ubuntu 24.04   
- Root/sudo access  
- GCC, Git, CMake, Ninja, Meson installed

---

## Step 1: Install DPDK

```shell
export TEST_DIR=/home/oran_lab/oaicicd/test_dir
mkdir -p $TEST_DIR
wget --no-verbose http://fast.dpdk.org/rel/dpdk-20.11.9.tar.xz -P $TEST_DIR
cd $TEST_DIR
tar xvf dpdk-20.11.9.tar.xz
cd dpdk-stable-20.11.9
export DPDK_INST=$(pwd)
export C_INCLUDE_PATH="$DPDK_INST/include"
meson setup --prefix=$DPDK_INST build
ninja -C build
ninja -C build install
```

---

## Step 2: Clone OpenAirInterface5G

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
git clone https://gitlab.eurecom.fr/oai/openairinterface5g.git $TEST_DIR/openairinterface5g
cd $TEST_DIR/openairinterface5g
git checkout oru-rebase-1-plus-compression
```

---

## Step 3: Build PHY Library (for O-RU)

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
git clone https://gerrit.o-ran-sc.org/r/o-du/phy.git $TEST_DIR/phy-f-1.0
cd $TEST_DIR/phy-f-1.0
git checkout oran_f_release_v1.0
# git apply $TEST_DIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oran_ru_prach_patch.patch
# git apply $TEST_DIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oran_callback_patch.patch
# git apply $TEST_DIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oaioran_F.patch
git apply $TEST_DIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oru.patch
git apply $TEST_DIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oaioran_F.patch
cd fhi_lib/lib
TARGET=x86 WIRELESS_SDK_TOOLCHAIN=gcc RTE_SDK=$DPDK_INST XRAN_DIR=$TEST_DIR/phy-f-1.0/fhi_lib make XRAN_LIB_SO=1
```

---

---

## Step 4: Build O-RU and NR-UE 

**IMPORTANT:** Must include `oran_fhlib_5g` target to build the FHI 7.2 transport library\!

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
cd $TEST_DIR/openairinterface5g
rm -rf build
mkdir build && cd build

# Configure with FHI 7.2 and all optional features disabled
PKG_CONFIG_PATH=$DPDK_INST/lib/x86_64-linux-gnu/pkgconfig/ cmake ../ -GNinja \
  -DOAI_FHI72=ON \
  -Dxran_LOCATION=$TEST_DIR/phy-f-1.0/fhi_lib/lib \
  -DENABLE_WEBSRV=OFF \
  -DENABLE_NRSCOPE=OFF \
  -DENABLE_ENBSCOPE=OFF \
  -DENABLE_UESCOPE=OFF \
  -DENABLE_IMSCOPE=OFF \
  -DENABLE_IMSCOPE_RECORD=OFF \
  -DENABLE_LDPC_CUDA=OFF \
  -DENABLE_LDPC_AAL=OFF \
  -DENABLE_LDPC_XDMA=OFF

# Build FHI library FIRST (this creates liboai_transpro.so)
PKG_CONFIG_PATH=$DPDK_INST/lib/x86_64-linux-gnu/pkgconfig/ cmake --build . --target oran_fhlib_5g

# Then build all other components
PKG_CONFIG_PATH=$DPDK_INST/lib/aarch64-linux-gnu/ cmake --build .   --target vrtsim oairu oran_fhlib_5g nr-softmodem ldpc params_libconfig nr-uesoftmodem nr-oru
```

**Verify FHI library was built:**

```shell
find $TEST_DIR/openairinterface5g/build -name "*transpro*"
```

Should show: `./liboai_transpro.so`

---

## Step 5: Build gNB

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
cd $TEST_DIR/openairinterface5g/cmake_targets
PKG_CONFIG_PATH=$DPDK_INST/lib/x86_64-linux-gnu/pkgconfig/ ./build_oai --gNB --ninja -t oran_fhlib_5g --cmake-opt -Dxran_LOCATION=$TEST_DIR/phy-f-1.0/fhi_lib/lib --cmake-opt -DENABLE_WEBSRV=OFF --cmake-opt -DENABLE_NRSCOPE=OFF --cmake-opt -DENABLE_ENBSCOPE=OFF --cmake-opt -DENABLE_UESCOPE=OFF --cmake-opt -DENABLE_IMSCOPE=OFF --cmake-opt -DENABLE_IMSCOPE_RECORD=OFF --cmake-opt -DENABLE_LDPC_CUDA=OFF --cmake-opt -DENABLE_LDPC_AAL=OFF --cmake-opt -DENABLE_LDPC_XDMA=OFF
```

---

## Step 6: Verify Builds

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
echo "=== O-RU Executable ==="
find $TEST_DIR/openairinterface5g/build -name "nr-oru" -type f
echo "=== gNB Executable ==="
find $TEST_DIR/openairinterface5g/cmake_targets/ran_build/build -name "nr-softmodem" -type f
echo "=== UE Executable ==="
find $TEST_DIR/openairinterface5g/build -name "nr-uesoftmodem" -type f
echo "=== FHI Transport Library ==="
find $TEST_DIR/openairinterface5g/build -name "liboai_transpro.so"
```

Expected locations:

- **O-RU**: `$TEST_DIR/openairinterface5g/build/nr-oru`  
- **gNB**: `$TEST_DIR/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem`  
- **UE**: `$TEST_DIR/openairinterface5g/build/nr-uesoftmodem`  
- **FHI Lib**: `$TEST_DIR/openairinterface5g/build/liboai_transpro.so`

---

## Step 7: Setup SR-IOV (Single Machine)

**CRITICAL:** Single-machine setup requires **5 VFs with VLANs** for VF-to-VF communication.

### Find Your Network Interfaces

```shell
for iface in $(ls /sys/class/net/ | grep -v lo); do if [ -e "/sys/class/net/$iface/device/sriov_totalvfs" ]; then pci=$(basename $(readlink /sys/class/net/$iface/device)); total_vfs=$(cat /sys/class/net/$iface/device/sriov_totalvfs); echo "Interface: $iface, PCI: $pci, Max VFs: $total_vfs"; fi; done
```

### Set Your PCI Address

```shell
export PCI_DEVICE="0000:05:00.0"  # Replace with YOUR PCI address
```

### Run SR-IOV Setup

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
sudo PCI_DEVICE=$PCI_DEVICE DPDK_INST=$DPDK_INST TEST_DIR=$TEST_DIR bash $TEST_DIR/setup_sriov_single_machine.sh
```

### Verify SR-IOV Setup

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
cat $TEST_DIR/sriov_single_machine.txt
$DPDK_INST/usertools/dpdk-devbind.py --status-dev net
```

Should show **5 VFs**:

```
VF Assignments:
  O-RU VF 0 (U-plane): 0000:c1:01.0 MAC=00:11:22:33:64:66 VLAN=3 (vfio-pci)
  O-RU VF 1 (C-plane): 0000:c1:01.1 MAC=00:11:22:33:64:67 VLAN=4 (vfio-pci)
  gNB  VF 2 (U-plane): 0000:c1:01.2 MAC=00:11:22:33:64:68 VLAN=3 (vfio-pci)
  gNB  VF 3 (C-plane): 0000:c1:01.3 MAC=00:11:22:33:64:69 VLAN=4 (vfio-pci)
  Capture VF 4:        0000:c1:01.4 MAC=00:11:22:33:64:70 VLAN=3 (iavf)
```

**Why 5 VFs with VLANs?**

- Separate VLANs (3 for U-plane, 4 for C-plane) enable VF-to-VF communication on same NIC  
- VF 4 with iavf driver allows packet capture for debugging

---

## Step 8: Configuration Files

O-RAN 7.2 fronthaul compression is configured through two main parameters:

- **compMeth**: Compression method/algorithm  
- **iqWidth**: IQ sample bit width

These must be configured identically in both O-DU and O-RU configuration files.

---

## Configuration File Locations

### O-DU Config (gNB)

In the `fhi_72` section:

```
fhi_72 = {
  dpdk_devices = ("0002:01:01.5", "0002:01:01.6");
  system_core  = 8;
  io_core      = 9;
  worker_cores = (15);
  ru_addr      = ("00:11:22:33:64:66", "00:11:22:33:64:67");
  mtu          = 9600;
  GPS_Alpha    = 0;
  GPS_Beta     = -9000;
  fh_config = ({
    T1a_cp_dl = (285, 470);
    T1a_cp_ul = (285, 429);
    T1a_up    = (300, 450);
    Ta3_up    = (200, 470);
    Ta4       = (400, 440);
    ru_config = {
      iq_width       = 16;        # ← DL/UL IQ width
      iq_width_prach = 16;        # ← PRACH IQ width
      comp_meth      = 0;         # ← DL/UL compression method (optional, defaults to 0)
      comp_meth_prach = 0;        # ← PRACH compression method (optional, defaults to 0)
    };
  });
};
```

### O-RU Config

In the `fhi_72` section:

```
fhi_72 = {
  dpdk_devices = ("0002:01:00.5", "0002:01:00.6");
  system_core  = 10;
  io_core      = 11;
  worker_cores = (12);
  du_addr      = ("00:11:22:33:54:00", "00:11:22:33:54:01");
  mtu          = 9600;
  file_prefix  = "ru";
  app_id       = "RU";
  fh_config = ({
    Ta3_up    = (200, 470);
    T1a_cp_dl = (285, 470);
    T1a_cp_ul = (285, 429);
    T1a_up    = (300, 450);
    Ta4       = (400, 440);
    T2a_up    = (350, 1200);
    ru_config = {
      iq_width       = 16;        # ← DL/UL IQ width (must match O-DU)
      iq_width_prach = 16;        # ← PRACH IQ width (must match O-DU)
      comp_meth      = 0;         # ← DL/UL compression method
      comp_meth_prach = 0;        # ← PRACH compression method
    };
  });
};
```

**IMPORTANT**: Both O-DU and O-RU configs must have identical values for these parameters.

---

## Parameter Values

### compMeth (Compression Method)

| Value | Name | Description | Status |
| :---- | :---- | :---- | :---- |
| **0** | NONE | No compression (uncompressed IQ samples) | ✅ Working |
| **1** | BLKFLOAT | Block Floating Point | ⚠️ PRACH only |
| **2** | BLKSCALE | Block Scaling | ⚠️ PRACH only |
| **3** | ULAW | μ-law compression | ⚠️ PRACH only |

**Note**: Methods 1-3 currently only work for PRACH. PUSCH compression is under investigation.

---

## Step 9: Run the Components

### Terminal 1 \- Start gNB

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
cd $TEST_DIR/openairinterface5g/cmake_targets/ran_build/build
sudo -E LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu/:.:$DPDK_INST/lib/x86_64-linux-gnu/" ASAN_OPTIONS=detect_odr_violation=0 taskset -c 5,6,7,8,9,15,21,22,23,24 ./nr-softmodem -O ../../../targets/PROJECTS/GENERIC-NR-5GC/CONF/gnb.sa.band77.106prb.fhi72.2x2-oairu.conf --gNBs.[0].min_rxtxtime 6 --thread-pool 21,22,23,24
```

**Wait for:** gNB to connect to O-RU and show **non-zero rx pps**:

```
[o-du 0][rx  12345 pps  12345 kbps  ...]
```

### Terminal 2 \- Start O-RU

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
cd $TEST_DIR/openairinterface5g/build
sudo -E LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu/:.:$DPDK_INST/lib/x86_64-linux-gnu/" ASAN_OPTIONS=detect_odr_violation=0 taskset -c 10,11,12,13,14,20 ./nr-oru -O ../targets/PROJECTS/GENERIC-NR-5GC/CONF/ru.band77.106prb.fhi72.2x2.conf --vrtsim.role server
```

**Wait for:** "waiting for connection..." message

### Terminal 3 \- Start UE

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
cd $TEST_DIR/openairinterface5g/build
sudo -E LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu/:.:$DPDK_INST/lib/x86_64-linux-gnu/" ASAN_OPTIONS=detect_odr_violation=0 taskset -c 16,17,18,19 chrt -f 50 ./nr-uesoftmodem -C 4049760000 -r 106 --numerology 1 --band 77 --ssb 516 --device.name vrtsim --vrtsim.role client --ue-nb-ant-tx 1 --ue-nb-ant-rx 1
```

---

### Single Machine Requirements

1. **5 VFs from one interface** (2 for O-RU, 2 for gNB, 1 for capture)  
2. **Separate VLANs** (U-plane on VLAN 3, C-plane on VLAN 4\) \- **CRITICAL for VF-to-VF communication**  
3. **VF MAC addresses** must match config file addresses (`00:11:22:33:64:66-70`)  
4. **`file_prefix = "ru"`** in O-RU config (prevents DPDK conflicts)  
5. **Non-overlapping CPU affinity** between O-RU, O-DU/gNB, and UE

---

## Troubleshooting

### Problem: "Library oai\_transpro couldn't be loaded"

**Solution:** You forgot to build `oran_fhlib_5g` target. Go back to Step 4 and run:

```shell
cd $TEST_DIR/openairinterface5g/build
PKG_CONFIG_PATH=$DPDK_INST/lib/x86_64-linux-gnu/pkgconfig/ cmake --build . --target oran_fhlib_5g
```

### Problem: O-RU and gNB show "rx 0 pps" (not receiving)

**Root cause:** VF-to-VF communication not working on same NIC.

**Solution:** You need **5 VFs with separate VLANs** (U-plane on VLAN 3, C-plane on VLAN 4):

```shell
export TEST_DIR=$HOME/oran_lab/oaicicd/test_dir
export PCI_DEVICE="0000:c1:00.0"
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
sudo PCI_DEVICE=$PCI_DEVICE DPDK_INST=$DPDK_INST TEST_DIR=$TEST_DIR bash $TEST_DIR/setup_sriov_single_machine.sh
```

Verify with:

```shell
cat $TEST_DIR/sriov_single_machine.txt
```

Must show 5 VFs with correct VLANs and MACs.  
---

## System Hardware

**CPU**: AMD Ryzen Threadripper PRO 7975WX (32-Core, 64-Thread)

- Architecture: x86\_64  
- Total CPUs: 64 (with SMT/HyperThreading)  
- Base/Boost: 419 MHz \- 5356 MHz  
- Single NUMA node (0-63)

**Network**:

- Fronthaul: High-speed network interface with MTU 9600  
- SR-IOV Virtual Functions for DPDK-based fronthaul

## Architecture Overview

This setup runs a **single-machine O-RAN 7.2 configuration**:

```
┌─────────────────────────────────────────────────────┐
│                Single Machine                        │
│                                                      │
│  ┌──────────┐    xRAN/DPDK    ┌──────────┐         │
│  │   O-DU   │ ◄────────────► │   O-RU   │         │
│  │  (gNB)   │   fronthaul     │          │         │
│  └──────────┘                 └──────────┘         │
│                                     │                │
│                                  vrtsim              │
│                                     │                │
│                                ┌────▼────┐          │
│                                │   UE    │          │
│                                └─────────┘          │
└─────────────────────────────────────────────────────┘
```

**Components**:

- **O-DU** (nr-softmodem): Distributed Unit \- handles L2/L3 processing  
- **O-RU** (nr-oru): Radio Unit \- handles L1 PHY processing  
- **UE** (nr-uesoftmodem): User Equipment (simulated)  
- **vrtsim**: Virtual radio simulator connecting O-RU and UE  
- **xRAN/DPDK**: High-performance fronthaul using O-RAN 7.2 interface

## CPU Core Assignment

Real-time processes require dedicated high-performance cores with CPU affinity:

### O-DU (gNB) \- 6 performance cores

```
Cores: 5, 6, 7, 8, 9, 15
├─ Core 5: L1 RX thread
├─ Core 6: L1 TX thread  
├─ Core 7: RU thread
├─ Core 8: FHI 7.2 system core
├─ Core 9: FHI 7.2 I/O core
└─ Core 15: FHI 7.2 worker core
```

Additional thread pool: Cores 21, 22, 23, 24 (for MAC/RLC/PDCP)

### O-RU \- 6 performance cores

```
Cores: 10, 11, 12, 13, 14, 20
├─ Core 10: FHI 7.2 system core
├─ Core 11: FHI 7.2 I/O core
├─ Core 12: FHI 7.2 worker core
├─ Core 13: RU thread
├─ Core 14: TP (transport processing) core
└─ Core 20: spare/helper O-RU process affinity
```

### UE \- 4 cores

```
Cores: 16, 17, 18, 19
└─ General PHY processing
```

**Note**: This map keeps O-DU, O-RU, and UE on non-overlapping logical CPUs. On this Ryzen 9 5950X, the O-DU thread pool uses SMT siblings of O-DU cores, but no separate process shares the same logical CPU.  

# O-RAN 7.2 Fronthaul Setup Tutorial

This tutorial describes how to set up an O-RAN 7.2 fronthaul on OAI infrastructure using two DGX Spark host machines. One host runs the O-RU and NR-UE, the other runs the O-DU. The two machines are connected directly via fiber for the fronthaul and synchronized over PTP.

---

## Step 1 -- Create Working Directory

Run on **both hosts**:

```bash
mkdir ~/ran_demo && cd ~/ran_demo
export TEST_DIR=$(pwd)
```

---

## Step 2 -- Install DPDK

Run on **both hosts**:

```bash
wget --no-verbose http://fast.dpdk.org/rel/dpdk-20.11.9.tar.xz -P $TEST_DIR
tar xvf $TEST_DIR/dpdk-20.11.9.tar.xz
cd $TEST_DIR/dpdk-stable-20.11.9
export DPDK_INST=$(pwd)
meson setup -Dmachine=default build
ninja -C build install
export C_INCLUDE_PATH="$DPDK_INST/include"
```

---

## Step 3 -- Install ARM RAL

Run on **both hosts**:

```bash
git clone https://git.gitlab.arm.com/networking/ral.git $TEST_DIR/ral
cd $TEST_DIR/ral
git checkout armral-25.01
mkdir build && cd build
cmake -GNinja -DBUILD_SHARED_LIBS=On -DCMAKE_INSTALL_PREFIX=$TEST_DIR/ral ../
ninja && ninja install
```

---

## Step 4 -- Create Environment File

Run on **both hosts**:

```bash
cat > $TEST_DIR/testenv << 'EOF'
#!/usr/bin/env bash
export TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export DPDK_INST=$TEST_DIR/dpdk-stable-20.11.9
export C_INCLUDE_PATH="$DPDK_INST/include"
EOF
```

Always source this before running any binary:

```bash
source $TEST_DIR/testenv
```

---

## Step 5 -- Clone OAI

Run on **both hosts**:

```bash
git clone https://gitlab.eurecom.fr/oai/openairinterface5g.git $TEST_DIR/openairinterface5g
cd $TEST_DIR/openairinterface5g
git checkout oru-rebase-1
```

---

## Step 6 -- Build xRAN PHY Library and Apply Patches

Run on **both hosts**:

```bash
git clone https://gerrit.o-ran-sc.org/r/o-du/phy.git $TEST_DIR/phy-f-1.0
cd $TEST_DIR/phy-f-1.0
git checkout oran_f_release_v1.0
git apply $TEST_DIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oru.patch
git apply $TEST_DIR/openairinterface5g/cmake_targets/tools/oran_fhi_integration_patches/F/oaioran_F.patch
cd $TEST_DIR/phy-f-1.0/fhi_lib/lib
TARGET=armv8 WIRELESS_SDK_TOOLCHAIN=gcc RTE_SDK=$DPDK_INST XRAN_DIR=$TEST_DIR/phy-f-1.0/fhi_lib make XRAN_LIB_SO=1
```

---

## Step 7 -- Build OAI

### O-RU host (also builds NR-UE):

```bash
cd $TEST_DIR/openairinterface5g
mkdir build && cd build
PKG_CONFIG_PATH=$DPDK_INST/lib/aarch64-linux-gnu/pkgconfig/ cmake ../ -GNinja -DOAI_FHI72=ON \
  -Dxran_LOCATION=$TEST_DIR/phy-f-1.0/fhi_lib/lib \
  -Darmral_LOCATION=$TEST_DIR/ral
PKG_CONFIG_PATH=$DPDK_INST/lib/aarch64-linux-gnu/ cmake --build . \
  --target vrtsim oairu oran_fhlib_5g nr-softmodem ldpc params_libconfig nr-uesoftmodem nr-oru
```

### O-DU host:

```bash
cd $TEST_DIR/openairinterface5g/cmake_targets
PKG_CONFIG_PATH=$DPDK_INST/lib/aarch64-linux-gnu/pkgconfig/ ./build_oai --gNB --ninja \
  -t oran_fhlib_5g \
  --cmake-opt -Dxran_LOCATION=$TEST_DIR/phy-f-1.0/fhi_lib/lib \
  --cmake-opt -Darmral_LOCATION=$TEST_DIR/ral
```

---

## Step 8 -- Configure SR-IOV Virtual Functions

Run after every reboot on each host:

```bash
bash $TEST_DIR/setup_sriov_ru.sh   # on O-RU host
bash $TEST_DIR/setup_sriov_du.sh   # on O-DU host
```

Verify the VF MACs are set correctly:

```bash
ip link show <fronthaul_interface> | grep -A2 "vf"
```

The fronthaul interface name can be found in `/etc/ptp4l.conf`.

---

## Step 9 -- Configuration Files

Two config files are needed: one for the DU (saved on the O-DU host) and one for the RU (saved on the O-RU host). The configs below are the ones used in this setup. Before using them, update the following fields to match your hardware:

- `dpdk_devices` -- PCI addresses of the VFs on each host
- `ru_addr` in the DU config -- VF MAC addresses of the O-RU host
- `du_addr` in the RU config -- VF MAC addresses of the O-DU host

### DU config -- save as `~/du_test.conf` on the O-DU host:

```
Active_gNBs = ( "gNB-OAI");
Asn1_verbosity = "none";

gNBs =
(
 {
    gNB_ID    =  0xe00;
    gNB_name  =  "gNB-OAI";
    tracking_area_code  =  1;
    plmn_list = ({ mcc = 208; mnc = 99; mnc_length = 2; snssaiList = ( { sst = 1; }); });
    nr_cellid = 1;

    pdsch_AntennaPorts_XP = 1;
    pusch_AntennaPorts    = 1;
    do_CSIRS              = 1;
    do_SRS                = 0;
    sib1_tda              = 15;

    servingCellConfigCommon = (
    {
      physCellId                                                    = 0;
      absoluteFrequencySSB                                          = 669984;
      dl_frequencyBand                                              = 77;
      dl_absoluteFrequencyPointA                                    = 668712;
      dl_offstToCarrier                                             = 0;
      dl_subcarrierSpacing                                          = 1;
      dl_carrierBandwidth                                           = 106;
      initialDLBWPlocationAndBandwidth                              = 28875;
      initialDLBWPsubcarrierSpacing                                 = 1;
      initialDLBWPcontrolResourceSetZero                            = 11;
      initialDLBWPsearchSpaceZero                                   = 0;
      ul_frequencyBand                                              = 77;
      ul_offstToCarrier                                             = 0;
      ul_subcarrierSpacing                                          = 1;
      ul_carrierBandwidth                                           = 106;
      pMax                                                          = 23;
      initialULBWPlocationAndBandwidth                              = 28875;
      initialULBWPsubcarrierSpacing                                 = 1;
      prach_ConfigurationIndex                                      = 159;
      prach_msg1_FDM                                                = 0;
      prach_msg1_FrequencyStart                                     = 0;
      zeroCorrelationZoneConfig                                     = 0;
      preambleReceivedTargetPower                                   = -100;
      preambleTransMax                                              = 7;
      powerRampingStep                                              = 2;
      ssb_perRACH_OccasionAndCB_PreamblesPerSSB_PR                  = 4;
      ssb_perRACH_OccasionAndCB_PreamblesPerSSB                     = 15;
      ra_ContentionResolutionTimer                                  = 7;
      rsrp_ThresholdSSB                                             = 19;
      prach_RootSequenceIndex_PR                                    = 2;
      prach_RootSequenceIndex                                       = 1;
      msg1_SubcarrierSpacing                                        = 1,
      restrictedSetConfig                                           = 0,
      msg3_DeltaPreamble                                            = 2;
      p0_NominalWithGrant                                           = -100;
      pucchGroupHopping                                             = 0;
      hoppingId                                                     = 0;
      p0_nominal                                                    = -96;
      ssb_PositionsInBurst_Bitmap                                   = 0x1;
      ssb_periodicityServingCell                                    = 2;
      dmrs_TypeA_Position                                           = 0;
      subcarrierSpacing                                             = 1;
      referenceSubcarrierSpacing                                    = 1;
      dl_UL_TransmissionPeriodicity                                 = 5;
      nrofDownlinkSlots                                             = 3;
      nrofDownlinkSymbols                                           = 6;
      nrofUplinkSlots                                               = 1;
      nrofUplinkSymbols                                             = 4;
      ssPBCH_BlockPower                                             = 0;
    }
    );

    SCTP :
    {
        SCTP_INSTREAMS  = 2;
        SCTP_OUTSTREAMS = 2;
    };

    amf_ip_address = ({ ipv4 = "172.21.6.5"; });

    NETWORK_INTERFACES :
    {
        GNB_IPV4_ADDRESS_FOR_NG_AMF  = "172.21.19.111";
        GNB_IPV4_ADDRESS_FOR_NGU     = "172.21.19.111";
        GNB_PORT_FOR_S1U             = 2152;
    };
  }
);

MACRLCs = (
{
  num_cc               = 1;
  tr_s_preference      = "local_L1";
  tr_n_preference      = "local_RRC";
  pusch_TargetSNRx10   = 200;
  pucch_TargetSNRx10   = 200;
  ul_bler_target_upper = .35;
  ul_bler_target_lower = .15;
  pusch_FailureThres   = 100;
}
);

L1s = (
{
  num_cc               = 1;
  tr_n_preference      = "local_mac";
  prach_dtx_threshold  = 110;
  pucch0_dtx_threshold = 80;
  pusch_dtx_threshold  = -100;
  tx_amp_backoff_dB    = 36;
  L1_rx_thread_core    = 5;
  L1_tx_thread_core    = 6;
  phase_compensation   = 0;
}
);

RUs = (
{
  local_rf       = "no";
  nb_tx          = 1;
  nb_rx          = 1;
  att_tx         = 0;
  att_rx         = 0;
  bands          = [77];
  max_pdschReferenceSignalPower = -27;
  max_rxgain     = 75;
  sf_extension   = 0;
  eNB_instances  = [0];
  ru_thread_core = 7;
  sl_ahead       = 10;
  tr_preference  = "raw_if4p5";
  do_precoding   = 0;
}
);

security = {
  ciphering_algorithms = ( "nea0" );
  integrity_algorithms = ( "nia2", "nia0" );
  drb_ciphering        = "yes";
  drb_integrity        = "no";
};

log_config :
{
  global_log_level = "info";
  hw_log_level     = "info";
  phy_log_level    = "info";
  mac_log_level    = "info";
  rlc_log_level    = "info";
  pdcp_log_level   = "info";
  rrc_log_level    = "info";
  ngap_log_level   = "info";
  f1ap_log_level   = "info";
};

fhi_72 = {
  dpdk_devices = ("0002:01:01.5", "0002:01:01.6");  # update to your VF PCI addresses
  system_core  = 8;
  io_core      = 9;
  worker_cores = (15);
  ru_addr      = ("00:11:22:33:64:66", "00:11:22:33:64:67");  # update to O-RU VF MACs
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
      iq_width       = 16;
      iq_width_prach = 16;
    };
  });
};
```

### RU config -- save as `~/ru_test.conf` on the O-RU host:

```
Asn1_verbosity = "none";
ORUs = (
{
  tx_bw              = [106];
  rx_bw              = [106];
  carrier_tx         = [4049760];
  carrier_rx         = [4049760];
  prach_config_index = 159;
  prach_msg1_start   = 0;
  tdd_period         = 5;
  num_dl_slots       = 3;
  num_dl_symbols     = 6;
  num_ul_slots       = 1;
  num_ul_symbols     = 4;
  numerology         = 1;
  tp_cores           = [14];
  num_tp_cores       = 1;
  ru_thread_core     = 13
});

RUs = (
{
  local_rf       = "no";
  nb_tx          = 1;
  nb_rx          = 1;
  att_tx         = 0;
  att_rx         = 0;
  bands          = [77];
  max_pdschReferenceSignalPower = -27;
  max_rxgain     = 75;
  sf_extension   = 0;
  eNB_instances  = [0];
  sl_ahead       = 10;
  tr_preference  = "raw_if4p5";
  do_precoding   = 0;
});

log_config :
{
  global_log_level = "info";
  hw_log_level     = "info";
  phy_log_level    = "info";
  mac_log_level    = "info";
  rlc_log_level    = "info";
  pdcp_log_level   = "info";
  rrc_log_level    = "info";
  ngap_log_level   = "info";
  f1ap_log_level   = "info";
};

fhi_72 = {
  dpdk_devices = ("0002:01:00.5", "0002:01:00.6");  # update to your VF PCI addresses
  system_core  = 10;
  io_core      = 11;
  worker_cores = (12);
  du_addr      = ("00:11:22:33:54:00", "00:11:22:33:54:01");  # update to O-DU VF MACs
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
      iq_width       = 16;
      iq_width_prach = 16;
    };
  });
};
```

---

## Step 10 -- CPU Core Assignment

Assign cores based on performance requirements. The RU and DU are real-time processes and need the most capable cores on the system. The UE needs fewer cores. A good rule of thumb based on testing:

- **RU**: ~6 performance cores
- **DU**: ~6 performance cores (same count as RU)
- **UE**: ~4 cores

To identify the higher-frequency cores on your system:

```bash
sudo cpupower -c 0-$(nproc --all) frequency-info | grep -E "CPU|current"
```

Assign non-overlapping logical CPUs to DU, RU, and UE. Put the most latency-sensitive DU and RU threads on the fastest physical cores where possible.

In the OAI infrastructure setup used for this tutorial, cores are divided as follows:

- DU: cores 5,6,7,8,9,15 with thread pool 21,22,23,24
- RU: cores 10,11,12,13,14,20
- UE: cores 16,17,18,19

Adjust these based on your system's available cores.

---

## Step 11 -- Run

Start in this exact order.

### O-DU host -- start DU first:

```bash
sudo pkill -9 nr-softmodem; sudo rm -rf /var/run/dpdk/wls_0/ /var/run/dpdk/rte/
cd $TEST_DIR/openairinterface5g/cmake_targets/ran_build/build
source $TEST_DIR/testenv
sudo taskset -c 5,6,7,8,9,15,21,22,23,24 env LD_LIBRARY_PATH=.:$DPDK_INST/lib/aarch64-linux-gnu/ LD_PRELOAD=$TEST_DIR/ral/build/libarmral.so ./nr-softmodem -O ~/du_test.conf --thread-pool 21,22,23,24
```

Wait until you see `tx pps 31872` in the DU output before proceeding.

### O-RU host -- start RU:

```bash
sudo kill -9 $(pgrep nr-oru) 2>/dev/null; sudo kill -9 $(pgrep nr-uesoftmodem) 2>/dev/null
sudo rm -rf /var/run/dpdk/ru/ /var/run/dpdk/rte/; sudo rm -f /dev/shm/vrtsim*
sleep 5
cd $TEST_DIR/openairinterface5g/build
source $TEST_DIR/testenv
sudo taskset -c 10,11,12,13,14,20 env LD_LIBRARY_PATH=.:$DPDK_INST/lib/aarch64-linux-gnu/ LD_PRELOAD=$TEST_DIR/ral/build/libarmral.so ./nr-oru -O ~/ru_test.conf --vrtsim.role server
```

Wait until the RU shows `packets received` increasing steadily.

### O-RU host -- start UE in a new terminal:

```bash
cd $TEST_DIR/openairinterface5g/build
source $TEST_DIR/testenv
sudo taskset -c 16,17,18,19 env LD_LIBRARY_PATH=.:$DPDK_INST/lib/aarch64-linux-gnu/ LD_PRELOAD=$TEST_DIR/ral/build/libarmral.so chrt -f 50 ./nr-uesoftmodem -C 4049760000 -r 106 --numerology 1 --band 77 --ssb 516 --device.name vrtsim --vrtsim.role client --ue-nb-ant-tx 1 --ue-nb-ant-rx 1
```

# O-RAN RU Test Bring-Up

This host already has the important X710 loopback pieces in place:

- PF `enp33s0f0np0` has `4` VFs enabled.
- VFs `0000:22:02.0` through `0000:22:02.3` are already bound to `vfio-pci`.
- VF MACs on `enp33s0f0np0` already match the expected RU/DU test values.

## Files

- `~/oran_lab/setup_oran_k.sh`: clone and build DPDK, XRAN, and OAI.
- `~/oran_lab/testenv`: generated environment file used by the run scripts.
- `~/oran_lab/patch_oru_configs.sh`: patch RU and DU config files with this machine's VF PCI IDs and MACs.
- `~/oran_lab/run_ru.sh`: launch the O-RU binary.
- `~/oran_lab/run_du.sh`: launch the DU/gNB binary.
- `~/oran_lab/run_ue.sh`: launch the UE binary.

## Bring-Up Order

1. Run `~/oran_lab/setup_oran_k.sh`
2. Run `~/oran_lab/patch_oru_configs.sh`
3. In separate terminals run:
   - `~/oran_lab/run_ru.sh`
   - `~/oran_lab/run_du.sh`
   - `~/oran_lab/run_ue.sh`

## Notes

- The launch scripts still use `sudo` because the DPDK-backed OAI binaries typically need elevated privileges.
- If `sudo` prompts for a password, that is expected on this host.
- If the build fails on missing packages, install the prerequisites from your notes with `sudo apt-get install ...` and rerun the setup script.

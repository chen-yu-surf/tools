# Region-aware RDT MBA scalability test

Scripts to exercise Intel **region-aware RDT** (MBA / MBM) on a kernel that
exposes per-memory-region MBA controls (`MB_REGION<n>_OPT/MIN/MAX` in
`/sys/fs/resctrl/schemata`). The main test sweeps the MBA throttle level for a
chosen memory region while Intel **MLC** saturates memory bandwidth, and records
both the achieved MLC bandwidth and the region's MBM byte counter at each level.

This repository contains **scripts only** — no binaries and no results. You must
supply the `mlc` binary yourself (see below); it is not redistributed here.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `mba_scalability_remote.sh` | test machine | Region-aware MBA throttle sweep + MBM capture (the core test) |
| `plot_mba_scalability.py`   | build/host   | Plots the sweep (PNG via matplotlib, else built-in SVG fallback) |

## What the sweep does

For throttle levels `1, 10, 20, ... , <hw-max>` the same value is written to
`MB_REGION<n>_OPT/MIN/MAX` of a dedicated resctrl group `region_mba_test`. The
running shell is placed in that group first, then MLC is launched from it (so
MLC inherits the throttle) to saturate memory bandwidth with 100% reads
(`mlc --loaded_latency -R -d0`). For every level it records:

* the MLC memory bandwidth (MB/sec), and
* the group's `mbm_region<n>_bytes` accumulated over a fixed window.

Results are written region-tagged so different regions do not overwrite each
other: `mba_scalability_region<n>.txt` (summary), plus
`mba_scalability_region<n>_mlc.txt` and `mba_scalability_region<n>_mbm.txt`.

## Portability

The test script is self-configuring so it can run on different platforms:

* **Auto-enables region-aware MBA** — if `MB_REGION<n>_*` is not present but the
  platform lists `native` as an available `MB/control_mode`, the script switches
  to it automatically. It fails with a clear message if the kernel/platform does
  not expose the requested region.
* **Auto-detects** the hardware maximum throttle value and the controlled
  cache/domain IDs from the live schemata.
* **NUMA binding** — `NUMA_NODE` (default: the region index) makes MLC allocate
  from that node via `numactl --membind=<node>`, so traffic actually targets the
  memory backing the region (e.g. region 0 → DRAM node 0, region 1 → a CXL
  node 1). Guards warn if `numactl` is missing or the node has no online memory.

## Running the sweep directly on the test machine

Copy the script and an `mlc` binary to the test machine, then:

```bash
# Region 0 (e.g. local DRAM / node 0)
sudo MLC_BIN=./mlc REGION=0 ./mba_scalability_remote.sh

# Region 1 (e.g. a CXL node); bind MLC memory to that node
sudo MLC_BIN=./mlc REGION=1 NUMA_NODE=1 ./mba_scalability_remote.sh
```

Tunable environment variables (all optional):

| Var | Default | Meaning |
|-----|---------|---------|
| `REGION`         | `0`           | Memory region index controlled/monitored |
| `NUMA_NODE`      | `${REGION}`   | NUMA node MLC allocates from (`-1`/empty to disable binding) |
| `MLC_BIN`        | `./mlc`       | Path to the Intel MLC binary |
| `THROTTLE_START` | `1`           | First throttle level |
| `THROTTLE_STEP`  | `10`          | Step between throttle levels |
| `MLC_RUNTIME`    | `25`          | Seconds MLC runs per level |
| `MBM_WARMUP`     | `5`           | Seconds to let MLC ramp before sampling |
| `MBM_WINDOW`     | `10`          | MBM sampling window (seconds) |
| `OUT_PREFIX`     | `mba_scalability_region${REGION}` | Output file prefix |

## Plotting

```bash
./plot_mba_scalability.py \
  --mlc mba_scalability_region0_mlc.txt \
  --mbm mba_scalability_region0_mbm.txt
```

Produces PNGs if `matplotlib` is installed, otherwise dependency-free SVGs.

## Requirements

* **Test machine:** region-aware RDT kernel booted; root / passwordless `sudo`;
  `msr` module (loaded automatically); `numactl` (for NUMA binding); an `mlc`
  binary matching the machine's ABI.
* **Plotting host:** `python3` (`matplotlib` optional; SVG fallback is built in).

## Note on the MLC binary

Intel® Memory Latency Checker (MLC) is proprietary and is **not** included in
this repository. Download it from Intel and place it next to the scripts (or
point `MLC_BIN` at it). Do not commit the `mlc` binary to a public repository.

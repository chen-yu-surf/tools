# pts (Phoronix Test Suite) Suite Reference

> Loaded when the result's `suite:` or test prefix is `pts` or `performance` with
> a phoronix-style stressor name (e.g. `graphics-magick`, `compress-7zip`, `blender`).

## Related subsystem files

- [../subsystems/mm.md](../subsystems/mm.md) — file-backed mmap, page cache, readahead
- [../subsystems/vfs.md](../subsystems/vfs.md) — file I/O, page cache (non-mmap suites)

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `graphics-magick Swirl` | File-backed mmap; per-iteration image open + mmap + pixel transform | `filemap_map_pages`, `do_fault_around`, `do_sync_mmap_readahead` | mm |
| `compress-7zip` | CPU-bound compression; user-space LZMA; minimal kernel involvement | (userspace dominated) | — |
| `blender` | CPU-bound rendering; user-space ray tracing | (userspace dominated) | — |

## Suite Characteristics

- **Phoronix Test Suite** wraps upstream benchmarks; results are reported as
  `pts.<benchmark>.<stressor>.<metric>` in LKP.
- `graphics-magick Swirl`: runs `gm convert -swirl` on a test image in a loop; reports
  `iterations_per_minute` (higher = better). Each iteration opens and mmaps the image file,
  reads pixel data, applies a swirl transform, and writes the result.
  - **Memory access pattern**: sequential file-backed mmap read — image data is accessed
    **exclusively via `mmap(2)`**, not `read(2)`. Strong spatial locality (entire image read
    once per iteration); fault-around window typically covers 16+ pages.
  - **Readahead sensitivity**: highly sensitive to `f_ra.mmap_miss` / `MMAP_LOTSAMISS` cliff
    (see mm.md *mmap readahead cliff* pattern). A 5895% increase in `major-faults` was
    confirmed on Granite Rapids 2S (lkp-gnr-2sp3) when readahead was disabled by commit
    `0b9c0aeba938`.
  - **Metric polarity**: `iterations_per_minute` — higher is better.
- pts suites are typically run via the `phoronix-test-suite` wrapper; result paths use the
  `performance-<stressor>-<benchmark>-<version>` pattern under `/result/pts/`.

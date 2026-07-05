# fio / iozone Suite Reference

> Loaded when the result's `suite:` or test prefix is `fio` or `iozone`.

## Related subsystem files

- [../subsystems/vfs.md](../subsystems/vfs.md) — page cache, block layer, ext4

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `fio` (buffered) | VFS page cache + block layer | `generic_file_read_iter`, `filemap_get_pages`, `submit_bio` | vfs |
| `fio` (direct I/O) | VFS + block layer | `blkdev_direct_IO`, `ext4_file_write_iter` | vfs |
| `iozone` | VFS page cache | `vfs_read`, `generic_file_write_iter` | vfs |

## Suite Characteristics

- fio reports throughput (KB/s or IOPS) and latency; check the metric name for polarity via
  [../metrics.md](../metrics.md).
- **Buffered I/O** hot path: `read()`/`write()` → `vfs_read`/`vfs_write` → page cache; regression
  typically in `filemap_get_pages`, `folio_add_lru`, or `__alloc_pages`.
- **Direct I/O** hot path: `pread()`/`pwrite()` → `blkdev_direct_IO` → block queue; regression
  typically in bio submission or block device driver path. FBC changes to `fs/block_dev.c` or
  `block/` are relevant here.
- ext4 (the default fio filesystem) has its own journal and extent paths; check `fs/ext4/` if the
  FBC touches ext4 internals.
- iozone covers sequential and random read/write; confirm from `job.yaml` which mode triggered
  the regression before narrowing to page-cache vs. block paths.

# vfs Subsystem Reference

> Loaded when the FBC diff touches `fs/`, `include/linux/fs*.h`, or `include/linux/dcache.h`.
>
> Block-layer and NVMe-specific mechanics (blk-mq tag exhaustion, NVMe SQ/CQ overhead, I/O
> scheduler dispatch, polling-mode contention) are covered in
> [storage.md](storage.md) — load that file instead when the diff touches `block/` or
> `drivers/nvme/`, or in addition to this file when it spans both `fs/` and `block/`.

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `lookup_fast` / `d_lookup` / `path_openat` | dcache contention or overhead | `[LOCK-CONTENTION]` if rseq/seqlock; `[MEMORY-BOUND]` if layout | `fs/namei.c`, `fs/dcache.c`; dentry hash or RCU walk changes |
| `vfs_read` / `generic_file_read_iter` / `filemap_get_pages` | Page cache overhead | (check perf-stat) | `mm/filemap.c`; new per-page accounting or locking added |
| `ext4_file_write_iter` / `ext4_file_read_iter` | ext4 overhead | — | `fs/ext4/`; journal or extent-map changes |
| `generic_file_write_iter` | Page cache write overhead | — | `mm/filemap.c`, `fs/`; dirty-page accounting |
| `anon_pipe_write` / `anon_pipe_read` | Pipe mutex contention | `[LOCK-CONTENTION]` | `fs/pipe.c`; both take `pipe->mutex` per read/write iteration |

## Regression Patterns Specific to vfs

**dcache RCU-walk regression**:
- FBC changed dentry fields or seqlock generation in the RCU-walk path, forcing fallback to ref-walk.
- Confirm: `lookup_fast` negative-delta (fewer fast lookups), `d_lookup` positive-delta.
- Fix: keep hot dentry fields in the first cacheline; avoid writes to seqlock-protected fields in
  the lookup fast path.

**Page cache overhead**:
- FBC added new per-folio/page work in `filemap_get_pages` or `__filemap_get_folio`
  (e.g. extra LRU operations, stat updates).
- Confirm: `[MEMORY-BOUND]` from `filemap_get_pages` / `folio_add_lru` positive delta.
- Fix: batch LRU updates; per-CPU pagevec instead of per-page atomic.

**Pipe mutex contention** (`[LOCK-CONTENTION]`) — confirmed by `212ed884a1ae` ("fs/pipe:
  pre-allocate pages outside pipe->mutex in anon_pipe_write", improvement, +25.86%
  `lmbench3.PIPE.bandwidth.MB/sec` on 2-socket SPR `lkp-spr-2sp4`):
- Both `anon_pipe_write()` and `anon_pipe_read()` serialize on the same per-pipe `pipe->mutex`
  every iteration, so any sleep-capable call inside the critical section (e.g.
  `alloc_page(GFP_HIGHUSER | __GFP_ACCOUNT)`, which can enter direct reclaim/memcg charging)
  directly gates the other side's progress.
- Confirmed via profile shift: `perf-profile.self.cycles-pp.mutex_spin_on_owner` 2.24% → 45.30%,
  `perf-profile.self.cycles-pp.__wake_up_common` 0.50% → 0.05% — moving the blocking allocation
  out from under the mutex converts sleep-driven serialization (waiter parks, needs explicit
  wakeup) into cheap optimistic spin-then-acquire.
- Fix pattern: **batching** — pre-allocate into a small stack array before `mutex_lock()`, only
  pop pre-allocated items while holding the lock, free any leftovers after `mutex_unlock()`.
  Same shape applies to any per-object-lock-guarding-a-blocking-allocation call site (see
  `net/ipv4/tcp.c` `tcp_sendmsg_locked()`/`tcp_stream_alloc_skb()` in [net.md](net.md) for an
  unvalidated generalization candidate).

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `fs/namei.c` | Pathname resolution (`path_openat`, `lookup_fast`, `link_path_walk`) |
| `fs/dcache.c` | Dentry cache (`d_lookup`, `dentry_cmp`, `__d_lookup_rcu`) |
| `mm/filemap.c` | Page cache read/write (`filemap_get_pages`, `__filemap_get_folio`) |
| `fs/ext4/` | ext4 filesystem internals |
| `include/linux/dcache.h` | `dentry` struct layout — changes cause cacheline spill in lookup hot path |

See [storage.md](storage.md) for `block/blk-mq.c` and NVMe-specific key files.

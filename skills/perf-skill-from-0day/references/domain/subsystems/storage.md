# storage (block / NVMe) Subsystem Reference

> Loaded when the FBC diff touches `block/`, `include/linux/blk*.h`, `drivers/nvme/`,
> `include/linux/nvme*.h`, or `io_uring/` I/O-path files when the workload is
> storage-bound (check suite: `fio`, `iozone` — see [domain/suites/fio.md](../suites/fio.md)
> for suite-level symptom vocabulary first).
>
> This file covers the block-layer / NVMe queue mechanics distinct from filesystem/page-cache
> behaviour, which is covered in [vfs.md](vfs.md). Load both when the diff spans `fs/` and
> `block/`.

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `blk_mq_submit_bio` / `blk_mq_get_tag` | blk-mq submission overhead | `[LOCK-CONTENTION]` if tag-exhaustion wait; `[MEMORY-BOUND]` if new per-bio allocation | `block/blk-mq.c`; new per-bio work or reduced tag depth |
| `blk_mq_sched_dispatch_requests` / `dd_dispatch_request` (mq-deadline) / `kyber_dispatch_request` | I/O scheduler dispatch overhead | — | `block/mq-deadline.c`, `block/kyber-iosched.c`; new per-request accounting |
| `nvme_queue_rq` / `nvme_submit_cmd` | NVMe submission-queue overhead | `[LOCK-CONTENTION]` if SQ lock contended | `drivers/nvme/host/pci.c`; per-command setup work added |
| `nvme_irq` / `nvme_handle_cqe` | NVMe completion-queue overhead | — | Completion-path accounting or new per-CQE work |
| `blk_mq_poll` / `nvme_poll` | Polling-mode (iopoll) overhead | `[LOCK-CONTENTION]` if polling loop contends with IRQ completion | `block/blk-mq.c`, `drivers/nvme/host/pci.c`; `io_uring` `IORING_SETUP_IOPOLL` paths |
| `blkg_rwstat_add` / `blkcg_*` | Block cgroup accounting overhead | — | `block/blk-cgroup.c`; see also [cgroup.md](cgroup.md) |

---

## Regression Patterns Specific to storage

### blk-mq Tag Exhaustion (`[LOCK-CONTENTION]`)

- FBC reduces the effective tag depth (e.g. reserves more tags for a new purpose, or adds a new
  wait point before tag allocation), or increases per-request hold time so tags are held longer,
  causing threads to block in `blk_mq_get_tag()` waiting for a free tag.
- Confirm: `blk_mq_get_tag` / `__sbitmap_queue_get` hot in positive-delta stacks; regression scales
  with queue depth pressure (worse at high `iodepth` in fio, absent at `iodepth=1`) — this
  depth-dependence is the signature that separates tag exhaustion from a flat per-request cost.
- Fix: avoid reserving tags for infrequently-used purposes from the shared pool; shorten
  per-request hold time; check whether the new work can happen after tag release instead of before.

### NVMe Submission/Completion Queue Overhead

- FBC adds new per-command setup work in `nvme_queue_rq()` (e.g. new metadata, new PRP/SGL
  construction step) or new per-completion work in the CQE handler, adding fixed overhead to every
  I/O regardless of size — visible as a bigger regression on small-block-size fio runs (4K) than
  large-block-size runs (1M), since fixed per-command overhead is amortized over more data at
  larger block sizes.
- Confirm: `nvme_queue_rq` or `nvme_handle_cqe` positive delta; regression inversely proportional
  to block size in the fio results — check this before concluding it's a bandwidth-bound issue.
- Fix: move new accounting/setup work out of the per-command fast path where possible; batch
  metadata operations if the field doesn't need to be per-command.

### Polling-Mode (iopoll) Contention

- FBC changes polling-loop behaviour in `blk_mq_poll()`/`nvme_poll()`, or interacts with IRQ-driven
  completion in a way that now causes the poller and the IRQ handler to contend for the same
  completion queue.
- Confirm: only reproduces on jobs using `IORING_SETUP_IOPOLL` or a poll-mode block driver
  parameter; regression absent when the same FBC is tested with interrupt-driven completion —
  this poll-vs-interrupt-mode-dependence is the key discriminator.
- Fix: ensure new completion-path work is safe under concurrent polling; avoid introducing a lock
  between the poll loop and IRQ completion handler that didn't previously exist.

### I/O Scheduler Dispatch Overhead

- FBC adds new per-request accounting inside the active I/O scheduler's dispatch function
  (mq-deadline, kyber, bfq, or `none`). Overhead is scheduler-specific — a regression present with
  `mq-deadline` but absent with `none` isolates the scheduler's dispatch logic as the mechanism
  rather than the block layer generally.
- Confirm: check the job's `scheduler=` parameter (or `/sys/block/<dev>/queue/scheduler`) before
  concluding block-layer-wide overhead; re-run comparison against `none` scheduler if available to
  isolate scheduler-specific vs. blk-mq-generic cost.
- Fix: same techniques as blk-mq tag exhaustion — narrow the new per-request work, move it off the
  dispatch fast path.

---

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `block/blk-mq.c` | Core blk-mq submission/dispatch (`blk_mq_submit_bio`, `blk_mq_get_tag`, `blk_mq_poll`) |
| `block/blk-mq-sched.c` | Scheduler dispatch glue (`blk_mq_sched_dispatch_requests`) |
| `block/mq-deadline.c`, `block/kyber-iosched.c`, `block/bfq-iosched.c` | Per-scheduler dispatch logic |
| `drivers/nvme/host/pci.c` | NVMe PCIe submission/completion (`nvme_queue_rq`, `nvme_handle_cqe`) |
| `drivers/nvme/host/core.c` | NVMe core command construction |
| `block/blk-cgroup.c` | Block I/O cgroup accounting — see [cgroup.md](cgroup.md) |
| `include/linux/blk-mq.h` | `request`/`blk_mq_tags` struct layout |

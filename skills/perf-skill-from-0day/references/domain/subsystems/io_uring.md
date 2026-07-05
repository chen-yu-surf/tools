# io_uring Subsystem Reference

> Loaded when the FBC diff touches `io_uring/`, `include/linux/io_uring*.h`,
> `include/uapi/linux/io_uring.h`, or `include/linux/io_uring_types.h`.

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `io_submit_sqes` / `io_queue_sqe` | SQ submission overhead | (check perf-stat) | `io_uring/io_uring.c`; new per-sqe validation or prep work |
| `io_issue_sqe` | Per-operation dispatch overhead | (check perf-stat) | `io_uring/io_uring.c`; new flags or per-op checks added |
| `io_req_complete_post` / `io_fill_cqe_req` | CQ completion overhead | `[LOCK-CONTENTION]` if ring lock | `io_uring/io_uring.c`; new per-completion work or ring lock hold |
| `io_cqring_fill_event` | CQ ring fill overhead | — | Ring buffer contention; new wait queue wake |
| `io_run_task_work` / `io_req_task_work_add` | Task-work overhead | — | FBC adds new task-work item on the completion path |
| `io_uring_enter` | System call overhead | — | `io_uring/io_uring.c`; new per-enter validation or locking |
| `io_poll_add` / `io_poll_check_events` | Poll-mode overhead | — | `io_uring/poll.c`; poll event loop changes |

## Regression Patterns Specific to io_uring

**SQ submission overhead**:
- FBC added new per-sqe validation, linked-request overhead, or a new prep callback in
  the submission hot path (`io_queue_sqe` → `io_issue_sqe`).
- Confirm: `io_submit_sqes` / `io_issue_sqe` in positive-delta stacks.
- Fix: move non-critical validation to the prep phase (called once at ring setup); avoid
  per-sqe memory allocation; lazy-init optional features.

**CQ ring lock contention** (`[LOCK-CONTENTION]`):
- FBC extended the critical section held under `ctx->uring_lock` (a mutex) during completion
  posting, or added new paths that always grab the lock even for inline-complete operations.
- Confirm: `mutex_lock` / `io_cqring_fill_event` dominant in positive-delta stacks;
  hardware counters flat (spinners burn cycles while holding `uring_lock`).
- Fix: use the inline-complete path (`req->flags |= REQ_F_CQE_SKIP` for no-op completions);
  batch CQ updates; use `io_commit_cqring_flush` outside the hot path.

**Task-work overhead**:
- FBC moved completions off the inline path onto `task_work`, adding scheduling overhead for
  each completion (an IPI is sent to the submitting task's CPU).
- Confirm: `io_run_task_work` / `task_work_run` positive-delta; `try_to_wake_up` present.
- Fix: prefer inline completion (`io_req_complete_post` with `REQ_F_FORCE_ASYNC` avoided)
  for operations that can complete synchronously.

**Per-request memory allocation overhead** (`[MEMORY-BOUND]`):
- FBC added new per-`io_kiocb` fields that require allocation or initialisation on every
  request, increasing slab pressure.
- Confirm: `kmem_cache_alloc` / `io_alloc_req` positive delta.
- Fix: embed data in the existing `io_kiocb` fixed-size slab object; use existing padding
  fields; batch slab allocations via the request cache.

**Poll-mode regression**:
- FBC changed the poll event-loop retry logic, causing additional `poll()` system calls or
  wakeups per completion.
- Confirm: `io_poll_check_events` / `vfs_poll` positive-delta; `io_uring_enter` call count
  increased.
- Fix: ensure `IORING_SETUP_SQPOLL` and inline poll paths remain the preferred completion
  path; avoid unnecessary IPI-driven wakeups in the poll loop.

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `io_uring/io_uring.c` | Core: `io_uring_enter`, `io_submit_sqes`, `io_issue_sqe`, `io_req_complete_post` |
| `io_uring/io_uring.h` | `io_kiocb` struct definition — layout changes hit every request path |
| `io_uring/poll.c` | Poll-mode: `io_poll_add`, `io_poll_check_events` |
| `io_uring/rw.c` | Read/write ops: `io_read`, `io_write` (most-used op types) |
| `io_uring/net.c` | Network ops: `io_sendmsg`, `io_recvmsg` |
| `include/linux/io_uring_types.h` | `io_ring_ctx`, `io_kiocb` types |

## Notes

- io_uring regressions are often workload-specific: SQPOLL mode, fixed-file mode, and
  linked-request mode each take different code paths. Check `job.yaml` for `IORING_SETUP_*`
  flags used by the benchmark.
- The `io_kiocb` struct is 192 bytes (as of kernel 6.x); any FBC that adds a field risks
  pushing it to the next cacheline — confirm with `pahole -C io_kiocb vmlinux`.
- io_uring operations that complete synchronously (e.g. cached reads) use the inline-complete
  path and are more sensitive to per-completion overhead than async operations.

# fork Subsystem Reference

> Loaded when the FBC diff touches `kernel/fork.c`, `kernel/exec.c`, `fs/exec.c`,
> `include/linux/sched/task.h`, or `include/linux/mm_types.h` (task/mm init paths).

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `copy_process` / `dup_mm` | Fork / clone overhead | (check perf-stat) | `kernel/fork.c`; new per-task or per-mm initialisation |
| `do_fork` / `kernel_clone` | Fork system call overhead | — | `kernel/fork.c`; new pre/post-fork work |
| `dup_mmap` / `copy_page_range` | Memory map duplication overhead | `[MEMORY-BOUND]` | `mm/memory.c`; new per-VMA or per-page copy overhead |
| `do_execveat_common` / `load_elf_binary` | Exec overhead | — | `fs/exec.c`, `fs/binfmt_elf.c`; new per-exec setup |
| `mm_alloc` / `mm_init` | mm_struct initialisation overhead | (check perf-stat) | New fields in `mm_struct` that need zeroing or atomic init |

## Regression Patterns Specific to fork

**Per-task initialisation overhead**:
- FBC added new fields to `task_struct` or `mm_struct` requiring zeroing or atomic initialisation
  on every `fork()`.
- Confirm: `copy_process` cycles up; `kmem_cache_alloc` (for task_struct slab) positive delta.
- Fix: lazy init (defer until first use); add fields to existing padding; avoid per-fork atomics.

**Memory map duplication overhead** (`[MEMORY-BOUND]`):
- FBC added new per-VMA metadata or changed `copy_page_range` to touch more pages on COW setup.
- Confirm: `dup_mmap` / `copy_page_range` in positive-delta stacks; `[MEMORY-BOUND]` from new
  struct touches.
- Fix: copy only on first access (lazy); batch; reduce per-VMA allocation overhead.

**mm_struct layout change** (`[MEMORY-BOUND]`):
- FBC added a field to `mm_struct`, pushing a hot field to a new cacheline.
- Confirm with `pahole -C mm_struct vmlinux`.
- Fix: reorder fields; `____cacheline_aligned_in_smp` for independently-written field groups.

**exec overhead**:
- FBC added new security or audit hooks in `do_execveat_common`.
- Confirm: `do_execveat_common` / `security_bprm_check` in positive-delta stacks.
- Fix: move non-critical audit work outside the exec hot path; avoid per-exec memory allocation.

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `kernel/fork.c` | `kernel_clone`, `copy_process`, `dup_mm`, `dup_mmap` |
| `fs/exec.c` | `do_execveat_common`, `exec_binprm` |
| `fs/binfmt_elf.c` | `load_elf_binary` |
| `mm/memory.c` | `copy_page_range` (COW page table duplication) |
| `include/linux/sched.h` | `task_struct` definition — layout changes affect every fork |
| `include/linux/mm_types.h` | `mm_struct` definition |

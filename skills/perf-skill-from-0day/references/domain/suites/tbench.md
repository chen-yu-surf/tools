# tbench Suite Reference

> Loaded when the result's `suite:` or test prefix is `tbench`.

## Related subsystem files

- [../subsystems/sched.md](../subsystems/sched.md) — wakeup latency, CFS/EEVDF
- [../subsystems/net.md](../subsystems/net.md) — socket send/recv path
- [../subsystems/locking.md](../subsystems/locking.md) — socket lock, pipe write

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `tbench` (loopback) | `kernel/sched/` + `net/` (loopback sockets) | `try_to_wake_up`, `tcp_sendmsg`, `tcp_recvmsg` | sched + net |
| `tbench` (network) | `net/ipv4/tcp.c` + NIC driver | `tcp_sendmsg`, `net_rx_action`, `napi_poll` | net |

## Suite Characteristics

- Simulates Samba SMBtorture request-reply workload; reports throughput in MB/s (higher = better).
  Regression = negative `perf_change`.
- Primary bottleneck is the **wakeup path** (`try_to_wake_up` + `select_task_rq_fair`) for
  loopback mode, and the **TCP send/receive** path for network mode.
- tbench is a **dual-subsystem** benchmark: scheduler overhead and TCP overhead both affect
  throughput equally. When analyzing a regression:
  - If FBC touches `kernel/sched/`: look for `try_to_wake_up` in positive-delta stacks.
  - If FBC touches `net/` or socket: look for `tcp_sendmsg` / `sock_recvmsg` overhead.
  - If FBC touches `kernel/locking/`: check `lock_sock_nested` / `release_sock` overhead.
- tbench uses loopback by default in LKP; network-mode regressions are less common but possible
  when `job.yaml` specifies an explicit server address.
- tbench is particularly sensitive to scheduler group and domain topology changes that affect
  wakeup target CPU selection on NUMA machines.
- The result metric is `tbench.throughput`; check polarity via [../metrics.md](../metrics.md).

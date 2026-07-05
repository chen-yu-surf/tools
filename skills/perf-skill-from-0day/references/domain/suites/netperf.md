# netperf / iperf3 Suite Reference

> Loaded when the result's `suite:` or test prefix is `netperf` or `iperf3`.

## Related subsystem files

- [../subsystems/net.md](../subsystems/net.md) — TCP send/recv, socket buffers, net RX path

---

## Stressor → Kernel Path

| Stressor | Primary kernel path | Expected hot functions | Subsystem file |
|---|---|---|---|
| `netperf TCP_STREAM` | `net/ipv4/tcp.c` | `tcp_sendmsg`, `tcp_recvmsg`, `net_rx_action` | net |
| `netperf TCP_RR` | `net/ipv4/tcp.c` + `kernel/sched/` | `tcp_sendmsg`, `try_to_wake_up`, `net_rx_action` | net + sched |
| `netperf UDP_STREAM` | `net/ipv4/udp.c` | `udp_sendmsg`, `__udp4_lib_rcv` | net |
| `iperf3` | `net/ipv4/tcp.c` | `tcp_sendmsg`, `tcp_recvmsg`, `sock_recvmsg` | net |

## Suite Characteristics

- netperf reports throughput (Mbps or tps) and latency; check metric name polarity via
  [../metrics.md](../metrics.md).
- `TCP_STREAM`: single-flow bulk throughput; bottleneck is usually `tcp_sendmsg` → `skb` copy path
  or RX softirq (`net_rx_action`). Check socket buffer sizing changes in FBC.
- `TCP_RR`: round-trip request-reply; sensitive to wakeup latency and TCP ACK path. Scheduler
  changes that increase `try_to_wake_up` cost show up here.
- Loopback vs. real NIC matters: loopback bypasses the driver, so NIC driver changes in the FBC
  won't regress loopback netperf. Check `job.yaml` for `server:` / `client:` addresses.
- `net_rx_action` is the NAPI softirq; if it appears in positive-delta stacks, look for changes in
  `net/core/dev.c` or GRO path. Confirm with `[LOCK-CONTENTION]` on RX socket lock.

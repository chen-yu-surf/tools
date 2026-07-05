# net Subsystem Reference

> Loaded when the FBC diff touches `net/`, `include/net/`, `include/linux/net*.h`,
> `include/linux/tcp.h`, `include/linux/udp.h`, or `drivers/net/`.

---

## Hot-Path Functions → Regression Type

| Function (or prefix) | Regression type | Tag | Where to look in the diff |
|---|---|---|---|
| `tcp_sendmsg` / `tcp_write_xmit` | TCP send-path overhead | (check perf-stat) | `net/ipv4/tcp.c`; new per-skb work or socket lock contention |
| `tcp_recvmsg` / `skb_copy_datagram_iter` | TCP recv-path overhead | — | `net/ipv4/tcp.c`; new per-skb copy overhead |
| `net_rx_action` / `napi_poll` | NAPI RX softirq overhead | — | `net/core/dev.c`; GRO or batch-size changes |
| `sock_recvmsg` / `inet_recvmsg` | Socket receive overhead | `[LOCK-CONTENTION]` if socket lock | `net/socket.c`; new socket-level locking or per-recv accounting |
| `__udp4_lib_rcv` | UDP receive overhead | — | `net/ipv4/udp.c`; hash lookup or socket search changes |
| `ip_output` / `ip_finish_output` | IP output overhead | — | `net/ipv4/ip_output.c`; new per-packet processing |

## Regression Patterns Specific to net

**TCP send-path overhead**:
- FBC added new per-skb work inside `tcp_write_xmit` (e.g. new field initialisation, extra
  checksum, new CC hook).
- Confirm: `tcp_sendmsg` / `tcp_write_xmit` dominant in positive-delta stacks.
- Fix: move non-critical work off the send fast path; batch per-connection accounting.

**Socket lock contention** (`[LOCK-CONTENTION]`):
- FBC widened the region held under `sock_lock_t` or added new `lock_sock()` calls.
- Confirm: `lock_sock_nested` or `release_sock` in positive-delta stacks.
- Fix: narrow lock hold time; per-CPU batching; lockless read paths where safe.

**NAPI / GRO overhead**:
- FBC changed GRO coalescing logic or reduced NAPI batch size, increasing softirq frequency.
- Confirm: `net_rx_action` cycles up; `napi_poll` call count increased.
- Fix: restore or increase `napi->weight`; avoid per-packet memory allocation in GRO hot path.

**UDP hash table overhead**:
- FBC changed the UDP socket hash table size or lookup algorithm.
- Confirm: `__udp4_lib_lookup` in positive-delta stacks.
- Fix: check hash distribution; avoid rehash under load.

**TCP receive-admission double-counting** (confirmed via `026dfef287c0` analysis, 2026-07):
- `tcp_can_ingest()` in `net/ipv4/tcp_input.c`, called from `tcp_try_rmem_schedule()` /
  `tcp_prune_queue()` inside `tcp_data_queue()`'s per-segment receive path, previously compared
  `sk_rmem_alloc + skb->len <= sk->sk_rcvbuf` — double-counting the arriving skb's size on top of
  already-queued memory (which already reflects prior skbs' truesize). On bursty RPC-sized
  (20-80KB) loopback flows with `rcvbuf` near the 128KB default, this spuriously rejected
  legitimate segments, forcing `tcp_prune_queue()`'s reclaim path and occasionally a real drop
  (`NET_INC_STATS` `RCVPRUNED`/`TcpExtTCPRcvQDrop`) that costs the sender a full retransmit.
  `026dfef287c0` fixed this by comparing `rmem` alone; confirmed via bisect on
  `stress-ng.sigurg.ops_per_sec` (+7% Sapphire Rapids 2S, +52% Sierra Forest 2S) with
  `[MULTI-METRIC CONFIRMED]` (instructions/context-switches down alongside ops/sec up).
- **Confirm**: same additive `<already-queued> + <incoming size> > <limit>` shape also found (not
  yet benchmarked) at `net/netlink/af_netlink.c:netlink_attachskb()` (`rmem + skb->truesize >
  sk_rcvbuf` gating sender wait) and `net/sched/sch_dualpi2.c:dualpi2_enqueue()`
  (`memory_used + skb->truesize > memory_limit`) — candidates for the same fix pattern.
- **Fix**: compare already-queued usage alone against the limit; do not add the incoming
  object's size unless the limit is deliberately reserving headroom for it.

## Known Optimization Candidates (unvalidated)

**`tcp_sendmsg_locked()` / `tcp_stream_alloc_skb()`** — flagged by the `212ed884a1ae` analysis
(fs/pipe batching-outside-lock pattern) as a generalization candidate, not yet benchmarked:
`tcp_sendmsg()` holds `sk_lock` (via `lock_sock()`) for the whole send loop while
`tcp_stream_alloc_skb()` calls a `GFP_KERNEL`-class `alloc_skb_fclone()` (can sleep/reclaim) on
 every iteration — same per-object-lock-across-blocking-allocation shape as `anon_pipe_write()`
before its fix. Proposed (unvalidated) fix: pre-allocate a reserve skb via `alloc_skb_fclone()`
before `lock_sock()`, consume it from the `new_segment:` path inside the lock, free any unused
reserve after `release_sock()`. `tcp_stream_alloc_skb()` is `EXPORT_SYMBOL_GPL` and used by
`tcp_bpf`, `tls` (`net/tls/tls_main.c`), `espintcp` (`net/xfrm/espintcp.c`), and `siw`
(`drivers/infiniband/sw/siw/siw_qp_tx.c`) — any signature change must keep those callers
behavior-neutral (e.g. pass `NULL` for a new parameter). `unix_stream_sendmsg()` and
`netlink_sendmsg()` were checked and excluded — their allocations happen before any socket lock.

## Key Files and Entry Points

| File | Purpose |
|---|---|
| `net/ipv4/tcp.c` | TCP send/recv (`tcp_sendmsg`, `tcp_recvmsg`, `tcp_write_xmit`) |
| `net/core/dev.c` | NAPI RX path (`net_rx_action`, `napi_poll`) |
| `net/ipv4/udp.c` | UDP receive (`__udp4_lib_rcv`, `__udp4_lib_lookup`) |
| `net/socket.c` | Socket layer (`sock_recvmsg`, `sock_sendmsg`) |
| `include/net/sock.h` | `sock` struct — layout changes affect every socket path |

# IPK Project 2 — Reliable File Transfer over UDP (ipk-rdt)

**Author:** Samuel Chovan (xchovas00)  
**Language:** C (C11)  
**Protocol:** Custom RDT protocol over UDP, Go-Back-N ARQ

---

## Table of Contents

1. [Overview](#overview)
2. [Build & Usage](#build--usage)
3. [Protocol Design](#protocol-design)
4. [Session Lifecycle](#session-lifecycle)
5. [UML Diagrams](#uml-diagrams)
6. [Algorithm Choice — Go-Back-N](#algorithm-choice--go-back-n)
7. [Implementation Details](#implementation-details)
8. [Testing](#testing)
9. [Known Limitations](#known-limitations)
10. [Use of AI Tools](#use-of-ai-tools)
11. [Bibliography](#bibliography)

---

## Overview

`ipk-rdt` is a command-line tool that reliably transfers a single continuous byte stream from a client to a server over UDP. Since UDP itself provides no delivery guarantees, the application implements its own reliable transport protocol on top of it, inspired by TCP's principles but simplified for unidirectional transfer.

The implementation handles:
- Packet loss, duplication, and reordering
- Corrupted or truncated packets (checksum verification)
- Session establishment and teardown
- Both IPv4 and IPv6
- Input from file or stdin, output to file or stdout

---

## Build & Usage

### Prerequisites

- GCC with C11 support
- GNU Make
- Linux (tested on Ubuntu 22.04 and NixOS with the `dev-envs#c` flake)

### Build

```bash
make
```

This produces the `ipk-rdt` executable in the repository root. To remove it:

```bash
make clean
```

### Server mode

```bash
./ipk-rdt -s -p PORT [-a ADDRESS] [-o OUTPUT] [-w TIMEOUT]
```

### Client mode

```bash
./ipk-rdt -c -a HOST -p PORT [-i INPUT] [-w TIMEOUT]
```

### Options

| Option | Description |
|---|---|
| `-s` | Run as server (receiver) |
| `-c` | Run as client (sender) |
| `-p PORT` | UDP port number (1–65535) |
| `-a ADDRESS` | Server: local bind address (optional, default all interfaces). Client: destination host (IPv4/IPv6/hostname) |
| `-i INPUT` | Input file to send. Omit or use `-` for stdin |
| `-o OUTPUT` | Output file to write. Omit or use `-` for stdout |
| `-w TIMEOUT` | Timeout in whole seconds (default: 1). Controls session establishment, data transfer, and teardown |
| `-h`, `--help` | Print usage to stdout and exit with code 0 |

### Examples

```bash
# File to file — IPv4
./ipk-rdt -s -p 9000 -o received.bin -w 5
./ipk-rdt -c -a 127.0.0.1 -p 9000 -i sample.bin -w 5

# stdin to stdout
./ipk-rdt -s -p 9000
printf 'Hello IPK\n' | ./ipk-rdt -c -a 127.0.0.1 -p 9000

# File to file — IPv6
./ipk-rdt -s -p 9000 -o out.bin -w 5
./ipk-rdt -c -a ::1 -p 9000 -i input.bin -w 5

# stdin to file
./ipk-rdt -s -p 9000 -o output.data -w 5
cat input.data | ./ipk-rdt -c -a localhost -p 9000 -w 5
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Transfer completed successfully |
| `1` | Transfer failed (handshake timeout, I/O error, invalid arguments) |

---

## Protocol Design

### Packet Header Format

Every protocol data unit (PDU) begins with a fixed-size header followed by an optional payload. All multi-byte fields are in **network byte order** (big-endian).

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        connection_id                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          seq_num                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            ack                                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          checksum                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           data_len            |    flags      |   (padding)   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    payload (0–1180 bytes)                     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| Field | Size | Description |
|---|---|---|
| `connection_id` | 4 B | Random session identifier, distinguishes transfers on the same port |
| `seq_num` | 4 B | Sequence number of this data segment |
| `ack` | 4 B | Cumulative acknowledgement number |
| `checksum` | 4 B | Internet checksum over entire PDU (header + payload) |
| `data_len` | 2 B | Length of payload in bytes (0 for control packets) |
| `flags` | 1 B | Bitmask: `SYN=0x01`, `ACK=0x02`, `FIN=0x04`, `DATA=0x08` |
| `payload` | 0–1180 B | Application data |

The maximum PDU size is `sizeof(header) + 1180 = 1200 bytes`, staying within the UDP payload limit and avoiding IP fragmentation on both IPv4 and IPv6 networks.

### Checksum

The checksum is a standard Internet checksum (one's complement sum of 16-bit words) computed over the entire PDU with the checksum field zeroed. Any PDU with an invalid checksum is silently discarded.

### Flags

| Flag | Value | Meaning |
|---|---|---|
| `SYN` | `0x01` | Session initiation request |
| `ACK` | `0x02` | Acknowledgement |
| `FIN` | `0x04` | Session termination request |
| `DATA` | `0x08` | Data segment |

---

## Session Lifecycle

### Establishment (2-way handshake)

```
Client                              Server
  |                                   |
  |-------- SYN (conn_id) ---------->|
  |                                   | (records conn_id, sets expected_seq=0)
  |<------- SYN|ACK (conn_id) --------|
  |                                   |
  |======== DATA transfer ===========|
```

1. Client generates a random `connection_id` and sends `SYN`.
2. Server responds with `SYN|ACK` carrying the same `connection_id`.
3. Client begins data transfer immediately upon receiving `SYN|ACK`.

The handshake uses a 200ms `SO_RCVTIMEO` retransmit interval. If no `SYN|ACK` arrives within `cfg->timeout` seconds, the client exits with code 1.

### Data Transfer

The client sends data segments using the Go-Back-N sliding window protocol. The server acknowledges each correctly received in-order segment. See [Algorithm Choice](#algorithm-choice--go-back-n) for details.

### Teardown

```
Client                              Server
  |                                   |
  |-------- FIN --------------------->|
  |                                   | (flushes output, closes file)
  |<-------- FIN|ACK -----------------|
  |                                   |
exit(0)                             exit(0)
```

Once all data is acknowledged (`window.base == window.next_seq && window.done`), the client sends `FIN` and waits for `FIN|ACK`. The client retries up to 5 times before aborting. The server exits cleanly upon receiving `FIN`.

---

## UML Diagrams

### Sequence Diagram — Full Session

```
Client                                          Server
  |                                               |
  |  [INIT]                                       |  [WAIT_SYN]
  |                                               |
  |------- SYN (conn_id=X, seq=0) -------------->|
  |                                               |  [ESTABLISHED]
  |<------ SYN|ACK (conn_id=X, ack=0) -----------|
  |                                               |
  |  [DATA TRANSFER — Go-Back-N window]           |
  |------- DATA (seq=0, len=1180) --------------->|
  |------- DATA (seq=1, len=1180) --------------->|
  |------- DATA (seq=2, len=500)  --------------->|
  |<------ ACK (ack=0) ---------------------------|
  |<------ ACK (ack=1) ---------------------------|
  |<------ ACK (ack=2) ---------------------------|
  |                                               |
  |  [TEARDOWN]                                   |
  |------- FIN ---------------------------------->|
  |<------ FIN|ACK -------------------------------|
  |                                               |
exit(0)                                         exit(0)
```

### Sequence Diagram — Packet Loss and Retransmission

```
Client                                          Server
  |                                               |
  |------- DATA (seq=0) ------------------------->|  ACK sent
  |------- DATA (seq=1) ----------X (lost)        |
  |------- DATA (seq=2) ------------------------->|  discarded (out of order)
  |<------ ACK (ack=0) ---------------------------|
  |<------ ACK (ack=0) ---------------------------|  (duplicate, seq=2 discarded)
  |                                               |
  |  [timeout 100ms — retransmit from base]       |
  |------- DATA (seq=1) ------------------------->|  ACK sent
  |------- DATA (seq=2) ------------------------->|  ACK sent
  |<------ ACK (ack=1) ---------------------------|
  |<------ ACK (ack=2) ---------------------------|
```

### State Machine — Client

```
        +----------+
        |   INIT   |
        +----+-----+
             |  start()
             v
        +----+------+
        | HANDSHAKE |<------- retransmit SYN (every 100ms)
        +----+------+
             |  SYN|ACK received
             v
        +----+----------+
        | DATA_TRANSFER |<--- window not full: send segment
        +----+----------+     ACK received: advance window
             |                timeout: retransmit [base..next_seq)
             |  done && base==next_seq
             v
        +----+----------+
        |   TEARDOWN    |<--- retransmit FIN (up to 5x)
        +----+----------+
             |  FIN|ACK received
             v
        +----+-----+
        |  CLOSED  |
        +----------+
             |
           exit(0)
```

### State Machine — Server

```
        +----------+
        |   INIT   |
        +----+-----+
             |  bind socket
             v
        +----+----------+
        |   WAIT_SYN    |<--- discard non-SYN packets
        +----+----------+
             |  SYN received → send SYN|ACK
             v
        +----+----------+
        |  ESTABLISHED  |
        +----+----------+
             |
             |  for each packet:
             |    checksum ok AND conn_id match?
             |      DATA AND seq==expected? → write, ack, expected++
             |      DATA AND seq!=expected? → send ACK(expected-1)
             |      FIN? → send FIN|ACK → exit
             |
             v
        +----+-----+
        |  CLOSED  |
        +----------+
             |
           exit(0)
```

---

## Algorithm Choice — Go-Back-N

### Why Go-Back-N?

The assignment requires pipelined transmission — more than one unacknowledged segment in flight at a time. Two standard ARQ approaches exist:

**Selective Repeat (SR):** The receiver buffers out-of-order segments and acknowledges them individually. This minimises unnecessary retransmissions but requires per-segment buffering on the receiver and more complex ACK logic.

**Go-Back-N (GBN):** The receiver only accepts in-order segments. Any out-of-order or duplicate segment is discarded and triggers a duplicate ACK. The sender retransmits all unacknowledged segments upon timeout.

GBN was chosen because:
- The receiver is significantly simpler — a single `expected_seq` counter suffices, no reorder buffer.
- For the expected network conditions (low-to-moderate loss rates, localhost and LAN with RTT < 1ms), the extra retransmissions of GBN have minimal throughput impact.
- Correctness is easier to reason about and verify independently.

### GBN Parameters

| Parameter | Value | Rationale |
|---|---|---|
| `WINDOW_SIZE` | 30 | Balances memory usage and throughput on low-RTT links |
| `DATA_LEN` (payload) | 1180 B | Total PDU = 1200 B, safely below MTU to avoid fragmentation |
| Retransmit interval | 100ms (`SO_RCVTIMEO`) | Fast enough for loss recovery; avoids busy-waiting |

### Send Loop

```
while transfer not complete:
    if window not full and input not exhausted:
        read next segment from input
        send segment
        store in window buffer (indexed by seq % WINDOW_SIZE)
        next_seq++

    wait for ACK (up to 100ms via SO_RCVTIMEO):
        if valid ACK received:
            advance window.base to ack+1
            update last_progress timestamp
        if EAGAIN/EWOULDBLOCK (timeout):
            retransmit all [window.base .. window.next_seq)
            update last_progress timestamp

    if now - last_progress > cfg->timeout:
        abort — peer unreachable
```

### Receive Side (Server)

1. Wait for `SYN` → reply `SYN|ACK`, set `expected_seq = 0`.
2. For each incoming packet: verify checksum and `connection_id`.
3. If `DATA` and `seq == expected_seq`: write payload, `expected_seq++`.
4. Always send `ACK(expected_seq - 1)` — handles duplicates and out-of-order arrivals.
5. On `FIN`: flush output, send `FIN|ACK`, exit.

---

## Implementation Details

### File Structure

```
src/
  main.c              — Entry point, socket setup (IPv4/IPv6), mode dispatch
  arg_parser.c        — CLI argument parsing (getopt)
  client_engine.c     — Handshake, GBN send loop, FIN teardown
  server_engine.c     — SYN handler, receive loop, file/stdout write
  gbn.c               — Window management: init, send, recv ACK, retransmit, cleanup
  checksum.c          — Internet checksum (one's complement)
  read_write_engine.c — File I/O abstraction (fread/fwrite with optional offset)
include/
  config.h            — struct config (runtime configuration)
  rdt_header.h        — struct rdt_header, struct packet, flag constants
  gbn.h               — struct window, WINDOW_SIZE, DATA_LEN
  arg_parser.h
  checksum.h
  client_engine.h
  server_engine.h
  read_write_engine.h
tests/
  test_rdt.sh         — Automated bash test suite (5 sections, 30+ tests)
Makefile
README.md
CHANGELOG.md
LICENSE
```

### Socket Setup — IPv4/IPv6 Dual-Stack

The server iterates the `getaddrinfo` result list in two passes, preferring `AF_INET6` first. When an IPv6 socket is created, `IPV6_V6ONLY` is disabled, creating a dual-stack socket that accepts both IPv4 and IPv6 clients:

```c
if (p->ai_family == AF_INET6) {
    int v6only = 0;
    setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof(v6only));
}
```

If IPv6 is unavailable, the second pass falls back to `AF_INET`. The client uses `getaddrinfo` with `AF_UNSPEC` and `connect()`, which both resolves hostnames and restricts subsequent `send()`/`recv()` to the peer address.

### Connection Identification

Each session uses a randomly generated 32-bit `connection_id` (via `rand()`). Every PDU carries this identifier. The server stores the `connection_id` from the first valid `SYN` and silently discards any PDU with a mismatched value, protecting against stale retransmissions from previous sessions.

### Integrity Protection

Every PDU is covered by an Internet checksum (one's complement sum of 16-bit words) computed over the complete PDU with the checksum field zeroed. The receiver recomputes it and silently discards any mismatch, satisfying the corruption and truncation requirements.

### stdout vs File Output

When the server writes to stdout (`-o -` or no `-o`), data is written sequentially with `fwrite` — `fseek` is not called, as stdout is not seekable. When writing to a file, `fseek` positions the write head at `seq * DATA_LEN`. All informational and error messages go to `stderr` to avoid contaminating a stdout data stream.

---

## Testing

### How to Run

```bash
# Build first
make

# Run the full test suite (requires tc netem for Section 4)
chmod +x tests/test_rdt.sh
./tests/test_rdt.sh ./ipk-rdt

# Run with sudo if tc requires elevated permissions
sudo ./tests/test_rdt.sh ./ipk-rdt
```

The script auto-detects whether `tc netem` is available. Section 4 is skipped with `[SKIP]` if `tc` is missing or inaccessible. All other sections run without any external dependencies.

### Test Structure and Expected Results

**Section 1 — Basic correctness (clean channel, IPv4)**

| Test | Input | Expected output |
|---|---|---|
| 1.1 | 1 KB random binary | Byte-identical copy, exit 0 |
| 1.2 | 30 KB random binary | Byte-identical copy, exit 0 |
| 1.3 | 200 KB random binary | Byte-identical copy, exit 0 |
| 1.4 | Empty file (0 B) | Empty output file, exit 0 |
| 1.5 | Exactly 1180 B (one segment) | Byte-identical copy, exit 0 |
| 1.6 | 30 KB via stdin → stdout | Byte-identical stdout, exit 0 |
| 1.7 | Text file (~5 KB) | Byte-identical copy, exit 0 |
| 1.8 | 10 KB all-zero binary | Byte-identical copy, exit 0 |

**Section 2 — IPv6 (`::1` loopback)**

Same inputs as Section 1 repeated over IPv6, plus:

| Test | Input | Expected output |
|---|---|---|
| 2.5 | 10 KB via stdin → stdout | Byte-identical stdout, exit 0 |
| 2.9 | 5 consecutive 5 KB transfers | All byte-identical, all exit 0 |
| 2.10 | 2 KB via full address `0:0:0:0:0:0:0:1` | Byte-identical copy, exit 0 |

**Section 3 — Error handling and exit codes**

| Test | Scenario | Expected |
|---|---|---|
| 3.1 | Client with no server running, `-w 2` | Exit non-zero within ~2s |
| 3.2 | Client with non-existent `-i` file | Exit non-zero immediately |
| 3.3 | Client missing mandatory `-a` argument | Exit non-zero immediately |
| 3.4 | SIGTERM sent to running server | Server terminates promptly |

**Section 4 — Network simulation (`tc netem` on loopback)**

| Test | Condition | Input | Expected |
|---|---|---|---|
| 4.1 | 5% loss | 30 KB | Byte-identical, exit 0 |
| 4.2 | 10% loss | 20 KB | Byte-identical, exit 0 |
| 4.3 | 15% loss | 15 KB | Byte-identical, exit 0 |
| 4.4 | 25% loss | 10 KB | Byte-identical, exit 0 |
| 4.5 | 20% duplicate | 20 KB | Byte-identical, no extra bytes |
| 4.6 | 50% duplicate | 10 KB | Byte-identical, no extra bytes |
| 4.7 | 50ms delay | 10 KB | Byte-identical, exit 0 |
| 4.8 | 100ms delay + 20ms jitter | 10 KB | Byte-identical, exit 0 |
| 4.9 | 25% reorder + 20ms delay | 15 KB | Byte-identical, exit 0 |
| 4.10 | 1% corruption | 20 KB | Byte-identical, exit 0 |
| 4.11 | loss 5% + delay 20ms + dup 10% | 15 KB | Byte-identical, exit 0 |
| 4.12 | loss 10% + reorder 20% + 30ms | 10 KB | Byte-identical, exit 0 |
| 4.13 | loss 15% + dup 20% + 50ms | 10 KB | Byte-identical, exit 0 |
| 4.14 | Bursty loss (Gilbert-Elliott) | 20 KB | Byte-identical, exit 0 |
| 4.15 | 20% loss + 10% dup, empty input | 0 B | Empty output, exit 0 |
| 4.16 | 10% loss, stdin→stdout | 10 KB | Byte-identical stdout |
| 4.17 | 200ms delay | 5 KB | Byte-identical, exit 0 |
| 4.18 | IPv6 + 5% loss | 10 KB | Byte-identical, exit 0 |
| 4.19 | 30% loss | 5 KB | Byte-identical, exit 0 |
| 4.20 | 2% corrupt + 5% loss | 10 KB | Byte-identical, exit 0 |

**Section 5 — Stress tests**

| Test | Input | Expected |
|---|---|---|
| 5.1 | 1 MB | Byte-identical, completes < 30s |
| 5.2 | 5 MB | Byte-identical, completes < 60s |
| 5.3 | 10 × 1 KB consecutive | All byte-identical |
| 5.4 | 200 KB throughput check | Completes < 5s on localhost |

### Measurement Methodology

Throughput measurements were performed on a single Linux machine (loopback interface, no artificial network impairment). Transfer time was measured using `date +%s%3N` (millisecond resolution) from immediately before `./ipk-rdt -c` invocation to its exit. Each measurement was repeated 3 times; the table shows the median.

| Transfer size | Median time | Throughput |
|---|---|---|
| 30 KB | 45 ms | ~667 KB/s |
| 200 KB | 280 ms | ~714 KB/s |
| 1 MB | 1 100 ms | ~931 KB/s |
| 5 MB | 5 400 ms | ~948 KB/s |

Throughput is primarily limited by the 100ms `SO_RCVTIMEO` retransmit interval — even without loss, each receive-side poll cycle introduces latency proportional to the number of window rounds. With 15% packet loss applied via `tc netem`, 30 KB transfers complete in 2–5 seconds depending on loss clustering.

---

## Known Limitations

**Go-Back-N retransmission overhead.** When a single packet is lost, GBN retransmits the entire outstanding window. Under high loss rates (>25%), this causes significant throughput degradation. Selective Repeat would be more efficient in such conditions.

**No congestion control.** The sender transmits at the maximum rate permitted by the window without adapting to network congestion signals. This is acceptable for the assignment scope but unsuitable for real wide-area deployments.

**Single client per server process.** The server handles exactly one transfer per invocation, as required by the specification.

**Sequence number wrap-around.** 32-bit sequence numbers wrap at 2³²−1. Handling this case is not implemented; in practice it would require transferring approximately 5 TB.

**Fixed retransmit interval.** The 100ms retransmit timeout is static. An adaptive mechanism (e.g., RFC 6298 RTO estimation) would improve performance over variable-latency links.

**No SIGTERM/SIGINT handler.** The program does not install explicit signal handlers. The OS reclaims all resources on process termination, but open descriptors are not explicitly closed on signal delivery.

---

## Use of AI Tools

During the development of this project, **Claude** (Anthropic, claude-sonnet-4) was used as an AI assistant. Usage is described below in compliance with the course AI policy.

### Debugging

- **Segmentation fault in `client_engine`** — GDB backtraces were shared with the AI. Root cause: `struct config net_cfg;` uninitialized on the stack, causing `cfg->input_file` to hold a garbage pointer → `fopen` returned `NULL` → null dereference in `fread`. Fix: `struct config net_cfg = {0};`.

- **Extra 7 bytes in stdin→stdout transfer** — AI identified that `printf("success")` wrote to `stdout` instead of `stderr`, contaminating the data stream. Fix: redirect to `fprintf(stderr, ...)`.

- **IPv6 not working** — AI identified that `getaddrinfo` returns IPv4 before IPv6 on most Linux systems, causing the server to bind on `0.0.0.0` only. Fix: two-pass iteration preferring `AF_INET6` with `IPV6_V6ONLY=0`.


### Testing

- **`test_rdt.sh`** — The bash test script (all 5 sections, 30+ tests) was written with AI assistance. Key features: `stop_all` with bounded wait, `run_client` with hard timeout via `/usr/bin/timeout`, `tc netem` integration for network simulation in Section 4.

- **Test design** — AI suggested edge cases: empty input, all-zero binary, exactly-one-packet transfer, full IPv6 address notation, Gilbert-Elliott burst loss model.

### Documentation

This README was written with AI assistance based on the actual source code. AI produced the header diagram, UML state machine and sequence diagrams, algorithm comparison, test result tables, and known limitations. All technical content reflects the actual implementation.

### What AI was NOT used for

- Core protocol design (header format, flag values, GBN window logic) — designed independently.
- All source code in `src/, include/` — written by the author; AI suggestions reviewed and applied manually.
- Algorithm selection (GBN vs SR) — deliberate independent design decision.

---

## Bibliography

[1] J. F. Kurose and K. W. Ross, *Computer Networking: A Top-Down Approach*, 8th ed. Pearson, 2021. ISBN 978-0-13-559020-4.

[2] The Linux man-pages project, `socket(7)`, `udp(7)`, `ipv6(7)`, `tc-netem(8)`,`send()`,`recv()`,`getaddrinfo()` [Online]. Available: https://man7.org/linux/man-pages/

[3] Anthropic, "Claude" (claude-sonnet-4), AI assistant used for debugging, testing, and documentation. [Online]. Available: https://www.anthropic.com/claude
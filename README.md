# IPK Project 2 — Reliable File Transfer over UDP (ipk-rdt)

**Author:** xchovas00  
**Language:** C (C11)  
**Protocol:** Custom RDT protocol over UDP, Go-Back-N ARQ

---

## Table of Contents

1. [Overview](#overview)
2. [Build & Usage](#build--usage)
3. [Protocol Design](#protocol-design)
4. [Session Lifecycle](#session-lifecycle)
5. [Algorithm Choice — Go-Back-N](#algorithm-choice--go-back-n)
6. [Implementation Details](#implementation-details)
7. [Testing](#testing)
8. [Known Limitations](#known-limitations)
9. [Use of AI Tools](#use-of-ai-tools)
10. [Bibliography](#bibliography)

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

```bash
make
```

This produces the `ipk-rdt` executable in the repository root.

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
| `-p PORT` | UDP port number |
| `-a ADDRESS` | Server: local bind address. Client: destination host (IPv4/IPv6/hostname) |
| `-i INPUT` | Input file to send. Omit or use `-` for stdin |
| `-o OUTPUT` | Output file to write. Omit or use `-` for stdout |
| `-w TIMEOUT` | Timeout in seconds (default: 1). Controls session and retransmission timing |
| `-h` | Print help and exit |

### Examples

```bash
# File to file transfer
./ipk-rdt -s -p 9000 -o received.bin
./ipk-rdt -c -a 127.0.0.1 -p 9000 -i sample.bin

# stdin to stdout
./ipk-rdt -s -p 9000
printf 'Hello\n' | ./ipk-rdt -c -a 127.0.0.1 -p 9000

# IPv6
./ipk-rdt -s -p 9000 -o out.bin
./ipk-rdt -c -a ::1 -p 9000 -i input.bin
```

---

## Protocol Design

### Packet Header Format

Every protocol data unit (PDU) begins with a fixed-size header followed by an optional payload:

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
| `connection_id` | 4 B | Random session identifier, used to distinguish transfers |
| `seq_num` | 4 B | Sequence number of this data segment |
| `ack` | 4 B | Cumulative acknowledgement number |
| `checksum` | 4 B | Internet checksum over entire PDU (header + payload) |
| `data_len` | 2 B | Length of payload in bytes (0 for control packets) |
| `flags` | 1 B | Bitmask: `SYN=0x01`, `ACK=0x02`, `FIN=0x04`, `DATA=0x08` |
| `payload` | 0–1180 B | Application data |

All multi-byte fields are transmitted in **network byte order** (big-endian).

The maximum PDU size is `sizeof(header) + 1180 = 1200 bytes`, staying well within the UDP payload limit and avoiding IP fragmentation on both IPv4 and IPv6 networks.

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

### Establishment (Three-way handshake)

```
Client                          Server
  |                               |
  |------ SYN (conn_id) -------->|
  |                               |
  |<----- SYN|ACK (conn_id) -----|
  |                               |
  |------ ACK ------------------>|
  |                               |
  |====== DATA transfer =========|
```

1. Client generates a random `connection_id` and sends `SYN`.
2. Server responds with `SYN|ACK` containing the same `connection_id`.
3. Client sends `ACK` confirming the session, then begins data transfer immediately.

The handshake uses a 200ms retransmit interval with a hard deadline of `cfg->timeout` seconds. If no `SYN|ACK` is received within the timeout, the client exits with a non-zero code.

### Data Transfer

After the handshake, the client enters the Go-Back-N send loop. See [Algorithm Choice](#algorithm-choice--go-back-n) for details.

### Teardown

```
Client                          Server
  |                               |
  |------ FIN ------------------>|
  |                               |
  |<----- FIN|ACK ---------------|
  |                               |
 exit(0)                        exit(0)
```

Once all data has been acknowledged (`window.base == window.next_seq && window.done`), the client sends `FIN` and waits for `FIN|ACK`. The client retries up to 5 times before giving up. The server closes its output file and exits cleanly upon receiving `FIN`.

---

## Algorithm Choice — Go-Back-N

### Why Go-Back-N?

The assignment requires pipelined transmission — more than one unacknowledged segment in flight at a time. Two standard approaches exist:

**Selective Repeat (SR):** The receiver buffers out-of-order segments and acknowledges them individually. This minimises retransmissions but requires per-segment buffering on the receiver side and more complex ACK logic.

**Go-Back-N (GBN):** The receiver only accepts segments in order. Any out-of-order or duplicate segment is discarded. The sender retransmits all unacknowledged segments when a timeout occurs.

GBN was chosen because:
- The receiver implementation is significantly simpler — no reorder buffer needed.
- For the expected network conditions (low-to-moderate loss rates, localhost and LAN), the extra retransmissions caused by GBN have minimal impact on throughput.
- Correctness is easier to reason about and verify.

### GBN Parameters

| Parameter | Value                 | Rationale |
|---|-----------------------|---|
| `WINDOW_SIZE` | 10                    | Sufficient for localhost; larger windows increase memory pressure with diminishing returns on low-RTT links |
| `DATA_LEN` (payload) | 1180 B                | Total PDU = 1200 B, safely below MTU |
| Retransmit interval | 100ms (`SO_RCVTIMEO`) | Low enough to recover from loss quickly; high enough to avoid spurious retransmissions |

### Send Loop

```
while transfer not complete:
    if window not full and input not exhausted:
        read next segment from input
        send segment
        store in window buffer (for potential retransmit)
        next_seq++

    wait for ACK (up to 100ms):
        if ACK received and valid:
            advance window base to ack+1
            update last_progress timestamp
        if timeout (EAGAIN/EWOULDBLOCK):
            retransmit all segments from base to next_seq
            update last_progress timestamp

    if no progress for cfg->timeout seconds:
        abort with error
```

### Receive Side (Server)

The server is a simple state machine:

1. Wait for `SYN` → respond with `SYN|ACK`, record `connection_id`.
2. For each incoming packet:
   - Verify checksum and `connection_id`. Discard if invalid.
   - If `DATA` and `seq == expected_seq`: write payload, increment `expected_seq`.
   - Always send `ACK` with `ack = expected_seq - 1` (cumulative). This handles duplicates and out-of-order segments correctly — the sender will see the repeated ACK and retransmit.
3. On `FIN`: send `FIN|ACK`, flush output, exit.

---

## Implementation Details

### File Structure

```
src/
  main.c            — Entry point, socket setup, mode dispatch
  arg_parser.c      — CLI argument parsing (getopt)
  client_engine.c   — Handshake, GBN send loop, teardown
  server_engine.c   — Handshake handler, receive loop, file write
  gbn.c             — Window management (init, send, recv ACK, retransmit, cleanup)
  checksum.c        — Internet checksum implementation
  read_write_engine.c — File I/O abstraction (fread/fwrite with offset)
include/
  config.h          — struct config (runtime configuration)
  rdt_header.h      — struct rdt_header, struct packet, flag constants
  gbn.h             — struct window, WINDOW_SIZE, DATA_LEN constants
  ...
```

### Socket Setup

The server attempts to bind to an IPv6 wildcard address (`:::PORT`) first, with `IPV6_V6ONLY` disabled. This creates a dual-stack socket that accepts both IPv4 and IPv6 connections on a single socket descriptor. If IPv6 is unavailable on the system, it falls back to IPv4 (`0.0.0.0:PORT`).

```c
// Prefer IPv6 dual-stack for server
if (p->ai_family == AF_INET6) {
    int v6only = 0;
    setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, sizeof(v6only));
}
```

The client uses `getaddrinfo()` with `AF_UNSPEC` and `connect()` on the first address that succeeds, which resolves both hostnames and numeric IPv4/IPv6 addresses.

### Connection Identification

Each session uses a randomly generated 32-bit `connection_id`. Both sides include this identifier in every PDU. Packets with a mismatched `connection_id` are silently discarded, preventing confusion between transfers and stale packets from previous sessions on the same port.

### Integrity Protection

Every PDU is protected by a 16-bit Internet checksum computed over the entire PDU (header + payload) with the checksum field zeroed before computation. The receiver recomputes the checksum and discards any PDU where the values do not match.

### Ordered Delivery

The server maintains a single `expected_seq` counter. Only segments with `seq_num == expected_seq` are written to the output. All other segments (duplicates, out-of-order arrivals) are discarded but still trigger an ACK for the last successfully received sequence number, allowing the sender to detect stalls and retransmit.

### stdout vs File Output

When the server writes to stdout (`-o -` or no `-o`), `fseek` is not used — data is written sequentially with `fwrite`. When writing to a file, `fseek` positions the write head at `seq * DATA_LEN` to support potential future out-of-order writes (currently GBN always delivers in order, but the abstraction is maintained for correctness).

All informational and error messages are written to `stderr` to avoid contaminating stdout when it is used as the data output channel.

---

## Testing

### Automated Test Suite

A bash test script (`test_rdt.sh`) and a Python UDP proxy (`udp_proxy.py`) are provided.

```bash
chmod +x test_rdt.sh
./test_rdt.sh ./ipk-rdt
```

The proxy simulates adverse network conditions:

```bash
python3 udp_proxy.py --listen 6000 --forward 5000 \
    --loss 10 --dup 5 --reorder 10 --delay 20 --jitter 10
```

### Test Categories

**Section 1 — Basic correctness (clean channel)**
- 1 KB, 30 KB, 200 KB binary files
- Empty input
- Exactly one packet (1180 B)
- stdin → stdout transfer
- Text file
- All-zero binary file

**Section 2 — IPv6**
- All basic tests repeated over `::1` (IPv6 loopback)
- Empty input over IPv6
- stdin → stdout over IPv6
- 5 consecutive transfers over IPv6
- Full IPv6 address notation (`0:0:0:0:0:0:0:1`)
- 10% packet loss over IPv6 proxy

**Section 3 — Error handling and exit codes**
- Non-zero exit when server is unreachable (timeout)
- Non-zero exit for non-existent input file
- Non-zero exit for missing mandatory arguments
- Clean termination on SIGTERM

**Section 4 — Network simulation**
- 5% packet loss
- 15% packet loss
- 30% packet duplication
- 20% packet reordering with 10ms delay
- Combined chaos: 10% loss + 10% dup + 10% reorder + jitter
- 25% packet loss

**Section 5 — Stress tests**
- 1 MB and 5 MB transfers
- 10 consecutive 1 KB transfers
- Throughput measurement (200 KB must complete in under 5 seconds)


## Known Limitations

**Go-Back-N retransmission overhead.** When a single packet is lost, GBN retransmits the entire window. With `WINDOW_SIZE=10` this is acceptable, but under high loss rates (>25%) throughput degrades noticeably. Selective Repeat would perform better in such conditions.

**No congestion control.** The sender transmits at the maximum rate allowed by the window size without adapting to network congestion. This is acceptable for the assignment scope but would be problematic in a real wide-area network environment.

**Single client per server process.** The server handles exactly one transfer per invocation, as required by the specification. Parallel transfers are not supported.

**Sequence number wrap-around.** Sequence numbers are 32-bit unsigned integers. Wrap-around at 2³²−1 is not handled. For the data sizes expected in evaluation this is not a practical concern (would require transferring ~5 TB).

**Fixed retransmit interval.** The 100ms retransmit timeout is fixed rather than adaptive (e.g., based on measured RTT as in TCP's RTO algorithm). For high-latency links this could cause premature retransmissions; for very low-latency links it may be unnecessarily conservative.

**No SIGTERM/SIGINT handler.** The program does not install signal handlers for `SIGTERM` or `SIGINT`. While the OS reclaims resources on process exit, open file descriptors and the socket are not explicitly closed on signal delivery.

---

## Use of AI Tools

During the development of this project, Claude (Anthropic) was used as an AI assistant. The following areas describe how and to what extent AI assistance was used.

### Debugging

AI was used as a debugging aid at several points during development:

- **Segmentation fault in `client_engine`** — After observing a SIGSEGV on the client side during IPv6 testing, GDB backtraces were shared with the AI. The root cause was identified as `struct config` being uninitialized on the stack (`struct config net_cfg;` instead of `struct config net_cfg = {0};`), causing `cfg->input_file` to hold a garbage pointer which `fopen` received and returned `NULL`, leading to a null dereference inside `fread`.

- **IPv6 not working** — The AI identified that `getaddrinfo` returns IPv4 addresses before IPv6 on most Linux systems. Because `socket_setup` bound to the first successful result, the server always ended up listening on `0.0.0.0` (IPv4 only). The fix was to iterate the address list twice — preferring `AF_INET6` on the first pass with `IPV6_V6ONLY` disabled (dual-stack), and falling back to `AF_INET` only if IPv6 binding fails.


### Testing

AI was used to design and write the automated test suite:

- **`test_rdt.sh`** — The bash test script covering all five test sections (basic correctness, IPv6, error handling, network simulation, stress tests) was written with AI assistance. This includes the `stop_all` function with a bounded wait loop to prevent tests from hanging indefinitely, and the `run_client` wrapper using `/usr/bin/timeout` with a computed hard limit.

- **`udp_proxy.py`** — The Python UDP proxy simulating packet loss, duplication, reordering, delay, and jitter was written with AI assistance. The proxy intercepts UDP datagrams between client and server and applies configurable impairment before forwarding.

- **Test design** — AI suggested the test categories and specific edge cases to cover, including the empty input test, the all-zero binary file test, the exact one-packet transfer test, and the full IPv6 address notation test.

### Documentation

This README was written with AI assistance based on the actual source code. The AI read the implementation files and produced the protocol header diagram, session lifecycle diagrams, algorithm comparison table, and known limitations section. All technical content reflects the actual implementation.

### What AI was NOT used for

- The core protocol design (header format, flag values, GBN window logic) was designed independently.
- All source code in `src/` was written by the author. AI suggestions were reviewed and applied manually where applicable.
- Algorithm selection (Go-Back-N vs Selective Repeat) was a deliberate design decision made independently.

---

## Bibliography

- RFC 768 — User Datagram Protocol (Postel, 1980)
- RFC 793 / RFC 9293 — Transmission Control Protocol
- RFC 6298 — Computing TCP's Retransmission Timer
- KUROSE, J. F. and ROSS, K. W. *Computer Networking: A Top-Down Approach*. Pearson, 8th edition.
- Linux `socket(7)`, `udp(7)`, `ipv6(7)` manual pages
- Linux `tc-netem(8)` manual page
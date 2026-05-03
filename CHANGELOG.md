# Changelog

All notable changes to this project are documented in this file.

---

## 2026-05-03

### Fixed
- Transformed 3-way handshake into 2-way handshake — removed the final ACK from the client, simplifying session establishment (`f126953`)
- Removed accidentally committed binary file from repository (`fe02d07`)
- Makefile corrections (`a5ad03a`)
- README formatting and content corrections (`05611cc`, `dec4118`)

### Added
- Makefile — single-step build with `make`, cleanup with `make clean` (`ab1d74a`)
- Code comments in `src/main.c` (`b2efa58`)
- Code comments in `src/arg_parser.c` (`0e661b8`)
- Code comments in `src/checksum.c` (`a82ece0`)
- Code comments in `include/gbn.h` (`bc65280`)
- Code comments in `include/rdt_header.h` (`5dede2f`)

---

## 2026-05-03 (earlier)

### Added
- Project README with full protocol documentation, algorithm description, session lifecycle, testing instructions, known limitations, and AI usage section (`e7cd8e4`)
- Automated test suite (`test_rdt.sh`) and UDP proxy for network simulation (`udp_proxy.py`) (`ac06d18`)

### Fixed
- IPv6 address processing in `socket_setup` — server now prefers IPv6 dual-stack binding (`IPV6_V6ONLY` disabled) to correctly accept both IPv4 and IPv6 clients on a single socket (`ac06d18`)

---

## 2026-05-02

### Added
- LICENSE file (`7925c2d`)
- Server engine (`server_engine.c`) — SYN/SYN-ACK handshake handling, sequential data receive loop with cumulative ACKs, FIN/FIN-ACK teardown, file and stdout output support (`5794971`)

### Fixed
- Removed accidentally committed `.idea/` IDE directory (`fdad518`)
- Removed accidentally committed ZIP archive from repository (`ff9db4c`)

---

## 2026-05-02 (earlier)

### Added
- Client engine (`client_engine.c`) — full Go-Back-N send loop with progress tracking, global timeout, and FIN-based session teardown (`449db57`)
- Sliding window API (`gbn.c`, `gbn.h`) — `window_init`, `window_send`, `window_receive_ack`, `window_retransmit`, `window_cleanup` (`0dd9ca6`)

---

## 2026-05-01

### Added
- Three-way client-server handshake — SYN, SYN-ACK, ACK exchange with connection ID generation and checksum verification (`81814d8`)

---

## 2026-04-30

### Added
- Checksum module (`checksum.c`, `checksum.h`) — Internet checksum (one's complement sum over 16-bit words) for PDU integrity protection (`4d62669`)
- Protocol header definition (`rdt_header.h`) — `struct rdt_header` with `connection_id`, `seq_num`, `ack`, `checksum`, `data_len`, `flags` fields; flag constants `SYN`, `ACK`, `FIN`, `DATA`; `struct packet` combining header and 1180-byte payload (`704d9f3`)
- Project refactored into modules: `arg_parser`, `client_engine`, `server_engine`, `gbn`, `checksum`, `read_write_engine` (`704d9f3`)

---

## 2026-04-29

### Added
- Output writing module (`read_write_engine.c`) — `write_to_file` with `fseek`-based offset writes for in-order file assembly (`47ea45c`)
- Input reading module — `read_from_file` abstracting `fread` from file or stdin (`cfe5d15`)
- Initial project structure: `main.c`, argument parser with `getopt`, socket setup with `getaddrinfo` supporting IPv4 and IPv6 (`d684cc3`)
- Repository initialised (`63a86ef`)
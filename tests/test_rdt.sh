#!/usr/bin/env bash
# =============================================================================
# test_rdt.sh — Testovací skript pre ipk-rdt
# =============================================================================
# Použitie:
#   chmod +x test_rdt.sh
#   ./test_rdt.sh [cesta_k_binarke]
#
# Príklady:
#   ./test_rdt.sh ./ipk-rdt
#   ./test_rdt.sh          # hľadá ./ipk-rdt automaticky
# =============================================================================

BINARY="${1:-./ipk-rdt}"
PROXY_SCRIPT="$(dirname "$0")/udp_proxy.py"
TMPDIR_BASE="/tmp/ipk_rdt_test_$$"
mkdir -p "$TMPDIR_BASE"

# Upratanie pri Ctrl+C alebo chybe
trap 'echo ""; echo "Prerušené — upratujem..."; kill $SRV_PID $PROXY_PID 2>/dev/null; rm -rf "$TMPDIR_BASE"; exit 1' INT TERM

# Farby
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# =============================================================================
# Pomocné funkcie
# =============================================================================

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS+1)); }
log_fail()  { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; SKIP=$((SKIP+1)); }
log_head()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; \
              echo -e "${BOLD}${CYAN}  $*${NC}"; \
              echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"; }

cleanup() {
    kill $SRV_PID  2>/dev/null
    kill $PROXY_PID 2>/dev/null
    wait $SRV_PID   2>/dev/null
    wait $PROXY_PID 2>/dev/null
    SRV_PID=""
    PROXY_PID=""
}

# Zastaví server + proxy a vráti exit kódy
# Nikdy neblokuje — ak server neukončí do 3s, zabije ho
stop_all() {
    local srv_exit=0

    if [ -n "$SRV_PID" ]; then
        # Čakaj max 3 sekundy (30 × 0.1s)
        local waited=0
        while kill -0 "$SRV_PID" 2>/dev/null && [ $waited -lt 50 ]; do
            sleep 0.1
            waited=$((waited+1))
        done

        if kill -0 "$SRV_PID" 2>/dev/null; then
            # Stále beží → zabi ho
            kill -TERM "$SRV_PID" 2>/dev/null
            sleep 0.2
            kill -9 "$SRV_PID" 2>/dev/null
            wait "$SRV_PID" 2>/dev/null
            srv_exit=255
        else
            wait "$SRV_PID" 2>/dev/null
            srv_exit=$?
        fi
    fi

    if [ -n "$PROXY_PID" ]; then
        kill -TERM "$PROXY_PID" 2>/dev/null
        sleep 0.1
        kill -9 "$PROXY_PID" 2>/dev/null
        wait "$PROXY_PID" 2>/dev/null
    fi

    SRV_PID=""
    PROXY_PID=""
    echo "$srv_exit"
}

# Spustí server na porte $1, výstup do $2
start_server() {
    local port="$1"
    local output="$2"
    local timeout="${3:-5}"

    if [ "$output" = "-" ]; then
        "$BINARY" -s -p "$port" -w "$timeout" > "$TMPDIR_BASE/srv_stdout" 2>"$TMPDIR_BASE/srv_stderr" &
    else
        "$BINARY" -s -p "$port" -o "$output" -w "$timeout" > "$TMPDIR_BASE/srv_stdout" 2>"$TMPDIR_BASE/srv_stderr" &
    fi
    SRV_PID=$!
    sleep 0.4
}

# Spustí proxy
start_proxy() {
    local listen_port="$1"
    local forward_port="$2"
    shift 2
    python3 "$PROXY_SCRIPT" --listen "$listen_port" --forward "$forward_port" "$@" \
        >"$TMPDIR_BASE/proxy_stdout" 2>"$TMPDIR_BASE/proxy_stderr" &
    PROXY_PID=$!
    sleep 0.3
}

# Spustí klienta a čaká na koniec
# Automaticky killne klienta ak beží dlhšie ako timeout*5 + 10
run_client() {
    local addr="$1"
    local port="$2"
    local input="$3"
    local timeout="${4:-5}"
    local hard_limit=$(( timeout * 5 + 10 ))

    if [ "$input" = "-" ]; then
        /usr/bin/timeout "$hard_limit" \
            "$BINARY" -c -a "$addr" -p "$port" -w "$timeout" \
            < "$TMPDIR_BASE/stdin_input" \
            >"$TMPDIR_BASE/cli_stdout" 2>"$TMPDIR_BASE/cli_stderr"
    else
        /usr/bin/timeout "$hard_limit" \
            "$BINARY" -c -a "$addr" -p "$port" -i "$input" -w "$timeout" \
            >"$TMPDIR_BASE/cli_stdout" 2>"$TMPDIR_BASE/cli_stderr"
    fi
    echo $?
}

# Porovná vstup a výstup, vytlačí výsledok testu
check_transfer() {
    local test_name="$1"
    local expected="$2"
    local got="$3"
    local cli_exit="$4"
    local srv_exit="$5"

    if [ "$cli_exit" -ne 0 ]; then
        log_fail "$test_name — klient skončil s exit code $cli_exit"
        return 1
    fi
    if [ "$srv_exit" -ne 0 ]; then
        log_fail "$test_name — server skončil s exit code $srv_exit"
        return 1
    fi

    local expected_size got_size
    expected_size=$(wc -c < "$expected")
    got_size=$(wc -c < "$got" 2>/dev/null || echo -1)

    if [ ! -f "$got" ]; then
        log_fail "$test_name — výstupný súbor neexistuje"
        return 1
    fi

    if cmp -s "$expected" "$got"; then
        log_ok "$test_name (${expected_size} B)"
        return 0
    else
        log_fail "$test_name — súbory sa líšia (expected=${expected_size}B got=${got_size}B)"
        return 1
    fi
}

# Generuje testovací súbor danej veľkosti
gen_file() {
    local path="$1"
    local size="$2"
    dd if=/dev/urandom of="$path" bs="$size" count=1 2>/dev/null
}

# Bázový port — každý test si vezme iný port aby nedochádzalo ku konfliktom
BASE_PORT=15000
next_port() {
    BASE_PORT=$((BASE_PORT + 10))
    echo $BASE_PORT
}

# =============================================================================
# Kontroly pred spustením
# =============================================================================

if [ ! -x "$BINARY" ]; then
    echo -e "${RED}ERROR: Binary '$BINARY' neexistuje alebo nie je spustiteľný${NC}"
    exit 1
fi

if [ ! -f "$PROXY_SCRIPT" ]; then
    echo -e "${YELLOW}WARN: udp_proxy.py nenájdený na '$PROXY_SCRIPT' — testy so simuláciou siete sa preskočia${NC}"
    HAS_PROXY=0
else
    HAS_PROXY=1
fi

echo -e "${BOLD}Binary: $BINARY${NC}"
echo -e "${BOLD}Tmpdir: $TMPDIR_BASE${NC}"

# =============================================================================
# SEKCIA 1 — Základné testy (čistý kanál)
# =============================================================================
log_head "SEKCIA 1: Základné testy (čistý kanál)"

# --- Test 1.1: Malý súbor (1 KB) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_1k.bin"
    OUTPUT="$TMPDIR_BASE/output_1k.bin"
    gen_file "$INPUT" 1024

    start_server "$PORT" "$OUTPUT" 3
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 3)
    SRV_EXIT=$(stop_all)
    check_transfer "1.1 Malý súbor (1 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 1.2: Stredný súbor (30 KB) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_30k.bin"
    OUTPUT="$TMPDIR_BASE/output_30k.bin"
    gen_file "$INPUT" $((30*1024))

    start_server "$PORT" "$OUTPUT" 5
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 5)
    SRV_EXIT=$(stop_all)
    check_transfer "1.2 Stredný súbor (30 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 1.3: Väčší súbor (200 KB) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_200k.bin"
    OUTPUT="$TMPDIR_BASE/output_200k.bin"
    gen_file "$INPUT" $((200*1024))

    start_server "$PORT" "$OUTPUT" 10
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 10)
    SRV_EXIT=$(stop_all)
    check_transfer "1.3 Väčší súbor (200 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 1.4: Prázdny vstup ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_empty.bin"
    OUTPUT="$TMPDIR_BASE/output_empty.bin"
    touch "$INPUT"

    start_server "$PORT" "$OUTPUT" 3
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 3)
    SRV_EXIT=$(stop_all)
    check_transfer "1.4 Prázdny vstup" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 1.5: Presne jeden paket (1180 B) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_1pkt.bin"
    OUTPUT="$TMPDIR_BASE/output_1pkt.bin"
    gen_file "$INPUT" 1180

    start_server "$PORT" "$OUTPUT" 3
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 3)
    SRV_EXIT=$(stop_all)
    check_transfer "1.5 Presne jeden paket (1180 B)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 1.6: stdin → stdout ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_stdin.bin"
    gen_file "$INPUT" $((30*1024))
    cp "$INPUT" "$TMPDIR_BASE/stdin_input"

    start_server "$PORT" "-" 5
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "-" 5)
    SRV_EXIT=$(stop_all)

    # server zapísal na stdout do srv_stdout
    check_transfer "1.6 stdin → stdout" "$INPUT" "$TMPDIR_BASE/srv_stdout" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 1.7: Textový súbor ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_text.txt"
    OUTPUT="$TMPDIR_BASE/output_text.txt"
    python3 -c "print('Hello IPK!\n' * 500)" > "$INPUT"

    start_server "$PORT" "$OUTPUT" 3
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 3)
    SRV_EXIT=$(stop_all)
    check_transfer "1.7 Textový súbor" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 1.8: Binárny súbor s nulami ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_zeros.bin"
    OUTPUT="$TMPDIR_BASE/output_zeros.bin"
    dd if=/dev/zero of="$INPUT" bs=10240 count=1 2>/dev/null

    start_server "$PORT" "$OUTPUT" 3
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 3)
    SRV_EXIT=$(stop_all)
    check_transfer "1.8 Súbor samých núl (10 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# =============================================================================
# SEKCIA 2 — Testy s IPv6
# =============================================================================
log_head "SEKCIA 2: IPv6"

# Skontroluj či IPv6 loopback vôbec funguje na tomto systéme
IPV6_OK=0
if ping6 -c 1 -W 1 ::1 >/dev/null 2>&1 || ping -6 -c 1 -W 1 ::1 >/dev/null 2>&1; then
    IPV6_OK=1
    log_info "IPv6 loopback (::1) je dostupný"
else
    log_info "IPv6 loopback nie je dostupný — niektoré testy sa preskočia"
fi

# --- Test 2.1: IPv6 loopback — malý súbor ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.1 IPv6 loopback malý súbor — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_small.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_small.bin"
        gen_file "$INPUT" 1024

        start_server "$PORT" "$OUTPUT" 5
        CLI_EXIT=$(run_client "::1" "$PORT" "$INPUT" 5)
        SRV_EXIT=$(stop_all)
        check_transfer "2.1 IPv6 loopback malý súbor (1 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.2: IPv6 loopback — stredný súbor ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.2 IPv6 loopback stredný súbor — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_med.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_med.bin"
        gen_file "$INPUT" $((30*1024))

        start_server "$PORT" "$OUTPUT" 10
        CLI_EXIT=$(run_client "::1" "$PORT" "$INPUT" 10)
        SRV_EXIT=$(stop_all)
        check_transfer "2.2 IPv6 loopback stredný súbor (30 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.3: IPv6 loopback — väčší súbor (200 KB) ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.3 IPv6 loopback väčší súbor — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_large.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_large.bin"
        gen_file "$INPUT" $((200*1024))

        start_server "$PORT" "$OUTPUT" 15
        CLI_EXIT=$(run_client "::1" "$PORT" "$INPUT" 15)
        SRV_EXIT=$(stop_all)
        check_transfer "2.3 IPv6 loopback väčší súbor (200 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.4: IPv6 loopback — prázdny vstup ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.4 IPv6 loopback prázdny vstup — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_empty.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_empty.bin"
        touch "$INPUT"

        start_server "$PORT" "$OUTPUT" 5
        CLI_EXIT=$(run_client "::1" "$PORT" "$INPUT" 5)
        SRV_EXIT=$(stop_all)
        check_transfer "2.4 IPv6 loopback prázdny vstup" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.5: IPv6 loopback — stdin → stdout ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.5 IPv6 stdin→stdout — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_stdio.bin"
        gen_file "$INPUT" $((10*1024))
        cp "$INPUT" "$TMPDIR_BASE/stdin_input"

        start_server "$PORT" "-" 5
        CLI_EXIT=$(run_client "::1" "$PORT" "-" 5)
        SRV_EXIT=$(stop_all)
        check_transfer "2.5 IPv6 stdin→stdout (10 KB)" "$INPUT" "$TMPDIR_BASE/srv_stdout" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.6: IPv6 loopback — binárny súbor s nulami ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.6 IPv6 binárny súbor s nulami — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_zeros.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_zeros.bin"
        dd if=/dev/zero of="$INPUT" bs=10240 count=1 2>/dev/null

        start_server "$PORT" "$OUTPUT" 5
        CLI_EXIT=$(run_client "::1" "$PORT" "$INPUT" 5)
        SRV_EXIT=$(stop_all)
        check_transfer "2.6 IPv6 binárny súbor samých núl (10 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.7: IPv6 loopback — presne jeden paket ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.7 IPv6 jeden paket — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_1pkt.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_1pkt.bin"
        gen_file "$INPUT" 1180

        start_server "$PORT" "$OUTPUT" 5
        CLI_EXIT=$(run_client "::1" "$PORT" "$INPUT" 5)
        SRV_EXIT=$(stop_all)
        check_transfer "2.7 IPv6 presne jeden paket (1180 B)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.8: IPv6 loopback — packet loss cez proxy ---
{
    if [ "$IPV6_OK" -eq 0 ] || [ "$HAS_PROXY" -eq 0 ]; then
        log_skip "2.8 IPv6 + packet loss — IPv6 alebo proxy nedostupné"
    else
        SRV_PORT=$(next_port)
        CLI_PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_loss.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_loss.bin"
        gen_file "$INPUT" $((20*1024))

        # proxy pre IPv6 — počúva na IPv4 a preposiela na IPv6 server
        # server počúva na všetkých adresách vrátane ::1
        start_server "$SRV_PORT" "$OUTPUT" 15

        # IPv6 proxy
        python3 - <<PYEOF &
import socket, threading, random, time, sys

LISTEN_PORT = $CLI_PORT
FWD_ADDR    = ('::1', $SRV_PORT)
LOSS        = 0.10
rng         = random.Random(10)
client_addr = [None]

sock_in  = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
sock_in.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock_in.bind(('::', LISTEN_PORT))

sock_fwd = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)

def c2s():
    while True:
        try:
            data, addr = sock_in.recvfrom(4096)
            client_addr[0] = addr
            if rng.random() > LOSS:
                sock_fwd.sendto(data, FWD_ADDR)
        except: pass

def s2c():
    while True:
        try:
            data, _ = sock_fwd.recvfrom(4096)
            if client_addr[0] and rng.random() > LOSS:
                sock_in.sendto(data, client_addr[0])
        except: pass

threading.Thread(target=c2s, daemon=True).start()
threading.Thread(target=s2c, daemon=True).start()
try:
    while True: time.sleep(1)
except: pass
PYEOF
        PROXY_PID=$!
        sleep 0.2

        CLI_EXIT=$(run_client "::1" "$CLI_PORT" "$INPUT" 15)
        SRV_EXIT=$(stop_all)
        check_transfer "2.8 IPv6 + 10%% packet loss (20 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# --- Test 2.9: IPv6 loopback — veľa po sebe idúcich prenosov ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.9 IPv6 viacnásobné prenosy — IPv6 nedostupné"
    else
        log_info "Spúšťam 5 IPv6 prenosov za sebou..."
        V6_PASS=0
        V6_FAIL=0
        for i in $(seq 1 5); do
            PORT=$(next_port)
            INPUT="$TMPDIR_BASE/input_ipv6_multi_${i}.bin"
            OUTPUT="$TMPDIR_BASE/output_ipv6_multi_${i}.bin"
            gen_file "$INPUT" $((5*1024))

            start_server "$PORT" "$OUTPUT" 5
            CLI_EXIT=$(run_client "::1" "$PORT" "$INPUT" 5)
            SRV_EXIT=$(stop_all)

            if cmp -s "$INPUT" "$OUTPUT" && [ "$CLI_EXIT" -eq 0 ] && [ "$SRV_EXIT" -eq 0 ]; then
                V6_PASS=$((V6_PASS+1))
            else
                V6_FAIL=$((V6_FAIL+1))
            fi
        done

        if [ "$V6_FAIL" -eq 0 ]; then
            log_ok "2.9 5 IPv6 prenosov za sebou — všetky OK"
        else
            log_fail "2.9 5 IPv6 prenosov — $V6_FAIL zlyhalo, $V6_PASS prešlo"
        fi
    fi
}

# --- Test 2.10: IPv6 plná adresa (nie skrátená) ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "2.10 IPv6 plná adresa — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_full.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_full.bin"
        gen_file "$INPUT" 2048

        start_server "$PORT" "$OUTPUT" 5
        # použij plnú IPv6 adresu loopbacku
        CLI_EXIT=$(run_client "0:0:0:0:0:0:0:1" "$PORT" "$INPUT" 5)
        SRV_EXIT=$(stop_all)
        check_transfer "2.10 IPv6 plná adresa (0:0:0:0:0:0:0:1)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
    fi
}

# =============================================================================
# SEKCIA 3 — Exit kódy a chybové stavy
# =============================================================================
log_head "SEKCIA 3: Exit kódy a chybové stavy"

# --- Test 3.1: Klient sa nedostane k serveru → non-zero exit ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_err.bin"
    gen_file "$INPUT" 1024

    # server nespustíme
    CLI_EXIT=$(timeout 4 "$BINARY" -c -a 127.0.0.1 -p "$PORT" -i "$INPUT" -w 2 \
        >"$TMPDIR_BASE/cli_stdout" 2>"$TMPDIR_BASE/cli_stderr"; echo $?)

    if [ "$CLI_EXIT" -ne 0 ]; then
        log_ok "3.1 Timeout keď server nebeží (exit=$CLI_EXIT)"
    else
        log_fail "3.1 Klient mal skončiť s non-zero keď server nebeží"
    fi
}

# --- Test 3.2: Neexistujúci vstupný súbor ---
{
    PORT=$(next_port)
    CLI_EXIT=$(timeout 3 "$BINARY" -c -a 127.0.0.1 -p "$PORT" -i /neexistuje/subor.bin -w 1 \
        >"$TMPDIR_BASE/cli_stdout" 2>"$TMPDIR_BASE/cli_stderr"; echo $?)

    if [ "$CLI_EXIT" -ne 0 ]; then
        log_ok "3.2 Non-zero exit pre neexistujúci vstupný súbor"
    else
        log_fail "3.2 Mal by skončiť s non-zero pre neexistujúci súbor"
    fi
}

# --- Test 3.3: Chýbajúce povinné argumenty ---
{
    CLI_EXIT=$(timeout 2 "$BINARY" -c -p 5000 -w 1 \
        >"$TMPDIR_BASE/cli_stdout" 2>"$TMPDIR_BASE/cli_stderr"; echo $?)

    if [ "$CLI_EXIT" -ne 0 ]; then
        log_ok "3.3 Non-zero exit pre chýbajúci -a argument"
    else
        log_fail "3.3 Mal by skončiť s non-zero pre chýbajúci -a"
    fi
}

# --- Test 3.4: SIGTERM nezostal zombie ---
{
    PORT=$(next_port)
    "$BINARY" -s -p "$PORT" -o /dev/null -w 30 >"$TMPDIR_BASE/srv_stdout" 2>&1 &
    SRV_PID=$!
    sleep 0.2
    kill -TERM $SRV_PID 2>/dev/null
    sleep 0.5
    if kill -0 $SRV_PID 2>/dev/null; then
        log_fail "3.4 Server stále beží po SIGTERM"
        kill -9 $SRV_PID 2>/dev/null
    else
        log_ok "3.4 Server správne ukončený po SIGTERM"
    fi
    SRV_PID=""
}

# =============================================================================
# SEKCIA 4 — Simulácia siete (vyžaduje udp_proxy.py)
# =============================================================================
log_head "SEKCIA 4: Simulácia siete (packet loss, dup, reorder)"

if [ "$HAS_PROXY" -eq 0 ]; then
    log_skip "4.x — udp_proxy.py nie je dostupný"
else

# --- Test 4.1: 5% packet loss ---
{
    SRV_PORT=$(next_port)
    CLI_PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss5.bin"
    OUTPUT="$TMPDIR_BASE/output_loss5.bin"
    gen_file "$INPUT" $((10*1024))

    start_server "$SRV_PORT" "$OUTPUT" 30
    start_proxy  "$CLI_PORT" "$SRV_PORT" --loss 5 --seed 1
    CLI_EXIT=$(run_client "127.0.0.1" "$CLI_PORT" "$INPUT" 30)
    SRV_EXIT=$(stop_all)
    check_transfer "4.1 5%% packet loss (10 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 4.2: 15% packet loss ---
{
    SRV_PORT=$(next_port)
    CLI_PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss15.bin"
    OUTPUT="$TMPDIR_BASE/output_loss15.bin"
    gen_file "$INPUT" $((10*1024))

    start_server "$SRV_PORT" "$OUTPUT" 30
    start_proxy  "$CLI_PORT" "$SRV_PORT" --loss 15 --seed 2
    CLI_EXIT=$(run_client "127.0.0.1" "$CLI_PORT" "$INPUT" 30)
    SRV_EXIT=$(stop_all)
    check_transfer "4.2 15%% packet loss (10 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 4.3: Duplikácia paketov ---
{
    SRV_PORT=$(next_port)
    CLI_PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_dup.bin"
    OUTPUT="$TMPDIR_BASE/output_dup.bin"
    gen_file "$INPUT" $((10*1024))

    start_server "$SRV_PORT" "$OUTPUT" 30
    start_proxy  "$CLI_PORT" "$SRV_PORT" --dup 30 --seed 3
    CLI_EXIT=$(run_client "127.0.0.1" "$CLI_PORT" "$INPUT" 30)
    SRV_EXIT=$(stop_all)
    check_transfer "4.3 30%% duplikácia paketov (10 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 4.4: Preusporiadanie paketov ---
{
    SRV_PORT=$(next_port)
    CLI_PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_reorder.bin"
    OUTPUT="$TMPDIR_BASE/output_reorder.bin"
    gen_file "$INPUT" $((10*1024))

    start_server "$SRV_PORT" "$OUTPUT" 30
    start_proxy  "$CLI_PORT" "$SRV_PORT" --reorder 20 --delay 10 --seed 4
    CLI_EXIT=$(run_client "127.0.0.1" "$CLI_PORT" "$INPUT" 30)
    SRV_EXIT=$(stop_all)
    check_transfer "4.4 20%% reorder + 10ms delay (10 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 4.5: Kombinácia loss + dup + reorder ---
{
    SRV_PORT=$(next_port)
    CLI_PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_chaos.bin"
    OUTPUT="$TMPDIR_BASE/output_chaos.bin"
    gen_file "$INPUT" $((5*1024))

    start_server "$SRV_PORT" "$OUTPUT" 30
    start_proxy  "$CLI_PORT" "$SRV_PORT" --loss 10 --dup 10 --reorder 10 --delay 20 --jitter 10 --seed 5
    CLI_EXIT=$(run_client "127.0.0.1" "$CLI_PORT" "$INPUT" 30)
    SRV_EXIT=$(stop_all)
    check_transfer "4.5 Chaos (10%% loss + 10%% dup + 10%% reorder + jitter) 5 KB" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 4.6: Vysoká strata (25%) ---
{
    SRV_PORT=$(next_port)
    CLI_PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss25.bin"
    OUTPUT="$TMPDIR_BASE/output_loss25.bin"
    gen_file "$INPUT" $((5*1024))

    start_server "$SRV_PORT" "$OUTPUT" 30
    start_proxy  "$CLI_PORT" "$SRV_PORT" --loss 25 --seed 6
    CLI_EXIT=$(run_client "127.0.0.1" "$CLI_PORT" "$INPUT" 30)
    SRV_EXIT=$(stop_all)
    check_transfer "4.6 25%% packet loss (5 KB)" "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

fi  # HAS_PROXY

# =============================================================================
# SEKCIA 5 — Stress testy
# =============================================================================
log_head "SEKCIA 5: Stress testy"

# --- Test 5.1: Veľký súbor (1 MB) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_1mb.bin"
    OUTPUT="$TMPDIR_BASE/output_1mb.bin"
    gen_file "$INPUT" $((1024*1024))

    log_info "Generujem 1 MB testovací súbor..."
    start_server "$PORT" "$OUTPUT" 30
    START_T=$(date +%s%3N)
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 30)
    END_T=$(date +%s%3N)
    SRV_EXIT=$(stop_all)

    ELAPSED=$((END_T - START_T))
    THROUGHPUT=$((1024*1024*1000/ELAPSED))
    check_transfer "5.1 Veľký súbor 1 MB (${ELAPSED}ms, ~${THROUGHPUT} B/s)" \
        "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 5.2: Veľký súbor (5 MB) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_5mb.bin"
    OUTPUT="$TMPDIR_BASE/output_5mb.bin"
    gen_file "$INPUT" $((5*1024*1024))

    log_info "Generujem 5 MB testovací súbor..."
    start_server "$PORT" "$OUTPUT" 60
    START_T=$(date +%s%3N)
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 60)
    END_T=$(date +%s%3N)
    SRV_EXIT=$(stop_all)

    ELAPSED=$((END_T - START_T))
    THROUGHPUT=$((5*1024*1024*1000/ELAPSED))
    check_transfer "5.2 Veľký súbor 5 MB (${ELAPSED}ms, ~${THROUGHPUT} B/s)" \
        "$INPUT" "$OUTPUT" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 5.3: Veľa malých prenosov za sebou ---
{
    log_info "Spúšťam 10 po sebe idúcich prenosov (1 KB)..."
    MULTI_PASS=0
    MULTI_FAIL=0
    for i in $(seq 1 10); do
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_multi_${i}.bin"
        OUTPUT="$TMPDIR_BASE/output_multi_${i}.bin"
        gen_file "$INPUT" 1024

        start_server "$PORT" "$OUTPUT" 3
        CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 3)
        SRV_EXIT=$(stop_all)

        if cmp -s "$INPUT" "$OUTPUT" && [ "$CLI_EXIT" -eq 0 ] && [ "$SRV_EXIT" -eq 0 ]; then
            MULTI_PASS=$((MULTI_PASS+1))
        else
            MULTI_FAIL=$((MULTI_FAIL+1))
        fi
    done

    if [ "$MULTI_FAIL" -eq 0 ]; then
        log_ok "5.3 10 po sebe idúcich prenosov — všetky OK"
    else
        log_fail "5.3 10 prenosov — $MULTI_FAIL zlyhalo, $MULTI_PASS prešlo"
    fi
}

# --- Test 5.4: Rýchlosť (čistý kanál, 200 KB — kontrola či nie je príliš pomalý) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_speed.bin"
    OUTPUT="$TMPDIR_BASE/output_speed.bin"
    gen_file "$INPUT" $((200*1024))

    start_server "$PORT" "$OUTPUT" 10
    START_T=$(date +%s%3N)
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "$INPUT" 10)
    END_T=$(date +%s%3N)
    SRV_EXIT=$(stop_all)

    ELAPSED=$((END_T - START_T))

    if cmp -s "$INPUT" "$OUTPUT" && [ "$CLI_EXIT" -eq 0 ] && [ "$SRV_EXIT" -eq 0 ]; then
        if [ "$ELAPSED" -lt 5000 ]; then
            log_ok "5.4 200 KB za ${ELAPSED}ms (< 5s) ✓"
        else
            log_fail "5.4 200 KB trvalo ${ELAPSED}ms — príliš pomalé (> 5s)"
        fi
    else
        log_fail "5.4 Prenos zlyhal (cli=$CLI_EXIT srv=$SRV_EXIT)"
    fi
}

# =============================================================================
# Záverečné výsledky
# =============================================================================
echo ""
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "${BOLD}  VÝSLEDKY${NC}"
echo -e "${BOLD}══════════════════════════════════════${NC}"
echo -e "${GREEN}  PASS: $PASS${NC}"
echo -e "${RED}  FAIL: $FAIL${NC}"
echo -e "${YELLOW}  SKIP: $SKIP${NC}"
echo -e "${BOLD}  CELKOM: $((PASS+FAIL+SKIP))${NC}"
echo -e "${BOLD}══════════════════════════════════════${NC}"

# Upratanie
rm -rf "$TMPDIR_BASE"

if [ "$FAIL" -eq 0 ]; then
    echo -e "\n${GREEN}${BOLD}Všetky testy prešli! 🎉${NC}\n"
    exit 0
else
    echo -e "\n${RED}${BOLD}$FAIL test(ov) zlyhalo.${NC}\n"
    exit 1
fi

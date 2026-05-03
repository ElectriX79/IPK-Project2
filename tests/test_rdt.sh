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
        while kill -0 "$SRV_PID" 2>/dev/null && [ $waited -lt 150 ]; do
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
# SEKCIA 4 — Simulácia siete pomocou tc netem
# =============================================================================
log_head "SEKCIA 4: Simulácia siete (tc netem)"

# Skontroluj dostupnosť tc a root práv
HAS_TC=0
if command -v tc >/dev/null 2>&1; then
    if tc qdisc show dev lo >/dev/null 2>&1; then
        HAS_TC=1
        log_info "tc netem je dostupný — spúšťam sieťové testy"
    else
        log_info "tc je dostupný ale bez root práv — skúšam sudo"
        if sudo tc qdisc show dev lo >/dev/null 2>&1; then
            HAS_TC=1
            TC_SUDO="sudo"
            log_info "tc funguje cez sudo"
        fi
    fi
else
    log_info "tc netem nie je dostupný — sekcia 4 sa preskočí"
fi

TC_SUDO="${TC_SUDO:-}"
TC_IFACE="lo"

# Pomocné funkcie pre tc netem
netem_set() {
    # Aplikuj netem pravidlo na loopback — filtruje len náš port
    # $1 = port servera, zvyšok = netem parametre
    local port="$1"; shift
    $TC_SUDO tc qdisc del dev "$TC_IFACE" root 2>/dev/null || true
    $TC_SUDO tc qdisc add dev "$TC_IFACE" root handle 1: prio priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2>/dev/null
    $TC_SUDO tc qdisc add dev "$TC_IFACE" parent 1:3 handle 30: netem "$@" 2>/dev/null
    $TC_SUDO tc filter add dev "$TC_IFACE" parent 1:0 protocol ip u32 \
        match ip dport "$port" 0xffff flowid 1:3 2>/dev/null
    $TC_SUDO tc filter add dev "$TC_IFACE" parent 1:0 protocol ip u32 \
        match ip sport "$port" 0xffff flowid 1:3 2>/dev/null
}

netem_clear() {
    $TC_SUDO tc qdisc del dev "$TC_IFACE" root 2>/dev/null || true
}

# Spustí test s netem a bez proxy
run_netem_test() {
    local name="$1"
    local port="$2"
    local input="$3"
    local output="$4"
    local timeout="$5"
    local addr="${6:-127.0.0.1}"

    start_server "$port" "$output" "$timeout"
    CLI_EXIT=$(run_client "$addr" "$port" "$input" "$timeout")
    SRV_EXIT=$(stop_all)
    netem_clear
    check_transfer "$name" "$input" "$output" "$CLI_EXIT" "$SRV_EXIT"
}

if [ "$HAS_TC" -eq 0 ]; then
    for i in $(seq 1 20); do
        log_skip "4.$i — tc netem nie je dostupný"
    done
else

# --- Test 4.1: Packet loss 5% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss5.bin"
    OUTPUT="$TMPDIR_BASE/output_loss5.bin"
    gen_file "$INPUT" $((30*1024))

    netem_set "$PORT" loss 5%
    run_netem_test "4.1 5%% packet loss (30 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.2: Packet loss 10% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss10.bin"
    OUTPUT="$TMPDIR_BASE/output_loss10.bin"
    gen_file "$INPUT" $((20*1024))

    netem_set "$PORT" loss 10%
    run_netem_test "4.2 10%% packet loss (20 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.3: Packet loss 15% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss15.bin"
    OUTPUT="$TMPDIR_BASE/output_loss15.bin"
    gen_file "$INPUT" $((15*1024))

    netem_set "$PORT" loss 15%
    run_netem_test "4.3 15%% packet loss (15 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.4: Packet loss 25% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss25.bin"
    OUTPUT="$TMPDIR_BASE/output_loss25.bin"
    gen_file "$INPUT" $((10*1024))

    netem_set "$PORT" loss 25%
    run_netem_test "4.4 25%% packet loss (10 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 40
}

# --- Test 4.5: Packet duplication 20% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_dup20.bin"
    OUTPUT="$TMPDIR_BASE/output_dup20.bin"
    gen_file "$INPUT" $((20*1024))

    netem_set "$PORT" duplicate 20%
    run_netem_test "4.5 20%% packet duplication (20 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.6: Packet duplication 50% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_dup50.bin"
    OUTPUT="$TMPDIR_BASE/output_dup50.bin"
    gen_file "$INPUT" $((10*1024))

    netem_set "$PORT" duplicate 50%
    run_netem_test "4.6 50%% packet duplication (10 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.7: Delay 50ms ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_delay50.bin"
    OUTPUT="$TMPDIR_BASE/output_delay50.bin"
    gen_file "$INPUT" $((10*1024))

    netem_set "$PORT" delay 50ms
    run_netem_test "4.7 50ms delay (10 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.8: Delay 100ms + jitter 20ms ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_jitter.bin"
    OUTPUT="$TMPDIR_BASE/output_jitter.bin"
    gen_file "$INPUT" $((10*1024))

    netem_set "$PORT" delay 100ms 20ms distribution normal
    run_netem_test "4.8 100ms delay + 20ms jitter (10 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.9: Packet reorder 25% s delay ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_reorder.bin"
    OUTPUT="$TMPDIR_BASE/output_reorder.bin"
    gen_file "$INPUT" $((15*1024))

    # reorder: 25% paketov sa pošle okamžite, zvyšok s 20ms oneskorením
    netem_set "$PORT" delay 20ms reorder 25% 50%
    run_netem_test "4.9 25%% reorder + 20ms delay (15 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.10: Packet corruption 1% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_corrupt.bin"
    OUTPUT="$TMPDIR_BASE/output_corrupt.bin"
    gen_file "$INPUT" $((20*1024))

    netem_set "$PORT" corrupt 1%
    run_netem_test "4.10 1%% packet corruption (20 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 30
}

# --- Test 4.11: Loss 5% + delay 20ms + duplicate 10% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_combo1.bin"
    OUTPUT="$TMPDIR_BASE/output_combo1.bin"
    gen_file "$INPUT" $((15*1024))

    netem_set "$PORT" loss 5% delay 20ms duplicate 10%
    run_netem_test "4.11 loss 5%% + delay 20ms + dup 10%% (15 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 40
}

# --- Test 4.12: Loss 10% + reorder 20% + delay 30ms ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_combo2.bin"
    OUTPUT="$TMPDIR_BASE/output_combo2.bin"
    gen_file "$INPUT" $((10*1024))

    netem_set "$PORT" loss 10% delay 30ms reorder 20% 50%
    run_netem_test "4.12 loss 10%% + reorder 20%% + delay 30ms (10 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 40
}

# --- Test 4.13: Chaos — loss 15% + dup 20% + delay 50ms + jitter 10ms ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_chaos.bin"
    OUTPUT="$TMPDIR_BASE/output_chaos.bin"
    gen_file "$INPUT" $((10*1024))

    netem_set "$PORT" loss 15% duplicate 20% delay 50ms 10ms
    run_netem_test "4.13 Chaos: loss 15%% + dup 20%% + 50ms delay (10 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 40
}

# --- Test 4.14: Packet loss burst (Gilbertov model) ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_burst.bin"
    OUTPUT="$TMPDIR_BASE/output_burst.bin"
    gen_file "$INPUT" $((20*1024))

    # loss gemodel = Gilbertov-Elliottov model bursty loss
    netem_set "$PORT" loss gemodel 10% 25% 85% 50%
    run_netem_test "4.14 Bursty loss (Gilbert-Elliott model) (20 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 40
}

# --- Test 4.15: Prázdny vstup cez lossy kanál ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_empty_loss.bin"
    OUTPUT="$TMPDIR_BASE/output_empty_loss.bin"
    touch "$INPUT"

    netem_set "$PORT" loss 20% duplicate 10%
    run_netem_test "4.15 Prázdny vstup cez lossy kanál" \
        "$PORT" "$INPUT" "$OUTPUT" 20
}

# --- Test 4.16: stdin→stdout cez lossy kanál ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_stdio_loss.bin"
    gen_file "$INPUT" $((10*1024))
    cp "$INPUT" "$TMPDIR_BASE/stdin_input"

    netem_set "$PORT" loss 10%
    start_server "$PORT" "-" 30
    CLI_EXIT=$(run_client "127.0.0.1" "$PORT" "-" 30)
    SRV_EXIT=$(stop_all)
    netem_clear
    check_transfer "4.16 stdin→stdout cez 10%% loss (10 KB)" \
        "$INPUT" "$TMPDIR_BASE/srv_stdout" "$CLI_EXIT" "$SRV_EXIT"
}

# --- Test 4.17: Extrémne oneskorenie 200ms ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_delay200.bin"
    OUTPUT="$TMPDIR_BASE/output_delay200.bin"
    gen_file "$INPUT" $((5*1024))

    netem_set "$PORT" delay 200ms
    run_netem_test "4.17 200ms delay (5 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 40
}

# --- Test 4.18: Loss 5% + IPv6 (ak dostupné) ---
{
    if [ "$IPV6_OK" -eq 0 ]; then
        log_skip "4.18 IPv6 + loss — IPv6 nedostupné"
    else
        PORT=$(next_port)
        INPUT="$TMPDIR_BASE/input_ipv6_loss.bin"
        OUTPUT="$TMPDIR_BASE/output_ipv6_loss.bin"
        gen_file "$INPUT" $((10*1024))

        netem_set "$PORT" loss 5%
        run_netem_test "4.18 IPv6 + 5%% loss (10 KB)" \
            "$PORT" "$INPUT" "$OUTPUT" 30 "::1"
    fi
}

# --- Test 4.19: Packet loss 30% --- (stres pre retransmit)
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_loss30.bin"
    OUTPUT="$TMPDIR_BASE/output_loss30.bin"
    gen_file "$INPUT" $((5*1024))

    netem_set "$PORT" loss 30%
    run_netem_test "4.19 30%% packet loss (5 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 60
}

# --- Test 4.20: Corrupt 2% + loss 5% ---
{
    PORT=$(next_port)
    INPUT="$TMPDIR_BASE/input_corrupt_loss.bin"
    OUTPUT="$TMPDIR_BASE/output_corrupt_loss.bin"
    gen_file "$INPUT" $((10*1024))

    netem_set "$PORT" corrupt 2% loss 5%
    run_netem_test "4.20 corrupt 2%% + loss 5%% (10 KB)" \
        "$PORT" "$INPUT" "$OUTPUT" 40
}

# Upratanie netem po sekcii 4
netem_clear
log_info "tc netem pravidlá vyčistené"

fi  # HAS_TC

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

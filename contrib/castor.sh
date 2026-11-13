#!/usr/bin/env bash
# Run a Castor bridge on the same machine as a Bitcoin Core full node.
#
# Castor and Bitcoin Core are expected to run as different users (for example
# `bridgerunner` and `noderunner`). Run this script as the Castor user.
#
# Usage: contrib/castor.sh <command>
#
#   check     Check the setup: binaries, Core RPC, txindex, pruning, P2P port
#   hints     Download (mainnet) or generate the hintsfile
#   build     Build the forest once from Core's datadir (bootstrap)
#   start     Start the bridge in the background, restarting it if it exits
#   stop      Stop the bridge gracefully
#   restart   Stop, then start
#   status    Show whether the bridge is running
#   logs      Follow the bridge logs
#
# Configuration is read from the environment, or from the file named by
# CASTOR_CONFIG (default: ~/.config/castor/castor.env), for example:
#
#   NETWORK=bitcoin
#   BITCOIN_CORE_DATADIR=/var/lib/bitcoind
#   BITCOIN_CORE_COOKIE_FILE=/run/bitcoin-rpc/.cookie
#
# Running on the same machine as Core:
#   - The bridge listens on IPv4, on the network's default P2P port (8333 on
#     mainnet), so Utreexo nodes can reach it without extra configuration.
#     Keep Core off IPv4 port 8333: bind it to the host's IPv6 address
#     (`bind=[<ipv6>]:8333`), move it with `port=8335` (not 8334, which Core
#     uses for incoming Tor connections), or set `listen=0`.
#     See docs/same-host-setup.md.
#   - The Castor user must be able to read Core's RPC cookie. With Core's
#     `rpccookieperms=group`, add the Castor user to Core's group.
#   - `hints` (when generating) and `build` open Core's datadir directly. They
#     need write access to it, and Bitcoin Core should be stopped while they
#     run. Steady state (`start`) only uses RPC, so Core keeps running.
#   - When Core restarts, the bridge exits; this script restarts it, so it
#     reconnects with Core's new cookie.
set -euo pipefail

# --- Configuration -----------------------------------------------------------
CASTOR_CONFIG="${CASTOR_CONFIG:-$HOME/.config/castor/castor.env}"
if [[ -f "$CASTOR_CONFIG" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$CASTOR_CONFIG"
    set +a
fi

# Makes a path absolute, because the bridge runs from DATA_DIR.
absolute() { [[ "$1" == /* ]] && echo "$1" || echo "$PWD/$1"; }

SCRIPT="$(absolute "$0")"
NETWORK="${NETWORK:-bitcoin}"
CASTOR_BIN="$(absolute "${CASTOR_BIN:-$(command -v bridge || echo target/release/bridge)}")"
HINTS_BIN="$(absolute "${HINTS_BIN:-$(command -v bridge-hints || echo target/release/bridge-hints)}")"
DATA_DIR="$(absolute "${DATA_DIR:-$HOME/.bridge}")"
export DATA_DIR
HINTS_FILE="$(absolute "${HINTS_FILE:-$DATA_DIR/$NETWORK.hints}")"
POLLARD_MEMORY_MIB="${POLLARD_MEMORY_MIB:-250}"
RESTART_DELAY="${RESTART_DELAY:-10}"   # seconds between automatic restarts
STOP_TIMEOUT="${STOP_TIMEOUT:-600}"    # seconds to wait for a graceful shutdown

# Bitcoin Core. BITCOIN_CORE_DATADIR is only needed by `hints` and `build`.
export BITCOIN_CORE_DATADIR="${BITCOIN_CORE_DATADIR:-}"
export BITCOIN_CORE_COOKIE_FILE="${BITCOIN_CORE_COOKIE_FILE:-/run/bitcoin-rpc/.cookie}"
export BITCOIN_CORE_RPC_USER="${BITCOIN_CORE_RPC_USER:-}"
export BITCOIN_CORE_RPC_PASSWORD="${BITCOIN_CORE_RPC_PASSWORD:-}"

case "$NETWORK" in
    bitcoin)  default_rpc_port=8332  default_p2p_port=8333  ;;
    testnet)  default_rpc_port=18332 default_p2p_port=18333 ;;
    testnet4) default_rpc_port=48332 default_p2p_port=48333 ;;
    signet)   default_rpc_port=38332 default_p2p_port=38333 ;;
    regtest)  default_rpc_port=18443 default_p2p_port=18444 ;;
    *) echo "Unsupported NETWORK: $NETWORK" >&2; exit 2 ;;
esac
export BITCOIN_CORE_RPC_URL="${BITCOIN_CORE_RPC_URL:-127.0.0.1:$default_rpc_port}"
export P2P_HOST="${P2P_HOST:-0.0.0.0}"
# Utreexo nodes expect bridges on the network's default P2P port.
export P2P_PORT="${P2P_PORT:-$default_p2p_port}"

# Pre-built hintsfiles. Only a mainnet one is published.
if [[ "$NETWORK" == bitcoin ]]; then
    HINTS_URL="${HINTS_URL:-https://hints.lab.vinteum.org/bridge_hints_mainnet}"
else
    HINTS_URL="${HINTS_URL:-}"
fi

PID_FILE="$DATA_DIR/castor.pid"
OUT_LOG="$DATA_DIR/castor.out"   # terminal output; detailed logs: $DATA_DIR/debug.log
# ------------------------------------------------------------------------------

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
ok() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; failures=$((failures + 1)); }
warn() { printf '  [warn] %s\n' "$*"; }
die() { echo "Error: $*" >&2; exit 1; }

is_running() {
    [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

core_is_running() {
    pgrep -x bitcoind >/dev/null 2>&1
}

# The bridge binds IPv4 only, so only IPv4 listeners conflict with it. Core
# bound to an IPv6 address on the same port is fine.
port_in_use() {
    ss -4 -ltnH "sport = :$1" 2>/dev/null | grep -q .
}

PORT_IN_USE_HINT="probably by Bitcoin Core; keep Core off IPv4 port $P2P_PORT with \
bind=[<ipv6>]:$P2P_PORT, port=8335 or listen=0 in bitcoin.conf (see docs/same-host-setup.md)"

# Calls a Core RPC method and prints the JSON response.
core_rpc() {
    local credentials
    if [[ -n "$BITCOIN_CORE_RPC_USER" ]]; then
        credentials="$BITCOIN_CORE_RPC_USER:$BITCOIN_CORE_RPC_PASSWORD"
    else
        credentials="$(cat "$BITCOIN_CORE_COOKIE_FILE")"
    fi
    curl -sf --max-time 10 --user "$credentials" \
        -H 'content-type: text/plain' \
        --data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"castor\",\"method\":\"$1\",\"params\":[]}" \
        "http://$BITCOIN_CORE_RPC_URL/"
}

valid_hints_file() {
    [[ -f "$1" ]] && [[ "$(head -c 8 "$1")" == BRLFCT01 ]]
}

# Checks that `hints` and `build` can open Core's datadir.
require_core_datadir() {
    [[ -n "$BITCOIN_CORE_DATADIR" ]] ||
        die "set BITCOIN_CORE_DATADIR to Bitcoin Core's data directory (Core's -datadir)"
    [[ -d "$BITCOIN_CORE_DATADIR" ]] || die "$BITCOIN_CORE_DATADIR does not exist"
    [[ -w "$BITCOIN_CORE_DATADIR" ]] ||
        die "$(id -un) cannot write to $BITCOIN_CORE_DATADIR; bootstrap opens Core's \
databases and needs write access (or point BITCOIN_CORE_DATADIR at a copy)"
    if core_is_running && [[ "${FORCE:-0}" != 1 ]]; then
        die "bitcoind is running. Stop it while bootstrapping, because Castor opens its \
databases directly (or set FORCE=1 to try anyway)"
    fi
}

cmd_check() {
    failures=0
    echo "Castor setup ($NETWORK)"

    [[ -x "$CASTOR_BIN" ]] && ok "bridge: $CASTOR_BIN" || fail "bridge not found: $CASTOR_BIN"
    [[ -x "$HINTS_BIN" ]] && ok "bridge-hints: $HINTS_BIN" ||
        warn "bridge-hints not found: $HINTS_BIN (only needed to generate hints)"
    command -v curl >/dev/null && ok "curl available" || fail "curl is required"

    if [[ -z "$BITCOIN_CORE_RPC_USER" ]]; then
        if [[ -r "$BITCOIN_CORE_COOKIE_FILE" ]]; then
            ok "cookie readable: $BITCOIN_CORE_COOKIE_FILE"
        else
            fail "cannot read $BITCOIN_CORE_COOKIE_FILE: is bitcoind running, and is \
$(id -un) in its group (rpccookieperms=group)?"
        fi
    fi

    local info index
    if info="$(core_rpc getblockchaininfo 2>/dev/null)"; then
        ok "Core RPC reachable at $BITCOIN_CORE_RPC_URL"
        grep -q '"pruned":false' <<<"$info" && ok "Core is not pruned" ||
            fail "Core is pruned; set prune=0"
        grep -q "\"chain\":\"$(core_chain_name)\"" <<<"$info" ||
            fail "Core is not on $NETWORK; check NETWORK and BITCOIN_CORE_RPC_URL"
    else
        fail "cannot call Core RPC at $BITCOIN_CORE_RPC_URL"
    fi
    if index="$(core_rpc getindexinfo 2>/dev/null)"; then
        if grep -q '"txindex":{"synced":true' <<<"$index"; then
            ok "txindex is enabled and synced"
        elif grep -q '"txindex"' <<<"$index"; then
            warn "txindex is still syncing"
        else
            fail "txindex is disabled; set txindex=1"
        fi
    fi

    if is_running; then
        ok "bridge is running (pid $(cat "$PID_FILE"))"
    elif port_in_use "$P2P_PORT"; then
        fail "IPv4 port $P2P_PORT is already in use, $PORT_IN_USE_HINT"
    else
        ok "IPv4 port $P2P_PORT is free"
    fi
    [[ "$P2P_PORT" == "$default_p2p_port" ]] ||
        warn "P2P_PORT=$P2P_PORT is not $NETWORK's default port $default_p2p_port; \
Utreexo nodes may not find the bridge"

    if valid_hints_file "$HINTS_FILE"; then
        ok "hintsfile: $HINTS_FILE"
    else
        warn "no valid hintsfile at $HINTS_FILE; run: $0 hints"
    fi
    if [[ -e "$DATA_DIR/forest.dat" ]]; then
        ok "forest built: $DATA_DIR/forest.dat"
    else
        warn "forest not built yet; run: $0 build"
    fi

    local memlock
    memlock="$(ulimit -H -l)"
    [[ "$memlock" == unlimited ]] && ok "memlock limit is unlimited" ||
        warn "memlock hard limit is $memlock KiB; the forest build falls back to the \
page cache (raise it with LimitMEMLOCK=infinity or /etc/security/limits.conf)"

    ((failures == 0)) && echo "All checks passed." || { echo "$failures check(s) failed."; exit 1; }
}

core_chain_name() {
    case "$NETWORK" in
        bitcoin) echo main ;;
        testnet) echo test ;;
        *) echo "$NETWORK" ;;
    esac
}

cmd_hints() {
    mkdir -p "$(dirname "$HINTS_FILE")"
    if valid_hints_file "$HINTS_FILE" && [[ "${FORCE:-0}" != 1 ]]; then
        echo "Hintsfile already exists: $HINTS_FILE (set FORCE=1 to replace it)"
        return 0
    fi
    if [[ -n "$HINTS_URL" ]]; then
        echo "Downloading $HINTS_URL"
        curl -fL --retry 3 -o "$HINTS_FILE.part" "$HINTS_URL"
        valid_hints_file "$HINTS_FILE.part" ||
            { rm -f "$HINTS_FILE.part"; die "downloaded file is not a bridge hintsfile"; }
        mv "$HINTS_FILE.part" "$HINTS_FILE"
    else
        require_core_datadir
        [[ -x "$HINTS_BIN" ]] || die "bridge-hints not found: $HINTS_BIN"
        "$HINTS_BIN" --network "$NETWORK" --bitcoin-datadir "$BITCOIN_CORE_DATADIR" \
            --output "$HINTS_FILE" --force
    fi
    echo "Hintsfile ready: $HINTS_FILE"
}

cmd_build() {
    is_running && die "the bridge is running; stop it first"
    valid_hints_file "$HINTS_FILE" || die "no valid hintsfile at $HINTS_FILE; run: $0 hints"
    require_core_datadir
    [[ -x "$CASTOR_BIN" ]] || die "bridge not found: $CASTOR_BIN"
    mkdir -p "$DATA_DIR"
    ulimit -l "$(ulimit -H -l)" 2>/dev/null || true
    echo "Building the forest; this takes a long time. Start Bitcoin Core again afterwards."
    cd "$DATA_DIR"
    "$CASTOR_BIN" --network "$NETWORK" --build-forest "$HINTS_FILE" \
        --bitcoin-datadir "$BITCOIN_CORE_DATADIR"
}

# Runs the bridge in the foreground, restarting it whenever it exits, until
# this process receives SIGTERM or SIGINT.
supervise() {
    local child="" status stop_requested=0
    echo $$ >"$PID_FILE"
    # Forward SIGTERM, which the bridge handles as a graceful shutdown. Not
    # SIGINT: background jobs of a script start with SIGINT ignored.
    trap 'stop_requested=1; [[ -n "$child" ]] && kill -TERM "$child" 2>/dev/null || true' INT TERM
    trap 'rm -f "$PID_FILE"' EXIT
    # Start from DATA_DIR so a stray .env in another directory is not loaded.
    cd "$DATA_DIR"
    ulimit -l "$(ulimit -H -l)" 2>/dev/null || true
    while ((!stop_requested)); do
        log "starting bridge"
        "$CASTOR_BIN" --network "$NETWORK" --steady-state "$HINTS_FILE" \
            --pollard-memory-mib "$POLLARD_MEMORY_MIB" &
        child=$!
        status=0
        # `wait` returns early when a signal arrives; keep waiting for the
        # bridge to finish its graceful shutdown.
        while kill -0 "$child" 2>/dev/null; do
            wait "$child" && status=0 || status=$?
        done
        child=""
        ((stop_requested)) && break
        log "bridge exited with status $status; restarting in ${RESTART_DELAY}s"
        sleep "$RESTART_DELAY" &
        wait $! || true
    done
    log "stopped"
}

cmd_start() {
    if is_running; then
        echo "Already running (pid $(cat "$PID_FILE"))"
        return 0
    fi
    [[ -x "$CASTOR_BIN" ]] || die "bridge not found: $CASTOR_BIN"
    valid_hints_file "$HINTS_FILE" || die "no valid hintsfile at $HINTS_FILE; run: $0 hints"
    [[ -e "$DATA_DIR/forest.dat" ]] || die "forest not built; run: $0 build"
    port_in_use "$P2P_PORT" && die "IPv4 port $P2P_PORT is already in use, $PORT_IN_USE_HINT"
    mkdir -p "$DATA_DIR"

    # setsid: no controlling terminal, so closing the terminal sends no SIGHUP.
    setsid nohup "$SCRIPT" _supervise >>"$OUT_LOG" 2>&1 </dev/null &
    for _ in 1 2 3 4 5; do
        sleep 1
        is_running && break
    done
    is_running || { tail -n 20 "$OUT_LOG" >&2; die "the bridge failed to start"; }
    echo "Started (pid $(cat "$PID_FILE")). Output: $OUT_LOG, details: $DATA_DIR/debug.log"
}

cmd_stop() {
    if ! is_running; then
        echo "Not running"
        rm -f "$PID_FILE"
        return 0
    fi
    local pid
    pid="$(cat "$PID_FILE")"
    kill -TERM "$pid"
    printf 'Stopping (pid %s), flushing pending work' "$pid"
    for ((i = 0; i < STOP_TIMEOUT; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo " done"
            return 0
        fi
        printf '.'
        sleep 1
    done
    echo
    die "still running after ${STOP_TIMEOUT}s. Avoid kill -9: a hard kill during a \
database write may prevent the bridge from reopening its data"
}

case "${1:-}" in
    check) cmd_check ;;
    hints) cmd_hints ;;
    build) cmd_build ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_stop && cmd_start ;;
    status) is_running && echo "Running (pid $(cat "$PID_FILE"))" || { echo "Stopped"; exit 1; } ;;
    logs) exec tail -F "$OUT_LOG" "$DATA_DIR/debug.log" ;;
    _supervise) supervise ;;
    *) sed -n '2,/^set -euo/p' "$SCRIPT" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac

#!/usr/bin/env bash
#
# Run one automated TCP-reset delivery test against a single pinned Vector
# revision.
#
# The shape of the test:
#   1. Start the TCP server with a short idle timeout, collecting every line it
#      receives to a file (-o) and resetting connections rather than closing
#      them gracefully (-r).
#   2. Start Vector at the pinned SHA. It tees the file source into a local file
#      sink (ground truth for "what was ingested") and into the TCP sink under
#      test.
#   3. Generate numbered lines in bursts separated by idle pauses longer than
#      the server's timeout, so the connection is reset between bursts and the
#      sink must reconnect and retry.
#   4. Shut down cleanly, then assert every ingested line reached the server at
#      least once. Duplicates are allowed.
#
# Usage: run_test.sh <sha> [label]
# Exit status: 0 if no lines were lost, 1 otherwise.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
# shellcheck source=revisions.env
source "${HARNESS_DIR}/revisions.env"

SHA="${1:?usage: run_test.sh <sha> [label]}"
LABEL="${2:-${SHA:0:12}}"

# Tunables. Defaults are chosen so the reset window is wide enough to be
# reliable on a loaded CI box while keeping the run under a minute.
PORT="${PORT:-6100}"
SERVER_TIMEOUT="${SERVER_TIMEOUT:-2}"   # server resets after this many idle seconds
LINE_COUNT="${LINE_COUNT:-500}"
BURST="${BURST:-25}"
PAUSE="${PAUSE:-3}"                     # must exceed SERVER_TIMEOUT
SETTLE="${SETTLE:-8}"                   # drain time after the last line

RUN_DIR="${HARNESS_DIR}/run/${LABEL}"
SERVER_BIN="${REPO_DIR}/tcp_server"

VECTOR_PID=""
SERVER_PID=""

cleanup() {
    # Stop Vector first so it can flush, then the server so it can flush its
    # collection file. Killing in the other order would strand in-flight lines
    # and produce a false failure.
    if [[ -n "${VECTOR_PID}" ]] && kill -0 "${VECTOR_PID}" 2>/dev/null; then
        kill -TERM "${VECTOR_PID}" 2>/dev/null
        wait "${VECTOR_PID}" 2>/dev/null
    fi
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill -TERM "${SERVER_PID}" 2>/dev/null
        wait "${SERVER_PID}" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

if (( $(echo "${PAUSE} <= ${SERVER_TIMEOUT}" | bc -l) )); then
    echo "ERROR: PAUSE (${PAUSE}s) must exceed SERVER_TIMEOUT (${SERVER_TIMEOUT}s)," >&2
    echo "       otherwise the connection is never reset and the test proves nothing." >&2
    exit 2
fi

if [[ ! -x "${SERVER_BIN}" ]]; then
    echo "building tcp_server" >&2
    make -C "${REPO_DIR}" >&2 || exit 2
fi

VECTOR_BIN="$("${HARNESS_DIR}/build_vector.sh" "${SHA}")" || {
    echo "ERROR: failed to build Vector at ${SHA}" >&2
    exit 2
}

# Start from a clean slate: stale files from a previous run would corrupt the
# expected/received comparison.
rm -rf "${RUN_DIR}"
mkdir -p "${RUN_DIR}/data"

PIPE_LOG="${RUN_DIR}/pipe.log"
INGESTED_LOG="${RUN_DIR}/ingested.log"
RECEIVED_LOG="${RUN_DIR}/received.log"
CONFIG="${RUN_DIR}/vector.toml"
: > "${PIPE_LOG}"
: > "${RECEIVED_LOG}"

sed -e "s|@DATA_DIR@|${RUN_DIR}/data|g" \
    -e "s|@PIPE_LOG@|${PIPE_LOG}|g" \
    -e "s|@INGESTED_LOG@|${INGESTED_LOG}|g" \
    -e "s|@PORT@|${PORT}|g" \
    "${HARNESS_DIR}/vector.toml.tmpl" > "${CONFIG}"

echo
echo "=== Running delivery test [${LABEL}] ==="
echo "  vector:     ${VECTOR_BIN}"
echo "  revision:   ${SHA}"
echo "  lines:      ${LINE_COUNT} in bursts of ${BURST}, ${PAUSE}s idle between"
echo "  server:     127.0.0.1:${PORT}, resets after ${SERVER_TIMEOUT}s idle"
echo "  run dir:    ${RUN_DIR}"
echo

# 1. TCP server: collect lines, reset (not FIN) on timeout, quiet per-read trace.
"${SERVER_BIN}" -h 127.0.0.1 -p "${PORT}" -t "${SERVER_TIMEOUT}" \
    -o "${RECEIVED_LOG}" -q -r > "${RUN_DIR}/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the listener to be up before starting Vector.
for _ in $(seq 50); do
    grep -q "Server listening" "${RUN_DIR}/server.log" 2>/dev/null && break
    sleep 0.1
done
if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "ERROR: tcp_server exited during startup:" >&2
    cat "${RUN_DIR}/server.log" >&2
    exit 2
fi

# 2. Vector at the pinned revision.
"${VECTOR_BIN}" --config "${CONFIG}" > "${RUN_DIR}/vector.log" 2>&1 &
VECTOR_PID=$!

sleep 3
if ! kill -0 "${VECTOR_PID}" 2>/dev/null; then
    echo "ERROR: vector exited during startup:" >&2
    tail -40 "${RUN_DIR}/vector.log" >&2
    exit 2
fi

# 3. Generate the numbered lines.
python3 "${HARNESS_DIR}/generate.py" "${PIPE_LOG}" \
    --count "${LINE_COUNT}" --burst "${BURST}" --pause "${PAUSE}"

# Let the final batch drain and any last reconnect complete.
echo "settling for ${SETTLE}s"
sleep "${SETTLE}"

# 4. Shut down in flush-safe order, then assert.
cleanup
VECTOR_PID=""
SERVER_PID=""
# Give the OS a moment to finish flushing both files to disk.
sleep 1

RESETS=$(grep -c "connection timeout" "${RUN_DIR}/server.log" 2>/dev/null || true)
echo "connection resets observed: ${RESETS:-0}"
if [[ "${RESETS:-0}" -eq 0 ]]; then
    echo
    echo "ERROR: no connection resets occurred -- the test never exercised the" >&2
    echo "       reconnect path, so a PASS would be meaningless. Increase PAUSE" >&2
    echo "       or decrease SERVER_TIMEOUT." >&2
    exit 2
fi
echo

python3 "${HARNESS_DIR}/assert_no_loss.py" \
    --expected "${INGESTED_LOG}" \
    --received "${RECEIVED_LOG}" \
    --label "${LABEL}"

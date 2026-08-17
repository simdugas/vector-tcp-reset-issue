#!/usr/bin/env bash
#
# Run the delivery test against both pinned revisions and report the contrast.
#
# This is the entry point that answers the question the PR needs answered: the
# BEFORE revision should lose lines, the AFTER revision should not. A run where
# both pass is not a success -- it means the reproduction stopped reproducing,
# and the fix is no longer being demonstrated.
#
# Usage: run_comparison.sh

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=revisions.env
source "${HARNESS_DIR}/revisions.env"

# Distinct ports so a lingering socket from the first run can't interfere with
# the second.
PORT_BEFORE="${PORT_BEFORE:-6100}"
PORT_AFTER="${PORT_AFTER:-6101}"

echo "############################################"
echo "# BEFORE fix: ${BEFORE_SHA:0:12}"
echo "############################################"
PORT="${PORT_BEFORE}" "${HARNESS_DIR}/run_test.sh" "${BEFORE_SHA}" "before"
BEFORE_STATUS=$?

echo
echo "############################################"
echo "# AFTER fix:  ${AFTER_SHA:0:12}"
echo "############################################"
PORT="${PORT_AFTER}" "${HARNESS_DIR}/run_test.sh" "${AFTER_SHA}" "after"
AFTER_STATUS=$?

# Status 2 means the harness itself failed (build error, no resets observed),
# which is neither a pass nor a demonstrated loss.
if [[ ${BEFORE_STATUS} -eq 2 || ${AFTER_STATUS} -eq 2 ]]; then
    echo
    echo "HARNESS ERROR: a run failed to execute properly; results are not valid." >&2
    exit 2
fi

echo
echo "############################################"
echo "# Summary"
echo "############################################"
printf '  before (%s): %s\n' "${BEFORE_SHA:0:12}" \
    "$([[ ${BEFORE_STATUS} -eq 0 ]] && echo 'no loss' || echo 'LOST LINES')"
printf '  after  (%s): %s\n' "${AFTER_SHA:0:12}" \
    "$([[ ${AFTER_STATUS} -eq 0 ]] && echo 'no loss' || echo 'LOST LINES')"
echo

if [[ ${AFTER_STATUS} -ne 0 ]]; then
    echo "RESULT: FAIL -- the fix still loses lines on reconnect." >&2
    exit 1
fi

if [[ ${BEFORE_STATUS} -eq 0 ]]; then
    echo "RESULT: INCONCLUSIVE -- the fix loses nothing, but neither did the" >&2
    echo "        pre-fix revision, so this run did not reproduce the bug." >&2
    echo "        Widen the reset window (raise PAUSE, lower SERVER_TIMEOUT)" >&2
    echo "        or raise LINE_COUNT, then re-run." >&2
    exit 2
fi

echo "RESULT: PASS -- the pre-fix revision loses lines and the fix does not."

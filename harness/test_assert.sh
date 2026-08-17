#!/usr/bin/env bash
#
# Self-checks for assert_no_loss.py.
#
# The assertion is the part of the harness that decides pass/fail, so it needs
# its own verification: a bug here would silently invalidate every result. The
# masked-loss case is the important one -- it is exactly what a count-based
# check gets wrong.

set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSERT="${HARNESS_DIR}/assert_no_loss.py"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0

# check <name> <expected-exit> <expected-lines> <received-lines>
check() {
    local name="$1" want="$2" expected="$3" received="$4"

    printf '%b' "${expected}" > "${WORK}/exp.log"
    printf '%b' "${received}" > "${WORK}/rec.log"

    local output status
    output="$(python3 "${ASSERT}" --expected "${WORK}/exp.log" \
        --received "${WORK}/rec.log" --label "${name}" 2>&1)"
    status=$?

    if [[ ${status} -eq ${want} ]]; then
        printf 'ok   %-24s (exit %d)\n' "${name}" "${status}"
    else
        printf 'FAIL %-24s (exit %d, wanted %d)\n' "${name}" "${status}" "${want}"
        printf '%s\n' "${output}" | sed 's/^/       /'
        FAILURES=$((FAILURES + 1))
    fi
}

FIVE='line-1\nline-2\nline-3\nline-4\nline-5\n'

# Clean delivery: everything arrived exactly once.
check "exact-match" 0 "${FIVE}" "${FIVE}"

# At-least-once retry duplicated two lines. Allowed.
check "duplicates-allowed" 0 "${FIVE}" \
    'line-1\nline-2\nline-2\nline-3\nline-4\nline-4\nline-5\n'

# A line is missing. Must fail.
check "missing-line" 1 "${FIVE}" 'line-1\nline-2\nline-4\nline-5\n'

# The case a count-based check gets wrong: line-3 is lost but line-2 is
# duplicated, so both files hold 5 lines. Identity comparison must still fail.
check "masked-loss-equal-count" 1 "${FIVE}" \
    'line-1\nline-2\nline-2\nline-4\nline-5\n'

# Whole trailing burst lost, as happens when the final batch is dropped.
check "trailing-burst-lost" 1 "${FIVE}" 'line-1\nline-2\n'

# Nothing arrived at all.
check "received-empty" 1 "${FIVE}" ''

# Reordered delivery is not loss -- order is not part of the contract.
check "reordered-ok" 0 "${FIVE}" 'line-3\nline-1\nline-5\nline-2\nline-4\n'

# Blank lines and trailing whitespace must not register as missing data.
check "whitespace-tolerated" 0 "${FIVE}" \
    'line-1\n\nline-2\nline-3\n\nline-4\nline-5\n\n'

echo
if [[ ${FAILURES} -eq 0 ]]; then
    echo "all assertion self-checks passed"
    exit 0
fi
echo "${FAILURES} assertion self-check(s) failed" >&2
exit 1

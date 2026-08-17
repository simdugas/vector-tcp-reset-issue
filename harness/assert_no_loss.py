#!/usr/bin/env python3
"""Assert that no ingested line is missing from the TCP sink's output.

The socket sink offers at-least-once delivery: after a connection reset it
retries the in-flight batch, which can legitimately duplicate lines that the
server already received. So the assertion is set inclusion, not equality --
every expected line must appear at least once, and duplicates are reported but
do not fail the run.

Exit status is 0 when nothing is missing and 1 when any expected line is
absent, which is what makes this usable as an automated test.
"""

import argparse
import re
import sys
from collections import Counter


LINE_RE = re.compile(r"^(?P<prefix>.*)-(?P<seq>\d+)$")


def read_lines(path: str) -> list[str]:
    """Read a file into a list of non-empty, stripped lines."""
    try:
        with open(path, "r") as f:
            return [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        sys.exit(f"FAIL: {path} does not exist -- did the run produce any output?")


def seq_of(line: str) -> int | None:
    """Extract the trailing sequence number from a '<prefix>-<n>' line."""
    match = LINE_RE.match(line)
    return int(match.group("seq")) if match else None


def summarize_ranges(seqs: list[int]) -> str:
    """Collapse a sorted sequence list into compact 'a-b, c' range notation."""
    if not seqs:
        return "none"

    ranges: list[tuple[int, int]] = []
    start = prev = seqs[0]
    for seq in seqs[1:]:
        if seq == prev + 1:
            prev = seq
        else:
            ranges.append((start, prev))
            start = prev = seq
    ranges.append((start, prev))

    return ", ".join(str(a) if a == b else f"{a}-{b}" for a, b in ranges)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--expected",
        required=True,
        help="File of lines Vector ingested (written by the local file sink)",
    )
    parser.add_argument(
        "--received",
        required=True,
        help="File of lines the TCP server collected (written with -o)",
    )
    parser.add_argument(
        "--label",
        default="",
        help="Label for this run, used in the report header",
    )
    args = parser.parse_args()

    expected_lines = read_lines(args.expected)
    received_lines = read_lines(args.received)

    if not expected_lines:
        sys.exit(f"FAIL: {args.expected} is empty -- Vector ingested nothing")

    expected = Counter(expected_lines)
    received = Counter(received_lines)

    missing = sorted(expected - received)
    # Anything received more times than it was ingested is a retry duplicate.
    duplicated = sorted((received - expected).elements())
    # Lines the server saw that Vector never ingested would mean the two files
    # disagree about reality -- worth surfacing, though not a delivery bug.
    unexpected = sorted(set(received) - set(expected))

    header = f"Delivery report{f' [{args.label}]' if args.label else ''}"
    print(header)
    print("=" * len(header))
    print(f"  ingested (expected): {len(expected_lines):>6} lines, {len(expected):>6} unique")
    print(f"  received  (on wire): {len(received_lines):>6} lines, {len(received):>6} unique")
    print(f"  duplicated (allowed): {len(duplicated):>5}")
    print(f"  missing    (failure): {len(missing):>5}")

    if duplicated:
        dup_seqs = sorted(s for s in (seq_of(line) for line in set(duplicated)) if s is not None)
        if dup_seqs:
            print(f"\n  duplicate sequences: {summarize_ranges(dup_seqs)}")
        print("  (duplicates are expected under at-least-once retry -- not a failure)")

    if unexpected:
        print(f"\n  WARNING: {len(unexpected)} line(s) received but never ingested:")
        for line in unexpected[:10]:
            print(f"    {line}")
        if len(unexpected) > 10:
            print(f"    ... and {len(unexpected) - 10} more")

    if missing:
        missing_seqs = sorted(s for s in (seq_of(line) for line in missing) if s is not None)
        print(f"\nFAIL: {len(missing)} ingested line(s) never reached the TCP server.")
        if missing_seqs:
            print(f"  missing sequences: {summarize_ranges(missing_seqs)}")
        else:
            for line in missing[:20]:
                print(f"    {line}")
        return 1

    print("\nPASS: every ingested line reached the TCP server at least once.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

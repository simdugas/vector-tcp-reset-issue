#!/usr/bin/env python3
"""Append a bounded, deterministic sequence of numbered lines to a log file.

Unlike ``append.py``, which runs forever at a fixed interval, this generator
writes an exact, known number of lines in bursts separated by idle pauses. The
pauses are what make the test meaningful: the TCP server resets connections on
an idle timeout, so a pause longer than that timeout forces a reset between
bursts. Every burst after the first therefore lands on a connection that the
sink has had to re-establish.

Each line carries its own sequence number, so loss is detected by identity
rather than by count -- losing line 7 while duplicating line 8 keeps the total
unchanged but is still a bug.
"""

import argparse
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", help="Path to the log file to append to")
    parser.add_argument(
        "--count",
        "-n",
        type=int,
        default=500,
        help="Total number of lines to write (default: 500)",
    )
    parser.add_argument(
        "--burst",
        "-b",
        type=int,
        default=25,
        help="Lines per burst before pausing (default: 25)",
    )
    parser.add_argument(
        "--pause",
        "-P",
        type=float,
        default=3.0,
        help=(
            "Idle seconds between bursts. Must exceed the TCP server's idle "
            "timeout to force a reset (default: 3.0)"
        ),
    )
    parser.add_argument(
        "--interval",
        "-i",
        type=float,
        default=0.0,
        help="Seconds between lines within a burst (default: 0.0)",
    )
    parser.add_argument(
        "--prefix",
        default="line",
        help="Line prefix; output is '<prefix>-<n>' (default: line)",
    )
    args = parser.parse_args()

    if args.count < 1:
        parser.error("--count must be at least 1")
    if args.burst < 1:
        parser.error("--burst must be at least 1")

    with open(args.file, "a") as f:
        for i in range(1, args.count + 1):
            f.write(f"{args.prefix}-{i}\n")
            # Flush per line so the file source sees data as it is produced
            # rather than in Python-buffered chunks.
            f.flush()

            if args.interval > 0:
                time.sleep(args.interval)

            # Pause after completing a burst, but not after the final line --
            # trailing idle time is the caller's business.
            if i % args.burst == 0 and i != args.count:
                print(f"wrote {i}/{args.count} lines, idling {args.pause}s", flush=True)
                time.sleep(args.pause)

    print(f"wrote {args.count}/{args.count} lines", flush=True)


if __name__ == "__main__":
    main()

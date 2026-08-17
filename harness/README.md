# Automated TCP Reset Delivery Test

An automated regression test for [vectordotdev/vector#25132][pr]. Where the
manual demo in the repository root relies on visually scanning for skipped
numbers, this harness pins exact Vector revisions, collects numbered lines
mechanically, and asserts on them — so the result is a pass/fail exit code
rather than a screenshot.

[pr]: https://github.com/vectordotdev/vector/pull/25132

## What it asserts

The socket sink provides **at-least-once** delivery. After a connection reset it
retries the in-flight batch, which can legitimately deliver some lines twice.
The assertion is therefore **set inclusion, not equality**:

- **Every ingested line must arrive at least once** — a missing line is a failure.
- **Duplicates are reported but allowed** — they are correct retry behavior.

This distinction matters. A test that merely compares line *counts* can pass
while data is lost: losing line 7 and duplicating line 8 leaves the total
unchanged. Because every line carries its own sequence number, loss is detected
by identity, and that exact case is covered by the checks in
[Verifying the harness](#verifying-the-harness).

## How it works

```
generate.py ──> pipe.log ──> [ file source ]
                                   │
                    ┌──────────────┴──────────────┐
                    v                             v
            [ file sink ]                  [ socket sink ]
            ingested.log                        │  TCP
          (ground truth)                        v
                                    tcp_server -o received.log
                                    (resets connection on idle timeout)
                                                 │
                    └────────> assert_no_loss.py <┘
                          expected ⊆ received ?
```

Two details make the result trustworthy:

**Ground truth comes from Vector, not the generator.** The file source is teed
into a local file sink, so `ingested.log` records what Vector actually read.
Comparing the TCP output against *that* isolates the socket sink: a line the
file source never picked up cannot be blamed on the sink.

**A run that never resets is not a pass.** The generator writes in bursts
separated by idle pauses longer than the server's idle timeout, forcing a reset
between bursts. `run_test.sh` counts the resets in the server log and exits `2`
if none occurred, because a clean run that never exercised reconnect proves
nothing.

## Usage

### Prerequisites

- GCC, Python 3.9+, and a Rust toolchain (the pinned revisions build with 1.95)
- `git`, `bc`
- `protoc` and `cmake` — required by Vector's build scripts
  (macOS: `brew install protobuf cmake`, Debian:
  `apt-get install -y protobuf-compiler cmake`).
  `build_vector.sh` checks for them up front rather than failing mid-build; set
  `PROTOC` if yours is not on `PATH`. The Vector repo ships a
  [Flox](https://flox.dev) environment that provides both, so running the
  harness from inside `flox activate` in a Vector checkout also satisfies this.
- ~10 GB disk for the Vector clone, worktrees, and shared cargo target dir

### Start here: check the assertion logic

This needs no Vector build and finishes in about a second. It is the fastest way
to confirm the harness is intact:

```bash
make test-assert          # from the repository root
```

### Run both revisions and compare

From the repository root:

```bash
make            # build tcp_server, the collector
make test       # run both pinned revisions and compare
```

Expect the pre-fix revision to lose lines and the fixed revision to lose none;
the run ends with a `RESULT:` line. With both binaries already cached this takes
roughly two minutes.

`make test` works without a build toolchain as long as the binaries are cached,
because `build_vector.sh` checks its cache before checking for `protoc`.

#### First run, or after `make clean-harness`

Building Vector needs `protoc` and `cmake`. The Vector repo's Flox environment
provides both, so the simplest route is to run the harness inside it:

```bash
cd harness
flox activate --dir ~/source/vector -- sh -c './run_comparison.sh'
```

Budget around 10 minutes per revision for a cold release build (two revisions,
built sequentially). The second is not much faster than the first: they share a
cargo target dir, but `lto = "fat"` means the final link dominates either way.

By default this clones Vector into `harness/.cache/`. To reuse a checkout you
already have — much faster, and no multi-gigabyte download:

```bash
flox activate --dir ~/source/vector -- sh -c \
  'VECTOR_LOCAL_CHECKOUT=~/source/vector ./run_comparison.sh'
```

The local clone is only ever read from. Each revision is built in its own
detached `git worktree`, so your HEAD, branches, and uncommitted work are left
untouched. Remove the worktrees when you are done:

```bash
git -C ~/source/vector worktree prune          # after make clean-harness
```

### Run a single revision

```bash
./run_test.sh <sha> [label]
```

Exit codes: `0` no loss, `1` lines lost, `2` the harness itself could not
produce a valid result (build failure, or no resets observed).

### Reading the output

Each run leaves its artifacts in `run/<label>/`, preserved for inspection:

| File | What it holds |
| --- | --- |
| `ingested.log` | What Vector read from the source — the expected set |
| `received.log` | What the TCP server actually collected |
| `vector.log` | Vector's own log; `grep 'Connection reset'` for the sink errors |
| `server.log` | Connection lifecycle, including each reset |
| `pipe.log` | The generated numbered lines |
| `vector.toml` | The config used, rendered from the template |

To confirm a run genuinely exercised the failure path rather than avoiding it:

```bash
grep -c 'connection timeout' run/after-*/server.log   # resets the server forced
grep 'Connection reset' run/after-*/vector.log        # the sink hitting them
```

`run_comparison.sh` labels its runs `before-<sha>` and `after-<sha>`, so results
from different commits sit side by side rather than overwriting each other.

### Tunables

Environment variables accepted by `run_test.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `6100` | TCP server listen port |
| `SERVER_TIMEOUT` | `2` | Idle seconds before the server resets a connection |
| `LINE_COUNT` | `500` | Total numbered lines to send |
| `BURST` | `25` | Lines per burst before pausing |
| `PAUSE` | `3` | Idle seconds between bursts (must exceed `SERVER_TIMEOUT`) |
| `SETTLE` | `8` | Drain time after the last line |

`PAUSE` must exceed `SERVER_TIMEOUT`; the harness refuses to run otherwise,
since without a reset there is nothing to test.

If a run exits `2` reporting no resets, widen the reset window:

```bash
PAUSE=5 SERVER_TIMEOUT=1 LINE_COUNT=1000 ./run_test.sh <sha>
```

### Cleaning up

```bash
make clean-runs      # per-run artifacts only; keeps the expensive build cache
make clean-harness   # everything, including cached Vector builds (~10 GB)
```

## Pinned revisions

Revisions are pinned as exact SHAs in [`revisions.env`](./revisions.env) — a
branch name moves, a SHA does not, so a recorded result stays reproducible.
Update them when the PR is rebased, and re-record the results below.

### Testing a different commit

Both SHAs are environment-overridable, so a one-off run needs no file edit:

```bash
BEFORE_SHA=<base> AFTER_SHA=<fix> ./run_comparison.sh
```

**Pair the fix with its own merge base.** Whenever the fix branch is rebased or
merges master, its baseline moves with it:

```bash
git -C ~/source/vector merge-base <after-sha> origin/master   # → BEFORE_SHA
```

Testing a merged fix against a stale base sweeps every unrelated master change
in between into the comparison, so a difference in results can no longer be
attributed to the socket sink. Same-merge-base pairing keeps the sink the only
variable.

Edit `revisions.env` instead of exporting when the new pair is the one that
should be recorded, and refresh the results below in the same change.

Vector is built with `--no-default-features --features
sources-file,sinks-socket,sinks-file`, which is everything the harness config
needs and far cheaper than a full build.

## Recorded results

From `./run_comparison.sh` at the defaults (500 lines, bursts of 25, 3s idle,
2s server timeout) on macOS aarch64:

| Revision | Resets | Ingested | Received | Missing | Result |
| --- | --- | --- | --- | --- | --- |
| `8bd193189671` (before) | 11 | 500 | 275 | **225** | LOST LINES |
| `178c470bad20` (after) | 12 | 500 | 500 | 0 | no loss |

The pre-fix losses arrive in whole-burst blocks — `26-50, 76-100, 126-150,
176-200, 226-250, 326-350, 376-400, 426-450, 476-500` — which is the signature
of a batch discarded when the connection dropped, rather than scattered
individual drops.

Both runs logged the same underlying failure on the sink, confirming the fixed
revision took the error path and recovered rather than simply avoiding it:

```
ERROR sink{component_id=socket_out component_type=socket}: Error sending data.
      error=Connection reset by peer (os error 54) error_code="socket_send"
      error_type="writer_failed" stage="sending" mode=tcp
```

Reset counts vary run to run with timing; the pass/fail outcome does not.

## Verifying the harness

The assertion logic decides pass/fail, so it has its own checks — including the
masked-loss case where a duplicate hides a missing line and the totals match,
which is exactly what a count-based check gets wrong:

```bash
./test_assert.sh          # or: make test-assert, from the repository root
```

All eight checks should report `ok`.

## Files

| File | Purpose |
| --- | --- |
| `run_comparison.sh` | Entry point: runs both revisions, compares, summarizes |
| `run_test.sh` | One full run against a single pinned revision |
| `build_vector.sh` | Builds/caches a Vector binary at an exact SHA via worktree |
| `revisions.env` | Pinned `BEFORE_SHA` / `AFTER_SHA` and build features |
| `vector.toml.tmpl` | Vector config: file source teed to file sink + socket sink |
| `generate.py` | Writes N numbered lines in bursts with idle pauses |
| `assert_no_loss.py` | Set-inclusion assertion; allows duplicates, fails on loss |
| `test_assert.sh` | Self-checks for the assertion logic |

Per-run artifacts land in `run/<label>/` (config, both logs, collected lines)
and are preserved after the run for inspection.

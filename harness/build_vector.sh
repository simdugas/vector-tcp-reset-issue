#!/usr/bin/env bash
#
# Build a Vector binary at an exact pinned commit SHA.
#
# Each SHA is built in its own git worktree so no checkout is ever mutated in
# place -- pointing VECTOR_LOCAL_CHECKOUT at a working Vector clone is safe and
# will not move its HEAD or touch its branches. Worktrees share the parent
# repo's object store, so the second one costs no network and little disk.
#
# All builds share one CARGO_TARGET_DIR, so building the second revision only
# recompiles crates that actually differ between the two SHAs. Finished
# binaries are cached by SHA, making re-runs of the test suite immediate.
#
# Usage: build_vector.sh <sha>
#   Prints the absolute path of the built binary on stdout. All progress output
#   goes to stderr so the path can be captured directly.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=revisions.env
source "${HARNESS_DIR}/revisions.env"

SHA="${1:?usage: build_vector.sh <sha>}"
SHORT="${SHA:0:12}"

# Vector's build scripts invoke protoc (lib/vector-core/build.rs) and cmake.
# Check up front rather than letting cargo fail minutes into a release build.
if [[ -z "${PROTOC:-}" ]] && ! command -v protoc >/dev/null 2>&1; then
    echo "ERROR: protoc not found, but Vector's build requires it." >&2
    echo "       Install it (macOS: 'brew install protobuf', Debian:" >&2
    echo "       'apt-get install -y protobuf-compiler'), set PROTOC to the" >&2
    echo "       path of an existing binary, or run this from inside" >&2
    echo "       'flox activate' in a Vector checkout." >&2
    exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "ERROR: cmake not found, but Vector's build requires it." >&2
    echo "       Install it (macOS: 'brew install cmake', Debian:" >&2
    echo "       'apt-get install -y cmake')." >&2
    exit 1
fi

CACHE_DIR="${HARNESS_DIR}/.cache"
CLONE_DIR="${CACHE_DIR}/vector-src"
WORKTREE_DIR="${CACHE_DIR}/wt-${SHORT}"
BIN_DIR="${CACHE_DIR}/bin"
BIN_PATH="${BIN_DIR}/vector-${SHORT}"

mkdir -p "${BIN_DIR}"

if [[ -x "${BIN_PATH}" ]]; then
    echo "using cached binary for ${SHORT}" >&2
    echo "${BIN_PATH}"
    exit 0
fi

# Reuse an existing local Vector clone when one is available -- the common case
# when iterating on the fix, and it avoids a multi-gigabyte network clone.
# It is only ever read from; the build happens in a separate worktree.
SOURCE_REPO="${VECTOR_LOCAL_CHECKOUT:-${CLONE_DIR}}"

if [[ -n "${VECTOR_LOCAL_CHECKOUT:-}" ]]; then
    echo "using local checkout as object source: ${VECTOR_LOCAL_CHECKOUT}" >&2
elif [[ ! -d "${CLONE_DIR}/.git" ]]; then
    echo "cloning ${VECTOR_REPO} -> ${CLONE_DIR} (this takes a while)" >&2
    mkdir -p "${CACHE_DIR}"
    git clone "${VECTOR_REPO}" "${CLONE_DIR}" >&2
fi

# Fetch only when the SHA is missing, so cached runs work offline.
if ! git -C "${SOURCE_REPO}" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
    echo "commit ${SHORT} not present locally; fetching" >&2
    git -C "${SOURCE_REPO}" fetch --all --tags >&2 || true
fi

if ! git -C "${SOURCE_REPO}" cat-file -e "${SHA}^{commit}" 2>/dev/null; then
    echo "ERROR: commit ${SHA} not found in ${SOURCE_REPO}" >&2
    echo "       Check BEFORE_SHA/AFTER_SHA in harness/revisions.env, or set" >&2
    echo "       VECTOR_REPO to a remote that carries both commits." >&2
    exit 1
fi

# Create the worktree if it isn't already there from an interrupted run.
if [[ ! -d "${WORKTREE_DIR}" ]]; then
    echo "creating worktree for ${SHORT}" >&2
    git -C "${SOURCE_REPO}" worktree add --detach "${WORKTREE_DIR}" "${SHA}" >&2
fi

pushd "${WORKTREE_DIR}" >/dev/null

# Confirm the worktree really is at the pinned commit. A stale worktree from a
# previous run at a different SHA would silently test the wrong code.
ACTUAL="$(git rev-parse HEAD)"
if [[ "${ACTUAL}" != "${SHA}" ]]; then
    echo "worktree at ${ACTUAL:0:12}, resetting to ${SHORT}" >&2
    git -c advice.detachedHead=false checkout --force --detach "${SHA}" >&2
fi

git submodule update --init --recursive >&2

echo "building Vector at ${SHORT} (features: ${VECTOR_FEATURES})" >&2
# Shared target dir across revisions: the second build reuses unchanged crates.
export CARGO_TARGET_DIR="${CACHE_DIR}/target"
cargo build --release --no-default-features --features "${VECTOR_FEATURES}" >&2

install -m 755 "${CARGO_TARGET_DIR}/release/vector" "${BIN_PATH}"
popd >/dev/null

# Verify the binary actually reports the revision we asked for, so a stale
# build can never masquerade as the revision under test.
echo "built $(basename "${BIN_PATH}"): $("${BIN_PATH}" --version 2>/dev/null | head -1)" >&2

echo "${BIN_PATH}"

#!/usr/bin/env bash
# Read a recruiter take-home inside locked containers. Run none of it.
#
#   inspect-takehome.sh <https link | path to .zip/.tar.gz | path to folder>
#
# Step 1 (unpack): a throwaway container gets the files into a private
#   container volume. Network is on only for a web link, to download it.
# Step 2 (read): a second container with NO network, a read-only copy of the
#   files and no root reads them and prints a JSON report.
# The take-home never lands in your own folders, so your editor can't
# auto-run anything in it.
#
# Exit codes: 0 report printed · 2 bad usage · 3 Docker missing (NOT checked)
#             4 unpack refused or failed, or reader failed (NOT checked)
set -euo pipefail

IMAGE="${INSPECT_IMAGE:-python:3.12-alpine}"
TIME_LIMIT="${INSPECT_TIME_LIMIT:-180}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 1 ]; then
  echo "usage: $(basename "$0") <https link | archive | folder>" >&2
  exit 2
fi
SOURCE="$1"

if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  echo '{"risk": "unknown", "note": "Docker is not running, so the code was NOT checked. Do not treat this as safe."}'
  exit 3
fi

LOCKED=(--rm --read-only --cap-drop ALL --security-opt no-new-privileges
        --user 65534:65534 --memory 512m --pids-limit 128 --cpus 1
        --tmpfs /tmp:rw,noexec,nosuid,size=64m
        -v "$SCRIPTS:/scripts:ro")

VOLUME="rdd-inspect-$$-$RANDOM"
cleanup() { docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker volume create --label rdd-inspect=1 "$VOLUME" >/dev/null
# Hand the empty volume to the unprivileged user. Nothing untrusted is present yet.
docker run --rm -v "$VOLUME:/work" "$IMAGE" chown 65534:65534 /work >/dev/null

run_with_limit() {
  local name="$1"; shift
  docker run --name "$name" "$@" &
  local pid=$!
  # Watchdog: kill the container if it runs past the limit. Its output goes to
  # /dev/null so a leftover timer never holds the report pipe open.
  (
    sleep "$TIME_LIMIT" & timer=$!
    trap 'kill "$timer" 2>/dev/null; exit 0' TERM
    wait "$timer"
    docker kill "$name"
  ) >/dev/null 2>&1 &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$status"
}

not_checked() {  # print a "not checked" report and stop. Never let a failure read as safe.
  python3 -c 'import json,sys; print(json.dumps({"risk": "unknown", "note": "The take-home was NOT checked: " + sys.argv[1] + " Do not treat this as safe."}, indent=2))' "$1"
  exit 4
}

# Step 1: unpack
UNPACK_LOG="$(mktemp)"
if [[ "$SOURCE" == https://* ]]; then
  run_with_limit "unpack-$VOLUME" "${LOCKED[@]}" --network bridge \
    -v "$VOLUME:/work" "$IMAGE" python -I -B /scripts/unpack.py "$SOURCE" >"$UNPACK_LOG" 2>&1 \
    || not_checked "unpacking failed or was refused ($(tail -1 "$UNPACK_LOG"))."
else
  [ -e "$SOURCE" ] || { echo "not found: $SOURCE" >&2; exit 2; }
  ABS="$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"
  case "$ABS" in *,*) not_checked "the path has a comma in it; rename the file or folder and retry." ;; esac
  # Mount under a cleaned-up name so odd characters never reach Docker's options.
  NAME="$(basename "$ABS" | LC_ALL=C tr -c 'A-Za-z0-9._\n-' '_' | sed 's/^\.*//')"
  run_with_limit "unpack-$VOLUME" "${LOCKED[@]}" --network none \
    --mount "type=bind,src=$ABS,dst=/input/${NAME:-item},readonly" -v "$VOLUME:/work" \
    "$IMAGE" python -I -B /scripts/unpack.py "/input/${NAME:-item}" >"$UNPACK_LOG" 2>&1 \
    || not_checked "unpacking failed or was refused ($(tail -1 "$UNPACK_LOG"))."
fi
rm -f "$UNPACK_LOG"

# Step 2: read, with no network and a read-only copy
run_with_limit "read-$VOLUME" "${LOCKED[@]}" --network none \
  -v "$VOLUME:/work:ro" "$IMAGE" python -I -B /scripts/reader.py /work/takehome \
  || not_checked "the reader failed or ran out of time."

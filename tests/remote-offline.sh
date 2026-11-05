#!/usr/bin/env bash
# Check --remote without GitHub: a stand-in gh (tests/stub-gh) acts as the
# codespace, so this runs the full flow with real Docker on this machine.
# Proves: the report comes back, archives travel packed, every failure reads
# "unknown", and the codespace is deleted every time.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export STUB_LOG="$T/log" STUB_STATE="$T/state" RDD_REMOTE_REPO=test/repo
STUB_PATH="$PWD/tests/stub-gh:$PATH"

run() {  # run <name> <want risk> <want exit> <input> [env...]
  local name="$1" want="$2" wantcode="$3" input="$4"; shift 4
  rm -rf "$T/state" "$T/space" "$T/log"; mkdir -p "$T/state"
  local out code
  out="$(env PATH="$STUB_PATH" RDD_REMOTE_DIR="$T/space" "$@" scripts/inspect-takehome.sh --remote "$input" 2>"$T/err")"; code=$?
  local got; got="$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["risk"])' 2>/dev/null)"
  if [ "$got" != "$want" ] || [ "$code" != "$wantcode" ]; then
    echo "FAIL $name: risk '$got' exit $code, wanted $want exit $wantcode"; cat "$T/err"; fails=$((fails+1)); return 1
  fi
  REPORT="$out"
  echo "pass $name -> $got (exit $code)"
}
gone() {  # the codespace must not exist after any run that created one
  if [ -s "$T/state/alive" ]; then echo "FAIL $1: codespace left running"; fails=$((fails+1)); fi
}

run "zip in codespace" high 0 tests/fixtures/fake-recruiter-takehome.zip && {
  printf '%s' "$REPORT" | grep -q '"codespace": "deleted (stub-space-1)"' || { echo "FAIL zip: report does not say deleted"; fails=$((fails+1)); }
  printf '%s' "$REPORT" | grep -q '"where": "codespace"' || { echo "FAIL zip: report does not say where"; fails=$((fails+1)); }
  # The zip travelled packed: the only thing copied in is the .zip file itself.
  [ "$(ls "$T/space/input")" = "fake-recruiter-takehome.zip" ] || { echo "FAIL zip: input was not the packed zip"; fails=$((fails+1)); }
}
gone "zip"
run "folder in codespace" low 0 tests/fixtures/clean-takehome; gone "folder"
run "folder with tricks" high 0 tests/fixtures/fake-recruiter-takehome; gone "folder tricks"

# Failures must read "unknown" and still delete the codespace.
run "no codespace permission" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=auth
grep -q "codespace create" "$T/log" && { echo "FAIL auth: created a codespace anyway"; fails=$((fails+1)); }
run "create fails" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=create; gone "create"
run "create half-fails, name printed" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=create-partial; gone "create-partial"
run "create half-fails, no name" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=create-silent; gone "create-silent"
run "docker never ready" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=ssh; gone "ssh"
run "copy fails" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=upload; gone "copy"
run "connection drops mid-scan" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=scan; gone "scan"
run "malformed report" unknown 4 tests/fixtures/clean-takehome STUB_FAIL=badreport; gone "badreport"

# A codespace we cannot confirm deleted is never reported as deleted (exit 5).
run "delete fails" low 5 tests/fixtures/clean-takehome STUB_FAIL=keep && {
  printf '%s' "$REPORT" | grep -q 'NOT deleted' || { echo "FAIL keep: report hides the leftover codespace"; fails=$((fails+1)); }
}
run "list fails after delete" low 5 tests/fixtures/clean-takehome STUB_FAIL=list-after-delete && {
  printf '%s' "$REPORT" | grep -q 'NOT deleted' || { echo "FAIL list-after-delete: claimed deleted without proof"; fails=$((fails+1)); }
}

# Review findings, 4 Nov night: folder paths, odd names, settings.
mkdir -p "$T/hookdir/.git/hooks"; printf '#!/bin/sh\necho hi\n' > "$T/hookdir/.git/hooks/pre-commit"
run "git hook in folder" high 0 "$T/hookdir"; gone "hookdir"
mkdir -p -- "$T/-x"; cp tests/fixtures/fake-recruiter-takehome/package.json "$T/-x/"
run "folder named -x" high 0 "$T/-x"; gone "dash folder"
out="$(env PATH="$STUB_PATH" RDD_REMOTE_DIR="/tmp/rdd'; echo INJECTED; #" scripts/inspect-takehome.sh --remote tests/fixtures/clean-takehome 2>&1)"; code=$?
if [ "$code" = 2 ] && ! printf '%s' "$out" | grep -q INJECTED; then echo "pass odd RDD_REMOTE_DIR refused"; else echo "FAIL odd RDD_REMOTE_DIR: exit $code"; fails=$((fails+1)); fi

# A scan that comes back "unknown" exits 4 locally too, even though
# gh codespace ssh turns the remote 4 into 1 (seen on a live run, 4 Nov).
python3 -c '
import zipfile,sys
with zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED) as z:
    with z.open("zeros.bin","w",force_zip64=True) as f:
        chunk=b"\0"*(1<<20)
        for _ in range(1100): f.write(chunk)
' "$T/bomb.zip"
run "bomb in codespace" unknown 4 "$T/bomb.zip"; gone "bomb"

# gh missing must never read as safe.
out="$(PATH=/usr/bin:/bin scripts/inspect-takehome.sh --remote tests/fixtures/clean-takehome 2>/dev/null)"; code=$?
if [ "$code" = 4 ] && printf '%s' "$out" | grep -q '"risk": "unknown"'; then echo "pass no gh -> unknown"; else echo "FAIL no gh: exit $code"; fails=$((fails+1)); fi

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

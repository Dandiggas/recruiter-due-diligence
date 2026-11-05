#!/usr/bin/env bash
# Live check of --remote on real GitHub codespaces. Opt-in: it uses about
# 3 short codespaces (a few core-minutes of your free allowance).
#   RDD_REMOTE_REPO=<you>/recruiter-due-diligence tests/remote-live.sh
# Proves: the locked settings hold inside a codespace, a packed zip and a
# GitHub link are read there, and no codespace is left behind.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
REPO="${RDD_REMOTE_REPO:-$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
fail() { echo "FAIL $*"; fails=$((fails+1)); }

# 1. Locked settings inside a codespace. Each must block, and the open network
#    run must work, so a broken probe can't pass.
CS=""
cleanup() {  # delete the probe codespace even if the run is interrupted
  [ -n "$CS" ] && gh codespace delete -c "$CS" --force >/dev/null 2>&1; CS=""
  local d; d="$(gh codespace list -R "$REPO" --json name,displayName -q '.[] | select(.displayName == "rdd-live-probe") | .name' 2>/dev/null)"
  for n in $d; do gh codespace delete -c "$n" --force >/dev/null 2>&1; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
CS="$(gh codespace create -R "$REPO" -m basicLinux32gb --idle-timeout 10m --retention-period 1h \
      --display-name rdd-live-probe --default-permissions 2>/dev/null | tail -1)"
r() { gh codespace ssh -c "$CS" -- "$@" 2>/dev/null; }
for _ in $(seq 1 30); do r "docker version" >/dev/null && break; sleep 4; done
NET='import socket; s=socket.create_connection(("140.82.112.3",443),5); print("OPEN")'
[ "$(r "docker run --rm --network bridge python:3.12-alpine python -c '$NET'" | tail -1)" = OPEN ] \
  || fail "probe: open network did not work, so the network test means nothing"
[ "$(r "docker run --rm --network none python:3.12-alpine python -c '$NET'" | tail -1)" != OPEN ] \
  && echo "pass no network inside codespace" || fail "network none still reached a raw IP"
[ "$(r 'docker run --rm --read-only python:3.12-alpine sh -c "touch /x && echo WROTE || echo blocked"' | tail -1)" = blocked ] \
  && echo "pass read-only inside codespace" || fail "read-only did not block a write"
[ "$(r 'docker run --rm --cap-drop ALL --security-opt no-new-privileges --user 65534:65534 python:3.12-alpine sh -c "id -u; grep CapEff /proc/self/status"' | tr -s ' \t\n' ' ')" = "65534 CapEff: 0000000000000000 " ] \
  && echo "pass no root, no permissions inside codespace" || fail "user or capabilities not locked"
gh codespace delete -c "$CS" --force >/dev/null 2>&1; CS=""

# 2. The real flow.
expect() {  # expect <input> <risk> [must-find "file:kind" ...]
  local input="$1" want="$2"; shift 2
  local report; report="$(scripts/inspect-takehome.sh --remote "$input" 2>/dev/null)"
  local got; got="$(printf '%s' "$report" | python3 -c 'import sys,json;print(json.load(sys.stdin)["risk"])' 2>/dev/null)"
  [ "$got" = "$want" ] || { fail "$input: risk '$got', wanted $want"; return; }
  printf '%s' "$report" | grep -q '"codespace": "deleted' || { fail "$input: codespace not reported deleted"; return; }
  for need in "$@"; do
    printf '%s' "$report" | python3 -c '
import sys,json; f,k=sys.argv[1].split(":")
sys.exit(0 if any(x["file"].endswith(f) and x["kind"]==k for x in json.load(sys.stdin)["findings"]) else 1)' "$need" \
      || { fail "$input: missed $need"; return; }
  done
  echo "pass $input -> $got (in a codespace, deleted)"
}
expect tests/fixtures/fake-recruiter-takehome.zip high "package.json:auto_run" ".vscode/tasks.json:auto_run" "README.md:agent_trick"
expect "https://github.com/$REPO" high "fake-recruiter-takehome/package.json:auto_run"

# 3. Nothing left running.
if listing="$(gh codespace list -R "$REPO" --json displayName -q '.[].displayName')"; then
  left="$(printf '%s\n' "$listing" | grep -E '^rdd-' || true)"
  [ -z "$left" ] && echo "pass no codespaces left" || fail "codespaces left: $left"
else
  fail "could not list codespaces, so cannot prove none are left"
fi

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

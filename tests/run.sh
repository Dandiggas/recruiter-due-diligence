#!/usr/bin/env bash
# End-to-end check: each test take-home goes through the real locked containers.
# A test fails if the risk level or a must-find trick is wrong.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0

expect() {  # expect <input> <risk> [must-find "file:kind" ...]
  local input="$1" want="$2"; shift 2
  local report; report="$(scripts/inspect-takehome.sh "$input" 2>/dev/null)"
  local got; got="$(printf '%s' "$report" | python3 -c 'import sys,json;print(json.load(sys.stdin)["risk"])')"
  if [ "$got" != "$want" ]; then echo "FAIL $input: risk $got, wanted $want"; fails=$((fails+1)); return; fi
  for need in "$@"; do
    if ! printf '%s' "$report" | python3 -c '
import sys,json; f,k=sys.argv[1].split(":")
sys.exit(0 if any(x["file"]==f and x["kind"]==k for x in json.load(sys.stdin)["findings"]) else 1)' "$need"; then
      echo "FAIL $input: missed $need"; fails=$((fails+1)); return
    fi
  done
  echo "pass $input -> $got"
}

expect tests/fixtures/clean-takehome low
expect tests/fixtures/fake-recruiter-takehome high \
  "package.json:auto_run" ".vscode/tasks.json:auto_run" "README.md:agent_trick" \
  "scripts/setup.js:hidden_code" "scripts/setup.js:secrets" "scripts/setup.js:network"
expect tests/fixtures/fake-recruiter-takehome.zip high "package.json:auto_run" ".vscode/tasks.json:auto_run"

# Docker missing must never read as safe.
out="$(PATH=/nonexistent /bin/bash scripts/inspect-takehome.sh tests/fixtures/clean-takehome 2>/dev/null)"; code=$?
if [ "$code" = 3 ] && printf '%s' "$out" | grep -q '"risk": "unknown"'; then echo "pass no-docker -> unknown"; else echo "FAIL no-docker: exit $code"; fails=$((fails+1)); fi

# --- Regression tests for the review findings (Codex, 2026-11-04) ---------
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Finding 4: nothing may be skipped silently.
mkdir -p "$T/big" "$T/deps/node_modules/helper" "$T/hook/.git/hooks" "$T/link"
python3 -c 'import json,sys; json.dump({"scripts":{"postinstall":"node x.js"},"pad":"a"*2100000}, open(sys.argv[1],"w"))' "$T/big/package.json"
printf 'eval(atob("Y29uc29sZS5sb2coMSk="))\n' > "$T/deps/node_modules/helper/index.js"
printf '#!/bin/sh\necho hi\n' > "$T/hook/.git/hooks/post-checkout"
ln -s /etc/passwd "$T/link/passwd"
expect "$T/big" medium
expect "$T/deps" high "node_modules/helper/index.js:hidden_code"
expect "$T/hook" high ".git/hooks/post-checkout:auto_run"
expect "$T/link" medium

# Review finding 7 (Codex, 4 Nov night): a git hook inside a top-level folder,
# the usual zip shape, was read as low.
mkdir -p "$T/wrap/takehome/.git/hooks"; printf '#!/bin/sh\necho hi\n' > "$T/wrap/takehome/.git/hooks/pre-commit"
(cd "$T/wrap" && zip -qr "$T/wrapped.zip" takehome)
expect "$T/wrapped.zip" high "takehome/.git/hooks/pre-commit:auto_run"

# Finding 5: every text file is read, whatever its name.
mkdir -p "$T/single" "$T/svg"
printf 'const k = "wallet.dat"; eval(k)\n' > "$T/single/payload"
printf '<svg xmlns="http://www.w3.org/2000/svg"><script>eval(atob("eA=="))</script></svg>\n' > "$T/svg/logo.svg"
expect "$T/single/payload" high "payload:hidden_code"
expect "$T/svg" high "logo.svg:hidden_code"

# Finding 6: an archive inside the take-home is never read as clean.
mkdir -p "$T/nested"; (cd tests/fixtures/fake-recruiter-takehome && zip -qr "$T/nested/inner.zip" .)
(cd "$T/nested" && zip -q "$T/outer.zip" inner.zip)
expect "$T/outer.zip" medium

# Finding 2: an archive bomb is refused, not unpacked.
python3 -c '
import zipfile,sys
with zipfile.ZipFile(sys.argv[1],"w",zipfile.ZIP_DEFLATED) as z:
    with z.open("zeros.bin","w",force_zip64=True) as f:
        chunk=b"\0"*(1<<20)
        for _ in range(1100): f.write(chunk)
' "$T/bomb.zip"
expect "$T/bomb.zip" unknown

# Finding 1: links to private or local addresses are refused.
# The refusal must come from the address check, not from a failed connection.
python3 -I - <<'PYT' || { echo "FAIL private address check"; fails=$((fails+1)); }
import sys; sys.path.insert(0, "scripts"); import unpack
for url in ["https://127.0.0.1/t.zip", "https://localhost/t.zip", "https://10.0.0.5/t.zip",
            "https://169.254.169.254/latest/meta-data", "https://[::1]/t.zip", "http://example.com/t.zip"]:
    try:
        unpack.check_public_https(url)
    except unpack.Refused:
        continue
    raise SystemExit(f"not refused: {url}")
unpack.check_public_https("https://github.com/")  # a public address must pass
print("pass private address check")
PYT
out="$(scripts/inspect-takehome.sh https://127.0.0.1/takehome.zip 2>/dev/null)"
if printf '%s' "$out" | grep -q "Refused private or local address"; then echo "pass private link refused end to end"; else echo "FAIL private link not refused by the check"; fails=$((fails+1)); fi

# Finding 3: GitHub links keep their branch, tag or commit.
python3 -I - <<'PYT' || { echo "FAIL github ref parsing"; fails=$((fails+1)); }
import sys; sys.path.insert(0, "scripts"); import unpack
cases = {
  "https://github.com/acme/exercise": ("https://api.github.com/repos/acme/exercise/tarball", "default branch"),
  "https://github.com/acme/exercise/tree/assessment": ("https://api.github.com/repos/acme/exercise/tarball/assessment", "assessment"),
  "https://github.com/acme/exercise/blob/v2/src/app.js": ("https://api.github.com/repos/acme/exercise/tarball/v2", "v2"),
  "https://github.com/acme/exercise/commit/abc123": ("https://api.github.com/repos/acme/exercise/tarball/abc123", "abc123"),
}
for url, want in cases.items():
    got = unpack.to_archive_url(url)
    assert got == want, (url, got)
print("pass github ref parsing")
PYT

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

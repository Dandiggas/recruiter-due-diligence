#!/usr/bin/env bash
# Read a recruiter take-home in a throwaway GitHub codespace, not on this machine.
#
#   inspect-remote.sh <https link | path to .zip/.tar.gz/file | path to folder>
#
# 1. Create a codespace (a short-lived cloud machine) from your copy of this repo.
# 2. Stream the scripts and the take-home into it over ssh. Archives travel
#    packed: they are only unpacked inside the codespace, in the locked container.
# 3. Run inspect-takehome.sh there (same locked containers, nothing runs).
# 4. Copy the JSON report back and delete the codespace, even on failure.
#
# Needs: gh, logged in with the "codespace" scope
#   (gh auth refresh -h github.com -s codespace).
# Settings (environment):
#   RDD_REMOTE_REPO     repo to start the codespace from (default: this repo's origin)
#   RDD_REMOTE_MACHINE  machine type (default: basicLinux32gb, the smallest)
#
# Exit codes: 0 report · 2 bad usage · 4 NOT checked (never read as safe)
#             5 report printed, but the codespace could not be confirmed deleted
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINE="${RDD_REMOTE_MACHINE:-basicLinux32gb}"
REMOTE_DIR="${RDD_REMOTE_DIR:-/tmp/rdd}"
DISPLAY_NAME="rdd-inspect-$$-$RANDOM"
CODESPACE=""      # its name, once known
CREATING=""       # set from the moment we ask GitHub for a codespace
LEFTOVER=""       # set if we could not confirm it is gone
DELETED="no codespace was created"
WORK=""

if [ $# -ne 1 ]; then
  echo "usage: $(basename "$0") <https link | archive | file | folder>" >&2
  exit 2
fi
SOURCE="$1"
# The remote folder goes into remote shell commands, so only plain path characters.
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9/._-]+$ ]] || { echo "RDD_REMOTE_DIR must be a plain absolute path" >&2; exit 2; }

not_checked() {  # print a "not checked" report and stop. Never let a failure read as safe.
  delete_codespace
  python3 -c 'import json,sys; print(json.dumps({"risk": "unknown", "where": "codespace", "codespace": sys.argv[2], "note": "The take-home was NOT checked: " + sys.argv[1] + " Do not treat this as safe."}, indent=2))' "$1" "$DELETED"
  exit 4
}

list_codespaces() {  # name<TAB>display name, one per line. Fails if GitHub can't be asked.
  gh codespace list --json name,displayName -q '.[] | .name + "\t" + .displayName'
}

delete_codespace() {  # delete it, then confirm it is gone with a list that succeeded
  [ -n "$CREATING" ] || return 0
  local listing
  if [ -z "$CODESPACE" ]; then
    # Create was cut short before it told us the name: find it by its display name.
    if ! listing="$(list_codespaces 2>/dev/null)"; then
      LEFTOVER=1; DELETED="NOT confirmed deleted: could not list codespaces to find $DISPLAY_NAME. Check: gh codespace list"
      echo "$DELETED" >&2; return 0
    fi
    CODESPACE="$(printf '%s\n' "$listing" | awk -F'\t' -v d="$DISPLAY_NAME" '$2 == d {print $1; exit}')"
    if [ -z "$CODESPACE" ]; then CREATING=""; DELETED="no codespace was created"; return 0; fi
  fi
  gh codespace delete -c "$CODESPACE" --force >/dev/null 2>&1 || true
  if listing="$(list_codespaces 2>/dev/null)" && ! printf '%s\n' "$listing" | cut -f1 | grep -qx "$CODESPACE"; then
    DELETED="deleted ($CODESPACE)"; LEFTOVER=""; CREATING=""; CODESPACE=""
  else
    LEFTOVER=1; DELETED="NOT deleted: $CODESPACE may still exist. Delete it: gh codespace delete -c $CODESPACE --force"
    echo "$DELETED" >&2
  fi
}

finish() { delete_codespace; [ -z "$WORK" ] || rm -rf "$WORK"; }
trap finish EXIT
trap 'exit 130' INT TERM HUP   # a signal still runs finish, so the codespace is deleted

command -v gh >/dev/null 2>&1 || not_checked "the GitHub CLI (gh) is not installed."
gh codespace list --limit 1 >/dev/null 2>&1 \
  || not_checked "gh cannot manage codespaces. Run: gh auth refresh -h github.com -s codespace"

REPO="${RDD_REMOTE_REPO:-}"
if [ -z "$REPO" ]; then
  REPO="$(git -C "$SCRIPTS/.." remote get-url origin 2>/dev/null \
          | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')" || true
fi
[ -n "$REPO" ] || not_checked "no repo to start the codespace from. Set RDD_REMOTE_REPO=owner/repo."

# Get the input ready to travel. Nothing is unpacked here.
WORK="$(mktemp -d)" || not_checked "could not make a temporary folder on this machine."
clean_name() { LC_ALL=C tr -c 'A-Za-z0-9._\n-' '_' | sed 's/^[.-]*//'; }
if [[ "$SOURCE" == https://* ]]; then
  # The link goes into the remote command (quoted below). Printable ASCII only,
  # so the quoting stays plain backslashes in any shell.
  [[ "$SOURCE" =~ ^https://[!-~]+$ ]] || not_checked "the link has spaces or unusual characters."
  TARGET="$SOURCE"
elif [ -d "$SOURCE" ]; then
  # A folder already on this machine: pack its contents (tar stores links as
  # links and runs nothing). No extra top folder, so paths match local mode.
  ABS="$(cd "$SOURCE" && pwd)"
  NAME="$(basename "$ABS" | clean_name)"
  UPLOAD="$WORK/${NAME:-takehome}.tar.gz"
  tar -czf "$UPLOAD" -C "$ABS" . 2>"$WORK/tar.log" \
    || not_checked "could not pack the folder ($(tail -1 "$WORK/tar.log"))."
  TARGET="$REMOTE_DIR/input/$(basename "$UPLOAD")"
elif [ -f "$SOURCE" ]; then
  NAME="$(basename "$SOURCE" | clean_name)"
  UPLOAD="$SOURCE"
  TARGET="$REMOTE_DIR/input/${NAME:-item}"
else
  echo "not found: $SOURCE" >&2
  exit 2
fi

echo "creating a codespace from $REPO ($MACHINE)..." >&2
CREATING=1
created="$(gh codespace create -R "$REPO" -m "$MACHINE" --idle-timeout 10m \
  --retention-period 1h --display-name "$DISPLAY_NAME" --default-permissions 2>"$WORK/create.log")" \
  || create_failed=1
# Keep any name it printed, even on failure, so it still gets deleted.
CODESPACE="$(printf '%s\n' "$created" | tail -1 | grep -E '^[A-Za-z0-9-]+$' || true)"
[ -z "${create_failed:-}" ] && [ -n "$CODESPACE" ] \
  || not_checked "the codespace could not be created ($(tail -1 "$WORK/create.log"))."

remote() { gh codespace ssh -c "$CODESPACE" -- "$@"; }

# Wait for Docker inside the codespace (the docker-in-docker feature starts it).
ready=""
for _ in $(seq 1 30); do
  if remote "docker version --format '{{.Server.Version}}'" >/dev/null 2>&1; then ready=1; break; fi
  sleep 4
done
[ -n "$ready" ] || not_checked "Docker did not start inside the codespace."

remote "mkdir -p '$REMOTE_DIR/scripts' '$REMOTE_DIR/input'" >/dev/null \
  || not_checked "could not prepare the codespace."
# Files go in over ssh as a plain byte stream (no scp, so no path quoting
# surprises). Remote paths are built only from cleaned-up names.
upload() { remote "cat > '$2'" < "$1" >/dev/null; }
for f in inspect-takehome.sh unpack.py reader.py; do
  upload "$SCRIPTS/$f" "$REMOTE_DIR/scripts/$f" || not_checked "could not copy the scripts into the codespace."
done
if [ -n "${UPLOAD:-}" ]; then
  upload "$UPLOAD" "$TARGET" || not_checked "could not copy the take-home into the codespace."
fi
# The locked containers run as user nobody, so nobody must be able to read the files.
remote "chmod -R a+rX '$REMOTE_DIR'" >/dev/null || not_checked "could not prepare the codespace."

# gh codespace ssh does not pass the exit code through (4 arrives as 1), so the
# scan writes its own exit code as a last line on stderr. No marker means the
# connection broke before the scan finished.
scan_status=0
remote "bash '$REMOTE_DIR/scripts/inspect-takehome.sh' $(printf '%q' "$TARGET"); echo RDD_EXIT=\$? >&2" \
  >"$WORK/report.json" 2>"$WORK/scan.log" || scan_status=$?
marker="$(grep -E '^RDD_EXIT=[0-9]+$' "$WORK/scan.log" | tail -1 | cut -d= -f2 || true)"
delete_codespace

[ "$scan_status" = 0 ] && [ -n "$marker" ] \
  || not_checked "the connection to the codespace broke before the scan finished."

# Pass the report through, marked with where it ran. It must be a whole report
# whose risk matches the scan's own exit code; anything else is "not checked".
code=0
python3 - "$WORK/report.json" "$DELETED" "$marker" <<'PY' || code=$?
import json, sys
path, deleted, scan_exit = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    report = json.load(open(path))
except ValueError:
    sys.exit(1)
if not isinstance(report, dict):
    sys.exit(1)
risk = report.get("risk")
if risk == "unknown":
    ok = scan_exit in (3, 4)
else:
    ok = (risk in ("low", "medium", "high") and scan_exit == 0
          and isinstance(report.get("findings"), list) and isinstance(report.get("not_read"), list))
if not ok:
    sys.exit(1)
report["where"] = "codespace"
report["codespace"] = deleted
print(json.dumps(report, indent=2))
sys.exit(4 if risk == "unknown" else 0)
PY
case "$code" in
  0) [ -n "$LEFTOVER" ] && exit 5; exit 0 ;;
  4) exit 4 ;;
  *) not_checked "the codespace returned something that is not a whole report." ;;
esac

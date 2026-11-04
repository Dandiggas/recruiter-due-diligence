"""Get the take-home into /work/takehome without running any of it.

Runs INSIDE a throwaway container (no root, read-only system, all extra
permissions removed). It has network only when the take-home is a web link,
and only to download it. Nothing downloaded is ever run.

Input (argv[1]):
  https://github.com/<owner>/<repo>                 default branch
  https://github.com/<owner>/<repo>/tree/<branch>   that branch (or tag, or commit)
  https://.../<file>.zip | .tar.gz | .tgz | <any file>   direct download link
  /input/<file>      a local file or archive, mounted read-only
  /input/<folder>    a local folder, mounted read-only

Writes /work/source.json saying exactly what was fetched, so the report
can name it.
"""

import io
import ipaddress
import json
import re
import shutil
import socket
import sys
import tarfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

WORK = Path("/work")
MAX_DOWNLOAD_BYTES = 200 * 1024 * 1024
MAX_UNPACKED_BYTES = 1024 * 1024 * 1024
MAX_FILES = 50_000
GITHUB_REPO = re.compile(r"^https://github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?(?:/(tree|blob|commit)/([^/?#]+))?(?:[/?#].*)?$")


class Refused(Exception):
    pass


def main(source: str) -> None:
    dest = WORK / "takehome"
    dest.mkdir(parents=True, exist_ok=True)
    record = {"input": source}
    if source.startswith("https://"):
        url, ref = to_archive_url(source)
        record.update({"fetched": url, "ref": ref})
        data = download(url)
        unpack_bytes(data, name_from_url(source), dest)
    elif "://" in source:
        raise Refused("Only https:// links are accepted.")
    else:
        path = Path(source)
        if path.is_dir():
            copy_folder(path, dest)
        else:
            unpack_bytes(path.read_bytes(), path.name, dest)
    (WORK / "source.json").write_text(json.dumps(record))
    print(f"unpacked into {dest}")


# --- what to fetch ---------------------------------------------------------

def to_archive_url(url: str) -> tuple:
    """GitHub page links become the tarball of the exact branch, tag or commit in the link."""
    match = GITHUB_REPO.match(url)
    if not match:
        return url, None
    owner, repo, _kind, ref = match.groups()
    ref = urllib.parse.unquote(ref) if ref else None
    tail = f"/{urllib.parse.quote(ref, safe='')}" if ref else ""
    return f"https://api.github.com/repos/{owner}/{repo}/tarball{tail}", ref or "default branch"


def name_from_url(url: str) -> str:
    name = Path(urllib.parse.urlparse(url).path).name
    return name or "download"


# --- download, public internet only ----------------------------------------

def check_public_https(url: str) -> None:
    """Refuse anything that is not https to a public internet address.

    Stops a link (or a redirect) from reaching your router, your Mac or
    other containers.
    """
    parts = urllib.parse.urlparse(url)
    if parts.scheme != "https" or not parts.hostname:
        raise Refused(f"Refused non-https address: {url}")
    for info in socket.getaddrinfo(parts.hostname, parts.port or 443, proto=socket.IPPROTO_TCP):
        address = ipaddress.ip_address(info[4][0])
        if not address.is_global:
            raise Refused(f"Refused private or local address {address} for {parts.hostname}")


class PublicOnlyRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_public_https(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(url: str) -> bytes:
    check_public_https(url)
    opener = urllib.request.build_opener(PublicOnlyRedirects)
    request = urllib.request.Request(url, headers={"User-Agent": "recruiter-due-diligence-inspector"})
    with opener.open(request, timeout=60) as response:
        data = response.read(MAX_DOWNLOAD_BYTES + 1)
    if len(data) > MAX_DOWNLOAD_BYTES:
        raise Refused("Download is over 200 MB. Inspect it by hand on a throwaway machine.")
    return data


# --- unpack, with size and count limits -------------------------------------

def unpack_bytes(data: bytes, name: str, dest: Path) -> None:
    if data[:4] == b"PK\x03\x04":
        unpack_zip(data, dest)
    elif data[:2] == b"\x1f\x8b" or name.endswith((".tar", ".tar.gz", ".tgz")):
        unpack_tar(data, dest)
    else:
        (dest / safe_name(name)).write_bytes(data)  # a single file: keep its name so it gets read as text


def unpack_zip(data: bytes, dest: Path) -> None:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        check_limits(len(members), sum(m.file_size for m in members))
        root = dest.resolve()
        for member in members:
            target = (dest / member.filename).resolve()
            if not target.is_relative_to(root):
                print(f"skipped unsafe path: {member.filename}")
                continue
            if is_zip_symlink(member):
                print(f"skipped link: {member.filename}")
                continue
            archive.extract(member, dest)


def unpack_tar(data: bytes, dest: Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        members = archive.getmembers()
        check_limits(len(members), sum(m.size for m in members if m.isfile()))
        # "data" filter blocks ../ paths, absolute paths, links out of the folder and device files
        archive.extractall(dest, filter="data")


def copy_folder(source: Path, dest: Path) -> None:
    files = [p for p in source.rglob("*") if p.is_file() and not p.is_symlink()]
    check_limits(len(files), sum(p.stat().st_size for p in files))
    shutil.copytree(source, dest, dirs_exist_ok=True, symlinks=True)  # links copied as links, never followed


def check_limits(count: int, total_bytes: int) -> None:
    if count > MAX_FILES:
        raise Refused(f"Archive has {count} entries (limit {MAX_FILES}). Possible archive bomb.")
    if total_bytes > MAX_UNPACKED_BYTES:
        raise Refused(f"Archive unpacks to {total_bytes} bytes (limit {MAX_UNPACKED_BYTES}). Possible archive bomb.")


def is_zip_symlink(member: zipfile.ZipInfo) -> bool:
    return (member.external_attr >> 16) & 0o170000 == 0o120000


def safe_name(name: str) -> str:
    cleaned = re.sub(r"[^\w.-]", "_", name).lstrip(".") or "download"
    return cleaned[:120]


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except Refused as reason:
        print(f"REFUSED: {reason}", file=sys.stderr)
        sys.exit(4)

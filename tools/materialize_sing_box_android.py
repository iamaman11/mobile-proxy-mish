#!/usr/bin/env python3
"""Materialize the exact pinned Android sing-box executable as an APK native library.

The release manifest is the sole vendor identity. The script accepts only the two
explicit Android ABIs, verifies SHA-256 before extraction, requires exactly one
`sing-box` file in the archive, verifies ELF magic, and never executes downloaded bytes.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import tarfile
import tempfile
import tomllib
import urllib.request
from pathlib import Path

ABI_SECTION = {
    "armeabi-v7a": "android_arm",
    "arm64-v8a": "android_arm64",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_exact(url: str, destination: Path, expected_sha256: str) -> None:
    if destination.is_file() and sha256(destination) == expected_sha256:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temp:
        temp_path = Path(temp.name)
    try:
        with urllib.request.urlopen(url, timeout=120) as reply, temp_path.open("wb") as out:
            shutil.copyfileobj(reply, out)
        observed = sha256(temp_path)
        if observed != expected_sha256:
            raise RuntimeError(
                f"sing-box archive SHA-256 mismatch: expected {expected_sha256}, got {observed}"
            )
        os.replace(temp_path, destination)
    finally:
        temp_path.unlink(missing_ok=True)


def extract_binary(archive: Path, destination: Path) -> None:
    with tarfile.open(archive, mode="r:gz") as bundle:
        candidates = [
            member for member in bundle.getmembers()
            if member.isfile() and Path(member.name).name == "sing-box"
        ]
        if len(candidates) != 1:
            raise RuntimeError(
                f"expected exactly one sing-box executable in archive, found {len(candidates)}"
            )
        member = candidates[0]
        source = bundle.extractfile(member)
        if source is None:
            raise RuntimeError("sing-box archive member could not be read")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temp:
            temp_path = Path(temp.name)
            shutil.copyfileobj(source, temp)
        try:
            with temp_path.open("rb") as handle:
                if handle.read(4) != b"\x7fELF":
                    raise RuntimeError("sing-box Android asset is not an ELF executable")
            os.chmod(temp_path, 0o755)
            os.replace(temp_path, destination)
        finally:
            temp_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--abi", required=True, choices=sorted(ABI_SECTION))
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--cache-dir", required=True, type=Path)
    args = parser.parse_args()

    with args.manifest.open("rb") as handle:
        manifest = tomllib.load(handle)
    section = manifest.get(ABI_SECTION[args.abi])
    if not isinstance(section, dict):
        raise RuntimeError(f"missing {ABI_SECTION[args.abi]} section in release manifest")

    asset = section.get("asset")
    url = section.get("url")
    expected = section.get("sha256")
    if not all(isinstance(value, str) and value for value in (asset, url, expected)):
        raise RuntimeError("sing-box release manifest has incomplete Android asset identity")
    if len(expected) != 64 or any(ch not in "0123456789abcdef" for ch in expected):
        raise RuntimeError("sing-box release manifest SHA-256 is invalid")

    archive = args.cache_dir / asset
    download_exact(url, archive, expected)
    destination = args.output_dir / args.abi / "libsingbox.so"
    extract_binary(archive, destination)
    print(f"MISH_SING_BOX_ANDROID_MATERIALIZED={destination}")
    print(f"MISH_SING_BOX_ARCHIVE_SHA256={expected}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Materialize the pinned keyboard and settled rerank models.

The two outputs keep the upstream safetensors bytes but use the file names
consumed by the macOS host. Files are copied or downloaded into a staging
directory, checked against the lock, and only then atomically moved into the
seed resource tree. Re-running the command is idempotent.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import shutil
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = ROOT / "resources/rerank-models.lock.json"
CHUNK_BYTES = 1 << 20
MAX_MODEL_BYTES = 64 * 1024 * 1024
DOWNLOAD_ATTEMPTS = 3
EXPECTED_MODELS = {
    "keyboard": {
        "upstream_preset": "keyboard",
        "upstream_name": "sentence-model.safetensors",
        "output_name": "keyboard-model.bin",
    },
    "settled": {
        "upstream_preset": "desktop",
        "upstream_name": "sentence-model-desktop.safetensors",
        "output_name": "settled-model.bin",
    },
}


class Failure(Exception):
    pass


def sha256(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK_BYTES), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def safe_basename(value: Any, label: str, suffix: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or Path(value).name != value
        or Path(value).is_absolute()
        or ".." in Path(value).parts
        or not value.endswith(suffix)
    ):
        raise Failure(f"invalid {label}: {value!r}")
    return value


def safe_relative_path(value: Any, label: str, base: Path) -> Path:
    if not isinstance(value, str) or not value:
        raise Failure(f"invalid {label}: {value!r}")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        raise Failure(f"{label} must stay below the lock directory: {value!r}")
    path = (base / relative).resolve()
    try:
        path.relative_to(base.resolve())
    except ValueError as error:
        raise Failure(f"{label} escapes the lock directory: {value!r}") from error
    if not path.is_file() or path.is_symlink():
        raise Failure(f"{label} is missing or is not a regular file: {path}")
    return path


def valid_sha256(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdefABCDEF" for character in value)
    ):
        raise Failure(f"invalid SHA-256 for {label}")
    return value.lower()


def valid_size(value: Any, label: str, maximum: int) -> int:
    if type(value) is not int or not 0 < value <= maximum:
        raise Failure(f"invalid size for {label}: {value!r}")
    return value


def load_lock(lock_path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise Failure(f"model lock does not exist: {lock_path}") from error
    except json.JSONDecodeError as error:
        raise Failure(f"model lock is not valid JSON: {lock_path}: {error}") from error
    if not isinstance(lock, dict) or lock.get("schema_version") != 1:
        raise Failure("model lock has an unsupported schema_version")

    upstream = lock.get("upstream")
    if not isinstance(upstream, dict):
        raise Failure("model lock has no upstream object")
    if upstream.get("release") != "model-v1" or upstream.get("license") != "Apache-2.0":
        raise Failure("model lock must pin release model-v1 under Apache-2.0")
    if upstream.get("msime_pin") != "09e3d53c16eb11420bef708c35d425c31eff41e2":
        raise Failure("model lock has an unexpected msime pin")

    lock_root = lock_path.parent
    upstream["license_path"] = safe_relative_path(
        upstream.get("license_file"), "license_file", lock_root
    )
    upstream["license_size"] = valid_size(
        upstream.get("license_size"), "license", 1024 * 1024
    )
    upstream["license_sha256"] = valid_sha256(
        upstream.get("license_sha256"), "license"
    )
    upstream["notice_path"] = safe_relative_path(
        upstream.get("notice_file"), "notice_file", lock_root
    )
    upstream["notice_size"] = valid_size(
        upstream.get("notice_size"), "notice", 1024 * 1024
    )
    upstream["notice_sha256"] = valid_sha256(
        upstream.get("notice_sha256"), "notice"
    )
    verify_file(
        upstream["license_path"],
        upstream["license_size"],
        upstream["license_sha256"],
        "license",
    )
    verify_file(
        upstream["notice_path"],
        upstream["notice_size"],
        upstream["notice_sha256"],
        "notice",
    )

    deployment = lock.get("deployment")
    if not isinstance(deployment, dict):
        raise Failure("model lock has no deployment object")
    directory = deployment.get("directory")
    if (
        not isinstance(directory, str)
        or not directory
        or Path(directory).is_absolute()
        or ".." in Path(directory).parts
    ):
        raise Failure(f"invalid deployment directory: {directory!r}")
    deployment["license_name"] = safe_basename(
        deployment.get("license_name"), "deployment license name", ".txt"
    )
    deployment["notice_name"] = safe_basename(
        deployment.get("notice_name"), "deployment notice name", ".txt"
    )
    if deployment["license_name"] == deployment["notice_name"]:
        raise Failure("deployment license and notice names must differ")

    raw_models = lock.get("models")
    if not isinstance(raw_models, list) or len(raw_models) != len(EXPECTED_MODELS):
        raise Failure("model lock must contain exactly the keyboard and settled models")
    models: list[dict[str, Any]] = []
    seen_roles: set[str] = set()
    seen_outputs: set[str] = set()
    for raw_model in raw_models:
        if not isinstance(raw_model, dict):
            raise Failure("model lock contains a non-object model entry")
        role = raw_model.get("role")
        if role not in EXPECTED_MODELS or role in seen_roles:
            raise Failure(f"invalid or duplicate model role: {role!r}")
        seen_roles.add(role)
        expected = EXPECTED_MODELS[role]
        for key, wanted in expected.items():
            if raw_model.get(key) != wanted:
                raise Failure(
                    f"{role}: {key} must be {wanted!r}, got {raw_model.get(key)!r}"
                )
        if raw_model.get("format") != "safetensors":
            raise Failure(f"{role}: output content must be safetensors")
        output_name = safe_basename(
            raw_model.get("output_name"), f"{role} output_name", ".bin"
        )
        if output_name in {deployment["license_name"], deployment["notice_name"]}:
            raise Failure(f"{role}: output name collides with a notice file")
        if output_name in seen_outputs:
            raise Failure(f"duplicate model output name: {output_name}")
        seen_outputs.add(output_name)
        url = raw_model.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise Failure(f"{role}: model URL must use HTTPS")
        model = {
            **raw_model,
            "output_name": output_name,
            "size": valid_size(raw_model.get("size"), role, MAX_MODEL_BYTES),
            "sha256": valid_sha256(raw_model.get("sha256"), role),
            "url": url,
        }
        models.append(model)
    if seen_roles != set(EXPECTED_MODELS):
        raise Failure("model lock is missing a required model role")
    return lock, models


def inspect_regular_file(path: Path) -> os.stat_result:
    try:
        file_stat = path.lstat()
    except FileNotFoundError as error:
        raise Failure(f"missing file: {path}") from error
    if not stat.S_ISREG(file_stat.st_mode) or path.is_symlink():
        raise Failure(f"not a regular file: {path}")
    return file_stat


def verify_file(path: Path, expected_size: int, expected_sha256: str, label: str) -> None:
    file_stat = inspect_regular_file(path)
    actual_sha256 = sha256(path)
    if file_stat.st_size != expected_size or actual_sha256 != expected_sha256:
        raise Failure(
            f"{label}: expected {expected_size} bytes at {expected_sha256}, "
            f"got {file_stat.st_size} bytes at {actual_sha256} ({path})"
        )


def matches(path: Path, expected_size: int, expected_sha256: str) -> bool:
    try:
        verify_file(path, expected_size, expected_sha256, path.name)
    except Failure:
        return False
    return True


def stage_copy(
    source: Path,
    destination: Path,
    expected_size: int,
    expected_sha256: str,
    label: str,
) -> Path:
    inspect_regular_file(source)
    with source.open("rb") as input_stream, destination.open("xb") as output_stream:
        shutil.copyfileobj(input_stream, output_stream, CHUNK_BYTES)
        output_stream.flush()
        os.fsync(output_stream.fileno())
    destination.chmod(0o644)
    verify_file(destination, expected_size, expected_sha256, label)
    return destination


def download(model: dict[str, Any], destination: Path) -> Path:
    request = urllib.request.Request(
        model["url"],
        headers={"User-Agent": "Owltype rerank model fetch/1"},
    )
    last_error: BaseException | None = None
    for attempt in range(DOWNLOAD_ATTEMPTS):
        destination.unlink(missing_ok=True)
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                advertised = response.headers.get("Content-Length")
                if advertised is not None:
                    try:
                        if int(advertised) > model["size"]:
                            raise Failure(
                                f"{model['role']}: response is larger than the lock"
                            )
                    except ValueError:
                        pass
                received = 0
                with destination.open("xb") as output_stream:
                    while chunk := response.read(CHUNK_BYTES):
                        received += len(chunk)
                        if received > model["size"]:
                            raise Failure(
                                f"{model['role']}: response is larger than the lock"
                            )
                        output_stream.write(chunk)
                    output_stream.flush()
                    os.fsync(output_stream.fileno())
            destination.chmod(0o644)
            verify_file(
                destination,
                model["size"],
                model["sha256"],
                model["role"],
            )
            return destination
        except Failure:
            destination.unlink(missing_ok=True)
            raise
        except (
            urllib.error.URLError,
            http.client.HTTPException,
            TimeoutError,
            OSError,
        ) as error:
            last_error = error
            destination.unlink(missing_ok=True)
            if attempt + 1 < DOWNLOAD_ATTEMPTS:
                time.sleep(attempt + 1)
    raise Failure(
        f"{model['role']}: download failed after {DOWNLOAD_ATTEMPTS} attempts: {last_error}"
    )


def print_check_result(
    path: Path,
    expected_size: int,
    expected_sha256: str,
    label: str,
) -> bool:
    try:
        verify_file(path, expected_size, expected_sha256, label)
    except Failure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return False
    print(f"{path.name}: ok ({expected_size} bytes, sha256 {expected_sha256})")
    return True


def check_output(
    lock: dict[str, Any],
    models: list[dict[str, Any]],
    output: Path,
) -> int:
    upstream = lock["upstream"]
    deployment = lock["deployment"]
    results = [
        print_check_result(
            output / deployment["license_name"],
            upstream["license_size"],
            upstream["license_sha256"],
            "license",
        ),
        print_check_result(
            output / deployment["notice_name"],
            upstream["notice_size"],
            upstream["notice_sha256"],
            "notice",
        ),
    ]
    results.extend(
        print_check_result(
            output / model["output_name"],
            model["size"],
            model["sha256"],
            model["role"],
        )
        for model in models
    )
    if not all(results):
        return 1
    print("PASS: rerank models and notices match the lock")
    return 0


def materialize(
    lock: dict[str, Any],
    models: list[dict[str, Any]],
    output: Path,
    source_dir: Path | None,
) -> int:
    if source_dir is not None and not source_dir.is_dir():
        raise Failure(f"model source directory does not exist: {source_dir}")

    upstream = lock["upstream"]
    deployment = lock["deployment"]
    expected_files = [
        (
            upstream["license_path"],
            deployment["license_name"],
            upstream["license_size"],
            upstream["license_sha256"],
            "license",
        ),
        (
            upstream["notice_path"],
            deployment["notice_name"],
            upstream["notice_size"],
            upstream["notice_sha256"],
            "notice",
        ),
    ]
    expected_files.extend(
        (
            source_dir / model["upstream_name"] if source_dir else None,
            model["output_name"],
            model["size"],
            model["sha256"],
            model["role"],
        )
        for model in models
    )

    missing = []
    for source, output_name, size, digest, label in expected_files:
        destination = output / output_name
        if matches(destination, size, digest):
            print(f"{output_name}: already at the locked digest")
        else:
            missing.append((source, output_name, size, digest, label))
    if not missing:
        print(f"PASS: {output}")
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=output.parent)
    )
    try:
        staged: list[tuple[Path, Path]] = []
        cache_root = Path(
            os.environ.get("OWLTYPE_RERANK_MODEL_CACHE", "/tmp/owltype-rerank-models")
        ) / str(upstream["release"])
        model_by_output = {model["output_name"]: model for model in models}
        for source, output_name, size, digest, label in missing:
            destination = staging / output_name
            if output_name in model_by_output and source is None:
                model = model_by_output[output_name]
                cached = cache_root / model["upstream_name"]
                if matches(cached, size, digest):
                    staged.append(
                        (
                            stage_copy(cached, destination, size, digest, label),
                            output / output_name,
                        )
                    )
                else:
                    staged.append(
                        (
                            download(model, destination),
                            output / output_name,
                        )
                    )
            else:
                assert source is not None
                staged.append(
                    (
                        stage_copy(source, destination, size, digest, label),
                        output / output_name,
                    )
                )
        output.mkdir(parents=True, exist_ok=True)
        for source, destination in staged:
            source.replace(destination)
        output_fd = os.open(output, os.O_RDONLY)
        try:
            os.fsync(output_fd)
        finally:
            os.close(output_fd)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    for model in models:
        path = output / model["output_name"]
        print(f"PASS: {path} ({model['size']} bytes, sha256 {model['sha256']})")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify existing outputs without creating or replacing files",
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        help="copy pinned upstream-named files from this directory instead of downloading",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help="output directory (default: the lock's deployment directory)",
    )
    parser.add_argument(
        "--lock",
        type=Path,
        default=DEFAULT_LOCK,
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()

    try:
        lock_path = args.lock.expanduser().resolve()
        lock, models = load_lock(lock_path)
        output = (
            args.out.expanduser().resolve()
            if args.out is not None
            else (lock_path.parent.parent / lock["deployment"]["directory"]).resolve()
        )
        if args.check:
            return check_output(lock, models, output)
        source_dir = (
            args.source_dir.expanduser().resolve()
            if args.source_dir is not None
            else None
        )
        return materialize(lock, models, output, source_dir)
    except (Failure, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3

"""Drive every signed release artifact through one fail-closed cohort state machine."""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path

from famo_bundle import (
    COHORT_SCHEMA_VERSION,
    RELEASE_ARTIFACTS,
    RELEASE_ARTIFACT_STATES,
    artifact_sha256,
    cohort_identifier,
    describe_artifact_path,
    output_root_fingerprint,
    read_cohort,
    release_paths,
    resolve_artifact_path,
    validate_cohort_shape,
    write_cohort,
)


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ADAPTER = ROOT / "package/apple_tool_adapter"
RETRYABLE_EXIT = 75
REJECTED_EXIT = 65


class CohortError(RuntimeError):
    pass


def head_revision() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()


def bundle_version(app: Path) -> str:
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CohortError(f"cannot read release App version: {error}") from error
    version = str(info.get("CFBundleShortVersionString", ""))
    if not version:
        raise CohortError("release App has no CFBundleShortVersionString")
    return version


def validate_identity(cohort: dict, output_root: Path, app: Path) -> None:
    try:
        validate_cohort_shape(cohort)
    except ValueError as error:
        raise CohortError(str(error)) from error
    revision = head_revision()
    version = bundle_version(app)
    root_sha = output_root_fingerprint(output_root)
    if cohort.get("revision") != revision:
        raise CohortError(
            f"cohort revision is {cohort.get('revision')!r}, but HEAD is {revision!r}"
        )
    if cohort.get("version") != version:
        raise CohortError(
            f"cohort version is {cohort.get('version')!r}, but the App is {version!r}"
        )
    if cohort.get("outputRootSha256") != root_sha:
        raise CohortError(
            f"cohort belongs to a different output root, not {output_root}"
        )
    build_sha = cohort.get("buildAppSha256")
    if not isinstance(build_sha, str) or not build_sha:
        raise CohortError("cohort has no build App identity")
    expected_id = cohort_identifier(revision, version, root_sha, build_sha)
    if cohort.get("cohortId") != expected_id:
        raise CohortError("cohort identity digest is invalid")


def validate_artifacts(cohort: dict, output_root: Path) -> None:
    artifacts = cohort["artifacts"]
    for name, record in artifacts.items():
        try:
            path = resolve_artifact_path(record, output_root, ROOT)
            current_sha = artifact_sha256(path)
        except (OSError, ValueError) as error:
            raise CohortError(f"cannot validate artifact {name}: {error}") from error
        if record.get("sha256") != current_sha:
            raise CohortError(f"artifact {name} does not match its cohort binding")


def load_validated(output_root_arg: str) -> tuple[Path, Path, Path, dict]:
    output_root, app, output_dir = release_paths(Path(output_root_arg))
    try:
        cohort = read_cohort(output_dir)
    except (OSError, ValueError) as error:
        raise CohortError(f"cannot read release cohort: {error}") from error
    validate_identity(cohort, output_root, app)
    validate_artifacts(cohort, output_root)
    return output_root, app, output_dir, cohort


def require_active(cohort: dict) -> None:
    if cohort.get("status") == "failed":
        failure = cohort.get("failure", {})
        raise CohortError(
            f"cohort is failed at {failure.get('artifact', '?')}/{failure.get('phase', '?')}; rebuild it"
        )
    if cohort.get("status") == "complete":
        raise CohortError(
            "cohort is already complete; rebuild before replacing artifacts"
        )


def initialize(output_root_arg: str) -> None:
    output_root, app, output_dir = release_paths(Path(output_root_arg))
    if not app.is_dir():
        raise CohortError(f"release App does not exist: {app}")
    revision = head_revision()
    version = bundle_version(app)
    app_sha = artifact_sha256(app)
    root_sha = output_root_fingerprint(output_root)
    output_dir.mkdir(parents=True, exist_ok=True)
    cohort = {
        "artifacts": {
            "app": {
                **describe_artifact_path(app, output_root, ROOT),
                "sha256": app_sha,
                "state": "built",
            }
        },
        "buildAppSha256": app_sha,
        "cohortId": cohort_identifier(revision, version, root_sha, app_sha),
        "outputRootSha256": root_sha,
        "revision": revision,
        "schemaVersion": COHORT_SCHEMA_VERSION,
        "status": "active",
        "version": version,
    }
    write_cohort(output_dir, cohort)
    print(f"PASS: initialized release cohort {cohort['cohortId']} for {version}")


def register(output_root_arg: str, name: str, artifact_arg: str) -> None:
    output_root, _, output_dir, cohort = load_validated(output_root_arg)
    require_active(cohort)
    if name == "app":
        raise CohortError("the App is registered only by cohort initialization")
    if name in cohort["artifacts"]:
        raise CohortError(
            f"artifact {name} is already registered; rebuild the cohort first"
        )
    artifact = Path(artifact_arg).resolve()
    sha = artifact_sha256(artifact)
    result = subprocess.run(
        [str(adapter_path()), "cohort-id", name, str(artifact)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        diagnostic = result.stderr.strip() or f"adapter exit {result.returncode}"
        raise CohortError(
            f"cannot inspect embedded cohort identity for {name}: {diagnostic}"
        )
    embedded_id = result.stdout.strip()
    if embedded_id != cohort["cohortId"]:
        raise CohortError(f"artifact {name} embeds a different cohort identity")
    cohort["artifacts"][name] = {
        **describe_artifact_path(artifact, output_root, ROOT),
        "sha256": sha,
        "state": "built",
    }
    write_cohort(output_dir, cohort)
    print(f"PASS: registered {name} in release cohort {cohort['cohortId']}")


def print_cohort_id(output_root_arg: str) -> None:
    _, _, _, cohort = load_validated(output_root_arg)
    require_active(cohort)
    print(cohort["cohortId"])


def require_artifact(output_root_arg: str, name: str, states: list[str]) -> None:
    _, _, _, cohort = load_validated(output_root_arg)
    if cohort.get("status") == "failed":
        require_active(cohort)
    record = cohort["artifacts"].get(name)
    if not record:
        raise CohortError(f"artifact {name} is not registered in this cohort")
    if record.get("state") not in states:
        raise CohortError(
            f"artifact {name} is {record.get('state')!r}, expected one of {', '.join(states)}"
        )
    print(f"PASS: artifact {name} is {record['state']} in cohort {cohort['cohortId']}")


def appcast_ready(output_root_arg: str) -> None:
    _, _, _, cohort = load_validated(output_root_arg)
    if cohort.get("status") == "failed":
        require_active(cohort)
    for name in ("app", "installer-pkg", "update-pkg"):
        state = cohort["artifacts"].get(name, {}).get("state")
        if state != "stapled":
            raise CohortError(
                f"appcast requires cohort artifact {name} to be stapled, got {state!r}"
            )
    print(f"PASS: release cohort {cohort['cohortId']} is ready for appcast")


def adapter_path() -> Path:
    configured = os.environ.get("FAMO_APPLE_TOOL_ADAPTER")
    adapter = Path(configured).resolve() if configured else DEFAULT_ADAPTER
    if not adapter.is_file() or not os.access(adapter, os.X_OK):
        raise CohortError(f"Apple tool adapter is not executable: {adapter}")
    return adapter


def retry_delay(phase: str) -> float:
    override = os.environ.get("FAMO_RELEASE_RETRY_DELAY_SECONDS")
    if override is not None:
        return float(override)
    return 8.0 if phase == "sign" else 20.0


def run_adapter(command: list[str], phase: str, attempts: int) -> int:
    for attempt in range(1, attempts + 1):
        result = subprocess.run(command, cwd=ROOT, check=False)
        if result.returncode == 0:
            return 0
        if result.returncode != RETRYABLE_EXIT or attempt == attempts:
            return result.returncode
        print(
            f"[famo] {phase} transient failure; retry {attempt}/{attempts}",
            file=sys.stderr,
        )
        delay = retry_delay(phase)
        if delay:
            time.sleep(delay)
    raise AssertionError("unreachable retry loop")


def fail_transition(
    output_dir: Path,
    cohort: dict,
    name: str,
    artifact: Path,
    phase: str,
    returncode: int,
) -> None:
    reason = (
        "rejected"
        if returncode == REJECTED_EXIT
        else ("timeout" if returncode == RETRYABLE_EXIT else f"tool-exit-{returncode}")
    )
    record = cohort["artifacts"][name]
    if artifact.exists():
        record["sha256"] = artifact_sha256(artifact)
    record["state"] = "failed"
    cohort["status"] = "failed"
    cohort["failure"] = {"artifact": name, "phase": phase, "reason": reason}
    write_cohort(output_dir, cohort)
    raise CohortError(f"{name} {phase} {reason}; cohort is now failed")


def persist_transition(
    output_dir: Path, cohort: dict, name: str, artifact: Path, state: str
) -> None:
    record = cohort["artifacts"][name]
    record["sha256"] = artifact_sha256(artifact)
    record["state"] = state
    if all(
        cohort["artifacts"].get(artifact_name, {}).get("state") == "stapled"
        for artifact_name in RELEASE_ARTIFACTS
    ):
        cohort["status"] = "complete"
    write_cohort(output_dir, cohort)
    print(f"PASS: {name} transitioned to {state}")


def seal(
    output_root_arg: str,
    name: str,
    identity: str,
    notary_profile: str,
) -> None:
    output_root, _, output_dir, cohort = load_validated(output_root_arg)
    require_active(cohort)
    record = cohort["artifacts"].get(name)
    if not record:
        raise CohortError(f"artifact {name} is not registered in this cohort")
    if record.get("state") != "built":
        raise CohortError(
            f"artifact {name} must be built before sealing, got {record.get('state')!r}"
        )
    if name != "app" and cohort["artifacts"]["app"].get("state") != "stapled":
        raise CohortError(
            "package and DMG transitions require the cohort App to be stapled"
        )
    if name == "dmg":
        for dependency in ("installer-pkg", "update-pkg"):
            if cohort["artifacts"].get(dependency, {}).get("state") != "stapled":
                raise CohortError(
                    f"DMG transition requires {dependency} from this cohort to be stapled"
                )

    artifact = resolve_artifact_path(record, output_root, ROOT)
    adapter = adapter_path()
    signed_output = artifact
    if name in {"installer-pkg", "update-pkg"}:
        signed_output = artifact.with_name(f".{artifact.name}.signed")
        signed_output.unlink(missing_ok=True)
    sign_command = [
        str(adapter),
        "sign",
        name,
        identity,
        str(artifact),
        str(signed_output),
    ]
    returncode = run_adapter(sign_command, "sign", 5)
    if returncode:
        signed_output.unlink(missing_ok=True)
        fail_transition(output_dir, cohort, name, artifact, "sign", returncode)
    if signed_output != artifact:
        signed_output.replace(artifact)
    persist_transition(output_dir, cohort, name, artifact, "signed")

    before_notary = artifact_sha256(artifact)
    notary_command = [str(adapter), "notarize", name, notary_profile, str(artifact)]
    returncode = run_adapter(notary_command, "notarize", 3)
    if returncode:
        fail_transition(output_dir, cohort, name, artifact, "notarize", returncode)
    if artifact_sha256(artifact) != before_notary:
        fail_transition(output_dir, cohort, name, artifact, "notarize", 70)
    persist_transition(output_dir, cohort, name, artifact, "notarized")

    staple_command = [str(adapter), "staple", name, str(artifact)]
    returncode = run_adapter(staple_command, "staple", 1)
    if returncode:
        fail_transition(output_dir, cohort, name, artifact, "staple", returncode)
    persist_transition(output_dir, cohort, name, artifact, "stapled")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    initialize_parser = subparsers.add_parser("initialize")
    initialize_parser.add_argument("output_root")

    register_parser = subparsers.add_parser("register")
    register_parser.add_argument("output_root")
    register_parser.add_argument("artifact", choices=RELEASE_ARTIFACTS)
    register_parser.add_argument("path")

    id_parser = subparsers.add_parser("id")
    id_parser.add_argument("output_root")

    require_parser = subparsers.add_parser("require")
    require_parser.add_argument("output_root")
    require_parser.add_argument("artifact", choices=RELEASE_ARTIFACTS)
    require_parser.add_argument("states", nargs="+", choices=RELEASE_ARTIFACT_STATES)

    appcast_parser = subparsers.add_parser("appcast-ready")
    appcast_parser.add_argument("output_root")

    seal_parser = subparsers.add_parser("seal")
    seal_parser.add_argument("output_root")
    seal_parser.add_argument("artifact", choices=RELEASE_ARTIFACTS)
    seal_parser.add_argument("identity")
    seal_parser.add_argument("notary_profile")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.command == "initialize":
            initialize(args.output_root)
        elif args.command == "id":
            print_cohort_id(args.output_root)
        elif args.command == "register":
            register(args.output_root, args.artifact, args.path)
        elif args.command == "require":
            require_artifact(args.output_root, args.artifact, args.states)
        elif args.command == "appcast-ready":
            appcast_ready(args.output_root)
        elif args.command == "seal":
            seal(args.output_root, args.artifact, args.identity, args.notary_profile)
        else:
            raise AssertionError(f"unhandled command {args.command}")
    except (CohortError, OSError, ValueError) as error:
        raise SystemExit(f"FAIL: {error}") from error


if __name__ == "__main__":
    main()

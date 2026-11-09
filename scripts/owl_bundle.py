"""Shared bundle-walking and inventory helpers.

Two scripts need to agree bit-for-bit on how a Owltype.app is walked and hashed:
finalize-release-bundle.py (the pre-signing gate) and inventory-release-bundle.py
(the shipped-artifact inventory). Keeping the walk in one module is deliberate —
this repo has already been bitten by two copies of the same logic drifting apart.

The inventory is written OUTSIDE the bundle on purpose. An inventory stored in
Contents/Resources changes the very thing it inventories, which makes the result
depend on how many times the writer has run and on what the previous release left
behind in DerivedData.
"""

import hashlib
import json
import os
import stat
from pathlib import Path

import msime_pin


MANIFEST_NAME = "OWLTYPE-FILE-MANIFEST.sha256"
SBOM_NAME = "OWLTYPE-SBOM.spdx.json"
# Binds an inventory to the commit and version it was taken from. Without it,
# "the inventory exists" is not the same claim as "the inventory describes the
# App built from this source" — see the staleness check in create-source-archive.sh.
PROVENANCE_NAME = "OWLTYPE-APP-PROVENANCE.txt"
COHORT_NAME = "OWLTYPE-RELEASE-COHORT.json"
COHORT_SCHEMA_VERSION = 4
INVENTORY_NAMES = (MANIFEST_NAME, SBOM_NAME, PROVENANCE_NAME)
RELEASE_APP_RELATIVE = Path("Build/Products/Release/Owltype.app")
RELEASE_INVENTORY_RELATIVE = Path("release")
RELEASE_ARTIFACTS = ("app", "installer-pkg", "update-pkg", "dmg")
RELEASE_ARTIFACT_STATES = ("built", "signed", "notarized", "stapled", "failed")
RELEASE_OUTPUTS = ("appcast", "source-archive")

def components(pin=None) -> tuple:
    """SBOM packages; the MSIME engine and dictionary versions come from rust/msime-source.json."""
    pin = pin or msime_pin.load()
    tag_url = f"https://github.com/metasequoiaime/msime-dictionary/releases/tag/{pin.release}"
    return (
        ("Owltype", None, "GPL-3.0-only", "https://responsay.com/owltype/"),
        ("Squirrel-derived frontend", "4db2c85ac639c229e14fd9424f79c3c4f97ce478", "GPL-3.0-only", "https://github.com/rime/squirrel"),
        ("Sparkle", "41847a58cdef7506b257591fcca6f9495df591d4", "MIT", "https://github.com/sparkle-project/Sparkle"),
        ("rime-wubi86-jidian", "a194fb8b3ec41ef9dcf079d3a67876fa75f79135", "Apache-2.0", "https://github.com/KyleBing/rime-wubi86-jidian"),
        ("OpenCC data", "556ed22496d650bd0b13b6c163be9814637970ae", "Apache-2.0", "https://github.com/BYVoid/OpenCC"),
        ("Metasequoia IME (msime)", pin.engine_revision, "GPL-3.0-only", "https://github.com/metasequoiaime/msime"),
        ("msime-dictionary pinyin, Wubi86/98, English and context resources", pin.release, "GPL-3.0-only AND GPL-3.0-or-later AND MIT AND CC-BY-SA-4.0 AND Apache-2.0 AND Unlicense AND WTFPL AND LicenseRef-SCOWL", tag_url),
        ("Owltype emoji and kaomoji catalog (msime-others.db)", pin.release, "GPL-3.0-only AND Unicode-3.0 AND MIT", tag_url),
        ("rime-ice emoji data", "9e66b0729083b37d217312294f6d516c8d7234be", "GPL-3.0-only", "https://github.com/iDvel/rime-ice"),
        ("Unicode Emoji, CLDR annotations, and Emoji 1.0 names", "17.0", "Unicode-3.0", "https://unicode.org/Public/emoji/17.0/"),
        ("python-pinyin emoji reading overrides", "v0.55.0", "MIT", "https://github.com/mozillazg/python-pinyin"),
        ("rime_kaomoji_dict", f"{pin.release}-derived", "MIT", "https://github.com/aoguai/rime_kaomoji_dict"),
        ("chinese-ime-lm reference crate", "15caab4fdeb59c11f452b91884371cf30e2e5608", "Apache-2.0", "https://github.com/metasequoiaime/chinese-ime-lm"),
        ("chinese-ime-lm model weights", "model-v1", "Apache-2.0", "https://github.com/metasequoiaime/chinese-ime-lm/releases/tag/model-v1"),
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_sha256(path: Path) -> str:
    """Hash a release file or bundle with normalized type and permission metadata."""
    path = path.absolute()
    try:
        root_stat = path.lstat()
    except OSError as error:
        raise FileNotFoundError(f"release artifact does not exist: {path}") from error
    if stat.S_ISREG(root_stat.st_mode):
        return sha256(path)
    if not stat.S_ISDIR(root_stat.st_mode):
        raise ValueError(f"unsupported release artifact root type: {path}")

    digest = hashlib.sha256()
    root_mode = stat.S_IMODE(root_stat.st_mode)
    digest.update(f"D\0.\0{root_mode:04o}\0".encode("utf-8"))
    for child in sorted(path.rglob("*"), key=lambda item: item.relative_to(path).as_posix()):
        relative = child.relative_to(path).as_posix().encode("utf-8")
        child_stat = child.lstat()
        mode = f"{stat.S_IMODE(child_stat.st_mode):04o}".encode("ascii")
        if child.is_symlink():
            digest.update(b"L\0" + relative + b"\0" + mode + b"\0")
            target = os.readlink(child).encode("utf-8")
            digest.update(hashlib.sha256(target).hexdigest().encode("ascii") + b"\0")
        elif stat.S_ISREG(child_stat.st_mode):
            digest.update(b"F\0" + relative + b"\0" + mode + b"\0")
            digest.update(sha256(child).encode("ascii") + b"\0")
        elif stat.S_ISDIR(child_stat.st_mode):
            digest.update(b"D\0" + relative + b"\0" + mode + b"\0")
        else:
            raise ValueError(f"unsupported release artifact entry type: {child}")
    return digest.hexdigest()


def validate_app_executable(app: Path) -> None:
    try:
        app_mode = app.lstat().st_mode
    except OSError as error:
        raise ValueError(f"cannot inspect release App root: {error}") from error
    if not stat.S_ISDIR(app_mode):
        raise ValueError("release App root is not a regular directory")
    executable = app / "Contents/MacOS/Owltype"
    try:
        executable_mode = executable.lstat().st_mode
    except OSError as error:
        raise ValueError(f"cannot inspect release App executable: {error}") from error
    if not stat.S_ISREG(executable_mode):
        raise ValueError("release App executable is not a regular file")
    if stat.S_IMODE(executable_mode) & 0o111 == 0:
        raise ValueError("release App executable is not executable")


def unreadable_by_others(root: Path) -> list[str]:
    """Entries the console user cannot use once the bundle is installed root-owned.

    The installer commits the App as root and finishes the install as the console user,
    so a 0700 framework binary passes signing, notarization and digest checks and still
    fails to load. Symlinks are skipped: their targets are entries of the same tree.
    """
    unreadable = []
    for path in sorted([root, *root.rglob("*")]):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            continue
        required = stat.S_IROTH
        if stat.S_ISDIR(mode) or mode & stat.S_IXUSR:
            required |= stat.S_IXOTH
        if mode & required != required:
            unreadable.append(f"{path.relative_to(root).as_posix()} ({stat.S_IMODE(mode):04o})")
    return unreadable


def release_paths(output_root: Path) -> tuple[Path, Path, Path]:
    """Resolve the one output root and its cohort-owned App/inventory paths."""
    root = output_root.resolve()
    return root, root / RELEASE_APP_RELATIVE, root / RELEASE_INVENTORY_RELATIVE


def output_root_fingerprint(output_root: Path) -> str:
    """Bind local state to a root without storing a private absolute path."""
    return hashlib.sha256(str(output_root.resolve()).encode("utf-8")).hexdigest()


def inventory_fingerprint(output_dir: Path) -> str:
    """Hash every published inventory file with an unambiguous name boundary."""
    digest = hashlib.sha256()
    for name in INVENTORY_NAMES:
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        with (output_dir / name).open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


def read_cohort(output_dir: Path) -> dict:
    value = json.loads((output_dir / COHORT_NAME).read_text())
    if not isinstance(value, dict):
        raise ValueError("cohort identity is not a JSON object")
    return value


def validate_cohort_shape(cohort: dict) -> None:
    if cohort.get("schemaVersion") != COHORT_SCHEMA_VERSION:
        raise ValueError(
            f"cohort schema is {cohort.get('schemaVersion')!r}, expected {COHORT_SCHEMA_VERSION}"
        )
    status = cohort.get("status")
    if status not in {"active", "failed", "complete"}:
        raise ValueError(f"cohort has invalid status {status!r}")
    if not isinstance(cohort.get("version"), str) or not isinstance(
        cohort.get("buildVersion"), str
    ):
        raise ValueError("cohort has incomplete version metadata")
    for binding in ("sourceSha256", "seedSha256"):
        value = cohort.get(binding)
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            raise ValueError(f"cohort has invalid {binding} binding")
    submodules = cohort.get("submodules")
    if not isinstance(submodules, dict) or any(
        not isinstance(path, str)
        or not path
        or not isinstance(revision, str)
        or len(revision) != 40
        or any(character not in "0123456789abcdef" for character in revision)
        for path, revision in submodules.items()
    ):
        raise ValueError("cohort has invalid submodule revision bindings")
    artifacts = cohort.get("artifacts")
    if not isinstance(artifacts, dict) or "app" not in artifacts:
        raise ValueError("cohort has no App artifact")
    if any(name not in RELEASE_ARTIFACTS for name in artifacts):
        raise ValueError("cohort contains an unknown release artifact")
    states = []
    for name, record in artifacts.items():
        if not isinstance(record, dict) or record.get("state") not in RELEASE_ARTIFACT_STATES:
            raise ValueError(f"artifact {name} has invalid state {record.get('state')!r}")
        states.append(record["state"])
    if status == "failed" and "failed" not in states:
        raise ValueError("failed cohort has no failed artifact")
    if status != "failed" and "failed" in states:
        raise ValueError("non-failed cohort contains a failed artifact")
    if status == "complete" and (
        set(artifacts) != set(RELEASE_ARTIFACTS) or any(state != "stapled" for state in states)
    ):
        raise ValueError("complete cohort does not have four stapled artifacts")
    outputs = cohort.get("outputs", {})
    if not isinstance(outputs, dict) or any(name not in RELEASE_OUTPUTS for name in outputs):
        raise ValueError("cohort contains an unknown release output")
    for name, record in outputs.items():
        if not isinstance(record, dict) or not isinstance(record.get("sha256"), str):
            raise ValueError(f"output {name} has an invalid binding")


def write_cohort(output_dir: Path, cohort: dict) -> None:
    """Atomically persist the complete release cohort state."""
    destination = output_dir / COHORT_NAME
    temporary = destination.with_name(f".{destination.name}.tmp")
    temporary.write_text(json.dumps(cohort, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    temporary.replace(destination)


def cohort_identifier(
    revision: str,
    version: str,
    build_version: str,
    output_root_sha256: str,
    build_app_sha256: str,
    source_sha256: str,
    seed_sha256: str,
    submodules: dict[str, str],
    sparkle_signing_public_key: str = "",
    sparkle_feed_mode: str = "",
) -> str:
    identity = {
        "buildAppSha256": build_app_sha256,
        "buildVersion": build_version,
        "outputRootSha256": output_root_sha256,
        "revision": revision,
        "schemaVersion": COHORT_SCHEMA_VERSION,
        "seedSha256": seed_sha256,
        "sourceSha256": source_sha256,
        "submodules": submodules,
        "version": version,
    }
    if sparkle_signing_public_key:
        identity["sparkleSigningPublicKey"] = sparkle_signing_public_key
    if sparkle_feed_mode:
        identity["sparkleFeedMode"] = sparkle_feed_mode
    return hashlib.sha256(
        json.dumps(identity, separators=(",", ":"), sort_keys=True).encode("utf-8")
    ).hexdigest()


def describe_artifact_path(path: Path, output_root: Path, repo_root: Path) -> dict[str, str]:
    """Store artifact locations without private absolute paths."""
    resolved = path.resolve()
    for base, root in (("outputRoot", output_root.resolve()), ("repository", repo_root.resolve())):
        try:
            relative = resolved.relative_to(root)
        except ValueError:
            continue
        return {"base": base, "path": relative.as_posix()}
    raise ValueError(f"release artifact must live under the output root or repository: {resolved}")


def resolve_artifact_path(record: dict, output_root: Path, repo_root: Path) -> Path:
    bases = {"outputRoot": output_root.resolve(), "repository": repo_root.resolve()}
    base = record.get("base")
    relative = record.get("path")
    if base not in bases or not isinstance(relative, str) or not relative:
        raise ValueError("artifact has an invalid path binding")
    candidate = (bases[base] / relative).resolve()
    try:
        candidate.relative_to(bases[base])
    except ValueError as error:
        raise ValueError("artifact path escapes its recorded base") from error
    return candidate


def relative_files(app: Path) -> list[tuple[str, Path]]:
    """Every regular file in the bundle, sorted by bundle-relative POSIX path.

    rglob does not descend into symlinked directories, so Sparkle's
    Versions/Current alias contributes no duplicate entries, while a symlink that
    points at a file (Sparkle.framework/Sparkle) is inventoried at its own path
    and hashed through to its target — which is what `shasum -c` verifies later.
    """
    return sorted(
        ((path.relative_to(app).as_posix(), path) for path in app.rglob("*") if path.is_file()),
        key=lambda item: item[0],
    )


def make_sbom(app: Path, version: str, revision: str, created: str) -> dict:
    pin = msime_pin.load()
    files = []
    for relative, path in relative_files(app):
        identifier = hashlib.sha256(relative.encode()).hexdigest()[:24]
        files.append(
            {
                "SPDXID": f"SPDXRef-File-{identifier}",
                "checksums": [{"algorithm": "SHA256", "checksumValue": sha256(path)}],
                "copyrightText": "NOASSERTION",
                "fileName": f"./{relative}",
                "licenseConcluded": "NOASSERTION",
            }
        )

    packages = []
    for index, (name, component_version, license_id, source) in enumerate(components(pin), start=1):
        packages.append(
            {
                "SPDXID": f"SPDXRef-Package-{index}",
                "copyrightText": "NOASSERTION",
                "downloadLocation": source,
                "filesAnalyzed": False,
                "licenseConcluded": license_id,
                "licenseDeclared": license_id,
                "name": name,
                "versionInfo": component_version or version,
            }
        )

        if name == "Sparkle":
            patch = Path(__file__).resolve().parent.parent / "patches/sparkle/application-relaunch.patch"
            packages[-1]["sourceInfo"] = "Official upstream pin with Owltype application-relaunch.patch SHA256 " + sha256(patch)
        elif name == "rime_kaomoji_dict":
            packages[-1]["sourceInfo"] = (
                "MIT, Copyright (c) 2023 aoguai; verbatim rime-kaomoji.LICENSE SHA256 "
                "bc4f44c16c8a6ea28e30ac4e1e9a737e8711ba3140f241fea9c8404a86f3ffe1. "
                "Only kaomoji (1675 rows) and kaomoji_catalog (1400 rows), retained unchanged "
                f"from msime {pin.release} (source artifact SHA256 "
                f"{pin.files['msime-others.db']['sha256']}), "
                f"builder commit {pin.builder_commit}, "
                "resources/dictionary-sources/kaomoji/kaomoji.txt. "
                "The version identifies the pinned derived release, not an aoguai repository revision."
            )
        elif name.startswith("msime-dictionary "):
            packages[-1]["sourceInfo"] = (
                f"Verbatim {pin.release} members pinned by manifest SHA256 {pin.manifest_sha256}; "
                "per-member sources and licenses: SharedSupport/msime-resources-NOTICE.md."
            )
        elif name == "Owltype emoji and kaomoji catalog (msime-others.db)":
            packages[-1]["sourceInfo"] = (
                f"Derived from the pinned {pin.release} release artifact with msime "
                f"builder commit {pin.builder_commit} and "
                f"msime-dictionary data commit {pin.data_commit}; "
                "only emoji, emoji_pinyin, kaomoji and kaomoji_catalog are retained. The upstream artifact's "
                "other tables, including PiliApp symbol_catalog, are excluded."
            )

    return {
        "SPDXID": "SPDXRef-DOCUMENT",
        "creationInfo": {"created": created, "creators": ["Tool: owltype-finalize-release-bundle"]},
        "dataLicense": "CC0-1.0",
        "documentNamespace": f"https://responsay.com/owltype/releases/{version}/spdx/{revision}",
        "files": files,
        "name": f"Owltype-{version}",
        "packages": packages,
        "relationships": [
            {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Package-1"},
            *(
                {"spdxElementId": "SPDXRef-Package-1", "relationshipType": "CONTAINS", "relatedSpdxElement": f"SPDXRef-Package-{index}"}
                for index in range(2, len(packages) + 1)
            ),
        ],
        "spdxVersion": "SPDX-2.3",
    }


def manifest_text(app: Path) -> str:
    """The manifest body for `app`, in `shasum -c` format.

    Single source of truth for both writing and re-verifying, so a staleness
    check can never disagree with the writer about formatting or ordering.
    """
    return "\n".join(f"{sha256(path)}  {relative}" for relative, path in relative_files(app)) + "\n"


def read_provenance(output_dir: Path) -> dict[str, str]:
    stamp = {}
    for line in (output_dir / PROVENANCE_NAME).read_text().splitlines():
        key, _, value = line.partition(" ")
        if key:
            stamp[key] = value
    return stamp


def write_inventory(
    app: Path,
    output_dir: Path,
    version: str,
    build_version: str,
    revision: str,
    cohort_id: str,
    created: str,
) -> int:
    """Write the manifest, SBOM and provenance stamp for `app` into `output_dir`.

    Covers the bundle completely — nothing is excluded, because none of the
    outputs land inside the bundle. Re-running against an unchanged bundle
    reproduces every file byte for byte. Returns the inventoried file count.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    body = manifest_text(app)

    (output_dir / SBOM_NAME).write_text(
        json.dumps(make_sbom(app, version, revision, created), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    (output_dir / MANIFEST_NAME).write_text(body)
    (output_dir / PROVENANCE_NAME).write_text(
        f"version {version}\nbuild-version {build_version}\n"
        f"revision {revision}\ncohort {cohort_id}\n"
    )
    return len(body.splitlines())

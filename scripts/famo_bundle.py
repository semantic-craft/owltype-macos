"""Shared bundle-walking and inventory helpers.

Two scripts need to agree bit-for-bit on how a Famo.app is walked and hashed:
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
from pathlib import Path


MANIFEST_NAME = "FAMOTYPE-FILE-MANIFEST.sha256"
SBOM_NAME = "FAMOTYPE-SBOM.spdx.json"
# Binds an inventory to the commit and version it was taken from. Without it,
# "the inventory exists" is not the same claim as "the inventory describes the
# App built from this source" — see the staleness check in create-source-archive.sh.
PROVENANCE_NAME = "FAMOTYPE-APP-PROVENANCE.txt"

COMPONENTS = (
    ("Famotype", None, "GPL-3.0-only", "https://github.com/semantic-craft/famotype-macos"),
    ("Squirrel-derived frontend", "4db2c85ac639c229e14fd9424f79c3c4f97ce478", "GPL-3.0-only", "https://github.com/rime/squirrel"),
    ("librime", "33e78140250125871856cdc5b42ddc6a5fcd3cd4", "BSD-3-Clause", "https://github.com/rime/librime"),
    ("librime-lua", "ec52e48ea18f11af37717a01c337f853215cf70b", "BSD-3-Clause", "https://github.com/hchunhui/librime-lua"),
    ("plum", "b1be1969f914cc005add4090631b855db00c2591", "LGPL-3.0-only", "https://github.com/rime/plum"),
    ("Sparkle", "41847a58cdef7506b257591fcca6f9495df591d4", "MIT", "https://github.com/sparkle-project/Sparkle"),
    ("rime-ice configuration", "b681a34f788795034b3b288830f4861980bc8b0d", "GPL-3.0-only", "https://github.com/iDvel/rime-ice"),
    ("jieba", "v0.42.1", "MIT", "https://github.com/fxsjy/jieba"),
    ("phrase-pinyin-data", "cee0ed6e6e4898580cafd2bd5e3723e20b214aa0", "MIT", "https://github.com/mozillazg/phrase-pinyin-data"),
    ("Unicode Unihan", "16.0.0", "Unicode-3.0", "https://www.unicode.org/Public/16.0.0/ucd/Unihan.zip"),
    ("OpenCC", "556ed22496d650bd0b13b6c163be9814637970ae", "Apache-2.0", "https://github.com/BYVoid/OpenCC"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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
    for index, (name, component_version, license_id, source) in enumerate(COMPONENTS, start=1):
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

    return {
        "SPDXID": "SPDXRef-DOCUMENT",
        "creationInfo": {"created": created, "creators": ["Tool: famotype-finalize-release-bundle"]},
        "dataLicense": "CC0-1.0",
        "documentNamespace": f"https://github.com/semantic-craft/famotype-macos/releases/{version}/spdx/{revision}",
        "files": files,
        "name": f"Famotype-{version}",
        "packages": packages,
        "relationships": [
            {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Package-1"},
            *(
                {"spdxElementId": "SPDXRef-Package-1", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": f"SPDXRef-Package-{index}"}
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


def write_inventory(app: Path, output_dir: Path, version: str, revision: str, created: str) -> int:
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
    (output_dir / PROVENANCE_NAME).write_text(f"version {version}\nrevision {revision}\n")
    return len(body.splitlines())

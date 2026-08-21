#!/usr/bin/env bash
# Mechanical end-to-end release composition. It reuses a built App, exercises the real package,
# DMG, appcast, and corresponding-source entrypoints, and replaces only credentialed Apple tools.
set -euo pipefail

CALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
built_app="${1:-$CALLER_ROOT/build/release-gate/Build/Products/Release/Owltype.app}"

[[ -d "$built_app" ]] || {
  echo >&2 "ERROR: missing built App fixture: $built_app"
  exit 1
}
built_app="$(cd "$(dirname "$built_app")" && pwd -P)/$(basename "$built_app")"
sign_update_source="$CALLER_ROOT/download/bin/sign_update"
[[ -x "$sign_update_source" ]] || {
  echo >&2 "ERROR: missing bootstrapped Sparkle signer: $sign_update_source"
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/owl-artifact-chain.XXXXXX")"
ROOT="$work/checkout"
output_root="$work/output"
app="$output_root/Build/Products/Release/Owltype.app"
bridge_private_key="$work/sparkle-ed25519-bridge-private-key"
successor_private_key="$work/sparkle-ed25519-successor-private-key"
fake_adapter="$work/fake-apple-tool-adapter"
asset_list="$work/published-assets.nul"
failure_output="$work/failure-output"
caller_before="$work/caller-package-installer.before"
caller_after="$work/caller-package-installer.after"

cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

snapshot_caller_package_and_installer() {
  python3 - "$CALLER_ROOT" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

base = Path(sys.argv[1])
records = []


def add(path: Path) -> None:
    relative = path.relative_to(base).as_posix()
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISLNK(metadata.st_mode):
        records.append([relative, "symlink", mode, os.readlink(path)])
    elif stat.S_ISREG(metadata.st_mode):
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        records.append([relative, "file", mode, metadata.st_size, digest.hexdigest()])
    elif stat.S_ISDIR(metadata.st_mode):
        records.append([relative, "directory", mode])
    else:
        records.append([relative, "other", mode])


for name in ("package", "installer"):
    root = base / name
    if not os.path.lexists(root):
        records.append([name, "missing"])
        continue
    add(root)
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        directories.sort()
        files.sort()
        for entry in [*directories, *files]:
            add(current_path / entry)
        directories[:] = [
            entry for entry in directories if not (current_path / entry).is_symlink()
        ]

print(json.dumps(records, ensure_ascii=False, indent=2))
PY
}

local_git() {
  command git \
    -c core.hooksPath=/dev/null \
    -c protocol.file.allow=always \
    -c protocol.git.allow=never \
    -c protocol.http.allow=never \
    -c protocol.https.allow=never \
    -c protocol.ssh.allow=never \
    "$@"
}

snapshot_caller_package_and_installer >"$caller_before"
revision="$(git -C "$CALLER_ROOT" rev-parse HEAD)"
local_git clone --quiet --no-checkout --local "$CALLER_ROOT" "$ROOT"
local_git -C "$ROOT" checkout --quiet --detach "$revision"

# Populate every pinned submodule from the already-initialized caller checkout. Direct local
# clones plus explicit detached revisions guarantee this test never contacts a submodule remote.
while read -r submodule_revision submodule_path _; do
  submodule_revision="${submodule_revision#[-+U]}"
  [[ "$submodule_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo >&2 "ERROR: invalid pinned submodule revision: $submodule_revision"
    exit 1
  }
  source_repo="$CALLER_ROOT/$submodule_path"
  destination="$ROOT/$submodule_path"
  [[ -d "$source_repo" ]] || {
    echo >&2 "ERROR: pinned submodule is not initialized locally: $submodule_path"
    exit 1
  }
  if [[ -d "$destination" ]]; then
    rmdir "$destination"
  fi
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    echo >&2 "ERROR: temporary submodule destination is not empty: $submodule_path"
    exit 1
  }
  mkdir -p "$(dirname "$destination")"
  local_git clone --quiet --no-checkout --local "$source_repo" "$destination"
  local_git -C "$destination" checkout --quiet --detach "$submodule_revision"
done < <(git -C "$CALLER_ROOT" submodule status --recursive)

[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || {
  echo >&2 "ERROR: disposable release checkout is not clean"
  exit 1
}

STATE="$ROOT/scripts/release-cohort-state.py"
INVENTORY="$ROOT/scripts/inventory-release-bundle.py"
# shellcheck source=package/common.sh
source "$ROOT/package/common.sh"
built_version="$(plutil -extract CFBundleShortVersionString raw "$built_app/Contents/Info.plist")"
version="$(get_marketing_version)"
[[ "$built_version" == "$version" ]] || {
  echo >&2 "ERROR: built App version $built_version does not match project version $version"
  exit 1
}

# This is a credential-free composition test even when launched from a maintainer shell.
unset DEV_ID NOTARY_PROFILE

mkdir -p "$(dirname "$app")"
ditto "$built_app" "$app"

# Disposable Sparkle seeds keep CI independent of the maintainer Keychain while exercising the
# real 2.0.1 trust bridge: the package is signed by the old key and the App embeds the new key.
sparkle_public_key() {
  xcrun swift - "$1" <<'SWIFT'
import CryptoKit
import Foundation

let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: encoded) else {
  fatalError("temporary Sparkle key is not base64")
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
}
openssl rand -base64 32 >"$bridge_private_key"
openssl rand -base64 32 >"$successor_private_key"
bridge_public_key="$(sparkle_public_key "$bridge_private_key")"
successor_public_key="$(sparkle_public_key "$successor_private_key")"
plutil -replace SUPublicEDKey -string "$successor_public_key" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"

# The production transition declaration contains only public material, but its exact keys cannot
# be used by a credential-free test. Replace it only inside this disposable checkout with an
# equivalent version-locked policy backed by the two temporary seeds above.
python3 - "$ROOT/scripts/sparkle-key-transition.json" "$version" \
  "$bridge_public_key" "$successor_public_key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(
    json.dumps(
        {
            "schemaVersion": 1,
            "releaseVersion": sys.argv[2],
            "fromPublicKey": sys.argv[3],
            "toPublicKey": sys.argv[4],
            "legacyFeedKey": "owltype/appcast.xml",
            "successorFeedKey": "owltype/v2/appcast.xml",
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
# The source archive gate intentionally rejects dirty release checkouts. Commit the synthetic
# public-key policy only inside this disposable clone so HEAD, sourceSha256, the cohort, and the
# corresponding-source archive all bind the exact same trust-bridge fixture.
local_git -C "$ROOT" config user.name "Owltype release selftest"
local_git -C "$ROOT" config user.email "release-selftest@invalid.example"
local_git -C "$ROOT" add scripts/sparkle-key-transition.json
local_git -C "$ROOT" -c commit.gpgSign=false commit --quiet \
  -m "test: bind disposable Sparkle bridge policy"

cat >"$fake_adapter" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
  cohort-id)
    exec "$ROOT/package/apple_tool_adapter" "\$@"
    ;;
  sign)
    kind="\${2:?missing artifact kind}"
    source_artifact="\${4:?missing source artifact}"
    signed_artifact="\${5:?missing signed artifact}"
    if [[ "\$kind" == installer-pkg || "\$kind" == update-pkg ]]; then
      cp "\$source_artifact" "\$signed_artifact"
    fi
    ;;
  notarize|staple)
    ;;
  *)
    exit 64
    ;;
esac
EOF
chmod +x "$fake_adapter"
export OWL_APPLE_TOOL_ADAPTER="$fake_adapter"
export OWL_RELEASE_RETRY_DELAY_SECONDS=0

python3 "$STATE" initialize "$output_root"
python3 "$STATE" seal "$output_root" app 'mechanical fixture' 'mechanical fixture'
python3 "$INVENTORY" record "$output_root"

bash "$ROOT/package/make_package" "$output_root"
python3 "$STATE" seal "$output_root" installer-pkg 'mechanical fixture' 'mechanical fixture'
python3 "$STATE" seal "$output_root" update-pkg 'mechanical fixture' 'mechanical fixture'

bash "$ROOT/package/make_dmg" "$output_root"
python3 "$STATE" seal "$output_root" dmg 'mechanical fixture' 'mechanical fixture'

# Scan exactly the four artifacts created by this disposable cohort. Never fall back to package/
# outputs in the invoking checkout: they may belong to an older release and are not evidence about
# this commit. Strict mode proves every expected layer exists and carries no predecessor identity.
OWL_IDENTITY_STRICT=1 \
  OWL_APP="$app" \
  OWL_INSTALLER_APP="$ROOT/installer/build/Build/Products/Release/OwltypeInstaller.app" \
  OWL_PKG="$ROOT/package/Owltype.pkg" \
  OWL_DMG="$ROOT/package/Owltype-${version}.dmg" \
  bash "$ROOT/scripts/check-identity-residual.sh" --artifacts

cp "$sign_update_source" "$ROOT/package/sign_update"
chmod +x "$ROOT/package/sign_update"

if RELEASE_OUTPUT_ROOT="$output_root" \
    SPARKLE_ED25519_PRIVATE_KEY_FILE="$work/missing-private-key" \
    bash "$ROOT/package/make_archive" >"$failure_output" 2>&1; then
  echo >&2 "ERROR: make_archive accepted a missing explicit Sparkle private key"
  exit 1
fi
grep -qF 'SPARKLE_ED25519_PRIVATE_KEY_FILE must name a readable regular file' \
  "$failure_output" || {
    sed 's/^/     /' "$failure_output" >&2
    echo >&2 "ERROR: make_archive did not fail closed at the explicit Sparkle key seam"
    exit 1
  }

RELEASE_OUTPUT_ROOT="$output_root" \
  SPARKLE_ED25519_PRIVATE_KEY_FILE="$bridge_private_key" \
  bash "$ROOT/package/make_archive"
bash "$ROOT/scripts/create-source-archive.sh" "$output_root"
python3 "$STATE" verify-chain "$output_root"
bash "$ROOT/scripts/check-published-release.sh" --dry-run "$output_root"
bash "$ROOT/scripts/check-published-release.sh" --print0 "$output_root" >"$asset_list"

python3 - "$asset_list" <<'PY'
import sys
from pathlib import Path

records = Path(sys.argv[1]).read_bytes().split(b"\0")
assert records[-1] == b"", records
assets = [Path(record.decode()) for record in records[:-1]]
assert len(assets) == 10, assets
assert all(asset.is_file() and asset.stat().st_size > 0 for asset in assets), assets
PY

snapshot_caller_package_and_installer >"$caller_after"
if ! cmp -s "$caller_before" "$caller_after"; then
  diff -u "$caller_before" "$caller_after" >&2 || true
  echo >&2 "ERROR: mechanical release composition changed the invoking checkout"
  exit 1
fi

printf 'PASS: invoking checkout package and installer trees remained unchanged\n'
printf 'PASS: real mechanical release composition produced ten non-empty verified assets\n'

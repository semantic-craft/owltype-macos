# Owltype for macOS

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://responsay.com/owltype/)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE.txt)

**中文：[README.md](README.md)** · Product page: <https://responsay.com/owltype/>

Owltype (猫头鹰) is a local-first Chinese input method for macOS. It bundles the Rime engine and
all of its dictionary data inside the app, and rebuilds the candidate window, settings, onboarding
and emoji panel in SwiftUI — it types out of the box, with no YAML to hand-edit.

![Owltype candidate window](docs/screenshots/candidates.png)

## Install

Requires macOS 14 or later. Universal binary (Apple Silicon and Intel).

1. Download `Owltype-update.pkg` from
   [responsay.com](https://responsay.com/owltype/Owltype-update.pkg) and
   double-click it (the installer asks for administrator approval).
2. Open **System Settings → Keyboard → Input Sources** and add 猫头鹰 to the list.
3. If it does not show up in the input menu right away, log out and back in once.

Existing users do not need to download anything: the app ships a pinned Sparkle updater that reads
only `responsay.com/owltype/appcast.xml`, then downloads and installs the same signed, notarized
`Owltype-update.pkg` in place — **no logout required**. Update checks upload no typing data.

To uninstall, run the bundled `卸载猫头鹰.command`, or remove the input source in System Settings and
delete `/Library/Input Methods/Owltype.app`.

## Features

- **Self-contained Rime** — Rime-ice pinyin (full and Flypy double pinyin), Wubi 86 (Jidian), and
  simplified/traditional conversion work out of the box, with no YAML configuration.
- **Context aware** — learns your vocabulary and reorders candidates from context, entirely
  on-device.
- **One settings surface** — candidate count, simplified-in/traditional-out, skins, fonts and
  horizontal/vertical layout apply across full pinyin, double pinyin and Wubi at once.
- **Multiple skins** — collegiate palettes, light/dark aware, switchable instantly.
- **Snippets, clipboard and scenario dictionaries** for the phrases you retype.
- **Emoji and symbol panel** in the input method menu.
- **Optional AI assistant**, off by default — see the boundary below.

## Interface

Nine colour skins, light/dark following the system, applied the moment you pick one:

![Skin picker](docs/screenshots/skins.png)

Pick another skin and the candidate window follows:

![Candidate window in the Champagne Orange (Flame) skin](docs/screenshots/candidates-flame.png)

The settings panel is paged by sidebar — schema, default states and dictionaries all in one place,
no YAML to touch:

![Keyboard settings](docs/screenshots/keyboard-settings.png)

## Privacy boundary

- Keystrokes, composition, candidate generation and dictionary lookups all happen on-device.
- Cloud AI is off by default. Once enabled, requests are made only when you explicitly trigger a
  cloud feature.
- A cloud request carries only the question you submitted, the text you explicitly selected, and
  the current conversation history.
- It never carries implicit context: raw input codes, composition, candidates, screen contents,
  window or browser information, the full text of the focused field, or the text around the cursor.
- Provider keys live in the macOS Keychain, never in config files or in this repository.

See [PRIVACY.md](PRIVACY.md) for the full statement. Report security issues privately as described
in [SECURITY.md](SECURITY.md).

## Project status

- Cursor Origin is the **single private development repository** for Owltype on macOS. GitHub is
  a private backup and issue tracker; responsay.com publishes signed installers, the Sparkle feed,
  and the complete corresponding source for each distributed version.
- History starts from a privacy-reviewed 1.4.22 source snapshot; earlier Git history is not
  included.
- 1.4.21 and earlier public builds are no longer distributed or supported.
- The Windows edition lives in its own repository; its code, tags and release assets are kept
  separate from this one.

## Build from source

Requires Xcode 26+ and macOS 14+:

```sh
git submodule update --init --recursive
make setup-dev
make deps
make release
```

`make setup-dev` installs the repository's pre-push gate for the current checkout. It blocks key
files, absolute home-directory paths, private remotes, non-noreply commit identities and secret
scanner hits before anything leaves your machine. Configure this repository's Git email to your
GitHub noreply address, keep local secrets in the Keychain or in gitignored env files, and never
commit AI transcripts, debug logs or machine-local configuration.

Public builds use a clean-room dictionary seed (`scripts/owl-seed.sh`) assembled only from inputs
with an auditable redistribution grant; generated word entries are restricted to the 8,105
characters of the 通用规范汉字表. The full dictionary set is fetched from its upstream repositories
by the app on first run — Owltype does not redistribute that data. Per-input provenance is written
to `OWLTYPE-SEED-SOURCES.md` inside the build product.

Signing, notarization and packaging are handled by `scripts/release.sh`. After verification,
`scripts/owl_distribution.py --publish` publishes the complete cohort through responsay.com. There
is no hosted CI: `scripts/gate.sh` runs the merge gate on the development Mac, as described in
[docs/operations/ci.md](docs/operations/ci.md).

## Provenance and license

Released under **GPL-3.0**; see [LICENSE.txt](LICENSE.txt). Owltype is a derivative work of
[RIME Squirrel](https://github.com/rime/squirrel) and
[librime](https://github.com/rime/librime). If you distribute binaries based on this project you
must also provide the corresponding modified source, the GPL-3.0 license text and the copyright
notices; it may not be shipped as a closed-source product.
The complete corresponding source for each binary release is available from the
[stable website link](https://responsay.com/owltype/source.tar.gz). Keeping the development repository
private does not restrict a recipient's GPL rights to use, modify, and redistribute that source.

Full lineage is in [PROVENANCE.md](PROVENANCE.md); third-party component licenses are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgements

- [RIME / Rime Input Method Engine](https://rime.im) — librime and Squirrel
- [rime-ice](https://github.com/iDvel/rime-ice)
- [Wubi 86 Jidian](https://github.com/KyleBing/rime-wubi86-jidian)

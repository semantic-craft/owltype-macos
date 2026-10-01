<div align="center">

<img src="Assets.xcassets/Owltype.appiconset/icon_128x128@2x.png" width="96" alt="Owltype app icon">

# Owltype · 猫头鹰输入法

**Local typing, with AI when you need it.**

Pinyin · Double Pinyin · Wubi · Text-selection tools

**深圳大学法律人工智能实训实验室 · Shenzhen University**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://responsay.com/owltype/)
[![Apple Silicon + Intel](https://img.shields.io/badge/Apple_Silicon_%2B_Intel-Universal-grey)](#get-started)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE.txt)

[Get started](#get-started) · [Features](#features) · [Recent updates](#recent-updates) · [Interface](#interface) · [Project and feedback](#project-and-feedback)

[Website](https://responsay.com/owltype/) · [中文](README.md)

</div>

Owltype is a Chinese input method for macOS. Write with familiar Pinyin or Wubi, then select text to polish, translate or investigate its sources. Rime powers the input engine; SwiftUI provides native candidates and settings. Everyday typing stays on your Mac. Optional cloud AI runs only after you configure and explicitly invoke it.

![Owltype candidate window](docs/screenshots/candidates.png)

## Recent updates

**2.0.11 · Current source version**

- **Mixed Chinese/English Pinyin:** repairs missing English and mixed-language candidate channels after a full dictionary download or upgrade.
- **Per-app language memory:** restores the previous Chinese/English choice, with controls to inspect and forget entries.
- **Pinned candidates:** pins or unpins complete full-Pinyin candidates, with Control Shift P as the default shortcut and a context-menu entry.
- **Real onboarding practice:** checks composition and commitment of “你好，猫头鹰” in a native text field; pasting does not count.
- **Installation and presentation:** selects an available system ASCII keyboard; keeps only the lab attribution in About and refreshes both project introductions.

<details>
<summary>Acceptance scope and previous release</summary>

Mixed input and keyboard pinning have TextEdit evidence. The context menu, cross-app Shift switching and full onboarding flow still need installed-app verification. Native-controller and real-Rime integration tests cover the feature logic. See the [design and acceptance record](docs/input-habits-design.md) (Chinese).

**2.0.10 (2026-10-01)** added the MiniMax M3.1 preset and China subscription search, and restored the update channel. Users on 2.0.9 or earlier need one manual installation of 2.0.10 or later before receiving subsequent in-app updates.

</details>

## Features

### ⌨️ Familiar ways to type

Full Pinyin, Flypy double Pinyin, Wubi 86 Jidian, and simplified-to-traditional output. Adjust candidate count, fonts, orientation, initial language and per-app initial English rules in the keyboard and candidate settings. Rime keeps vocabulary learning and user frequency data on-device.

The app bundles its engine and a basic seed dictionary. Full dictionaries are downloaded from upstream through the app. Initial downloads require a network connection; everyday typing then runs locally.

### ✨ Work directly with selected text

The text-selection toolbox offers eight individually configurable actions. Enable cloud AI, configure a provider and grant the system permissions needed to read your selection first.

| Action | What it does |
| --- | --- |
| Ask | Give instructions about selected text and ask follow-up questions; search before answering when configured. |
| Polish | Improve expression and preview the result before replacing the original. |
| Translate | Translate selected text. |
| Source verification | Extract legal, case or literature references and offer sources and search routes. |
| Research assistance | Organize research approaches, keywords and queries. |
| Prompt optimization | Clarify a prompt's goals, constraints and structure. |
| Task brief | Turn a rough request into an executable brief and identify missing information. |
| Publication formatting | Tidy Chinese spacing, punctuation and paragraphs, with a replacement preview. |

Source verification groups entry points into legislation, cases and literature, including China's national laws database, PKULaw, China Judgments Online, the People's Courts Case Database and CNKI. Search routes and AI answers help you consult originals; they do not imply full database access or completed fact-checking.

### 🔌 Configure models and search separately

Presets include Alibaba Cloud Bailian, Doubao, MiMo, DeepSeek and MiniMax. You can also configure OpenAI-compatible services. Set an endpoint, model and key for your account, then test the connection.

Independent search can supply results to an answering model from a different provider. MiniMax China subscription search requires a matching subscription key. Model access, independent search and source-verification capabilities are handled separately. M3.1 supports reasoning-depth controls; reasoning cannot be disabled.

### 📋 Keep reusable content close

Quick snippets, clipboard access, emoji and symbol panels help with text you use repeatedly. Configure common shortcuts in one settings page, without editing configuration files.

### 🎨 Native settings and collegiate palettes

Nine colour palettes support light, dark and system appearance. Adjust fonts, layout, candidate styling and animations; skin changes apply immediately. Settings also include dictionary management, the sync directory, diagnostics and maintenance tools.

## Get started

**macOS 14 or later · Apple Silicon / Intel**

1. [Download the installer DMG](https://responsay.com/owltype/Owltype.dmg), open “猫头鹰安装器” and click “安装” (Install). macOS may request administrator authorization.
2. Allow the input method if macOS asks, then select “猫头鹰” in the system input menu. If it is missing, check System Settings → Keyboard → Input Sources.
3. Choose a scheme under “键盘输入” (Keyboard input), follow the dictionary setup and try typing in a newly opened text app.
4. For AI, add a provider under “AI 配置” and enable the desired text-selection tools. Ordinary typing needs no model configuration.

**Cannot type after installation?** Reopen the host app first. If it still cannot connect, follow the installer's guidance to log out and back in once. Input-method connection refresh varies by host; not every installation or upgrade can avoid logout.

**Updates:** from 2.0.10 onward, use About → Check for updates. The feed is `https://downloads.responsay.com/owltype/v3/appcast.xml`. Older versions need one manual installation of 2.0.10 or later. [Direct update-package download](https://responsay.com/owltype/Owltype-update.pkg).

**Uninstall:** open the installer and choose “卸载” (Uninstall). This also clears Owltype user data; back up personal dictionaries and configuration first if you want to keep them.

## Interface

These are the existing repository screenshots. Exact controls depend on the installed version.

| Appearance | Keyboard input |
| --- | --- |
| ![Skin picker](docs/screenshots/skins.png) | ![Keyboard settings](docs/screenshots/keyboard-settings.png) |

<details>
<summary>Another candidate-window palette</summary>

![Candidate window in Champagne Orange (Flame)](docs/screenshots/candidates-flame.png)

</details>

## Privacy boundary

- **Typing stays local:** keystrokes, composition, candidate generation and dictionary processing are not automatically uploaded.
- **Cloud AI is off by default:** even when enabled, model and search requests require an explicit action.
- **Only explicitly submitted content:** requests may contain your question, selected text and current conversation history. They do not automatically include screen, window or browser information, text outside the selection or text around the cursor.
- **Keys stay in Keychain:** they are not stored in ordinary configuration files. Updates and dictionary downloads use the network without sending typing content.

See [PRIVACY.md](PRIVACY.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Project and feedback

**深圳大学法律人工智能实训实验室 · Shenzhen University**.

- [Website and public downloads](https://responsay.com/owltype/) · [Corresponding source](https://responsay.com/owltype/source.tar.gz)
- [Issues and suggestions](https://github.com/semantic-craft/owltype-macos/issues): the development repository is private; collaborators with access can file issues. Include the app version, macOS version, host app and steps to reproduce.
- [Windows edition](https://github.com/semantic-craft/owltype-win): independently maintained, with separate versions, features and release assets.

GitHub is the single private development repository for the complete macOS product, issues and reviews. The website distributes installers, update feeds and corresponding source. Repository history starts with the 1.4.22 source snapshot; public releases through 1.4.21 are no longer distributed or supported.

## Build from source

Requires Xcode 26+ and macOS 14+:

```sh
git clone git@github.com:semantic-craft/owltype-macos.git
cd owltype-macos
git submodule update --init --recursive
make setup-dev
make deps
make release
```

`make setup-dev` installs the repository's pre-push gate for the current checkout. It blocks key
files, absolute home-directory paths, retired private remotes, non-noreply commit identities and secret
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

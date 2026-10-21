<div align="center">

<img src="Assets.xcassets/Owltype.appiconset/icon_128x128@2x.png" width="96" alt="Owltype app icon">

# Owltype · 猫头鹰输入法

**An open-source Rime input method, made for everyday typing and AI workflows.**

Native macOS UI · Pinyin / Double Pinyin / Wubi · Prompt snippets · Raycast import

**深圳大学法律人工智能实训实验室 · Shenzhen University**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://responsay.com/owltype/)
[![Apple Silicon + Intel](https://img.shields.io/badge/Apple_Silicon_%2B_Intel-Universal-grey)](#get-started)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE.txt)

[Get started](#get-started) · [AI workflows](#built-for-ai-workflows) · [Features](#features) · [Interface](#interface) · [Contribute](#project-and-feedback)

[Website](https://responsay.com/owltype/) · [中文](README.md)

</div>

Owltype is an **open-source Chinese input method for macOS, built on Rime**. Describe a task in Chinese, type a `/` command or a `$` skill name, then insert a reusable prompt: the little steps of working with AI agents belong in the input experience.

Native SwiftUI candidates, nine colour palettes, familiar input schemes and mixed Chinese/English typing keep everyday writing comfortable. Typing and snippets run locally. Optional cloud AI runs only after you configure and explicitly invoke it.

We have used Owltype ourselves for two to three months and tested it with a small group. This is a version we use reliably for everyday work. **Log out and back in once after installation** so macOS can load the input method correctly.

> 🦉 **The development repository is private; installers and corresponding source for released versions remain public.** [Download](https://responsay.com/owltype/) · [Get release source](https://responsay.com/owltype/source.tar.gz)

![Owltype candidate window](docs/screenshots/candidates.png)

## Built for AI workflows

Small details for moving between agents such as Codex and Claude Code, editors and everyday writing.

| Your workflow | The detail that helps |
| --- | --- |
| Follow a Chinese request with a `/` command | By default, `/` commits the current Chinese candidate, switches to English and outputs an ASCII slash. A symbol-menu option is also available. |
| Type a `$` skill name in Codex | The `Shift + 4` currency candidates put ASCII `$` first, with `¥` still available. |
| Switch between editors, terminals and chat | Per-app language memory, initial-English rules, English punctuation in Chinese mode and optional Chinese/English spacing. |
| Reuse a long prompt | Search snippets by title, body, tag or trigger, or insert through candidate confirmation. |
| Change the task or source material each time | Templates support parameters, defaults, choices, clipboard text, date/time and cursor placement, with a preview before insertion. |
| Skip opening a panel | Opt into automatic expansion with `;;` triggers, immediately or after a delimiter, with per-app exclusions. |
| Bring an existing Raycast snippet library | Import basic Raycast JSON, preview entries and resolve duplicates and trigger conflicts. |
| Clarify a rough request | Use the selected-text Prompt optimization or Task brief action to organize goals, constraints and missing information. |

![Prompt snippets and Raycast import](docs/screenshots/prompt-snippets.jpg)

### Turn prompts into reusable templates

Create a template under Quick snippets, set its trigger to `;;review`, choose automatic expansion and enable it under Automatic expansion settings:

```text
Review the following changes, focusing on {argument name="Focus" default="correctness and edge cases"}.
List reproducible issues first, then suggest the smallest fixes.

{clipboard}
```

Copy the material, type `;;review` in a supported text field, fill or confirm parameters, preview and insert. Search-only and candidate-confirmed invocation are also available. `{cursor}` marks the desired caret position; unsupported hosts receive a fallback notice.

**Alongside Raycast:** choose Quick snippets → Import Raycast JSON and select your export. Supported dynamic fields become templates. Unsupported or ambiguous fields stay pending until you fix them or explicitly convert the entry to plain text. This is local import, not two-way sync. Assign a shared automatic trigger to only one tool. Automatic expansion requires Owltype to be active and does not send chat messages for you.

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

Source verification groups entry points into legislation, cases and literature, including China's national laws database, PKULaw, China Judgments Online, the People's Courts Case Database and CNKI. Online checks fetch pages with Doubao Search and DeepSeek built-in web search and judge against them with citations; this needs a Doubao Search API key in Settings → AI, or a DeepSeek provider using deepseek-v4-flash. Search routes and AI answers help you consult originals; they do not imply full database access or completed fact-checking.

### 🔌 Configure models and search separately

Presets include Alibaba Cloud Bailian, Doubao, DeepSeek and MiniMax. You can also configure OpenAI-compatible services. Set an endpoint, model and key for your account, then test the connection.

Ask Anything web search uses only DeepSeek's built-in search (`deepseek-v4-flash`): configure a DeepSeek provider, and the answering model can come from another provider. MiniMax uses the GA M3.1-Flash model on the China site (api.minimax.cn); its reasoning depth is adjustable but cannot be turned off.

### 📋 Keep reusable content close

Quick snippets, clipboard access, emoji and symbol panels help with text you use repeatedly. Configure common shortcuts in one settings page, without editing configuration files.

### 🎨 Native settings and collegiate palettes

Nine colour palettes support light, dark and system appearance. Adjust fonts, layout, candidate styling and animations; skin changes apply immediately. Settings also include dictionary management, the sync directory, diagnostics and maintenance tools.

## Get started

**macOS 14 or later · Apple Silicon / Intel**

1. [Download the installer DMG](https://responsay.com/owltype/Owltype.dmg), open “猫头鹰安装器” and click “安装” (Install). macOS may request administrator authorization.
2. **Log out and back in once after installation.** Allow the input method if macOS asks, then select “猫头鹰” in the system input menu. If it is missing, check System Settings → Keyboard → Input Sources.
3. Choose a scheme under “键盘输入” (Keyboard input), follow the dictionary setup and try typing in a newly opened text app.
4. For AI, add a provider under “AI 配置” and enable the desired text-selection tools. Ordinary typing needs no model configuration.

**Cannot type after installation?** Confirm you have logged out and back in, reopen the host app and check that “猫头鹰” is selected in the system input menu.

**Updates:** from 2.0.10 onward, use About → Check for updates. The feed is `https://downloads.responsay.com/owltype/v3/appcast.xml`. Older versions need one manual installation of 2.0.10 or later. [Direct update-package download](https://responsay.com/owltype/Owltype-update.pkg).

**Uninstall:** open the installer and choose “卸载” (Uninstall). This also clears Owltype user data; back up personal dictionaries and configuration first if you want to keep them.

## Interface

Settings screenshots use sample data in the isolated 2.0.12 demo window; candidates show actual typing. Exact controls depend on the installed version.

| Appearance | Keyboard input |
| --- | --- |
| ![Skin picker](docs/screenshots/skins.jpg) | ![Keyboard settings](docs/screenshots/keyboard-settings.jpg) |

<details>
<summary>Another candidate-window palette</summary>

![Candidate window in Champagne Orange (Flame)](docs/screenshots/candidates-flame.png)

</details>

## Recent updates

**2.0.12 · Current source version**

- **Settings application:** save, compile, and refresh input sessions through one path while preserving composition.
- **Selected-text rewrites:** share confirmation, cancellation, and delivery handling; cancelled results do not preview or replace text.
- **Snippet filter:** use a theme-aware neutral background and selection highlight while retaining All / Prompts filtering.

**2.0.11**

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

## Privacy boundary

- **Typing stays local:** keystrokes, composition, candidate generation and dictionary processing are not automatically uploaded.
- **Cloud AI is off by default:** even when enabled, model and search requests require an explicit action.
- **Only explicitly submitted content:** requests may contain your question, selected text and current conversation history. They do not automatically include screen, window or browser information, text outside the selection or text around the cursor.
- **Keys stay in Keychain:** they are not stored in ordinary configuration files. Updates and dictionary downloads use the network without sending typing content.

See [PRIVACY.md](PRIVACY.md). Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Project and feedback

**深圳大学法律人工智能实训实验室 · Shenzhen University**.

- [Website and public downloads](https://responsay.com/owltype/) · [Corresponding source](https://responsay.com/owltype/source.tar.gz)
- [Maintainer issues](https://github.com/semantic-craft/owltype-macos/issues): issues and pull requests are available to collaborators with repository access. Include the app version, macOS version, host app and steps to reproduce. No public feedback endpoint is currently configured for users without access.
- [Windows edition](https://github.com/semantic-craft/owltype-win): independently maintained, with separate versions, features and release assets.

GitHub is the private development repository for authorized collaborators working on the macOS product, issues and reviews. The website publicly distributes installers, update feeds and corresponding source. Repository access does not change the GPL-3.0 license of distributed versions. Repository history starts with the 1.4.22 source snapshot; public releases through 1.4.21 are no longer distributed or supported.

## Build from source

Requires Xcode 26+ and macOS 14+. Without repository access, download the
[release source archive](https://responsay.com/owltype/source.tar.gz), extract it and follow
the included build instructions. The clone and Git hook commands below are for authorized
repository collaborators:

```sh
git clone https://github.com/semantic-craft/owltype-macos.git
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
[stable website link](https://responsay.com/owltype/source.tar.gz). You are welcome to use, modify and redistribute the source under the GPL. The development branch
may differ from the source of a released binary.

Full lineage is in [PROVENANCE.md](PROVENANCE.md); third-party component licenses are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgements

- [RIME / Rime Input Method Engine](https://rime.im) — librime and Squirrel
- [rime-ice](https://github.com/iDvel/rime-ice)
- [Wubi 86 Jidian](https://github.com/KyleBing/rime-wubi86-jidian)

# Lessons from verified work

Each entry keeps the rule, reason, regression, a `Verify (验证点):` line (how to check later
that the lesson is in place: which file to read, which command to run, what result to expect),
and dates observed. Count distinct
review dates, not retries. Keep deterministic checks in the local gate.

## The gate completes the checkout before the first check reads it

**`submodules` is the gate's second stage, right after `tools`; no later stage may be the first to need a submodule, and the receipt must not count that initialization as a source change.**

- Reason: the first full gate in a fresh worktree (`20261022T000748Z-full-60z149yn`, the head of
  PR #241) failed in `portable_scripts`: `build-sparkle.selftest.py` runs `git archive` against
  the pinned revision inside `Sparkle/`, still an empty directory, so git answered
  `fatal: not a tree object`. `git submodule update --init --recursive` lived in `bootstrap_seed`,
  four stages later. The main checkout has always had its submodules, so the order was never
  exercised; the run was repeated after a manual initialization. A gate that had reached the
  end would still have failed: [verify.py](scripts/verify.py) recorded every submodule as
  `uninitialized` before and in full after, which reads as `source-changed`.
- Prevention: `submodules` is the second entry of `gate_steps` in both modes and `bootstrap_seed`
  no longer initializes. The receipt records a submodule that matches its gitlink as `pinned`
  whether or not it is initialized, so initialization alone is never a source change, while a
  modified or re-pointed submodule is still recorded in full.
- Regression: `test_gate_initializes_submodules_before_any_check_reads_the_tree`,
  `test_submodule_initialization_during_check_is_not_a_source_change` and
  `test_edit_inside_a_submodule_during_check_is_a_source_change` in
  [verify.selftest.py](scripts/verify.selftest.py), run by the `navigation` stage of
  [the merge gate](scripts/gate.sh); all three fail on the previous scripts. The full gate of
  this change ran first in a worktree with no initialized submodule (PR #242).
- Seen on 1 distinct date: 2026-10-22.

## A probe must see the process that runs it and must not parse display text

**List servers with `pgrep -a`, because the App re-checking itself is the probe's parent; take a server's path and version from `proc_pidpath` and its bundle, not from `lsappinfo` text.**

- Reason: a tester's update to 2.0.20 through 检查更新 (2026-10-22) showed 「阶段「核验会话」失败：
  自检超时（selfCheckTimedOut）；未满足：运行中的猫头鹰不在 /Library/Input Methods（）；运行中的版本为 ，
  预期 2.0.20」 above 「刚才重新探测：没有运行中的猫头鹰进程」, while typing worked. Two faults. The
  installer's probe saw exactly one server mapping the installed executable's inode, but the path
  and version it parsed from `lsappinfo info -only executablepath,CFBundleVersion` were empty: the
  parser matched only `executable path="…"` and `Version="…"`, the layout macOS 27.0.1 prints
  (checked on Helios and Janus). What the tester's Mac printed is unknown; a 2020 write-up of
  `lsappinfo` on Catalina shows raw `"Key"="Value"` pairs, and a pid LaunchServices does not know
  prints nothing. Separately, the App's re-probe (#240) runs the probe as its child, and macOS
  `pgrep` leaves out its own ancestors unless given `-a`, so the running App never saw itself and
  every re-probe reported no server. Only fakes had exercised the re-probe before release.
- Prevention: `OwlSessionRestart.serverQuery` passes `-a`; the probe still drops the driver and
  itself. `OwlSessionRestart.server` takes the path from `proc_pidpath` and the version from the
  Info.plist beside the executable, read only while the process maps the file at that path. The
  probe no longer runs `lsappinfo`.
- Regression: `testServerQueryListsTheProcessThatRunsIt` (fails without `-a`) and
  `testServerFactsComeFromTheKernelAndTheBundle` in
  [OwlSessionRestartTests](tests/OwlSessionRestartTests.swift). Not verified: the fixed probe on the
  tester's Mac, whose macOS version is unknown.
- Verify (验证点): `make test TEST_ONLY='OwlSessionRestartTests'` passes; `rg -n 'usr/bin/lsappinfo' sources installer` finds nothing.
- Seen on 1 distinct date: 2026-10-22.

## A failed self-check must say which step failed and what it saw

**Record the stage, the error and the unmet conditions of a failed install self-check; re-probe before guidance and keep the reason in the support bundle.**

- Reason: the 2.0.14 report in #207 (filed 2026-10-11) and a tester's 2026-10-22 report after an
  update through 检查更新 both arrived as a screenshot of 「安装后的会话自检未通过」 with 「稍后处理」
  clicked, and typing worked in both. The App persisted only the failed version;
  `selfCheckTimedOut` named no stage, no condition and no probe result; the reason lived in the
  GUI dialog or `/var/log/install.log`, which neither tester sent. The prompt also fired without
  re-checking, so a transient failure showed stale guidance.
- Prevention: `OwlSessionRestart.run` reports each stage through `didEnter`; `diagnose` turns
  the thrown error and the last observation into a `Diagnosis` (stage, reason, unmet
  conditions, observation). The CLI prints `INSTALL_SESSION_DIAGNOSIS:` after
  `INSTALL_SESSION_FAILED:` and stores the record beside the failed version
  ([OwlInstallSelfCheckRecord](sources/Controller/OwlUpdateLogoutPrompt.swift)). At the
  input-safe time the App runs the same probe again and skips the prompt when every server
  condition holds; the alert and the support bundle section 「安装自检」 carry both facts.
- Regression: `testTimeoutDiagnosisNamesTheStageAndWhatTheLastProbeSaw`,
  `testSelectionThatNeverTakesEffectIsAttributedToTheSelectStage` and
  `testConsentTimeoutDiagnosisReportsOnlyTheEnableCondition` in
  [OwlSessionRestartTests](tests/OwlSessionRestartTests.swift);
  `test_selfCheck_failureStoresDiagnosisBesideVersion_passClearsBoth`,
  `test_recheckDecision_onlyACleanProbeCountsAsRecovered` and
  `test_recordRecovered_consumesPromptAndKeepsRecordMarkedRecovered` in
  [OwlUpdateLogoutPromptTests](tests/OwlUpdateLogoutPromptTests.swift). A tester's 2.0.20 alert
  (2026-10-22) carried a real failure's diagnosis and exposed two probe faults (previous entry); a
  passing re-probe on a tester's Mac remains unverified.
- Verify (验证点): `make test TEST_ONLY='OwlSessionRestartTests OwlUpdateLogoutPromptTests'` passes; a real failed self-check prints an `INSTALL_SESSION_DIAGNOSIS:` line after `INSTALL_SESSION_FAILED:`.
- Seen on 2 distinct dates: 2026-10-11, 2026-10-22.

## Run live tests through scripts/live-test.sh

**Live keys come from the environment only; `scripts/live-test.sh` loads them through direnv and fails when a named live test skips.**

- Reason: the DeepSeek key was in the project's `use secrets`, yet live tests skipped and the
  agent reported the key as missing. Three causes stacked: tests read keys from three places
  (`TEST_RUNNER_*`, `~/.owl-test-key`, `~/.owl-test-key-doubao`); the agent shell is not a login
  shell and had inherited a stale direnv export (DashScope and Ark keys, no DeepSeek key); and
  xcodebuild drops plain environment variables, so a skip looked like a clean run.
- Prevention: [OwlLiveKeys](tests/OwlLiveKeys.swift) is the only key reader and key list.
  [live-test.sh](scripts/live-test.sh) reads the names from it, always re-resolves them with
  `direnv exec` against the current `.envrc`, forwards them as `TEST_RUNNER_*`, and exits non-zero
  when a requested test skips. A blocked `.envrc` stops the run; the user approves it with
  `direnv allow`.
- Regression: [live-test.selftest.sh](scripts/live-test.selftest.sh) in the gate covers the
  stale-environment case, skip-as-failure, a blocked `.envrc` and keys never printed.
- Verify (验证点): `scripts/live-test.selftest.sh` passes; a live run through `scripts/live-test.sh` exits non-zero when a named live test skips.
- Seen on 1 distinct date: 2026-10-21.

## A web_search tool in the request is not a search

**Search with an explicit request, not a tool the model may ignore; take sources only from its results.**

- Reason: DeepSeek now serves `deepseek-v4-flash` as `deepseek-flash` (V4.1 Flash), which accepts
  the `web_search` tool and `tool_choice: required` yet never searches. It answered from memory
  with plausible official links, and its reasoning said it could not actually go online. Ask and
  source verification both showed these answers as searched. `deepseek-v4-pro` really searches:
  source verification took 17 to 23 seconds with links it had fetched.
- Prevention: DeepSeek search is a `POST /v1/tools/search` request
  ([OwlDeepSeekSearch](sources/Lane/OwlDeepSeekSearch.swift)); `deepseek-flash` answers from the
  numbered results with no `web_search` tool. Ask appends a sources footer built from the
  results, so a URL the model invents never reaches the user. Search failures with 401/402/403/404
  fail over to the next DeepSeek profile.
- Regression: `testSearchedAnswerNeverCarriesModelInventedSources` in
  [OwlAskAnythingModuleTests](tests/OwlAskAnythingModuleTests.swift),
  `testDeepSeekAloneSearchesAndFlashJudges` in
  [OwlSourceVerificationTests](tests/OwlSourceVerificationTests.swift); live checks
  `testAskWebSearchOnDeepSeekSearch` and `testSourceVerificationOnDeepSeekSearch` in
  [OwlSkillsLiveTests](tests/OwlSkillsLiveTests.swift).
- Verify (验证点): `make test TEST_ONLY='OwlAskAnythingModuleTests'` passes (includes `testSearchedAnswerNeverCarriesModelInventedSources`).
- Seen on 1 distinct date: 2026-10-21.

## The self-check budget must not include the user's consent

**Wait for the enable consent on its own deadline; start the 45-second self-check after it.**

- Reason: the same Mac as the next entry ran the notarized 2.0.17 GUI installer as a first install
  and got `INSTALL_SESSION_FAILED: selfCheckTimedOut`. The 45 seconds started before the
  「允许启用输入法」consent, so a late or hidden dialog spent the whole budget. A retry then ran as
  an update, which never requested enabling, so it could not recover. No probe output from that
  Mac was available; the consent wait is the inferred cause, and a surviving Owltype copy
  outside `/Library/Input Methods` (which the old code did not stop) is the other candidate.
- Prevention: `OwlSessionRestart.run` waits up to 120 seconds for enabled sources and fails with
  `inputSourceNotEnabled`; an update that finds them disabled requests enabling once; the session
  driver stops every process with the bundle id; the GUI shows consent guidance for that failure.
- Regression: `testConsentWaitDoesNotSpendTheSelfCheckBudget`,
  `testMissingConsentFailsWithItsOwnReason` and
  `testUpdateOfDisabledSourceRequestsEnableOnceSoRetryRecovers` in
  [OwlSessionRestartTests](tests/OwlSessionRestartTests.swift). A native GUI first install with
  consent remains unverified.
- Verify (验证点): `make test TEST_ONLY='OwlSessionRestartTests'` passes (includes `testConsentWaitDoesNotSpendTheSelfCheckBudget`).
- Seen on 1 distinct date: 2026-10-21.

## An existing App directory is not an existing install

**Classify first install versus update by `Contents/Info.plist`, not by the App directory.**

- Reason: a user's Mac had `/Library/Input Methods/Owltype.app` without `Contents/Info.plist`
  (an incomplete earlier removal). The GUI installer treated it as an update, and
  `--commit-install` failed reading the old Info.plist (`NSCocoaErrorDomain` 260,
  `INSTALL_FILES_FAILED`). preinstall would have failed too, running the missing executable.
- Prevention: the commit moves such a shell to the installer's `retained/` and publishes a
  first install; GUI and preinstall use the same Info.plist test, so session activation
  registers and enables the source instead of waiting for an update that has none.
- Regression: `testIncompleteLiveAppIsRetainedOutsideInputMethodsAndInstalledFresh` in
  [OwlInstallFilesTests](tests/OwlInstallFilesTests.swift). The GUI and preinstall
  classification has no offline test; a native install over an empty shell remains unverified.
- Verify (验证点): `make test TEST_ONLY='OwlInstallFilesTests'` passes (includes `testIncompleteLiveAppIsRetainedOutsideInputMethodsAndInstalledFresh`).
- Seen on 1 distinct date: 2026-10-21.

## Compare canonical paths with realpath, and test under /private

**Symlink checks must use realpath(3) on the raw path; file-system tests must run under the real `/private/...` path.**

- Reason: 2.0.16 moved install intermediates to `/private/var/db/...`. The candidate check
  compared `resolvingSymlinksInPath()` with the path, and Foundation drops a leading `/private`
  (so does `standardizedFileURL`), so the first real PKG install failed with `ELOOP` in
  `--commit-install`. The tests passed because their temp root was `/var/folders/...`, itself a
  symlinked path that Foundation round-trips unchanged. The live App stayed on 2.0.15; nothing
  was published.
- Prevention: `OwlBundleSwap.isCanonical` uses `realpath` against `url.path`; both bundle tests
  build their root with `realpath`, so it starts with `/private`.
- Regression: [OwlInstallFilesTests](tests/OwlInstallFilesTests.swift) and
  [OwlBundleSwapTests](tests/OwlBundleSwapTests.swift); the old check fails 4 of 8
  OwlInstallFilesTests. They run in [the merge gate](scripts/gate.sh). Offline tests still do not
  replace a real signed PKG install before publishing.
- Verify (验证点): `make test TEST_ONLY='OwlInstallFilesTests OwlBundleSwapTests'` passes; `rg -n realpath installer/Shared/OwlBundleSwap.swift` finds the check in `isCanonical`.
- Seen on 1 distinct date: 2026-10-20.

## Pin every gzip parameter a fixture depends on

**Fixtures that feed the canonical-archive gate must pass `compresslevel=9`, not rely on Python's default.**

- Reason: Python 3.15 lowered `gzip.GzipFile`'s default level from 9 to 6, which writes
  XFL `0x00` instead of `0x02`. The release-source and release-chain fixtures omitted the
  level, so the gzip header gate rejected them before the ownership and member-type checks
  they meant to exercise, and the full gate failed on main. The production writer already
  pinned the level and was unaffected.
- Prevention: pin `compresslevel=9` and `mtime=0` in every fixture that builds a
  `.tar.gz` for `check-archive-metadata`.
- Regression: [release-source-archive.selftest.py](scripts/release-source-archive.selftest.py)
  now recompresses a valid archive at level 6 and requires the gzip-metadata rejection.
  It runs in [the merge gate](scripts/gate.sh).
- Verify (验证点): `python3 scripts/release-source-archive.selftest.py` passes.
- Seen on 1 distinct date: 2026-10-19.

## Never install an ad hoc build as the input method

**Installed copies must carry a stable certificate requirement, not a per-build cdhash.**

- Reason: `install-dev.sh` re-signed the installed App ad hoc and `make install*` copied
  ad hoc or unsigned builds over the notarized copy. Keychain grants follow the designated
  requirement, so each rebuild would re-prompt for the login password; leftover ad hoc
  claims of the same bundle id made macOS resolve the input method to a dead build at login
  ([conclusion A](docs/default-input-method-plan.md)). Sonori hit the Keychain prompt on
  three dates (2026-10-13, 10-16, 10-19).
- Prevention: [stable-sign-identity.sh](scripts/stable-sign-identity.sh) picks the identity;
  `install-dev.sh` rejects `# designated => cdhash` and identity changes before copying; the
  `make install*` targets refuse. Real upgrade with silent Keychain reads still needs a
  human-run install, which the self-test does not cover.
- Regression: [install-dev.selftest.sh](scripts/install-dev.selftest.sh) runs the real script
  with a fake bundle and mocked `codesign`/`security`; it failed 8/8 cases on the old script.
  It runs in [the merge gate](scripts/gate.sh).
- Verify (验证点): `scripts/install-dev.selftest.sh` passes.
- Seen in this project on 1 distinct date: 2026-10-19 (found by audit; same class as Sonori).

## Every bundle that claims the id is a menu entry

**Uninstall and repair must clear all Owltype claims, not just the installed App.**

- Reason: a user's input menu showed two「猫头鹰输入法」entries, one with the 2.0.15 profile
  owl and one with the ≤2.0.14 badge icon. The old uninstaller deleted only
  `/Library/Input Methods/Owltype.app`, so older copies, installer `.Owltype.*` leftovers
  (LaunchServices registers them; 33 were on the development Mac) and stale records survived
  a reinstall. Which copy the user's Mac held is unconfirmed.
- Prevention: [repair-owltype.sh](scripts/repair-owltype.sh) and
  [uninstall-owltype.sh](scripts/uninstall-owltype.sh) share
  [owltype-maintenance-lib.sh](scripts/owltype-maintenance-lib.sh): remove stray copies,
  unregister every other claim, purge the list caches that mention the id, restart the menu agents.
- Regression: [uninstall-repair.selftest.sh](scripts/uninstall-repair.selftest.sh) runs both
  scripts against a fake system root with mocked privileged tools. It runs in
  [the merge gate](scripts/gate.sh). Not yet run on the affected Mac.
- Verify (验证点): `scripts/uninstall-repair.selftest.sh` passes.
- Seen on 1 distinct date: 2026-10-20.

## A librime session id is not a session identity

**Prove a session was recreated by its wrapper, never by comparing `RimeSessionId`s.**

- Reason: librime returns the `Session`'s heap address as its id
  ([service.cc](librime/src/rime/service.cc)), so destroy-then-create often gets the
  freed address back. `testControllerRoundTrip` asserted a new id after applying
  settings and failed once in `gate.sh --quick`
  (`20261020T080929Z-quick-idniri2m`, both ids `524545235096`) while the next
  assertions, including the new page size, passed. A probe reused the id in 1250 of
  3000 destroy/create pairs. The `start_maintenance failed` line in that log came
  from a later test and is unrelated.
- Prevention: assert the old wrapper is invalid (`destroy` zeroes its id) and the
  controller holds a different wrapper. Product staleness checks that key on
  `sessionID` (snapshots, pin and expansion callbacks) also see reused ids; they pair
  it with input and revision state.
- Regression: [OwlInputHabitsIntegrationTests](tests/OwlInputHabitsIntegrationTests.swift)
  now checks wrapper identity, which is independent of allocator reuse. It runs in
  [the merge gate](scripts/gate.sh).
- Verify (验证点): `make test TEST_ONLY='OwlInputHabitsIntegrationTests'` passes; `scripts/gate.sh` runs it.
- Seen on 1 distinct date: 2026-10-20.

## Require positive evidence before judging a live trace

**An empty or unfinished trace is unverified, even when its error count is zero.**

- Reason: `omnibox judge` returned success for an empty file and a composition
  that never cleared. Zero `commitComposition finalize` lines did not show that
  the intended interaction happened.
- Prevention: require a non-empty composition and a final zero-length clear
  before emitting PASS; keep forced-finalize rejection. The judge covers these
  trace properties only; host identity, the actual input sequence, and visual
  acceptance remain the live host matrix's responsibility.
- Regression: [smoke-live.selftest.py](scripts/smoke-live.selftest.py) invokes the
  actual shell judge with empty, unrelated, clear-only, unfinished, valid and
  forced-finalize logs. It runs in [the merge gate](scripts/gate.sh).
- Verify (验证点): `python3 scripts/smoke-live.selftest.py` passes.
- Seen on 1 distinct date: 2026-10-15.

## Commit endpoint and replacement key reference together

**Write a replacement key under an independent secret name before committing its endpoint.**

- Reason: saving the endpoint first exposed the old key if Keychain failed and rollback
  also failed. An atomic config write can also succeed before permission hardening throws;
  a thrown save does not prove that nothing was persisted.
- Prevention: commit endpoint and new secret reference together; retire the old key only
  after confirmed success and only if no profile references it. An ambiguous save retains
  both keys; a readable old reference with no staged-key reference permits staged-key cleanup.
  Compare scheme/host/default-normalized port against the persisted profile: origin changes
  require a nonblank replacement key. Same-origin edits preserve the persisted key reference,
  and failed-save retries refresh the editing profile from the reloaded list.
  Probe requests also require a replacement key when the origin changes.
- Regression: `ProviderProfileStoreTests` reloads the real JSON store and checks both
  `defaultProfile` and `OwlCloudRouting` for retired/custom defaults. Post-write errors and
  key-write plus rollback failures produced 8 assertion failures before the fix.
- Scope: isolated file storage and injected secret-store failures; no live Keychain or
  installed-app upgrade acceptance is claimed.
- Verify (验证点): `make test TEST_ONLY='ProviderProfileStoreTests'` passes.
- Seen on 1 distinct date: 2026-10-21.

## Make one live call before merging a new external-API capability

**A feature that depends on a provider's live behavior is not mergeable until one real request has shown that behavior; mocked tests only prove our side.**

- Reason: #233 (d70c63f) added DeepSeek built-in web search to source verification with 8 mocked
  service tests and stated "未做：DeepSeek 真实联网调用" because no DeepSeek dev key was on the
  machine. The first live run showed Flash never searched and invented links, so the same day
  needed #236 (bdf9c5d, switch to v4-pro) and #237 (881f85c, search API plus flash), the latter
  shipped in 2.0.19.
- Done right: #237 ran `scripts/live-test.sh` with all six named live tests passing and listed
  per-test timings; #236 ran live checks before merge.
- Prevention: when no key is available, keep the PR open or behind a disabled default and ask for
  the key instead of merging on mocks.
- Verify (验证点):
- Seen on 1 distinct date: 2026-10-21.


## 删除开发产物前先检查运行引用与应用注册

- 起因与后果：2026-10-23 本机盘点发现多个项目已删除的构建／验收 App 仍有 LaunchServices 注册；删除目录不会自动注销。历史引入提交未确定。
- 修复：本次清理入口改为精确目录注销，包含嵌套辅助 App、已失效路径和同路径多条记录；注销失败或目录内有运行中的可执行文件就保留产物。删除后再核对注册。
- Done right：只处理调用方拥有的临时目录，不停止进程、不重建数据库；正式安装与其他工作区不在清理范围。
- Verify (验证点)：运行 cleanup_app_registrations 的回归，检查运行中副本、符号链接、注销失败及嵌套／重复记录；真实隔离 App 验证另记 PR，模拟测试不替代本机证据。
- Seen 1x (2026-10-23)。

# Pinyin differential replay

`scripts/pinyin-parity.py` runs the same event stream through the unmodified,
fixed MSIME Host API and the Swift `OwlRustEngine` / `RimeSession` seam used by
Owltype. This includes Swift configuration and candidate handling. It does not
launch or install either input method, load personal preferences, or read a
personal dictionary. Every replay creates new temporary learning state.

The reference source is `macos-v0.55.0`, commit
`208c10e848bbed99373ca8b609fd2142b6b0b4e2`. The machine's installed MSIME was
confirmed as version 0.55.0; the selected reference is a source-built Host API,
not the installed IMK executable. The resource manifest and every file used
from the selected public desktop resource bundle are pinned by SHA-256 in
[baseline.json](../../tests/fixtures/pinyin-parity/baseline.json), including the
bigram/trigram and sentence models. The manifest identifies dictionary release
`dict-v2.0.24`, builder commit `128a332cabc5fa42b1cf5f827033ad5697ff528b` and
custom dictionary commit `71dc6f6cc7a451231ee29c0a39b39adbf2e04d32`.

The default `native-mac-host` profile preserves `prepare_host` preferences and
adds the three boolean capabilities requested by the pinned macOS
`MSIMESessionOptions` (`platforms/macos/src/input/InputController.mm:6050-6070`):
`phrase_preedit=true`, `korean_romaja=true`, and `quick_phrase_candidates=true`.
These are host capabilities, not persisted preferences. The sound-pack and
helpcode fallback paths in that function are resource locators; this pinyin
replay uses the pinned complete resource set and does not test sounds/helpcode.
`--reference-profile raw-host-api` reproduces the original bare API contract.
Every evidence file names the profile, source commit, overrides and complete
effective options; the comparator applies the same strict fields to both.

The Owl test starts with empty isolated preferences and sets only the same page
size (upstream default 6) and full-pinyin schema. It records persisted preferences
and effective rerank configuration. Rust options remain source-bound by a fresh
build. Ordinary pinyin uses pinned 0.55.0 engine/runtime and official resources;
Wubi retains its existing composition policy. Native quick-phrase candidates are
enabled without Owl's former blanket promotion. The earlier bare-API conclusion
that ordinary quick phrases should be disabled was corrected from the macOS
session-options source. Owl AI/template invocation is a separate host feature.
Model switches default off on both.

## Run

Choose an external directory for the reference checkout/build and the evidence.
Install Rust 1.98.1 and its `aarch64-apple-darwin` target if needed. Build the
reference from its pinned public commit:

```sh
python3 scripts/build-pinyin-reference.py "$REFERENCE_BUILD"
```

This fetches the exact commit, requires a clean source tree before and after
`cargo build --locked --release -p msime-host-api`, and writes `build.json`
containing source identity, builder hash, toolchain/target, and library hash.
The historical known build can also be used without a receipt when its exact
pinned SHA-256 matches. Modified sentence-alternative builds are rejected.

Prepare the normal project dependencies/resources, then build the current test
host. The export test skips during ordinary runs unless the runner injects its
request and output paths:

```sh
make bootstrap
make test TEST_ONLY=OwlRustEngineTests/testExportPinyinParityTrace
python3 scripts/pinyin-parity.py \
  --reference-library "$REFERENCE_BUILD/libmsime_host_api.dylib" \
  --reference-build-receipt "$REFERENCE_BUILD/build.json" \
  --reference-resources "$REFERENCE_RESOURCES" \
  --xctestrun "$XCTESTRUN" \
  --output "$EVIDENCE"
```

`REFERENCE_RESOURCES` must contain the pinned public desktop resource set.
The runner verifies all pinned hashes before loading the library. Obtain that
resource set from the matching official desktop distribution; a personal
resource generation with a different hash is rejected. `XCTESTRUN` is the
`.xctestrun` file produced under the chosen derived-data `Build/Products`
directory. The runner rebuilds the current Rust and Swift sources into that derived-data
directory before using the test host; a supplied stale test host alone is not
accepted as current-source evidence. `--owl-resources` can explicitly select an isolated
packaged SharedSupport directory; by default it uses `data/owl-rime`.

Exit 0 means equal observations, 1 means a behavioral difference, and 2 means
incomplete/invalid evidence. `comparison.json` keeps both complete traces, the complete reference host options,
configuration, resource hashes and each field difference. The runner rebuilds the
Rust archive and Swift test host from the current source before each replay,
requires unchanged source throughout, and records the source HEAD/dirty diff,
commands, host/test-bundle/archive hashes. It clears the old export and requires
a fresh run identifier echoed by the Swift exporter. Test-host execution
must pass before comparison; missing/empty steps cannot pass the comparator.
The pure comparator checks run in the normal gate:

```sh
python3 scripts/pinyin-parity.selftest.py
```

The JSON fixture supports single ASCII characters; backspace, commit, cancel,
caret movement, delete and page commands; and selecting a visible candidate.
The default `tadefangjian` trajectory records every character, traverses all 31
reference pages and returns to page one, then selects its second visible row.
Thus the complete reference order and later-page behavior remain observable.
A different trace can be supplied with `--trace`.

## Observations and limits

Every step compares event consumption, raw remaining input, exact preedit,
caret, all visible candidate texts in order, page number/size, last-page state,
highlight, and drained commit. Candidate/session/generation numbers are local
identities, so they are not numerically compared. Each endpoint selects through
its own currently published identity: MSIME uses the visible candidate's
`generation/index`; Owl uses the public session selection method. No candidate
text/order, page, commit, or behavior field is discarded as cosmetic.

The fixed, fresh-state upstream default returns **它的房间 / 他的房间 / 她的房间**.
The reported screenshot shows **他的房间 / 她的房间 / 它的房间**. Its source version,
effective configuration and learned state were not captured, so the screenshot
order cannot be attributed to one of those causes. Its three sentence readings
are present in this baseline, but its exact order is not reproduced. The oracle
preserves the actual isolated default rather than editing it to match either
the screenshot or Owltype. The default `tadefangjian` trace now matches all 75 events, including all
candidate pages, first/last-page consumption and the second-row commit. The
boundary-page adapter must preserve the upstream `handled` result even when the
page number stays unchanged; the key belongs to the composition and must not
scroll the host document.

Use `--trace tests/fixtures/pinyin-parity/full-pinyin.json` for sentence,
segmentation and initial-letter checks, `mixed-input.json` for mixed input, and
`editing.json` for partial selection from a later page, continuation/backspace,
raw commit, caret movement, forward delete, Esc and deletion to empty. The
reference's native marked text joins `phrase_prefix` with `preedit`, as the macOS
presenter does; original host views are preserved in `reference.raw_views`.
`commit` means upstream `Command::CommitRaw` and sends Return through Owl's
public key seam. Selection always uses each endpoint's current visible identity.
The strict comparator has no field exclusions.

Auxiliary resources retain the audited emoji derivative because the upstream
notice identifies unresolved PiliApp redistribution permission; see the
production resource notice.

This seam does not prove IMK event delivery, installed-app rendering, installed
resource activation, asynchronous pause-phase model behavior, or private
learned-state parity. Model files and defaults are pinned; this initial trace
uses the upstream default model settings. Those limitations do not change the
observable synchronous differences reported by this runner.

## Keyboard model control

The ordinary differential replay leaves both neural switches off, as upstream does.
Use the explicit official-resource C ABI regression to compare keyboard scoring with
its pinned Host API oracle. Prepare the normal seed and locked models first, then run:

```sh
python3 scripts/fetch-rerank-models.py --check
OWL_MODEL_PARITY_RESOURCES="$PWD/data/owl-rime/msime" \
  cargo test --manifest-path rust/Cargo.toml -p owl-msime-ffi --test model_parity -- --ignored --nocapture
```

The opt-in test fails when the requested resources are absent. It compares all six
visible `tadefangjian` rows with model-off and model-on orders captured through
macOS 0.55.0's Host API, checks cold and shared-cache sessions, selection identity,
engine replacement, disabling during composition, and missing/corrupt/digest-error
fallback. It prints measured loading and typing time without treating a machine's
latency as a portable pass threshold. Model-on changes the first row to `他的房间`
and also changes later sentence/completion rows; checking only the first row misses
a disconnected engine lattice scorer.

The host passes its already validated worker-loaded keyboard weights into the
existing upstream lattice scorer and runtime reranker. This avoids a second file
lookup under the engine's canonical filename and keeps candidate identity tied to
the refreshed view. The model algorithms and default switches remain upstream's.
Desktop pause scheduling and installed IMK behavior require their own acceptance.

## Learning and process restart

`--trace tests/fixtures/pinyin-parity/learning.json` starts both sides with new,
separate learning roots. It selects 尼 from the second row, verifies the changed
complete paged order, restarts, removes the dictionary phrase 你好吗 and restarts again.
The fixture also checks independent six-row learning checkpoints, so equal but
unchanged ranking or a reset learning root cannot pass.
Every `restart` begins a fresh reference Python process and a fresh Owl XCTest
host process while reusing only that endpoint's temporary learning directory.
The runner removes both directories on completion. The output records the process
run count. Thus persistence is observed through candidates after process exit,
without reading a journal table or a user's existing dictionary.

The `remove` action addresses a visible row by its current generation and index.
The Owl adapter rejects stale/foreign session tokens, absolute preview rows and
punctuation-menu generations before dispatching upstream `RemoveCandidate`.
The existing candidate context menu exposes deletion for multi-scalar visible
rows. The macOS upstream shortcut, Ctrl–Option–Shift + physical number-row 1–8,
is also reserved while candidates are present; rejected or repeated deletion
never falls through to normal commit. The engine retains its single-Han-character
protection and source eligibility checks. A deleted dictionary phrase may still
be generated as a sentence; deletion means the upstream dictionary operation,
not a blanket text blacklist.

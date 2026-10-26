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

Reference preferences come directly from `prepare_host` in an empty state root.
No reference preference is overridden. In particular, sentence alternatives,
mixed input, correction, learning, and model defaults stay enabled or disabled
exactly as upstream chooses. The Owl test starts with empty test preferences and
sets only the same page size (upstream default 6) and the full-pinyin schema.
It writes its persisted preferences and effective rerank configuration alongside
the complete reference host options. Rust EngineOptions do not have a public
getter at this seam; their remaining defaults are source-bound by the build
identity. In the starting code, `rust/crates/owl-msime-ffi/src/lib.rs` sets
`sentence_alternatives=false`, English prefix 2 / first-page count 3; upstream
uses sentence alternatives, prefix 5 / first-page count 1. These known differences
are retained and visible in the resulting candidates; matching page size is not
a claim that all configuration already matches. Model switches default off on
both endpoints.

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
the screenshot or Owltype. The baseline Owl packaged seed returns 塔德房间;
this is an intentionally failing differential command until subsequent parity
work fixes production.

This seam does not prove IMK event delivery, installed-app rendering, installed
resource activation, asynchronous pause-phase model behavior, or private
learned-state parity. Model files and defaults are pinned; this initial trace
uses the upstream default model settings. Those limitations do not change the
observable synchronous differences reported by this runner.

# Re-pinning the MSIME dictionary and engine

Owltype ships one fixed MSIME engine tag and one fixed `dict-v*` dictionary release.
[`rust/msime-source.json`](../../rust/msime-source.json) is the only place that names them:
`tag`/`revision` for the engine, `resources.release` plus the manifest's SHA-256 and size for
the dictionary. The manifest itself, [`data/msime-dictionary-manifest.json`](../../data/msime-dictionary-manifest.json),
is the upstream release's file byte for byte and supplies every member digest.

Scripts read the pin through [`scripts/msime_pin.py`](../../scripts/msime_pin.py). Documents,
fixtures and Swift constants repeat it as literals, and `msime_pin.py check` fails until each one
agrees. The gate runs that check.

## Is upstream ahead?

```sh
python3 scripts/msime_pin.py drift
```

Read-only. It lists `macos-v*` and `dict-v*` tags newer than the pin (pre-release suffixes such
as `-beta` are ignored) and, for the newest dictionary tag, which manifest members changed size
or content. It downloads only that manifest.

## New dictionary tag

1. Download both releases into a directory outside the checkout and check them against their
   manifests (`curl -LO …/releases/download/<tag>/<member>` for the manifest and the product
   members: pinyin, Wubi, English, bigram, trigram, others, `msime-scowl_Copyright.txt`).
2. Write the change report and keep its numbers for the pull request:

   ```sh
   python3 scripts/msime-dictionary-diff.py OLD_DIR NEW_DIR --json diff.json --markdown diff.md
   ```

   It counts added, removed and re-weighted words, codes whose first candidate changed, new
   Wubi duplicate codes and four-letter codes that lose unique auto-commit. Keep the report under
   `docs/reports/` when it explains a behaviour change users will notice.
3. Copy the new manifest to `data/msime-dictionary-manifest.json`; set `resources.release`,
   `manifestSha256` and `manifestSize` in `rust/msime-source.json`.
4. Run `python3 scripts/msime_pin.py check` and fix every site it names. It covers the resource
   and others notices, `PROVENANCE.md`, `THIRD_PARTY_NOTICES.md`, the parity guide, the
   parity baseline, the Swift Wubi digest, the English-DB secret-scan exception and test comments,
   and rejects any other stale `dict-v*` tag outside history files.
   - If `msime-others.db` changed, re-audit its tables before anything else: only `emoji`,
     `emoji_pinyin`, `kaomoji` and `kaomoji_catalog` may ship, and their row counts and hashes in
     `scripts/fetch-msime-others.py` must still hold. Editing `data/msime-others-NOTICE.txt`
     also moves its pinned hash in that script.
   - If `msime-english.db` changed, scan it (`trufflehog filesystem`, `gitleaks dir`) and confirm
     the known Eraser match keeps its pinned raw-match digest before moving the file digest in
     `scripts/secret-finding-policy.py`. Scan the other new members too; a new finding blocks the
     re-pin until it is classified.
   - If `msime-upstream-licensing-NOTICE.md` differs at the new builder commit, take the new text.
5. Advance `OwlRustCompatibleResources.packageVersion` in
   [`OwlRustDictPackResource.swift`](../../sources/DictPack/OwlRustDictPackResource.swift). Installed
   generations of the previous set then fail validation and the user is asked to prepare the new one.
6. `make owl-seed` (set `OWLTYPE_MSIME_RESOURCE_CACHE` to a durable directory to keep the
   download), then the Rust and Swift suites:

   ```sh
   cargo test --locked --manifest-path rust/Cargo.toml -p owl-msime-ffi
   python3 scripts/verify.py swift --test OwlRustEngineTests --test OwlDictPackTests --test OwlRustResourceTransactionTests
   ```

   Candidate orders hard-coded in tests come from the fixed upstream Host API, not from Owltype.
   When one moves, read the new order from the reference (the parity runner's
   `comparison.json`, or a trace written for that input) and only then change the test. Re-check
   the Wubi fixture codes with SQL against both tables: an empty code can gain rows.
7. Re-run every parity corpus against the reference Host API on the new resource set (see
   [pinyin parity](pinyin-parity.md)): the eight pinyin corpora, the six Wubi traces, and the
   Wubi 98 replays (`--scheme wubi98` / `wubi98-mixed`). The reference library refuses any
   dictionary other than the lock compiled into its engine tag, so first let it install the new
   release through its own updater (`scripts/install-reference-dictionary-update.py`) and pass
   that state to the runner with `--reference-dictionary-update`; keep the engine lock's digests
   in the baseline's `engine_lock_resources`. Then run the keyboard-model check
   (`model_parity.rs`) with `OWL_MODEL_PARITY_RESOURCES`. Each must report zero differences or
   carry a written explanation.
8. Run `scripts/gate.sh` on the pull-request head. A formal signed build checks one upgrade over
   the previous release and one rollback; the learned words, frequencies and pinned words must
   survive both.

## New engine tag

1. Set `tag` and `revision` in `rust/msime-source.json`. Fetch the tag in a clean checkout of
   `metasequoiaime/msime`.
2. Re-import `engine`, `input-runtime`, `path-trust` (whole crates) and the selected parts of
   `client-core` named under `extraction`. Keep `owl-msime-ffi`, `owl-agent-*` and the
   punctuation contract: they are Owltype's own.
3. Replay each entry in `adaptations` one at a time, each with its own regression (named in the
   commit or in [LESSONS.md](../../LESSONS.md)). An adaptation the new tag makes unnecessary is
   deleted from the list rather than replayed.
4. `msime_pin.py check` names the documents and the Swift configuration marker
   (`configurationVersion`, which embeds the tag) to update; also update
   `data/msime-upstream-licensing-NOTICE.md` from the new revision and the reference build in the
   parity baseline (`reference_library_sha256`, built with `scripts/build-pinyin-reference.py`).
5. Advance `packageVersion` and continue from step 6 of the dictionary procedure.

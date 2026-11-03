# Rust build-input helpers

## Overview
Python helpers prepare the pinned OpenCC inputs consumed by the Rust client build.

## Interface
- `download_retry.py:transient`, `urlopen`, and `RETRY_DELAYS` classify transient open failures and wrap `urllib.request.urlopen`.
- `fetch_opencc.py:read_lock`, `matches`, `prepare`, and `ensure_opencc` validate and prepare inputs from `resources/opencc.lock.json`; its CLI accepts `--offline`.
- `fetch_opencc.py:ensure_opencc` recognizes `MSIME_OPENCC_SOURCE_DIR`, `MSIME_OPENCC_OFFLINE`, and `CARGO_NET_OFFLINE`.

## Invariants
- `fetch_opencc.py:read_lock` requires lock version 1, the named upstream repository, a full 40-hex commit, unique constrained paths, positive sizes no larger than 2,000,000 bytes, and SHA-256 hashes.
- `fetch_opencc.py:prepare` validates length and SHA-256 before replacing a destination. Offline or explicit source-directory mode rejects missing or mismatched files instead of downloading.
- `fetch_opencc.py:ensure_opencc` compares the prepared LICENSE bytes with the bundled license.
- `download_retry.py:urlopen` retries opening a response at 2, 5, and 15 seconds for HTTP 429/5xx and connection/timeout errors; it does not retry response-body consumption.

## Side Effects
- `fetch_opencc.py:prepare` reads files, creates cache directories, downloads pinned HTTPS resources when allowed, and atomically replaces validated staged files; temporary files are removed in `finally`.
- `download_retry.py:urlopen` opens network responses, sleeps between retries, and writes diagnostics to stderr.

## Verification
- From the repository root, `python3 rust/scripts/fetch_opencc.py --offline` checks existing pinned build inputs without downloading (requires the cache or an explicit source directory). No download or cache preparation was executed during documentation bootstrap.

# Cloud candidate provider protocol

## Overview
Builds validated HTTP descriptions and parses bounded candidate responses. Hosts execute the requests.

## Interface
- `provider.rs:CloudCandidatePreferences`, `CloudCandidateSource`, `CloudHttpMethod`, and `CloudResponseFormat` represent provider configuration; `validate`, `identity`, and `recipient` validate it and derive cache identity/display recipient.
- `provider.rs:CloudHttpRequest` describes an HTTP request; `build_request`, `build_english_request`, and `parse_response` construct and consume it. `valid_endpoint` checks supported URL shapes.

## Invariants
- `provider.rs:valid_endpoint` allows HTTPS, or HTTP only for literal `localhost`, `127.0.0.1`, and `[::1]`; credentials, fragments, spaces, backslashes, and ambiguous host forms are rejected.
- `provider.rs:CloudCandidatePreferences::validate` bounds timeouts to 100–10,000 ms, user headers to 16 entries/4,096 bytes, templates to 4,096 bytes, endpoints to 2,048 bytes, and response paths to 128 bytes/16 segments. Custom requests require a query placeholder outside the authority or in a JSON-object POST body.
- `provider.rs:valid_headers` rejects reserved transport/cookie/proxy headers, duplicate case-insensitive names, and invalid ASCII names/values.
- `provider.rs:build_english_request` permits only custom providers, ASCII-letter input and bounded context; it includes `mode=english` and context in request/cache identity.
- `provider.rs:parse_response` checks the request, caps bodies at 256 KiB, extracts one candidate, and rejects empty/control-containing candidates or values beyond 512 bytes.

## Side Effects
- `provider.rs:CACHE` is a process-local `OnceLock<Mutex<_>>`; request construction removes expired entries, and parsing remembers positive results for 600 seconds or negative results for 60 seconds. At 4,096 entries insertion clears the cache.
- `provider.rs:build_request` and `parse_response` perform no network I/O; `CloudHttpRequest` carries the work for a host transport.

## Verification
- From `rust/`: `cargo test -p msime-client-core`.

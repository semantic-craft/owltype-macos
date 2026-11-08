# Kotone local reply suggestions

This optional client reads an explicit selection, displays 2–3 reply candidates, and copies a
candidate to the clipboard only when the user clicks its `复制` button. It never inserts or sends
text, never reads provider keys, and leaves normal keyboard input available.

Enable Kotone 回复建议 in Settings → Skills, with cloud AI and the selection toolbox enabled.
Select the message, double-tap Option (or the configured summon key), choose 回复建议, then
generate. Only this explicit action submits the material. The selection's speaker and history
remain unknown. Edit “这次我想怎么回” during generation to retire the old request, then generate
again. Cancel or close also retires the request; late replies cannot restore its candidates.

Kotone office owns the reply socket for the installed `Kotone.app` / `dev.kotone.office`
service. Check its service and reply-scene state in Kotone, then reconnect or generate again.
Office mounts the socket itself and has no temporary reply-service two-hour lifetime. Do not
start a second reply service on the same socket. Owltype does not launch office, load backend
keys, record audio or start Responsay. Owltype builds independently against the protocol below.

This reply integration is separate from Owltype's existing Jev candidate-selection path.
That [selection path](../../sources/Lane/OwlAICandidateService.swift) currently uses a general text model. This contract change does not
migrate it to Kotone, change its implementation, or change any defaults.

## Shared protocol

Protocol v1 uses one UTF-8 JSON line per connection over the user-private Unix socket at
`~/Library/Application Support/Jarvis Phone/replies.sock`. Requests carry `version: 1`,
`operation: preferences` or `recommend`. A recommendation includes an opaque `request_id`,
`source: owltype-selection`, `text`, complete `reply_style` and independent `instructions`.
Text is not truncated: the service accepts 1–10000 Unicode scalars and instructions up to 1000.
Style fields are approach (`nvc`/`standard`), relationship, purpose, tone, length, constraints.
Per-request instructions outrank conflicting saved style, while factual and read-only
constraints remain higher. Preferences are not rewritten. Explicit `recommend` establishes
reply intent without speech; the client does not manufacture speaker/history context.

Both hosts share the same normalized task: material, instructions, saved_style, context,
candidate_count (2–3), output_action (`read_only`). Source does not change task semantics.
The backend owns judgment, drafting and ranking; Owltype does not duplicate those policies.

Responses have `ok`, `version`, and for recommendations the exact `request_id`, optional
`source` and `status` (`ready` or `needs_clarification`), `verdict.intent`, `candidates`
(`text`/`prob`), `reply_style`, `task`, `elapsed` and `timings`. Under the Owltype v1
compatibility rules: missing `status` is treated as legacy `ready`,
`status=needs_clarification` requires an empty `candidates` array and displays a clarification
prompt without publishing candidates, and `status=null` or any other value is rejected as
invalid; missing `source` is accepted for legacy v1 servers (proving only current
private-socket call and `request_id` correlation rather than source echo verification), whereas
`source=null` or a mismatched string is rejected; `ready` requires 2–3 candidates whose
`trimmingCharacters(in: .whitespacesAndNewlines)` texts are non-empty, unique, and at most 2000
Unicode scalars (any violation rejects the entire group). When `ok=false`, allowlisted safe
codes (`paused`, `scenario_disabled`, `request_invalidated`, `model_quota_exhausted`,
`model_rate_limited`) map to local static messages while clearing stale candidates and
preserving the selection and instructions. Errors never produce automatic input or another
provider fallback. The protocol has no fill/send operation.

A recommendation may also include `contract`. Its absence preserves legacy compatibility.
When present, it must be an object with `name: reply`, integer `version: 1` (not a boolean),
`request_id` and `source` matching this request, and nonblank `rule_version` and
`build_identity` strings. Null, missing required fields, unsupported versions and mismatched
identity reject the response before candidates or clarification are presented. Existing
source, status, candidate and session checks still apply.

Nonblocking socket I/O uses one monotonic deadline across connection, sending and receiving:
5 seconds for preferences, 120 seconds for a recommendation. Cancellation is checked at
most 100 ms apart and closes the client socket. It does not promise immediate cancellation
of a provider request already issued by the backend. Error and timeout states retain the
selection and instructions and offer retry; no source material is logged by the client.

## Verification

`python3 scripts/verify.py swift --test JEVReplyModelTests --test JEVTransportTests`
exercises model ownership, private pasteboard copying, offline input, and real local sockets.
The normal offline gate excludes the opt-in live suite.

For an isolated, already-running service with synthetic preferences and backend credentials,
run `bash scripts/live-test.sh --reply-service /absolute/test.sock`. This narrowly scoped
profile runs only `JEVReplyServiceLiveTests/testSharedServiceCandidatesAndOverrides`, without
loading or forwarding host API keys. Other live suites retain their normal credential gate;
a skipped live test is still a failure. Synthetic requests, normalized tasks, stage timings
and returned candidates print as `KOTONE_LIVE` records for manual language-quality review.
A service failure in the injection counterexample establishes fail-closed presentation only,
not successful generation or proof that the model recognized an injection.

Automated in-process tests and synthetic provider calls do not establish installed keyboard,
shortcut, focus, real selection or user acceptance. Validate those separately on the installed
build; do not install an ad-hoc input method merely to run the isolated tests.

The byte-identical synthetic Kotone fixture is vendored under
`tests/fixtures/kotone-contracts/`. `source.json` records its origin and schema version;
`manifest.json` records the frozen SHA-256. `JEVReplyModelTests` verifies both offline and
runs all 12 reply cases through the production parser, without a neighboring checkout.
These checks prove source behavior. They do not establish a live provider call or installed
IMK acceptance.

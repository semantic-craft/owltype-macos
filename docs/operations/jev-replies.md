# Kotone（琴音）local reply suggestions

This optional client reads an explicit selection and displays 2–3 read-only reply candidates.
Each candidate has an explicit Copy button. Generation does not change the clipboard;
copying does not insert, replace the selection or send text. No Pallas window or microphone
is required. The input method stores no service credential. A missing service leaves normal
keyboard input available.

Enable Kotone 回复建议 in Settings → Skills, with cloud AI and the selection toolbox enabled.
Select the message, double-tap Option (or the configured summon key), choose 回复建议, then
generate. Only this explicit action submits the material. The selection's speaker and history
remain unknown. Edit “这次我想怎么回” during generation to retire the old request, then generate
again. Cancel or close also retires the request; late replies cannot restore its candidates.

Start the separate Kotone service with `scripts/reply-service` from its own service directory,
with `OPENAI_API_KEY` supplied to that backend process. Reconnect or generate again after
starting it. Owltype does not launch the backend, load its key, record audio or start Pallas.
The service has a bounded lifetime and may need relaunching. Its implementation is optional;
Owltype builds independently against the protocol below.

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

Responses have `ok`, `version`, and for recommendations the exact `request_id`, `status`,
`verdict.intent`, `candidates` (text/prob), `reply_style`, `task`, `elapsed` and `timings`.
Additive status/task/timing fields preserve the v1 envelope. Ready candidates must contain
2–3 distinct nonblank texts, each at most 2000 Unicode scalars. `needs_clarification` offers
an editable request without candidates. Errors never produce automatic input or another
provider fallback. The protocol has no fill/send operation.

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

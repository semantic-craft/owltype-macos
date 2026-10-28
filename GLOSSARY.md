# Glossary

Domain terms used in code, docs and architecture reviews. Add a term when a module is
named after it; sharpen an entry when its meaning is disputed.

## Input

**Input hot path** — the work between a keystroke reaching `OwlInputController` and the
composition or commit reaching the host. Bounded latency, no network, no blocking I/O, and
no failure may stop plain typing. The input method runs inside every host app, so a hang or
crash here is an outage across apps.

## Dictionary

**Resource generation** — one verified, immutable copy of the bundled `msime` resources in the
Rust resource store (`OwlRustResourceStore`), named by its digest. Typing uses the active
generation, or the bundled files directly when none is active.

**Dictionary lifecycle** — `OwlDictPackCenter`: `prepare()` copies the bundled resources into a
candidate generation, `activate()` makes it current after the user confirms, `rollback()` returns
to the previous one. `needsPrompt` is true while no generation is active or the active one is
older than the bundled version. Only Rust state decides; the legacy Rime YAML download
(`.owl-dictpack.json`, `cn_dicts/`) is never read or changed.

## AI

**AI skill** — a user-invoked, out-of-band operation that sends text to a cloud model:
selection polish, structured drafting (prompt optimize, goal brief), Ask, the AI window.
Never runs on the input hot path; text leaves the machine only on the user's explicit action,
and usage telemetry never carries text.

**Provider profile** — a stored endpoint, model and Keychain `secretName` the user configured
(`OwlProviderProfile`). The default profile drives every AI skill. To the user it is one
provider: how it is reached, whether it can search, and what it is called are one fact.

**Wire dialect** — which request shape a provider speaks: Chat Completions, or one of the
`/responses` dialects (`qwen`, `ark`, `deepseek`, `openAI`) in `OwlResponsesWire`.

**Provider capabilities** — what a provider profile's wire supports, resolved once from
`(providerID, model, host)` (`OwlProviderCapabilities`): the wire dialect, how thinking is
switched off, whether Chat JSON mode is sent, sampling rules, and which 任意提问 search channel
applies with its 署名 name.

**LLM gateway** — the module every AI skill calls for a model reply (`OwlLLMGateway`). It applies
provider capabilities, builds the Chat or `/responses` request, sends it through the transport,
parses the reply and records usage telemetry (never text). `stream` does the same fork for a
streamed free-text answer (plain generation, 任意提问).

**Transport** — the seam under the LLM gateway that sends one `URLRequest` and returns the bytes
and response, or opens one and returns its body as text chunks (`OwlLLMTransport`). Adapters: URLSession in production, a recording fake in tests.

**Server error detail** — what a provider said when it refused a request (`OwlServerErrorDetail`:
its error code and message), carried on `badHTTPStatus`. `OwlCloudPreferences.message(for:)` is
the one Chinese mapper: a known code (`OwlServerRefusal`) wins, otherwise the HTTP status decides.
The raw message is shown only in the settings connectivity probe, sanitized.

**Call purpose** — why an AI skill is calling (`OwlLLMCallPurpose`: interactive rewrite, drafting,
connectivity probe). It fixes the timeout and retry, so callers never pass them.

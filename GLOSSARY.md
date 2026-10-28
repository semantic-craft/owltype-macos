# Glossary

Domain terms used in code, docs and architecture reviews. Add a term when a module is
named after it; sharpen an entry when its meaning is disputed.

## Input

**Input hot path** — the work between a keystroke reaching `OwlInputController` and the
composition or commit reaching the host. Bounded latency, no network, no blocking I/O, and
no failure may stop plain typing. The input method runs inside every host app, so a hang or
crash here is an outage across apps.

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
switched off, whether Chat JSON mode is sent, and sampling rules.

**LLM gateway** — the module every non-streaming AI skill calls for a model reply
(`OwlLLMGateway`). It applies provider capabilities, builds the Chat or `/responses` request,
sends it through the transport, parses the reply and records usage telemetry (never text).
Streaming chat and Ask do not go through it yet.

**Transport** — the seam under the LLM gateway that sends one `URLRequest` and returns the bytes
and response (`OwlLLMTransport`). Adapters: URLSession in production, a recording fake in tests.

**Call purpose** — why an AI skill is calling (`OwlLLMCallPurpose`: interactive rewrite, drafting,
connectivity probe). It fixes the timeout and retry, so callers never pass them.

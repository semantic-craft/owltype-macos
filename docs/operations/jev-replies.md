# Kotone（琴音）local reply suggestions

This optional client reads an explicit selection and displays reply candidates. It never inserts or sends text. Enable the local reply service separately; the input method/application itself stores no service credential. Missing service is shown as an error and does not alter normal input.

Protocol v1 uses one UTF-8 JSON line per connection over the user-private Unix socket at `~/Library/Application Support/Jarvis Phone/replies.sock`. Requests carry `version: 1`, `operation: preferences` or `recommend`. A recommendation includes `request_id`, `source`, `text`, optional complete `reply_style` and `instructions`. Sources are `owltype-selection` and `pallas-selection`. Text is not truncated: the service accepts 1–10000 characters. Style fields are approach (`nvc`/`standard`), relationship, purpose, tone, length, constraints. Instructions override the purpose for this request only. Existing saved preferences are not changed by the client.

Responses have `ok`, `version`, and for recommendations the same `request_id`, `verdict.intent`, `candidates` (each with text/prob), effective `reply_style`, and `elapsed`. Clients discard results after closing or superseding the request. Receive timeout is120 seconds. Errors never trigger automatic input or fallback to another provider. The protocol has no fill/send operation. No build dependency on a service implementation is required.

Enable Kotone 回复建议 in Settings → Skills, with cloud AI and the selection toolbox enabled. Select the message, double-tap Option (or the configured summon key), choose 回复建议, then generate. Only this explicit invocation submits text.

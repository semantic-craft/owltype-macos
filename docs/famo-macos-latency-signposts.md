# Famo macOS Latency Signposts

Famo emits `os_signpost` points under subsystem `im.famo.inputmethod.Famo`, category `latency`.
Signpost names describe phases only. They do not include preedit text, committed text, candidate text,
prompt bodies, selected text, or surrounding host text.

## Capture

1. Build and run the input method on a real Mac.
2. Open Instruments.
3. Choose a template with Points of Interest / os_signpost support.
4. Filter for subsystem `im.famo.inputmethod.Famo` and category `latency`.
5. Type in a host app, open settings/emoji/quick-send/AI windows, and trigger reload/deploy.

## Important Names

- `key.received`
- `handle`
- `session.process`
- `composition.update`
- `markedText.apply`
- `candidatePanel.update`
- `candidatePanel.firstVisible`
- `candidatePanel.delayedReposition`
- `button.open.*`
- `window.open.*`
- `deploy.full`
- `deploy.fast.config`
- `deploy.fast.fuzzy`
- `reload.notification`
- `sync.userData`
- `strandedComposition.finalize`

Use these intervals to compare key-to-candidate timing, panel first visibility, button-to-window-visible
latency, and deploy/reload phases. The older `perf` logger remains available for coarse cold-start and
fast-apply timing:

```bash
log stream --predicate 'subsystem == "im.famo.inputmethod.Famo" && category == "perf"' --info
```

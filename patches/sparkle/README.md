# Sparkle application relaunch

Base: official Sparkle 2.6.2, commit `41847a58cdef7506b257591fcca6f9495df591d4`.
`application-relaunch.patch` changes only the progress agent's relaunch method.
Download, signature verification, authorization and package installation remain upstream.

On the tested macOS host, opening an App with `NSWorkspace.openURL` requests a
`com.apple.app-sandbox.read-write` extension for that App. An independently launched
ad-hoc Updater is denied by App Management even though installation already succeeded.
The application-specific API reuses the running App without that request. See issue #204
and `docs/operations/no-logout-install-update.md` for the captured call stack and controls.

The patch uses `openApplicationAtURL` for APPL bundles on macOS 10.15+, waits for its
completion, reports failures, then preserves upstream's exit delay. Plug-in bundles and
older hosts retain upstream's document-open path. No swizzling, sandbox SPI or extra
permission is used by the product. This is a maintained source patch, not an unmodified
upstream binary; remove it when adopting an upstream revision with equivalent behavior.

`make sparkle` archives the committed pin, applies this patch in an isolated build
folder and builds both architectures without Developer ID signing. The submodule is
not edited. A receipt binds the patch digest and Updater Mach-O UUIDs; bootstrap,
release finalization and release checks reject stale/unpatched artifacts. UUIDs remain
stable when the release pipeline replaces code signatures. This receipt detects build
mixups; it does not replace signing or Sparkle's download verification.

Validation uses the actual compiled agent in a disposable user-session probe, alongside
the prior failing agent. Full Sparkle installation remains a separate manual gate.
A release installing this fix still begins with the old version's updater: it cannot
retroactively fix that already-running helper. The following update uses the repaired
helper. Test artifacts must therefore put the fix in the starting App as well.

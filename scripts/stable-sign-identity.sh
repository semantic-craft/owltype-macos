#!/usr/bin/env bash
# Prints the code-signing identity for a development build that will be installed as an
# input method. Keychain items (AI provider keys) and privacy grants trust the App's
# designated requirement; ad hoc signing pins it to the per-build cdhash, so every
# reinstall asks for the login password again and stale ad hoc copies shadow the
# notarized input method. OWL_SIGN_IDENTITY overrides the default: the Developer ID
# Application identity, whose requirement matches the shipped App, else the first
# Apple Development identity. Nothing is created or stored here.
set -euo pipefail
identity="${OWL_SIGN_IDENTITY:-auto}"
if [[ "$identity" == auto ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  identity=$(sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' <<<"$identities" | head -1)
  if [[ -z "$identity" ]]; then
    identity=$(sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' <<<"$identities" | head -1)
  fi
fi
if [[ -z "$identity" || "$identity" == - ]]; then
  echo "ERROR: no stable signing identity. An installed input method must not be ad hoc signed;" >&2
  echo "install a Developer ID Application or Apple Development certificate, or set" >&2
  echo "OWL_SIGN_IDENTITY to one listed by: security find-identity -v -p codesigning" >&2
  exit 2
fi
printf '%s\n' "$identity"

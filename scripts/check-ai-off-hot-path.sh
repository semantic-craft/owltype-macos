#!/usr/bin/env bash
# The input hot path (sources/Controller, sources/Engine) must never reach the network: AI skills
# are user-invoked and run in Lane behind a service protocol. Fails when hot-path code names the
# LLM gateway, its transport, a skill client or URLSession. Agent access (#208) is held to the same
# rule: its socket I/O lives in sources/Agent on a background queue, so the hot path must not name
# the bridge, the access switch or a socket call.
#
#   bash scripts/check-ai-off-hot-path.sh [root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
pattern='\b(OwlLLMGateway|OwlLLMTransport|OwlURLSessionTransport|OwlSelectionPolishClient|OwlStructuredDraftingClient|URLSession|OwlAgentBridge[A-Za-z]*|OwlAgentAccess[A-Za-z]*|OwlAgentPeerVerifier)\b|\b(accept|listen|getpeereid)\('

if hits="$(grep -rnE "$pattern" "$root/sources/Controller" "$root/sources/Engine" --include='*.swift')"; then
  printf 'AI networking or agent bridge I/O named on the input hot path:\n%s\n' "$hits" >&2
  exit 1
fi
echo "AI and agent bridge off the input hot path: ok"

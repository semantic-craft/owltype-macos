#!/usr/bin/env python3
"""Synthetic MiniMax comparison; key stays in process memory, never in the report.

MINIMAX_API_KEY or --keychain-account supplies an existing subscription key.
Default region: China; use --region global for an international subscription.
"""
import argparse
import json
import os
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path


MODEL = "MiniMax-M3.1-Flash-Preview"
CASES = [
    ("polish", '润色这句话，保留全部事实。只输出JSON，格式为{"candidates":["改写"]}：'
     '我们约好了10月8日下午3点开会，但是会议室还没有确定。'),
    ("translate", '翻译成英文，只输出JSON，格式为{"candidates":["译文"]}：'
     '请在周五之前确认预算，金额不得超过5000元。'),
    ("ask", "用不超过80个汉字解释HTTP缓存中的ETag有什么作用。"),
]


def call(key, host, model, extras, prompt, limit=4096):
    body = dict(model=model, stream=True, reasoning_split=True,
                stream_options={"include_usage": True}, max_completion_tokens=limit,
                temperature=0.2, messages=[{"role": "user", "content": prompt}], **extras)
    request = urllib.request.Request(host + "/v1/chat/completions",
        data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + key,
        "Content-Type": "application/json"})
    start = time.monotonic()
    first = None
    text = ""
    usage = {}
    finish = None
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            for line in response:
                if not line.startswith(b"data:"):
                    continue
                raw = line[5:].strip()
                if raw == b"[DONE]":
                    break
                event = json.loads(raw)
                if event.get("error"):
                    return {"error": "upstream_stream_error"}
                usage = event.get("usage") or usage
                for choice in event.get("choices", []):
                    content = choice.get("delta", {}).get("content")
                    if content:
                        if first is None:
                            first = time.monotonic() - start
                        text += content
                    finish = choice.get("finish_reason") or finish
    except urllib.error.HTTPError as error:
        # Never echo an arbitrary server error body (it might reflect credentials).
        return {"http_status": error.code, "total_s": round(time.monotonic() - start, 3)}
    except (OSError, ValueError) as error:
        return {"error": type(error).__name__, "total_s": round(time.monotonic() - start, 3)}
    return {"http_status": 200, "first_answer_s": round(first, 3) if first else None,
            "total_s": round(time.monotonic() - start, 3), "finish_reason": finish,
            "usage": usage, "answer": text}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keychain-account")
    parser.add_argument("--region", choices=["cn", "global"], default="cn")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--output", type=Path, default=Path("/tmp/owltype-minimax-probe.json"))
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10:
        parser.error("--rounds must be between 1 and 10")
    key = os.environ.get("MINIMAX_API_KEY", "").strip()
    if args.keychain_account:
        stored = subprocess.run(["security", "find-generic-password", "-s",
            "im.owltype.inputmethod.Owltype.providers", "-a", args.keychain_account, "-w"],
            capture_output=True, text=True, check=False)
        key = stored.stdout.strip() if stored.returncode == 0 else ""
    if not key:
        parser.exit(2, "No MiniMax subscription credential configured; no network calls made.\n")
    host = "https://api.minimax.cn" if args.region == "cn" else "https://api.minimax.io"
    results = []
    variants = [("m3.1-low", MODEL, {"reasoning_effort": "low"}),
                ("m3.1-max", MODEL, {"reasoning_effort": "max"}),
                ("m3-off", "MiniMax-M3", {"thinking": {"type": "disabled"}})]
    for iteration in range(args.rounds):
        # Rotate ordering to reduce warm-up/time-of-day bias.
        for label, model, extras in variants[iteration % 3:] + variants[:iteration % 3]:
            for case, prompt in CASES:
                result = call(key, host, model, extras, prompt)
                if case != "ask" and "answer" in result:
                    try:
                        candidates = json.loads(result["answer"]).get("candidates")
                        result["valid_json"] = (isinstance(candidates, list) and bool(candidates)
                            and all(isinstance(x, str) and x.strip() for x in candidates))
                    except (ValueError, AttributeError):
                        result["valid_json"] = False
                results.append(dict(variant=label, case=case, round=iteration + 1, **result))
                print(label, case, result.get("http_status", result.get("error")),
                      result.get("first_answer_s"), flush=True)
                args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
                if result.get("http_status") in (401, 403, 429):
                    parser.exit(1, "Credential/permission/rate refusal; stopped further calls.\n")
    for label, _, _ in variants:
        samples = [r["first_answer_s"] for r in results
                   if r["variant"] == label and r.get("first_answer_s") is not None]
        print(label, "median_first_answer_s:", statistics.median(samples) if samples else "no answer")
    print("Synthetic answers and metrics:", args.output)


if __name__ == "__main__":
    main()

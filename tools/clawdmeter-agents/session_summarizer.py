"""Nightly session summarizer — writes one-line summaries of yesterday's
Antigravity conversations to `~/.clawdmeter/session-summaries.jsonl`.

v0.6.0 stub: validates the entry point + scheduler wiring. Real impl
lands in v0.6.1 using:
    from google.antigravity import Agent, LocalAgentConfig
    agent = Agent(LocalAgentConfig(model="gemini-3.5-flash", ...))
    response = agent.run(prompt=f"Summarize this conversation: {body}")
"""

import json
import sys


def main() -> int:
    sys.stdout.write(json.dumps({
        "type": "error",
        "code": "sdk_not_provisioned",
        "agent": "session_summarizer",
        "msg": "Skeleton — full impl in v0.6.1.",
    }) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

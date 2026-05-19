"""Repo context extractor — one-shot agent triggered by the Plan pane's
"Extract repo context" button. Reads TODOS.md / CLAUDE.md / README /
recent commit messages and writes a distilled knowledge file at
`~/.gemini/antigravity/brain/<active-uuid>/knowledge-base/clawdmeter-repo-context.md`
so Antigravity auto-loads it on the next agent turn.

v0.6.0 stub: validates the entry point + Plan pane button wiring.
Real impl lands in v0.6.1.
"""

import json
import sys


def main() -> int:
    sys.stdout.write(json.dumps({
        "type": "error",
        "code": "sdk_not_provisioned",
        "agent": "repo_context_extractor",
        "msg": "Skeleton — full impl in v0.6.1.",
    }) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""Cost-pulse watcher — long-running launchd job that polls
`agent.conversation.total_usage` every 30s and POSTs an alert to the
daemon's /internal/pulse-alert route when the burn rate exceeds the
user-configured threshold (default $0.50/hr).

v0.6.0 stub: validates the entry point + APNS round-trip via the
daemon's alert handler. Real impl lands in v0.6.1.
"""

import json
import sys


def main() -> int:
    sys.stdout.write(json.dumps({
        "type": "error",
        "code": "sdk_not_provisioned",
        "agent": "cost_pulse_watcher",
        "msg": "Skeleton — full impl in v0.6.1.",
    }) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

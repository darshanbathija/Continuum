# continuum-agent (Linux)

Headless Clawdmeter execution-host daemon for Linux VPS and AWS EC2 runners.

## Build

```bash
./build-linux.sh
# -> dist/continuum-agent-linux-{arm64,amd64}
```

Requires Go 1.23+.

## Install on Linux

```bash
sudo CONTINUUM_AGENT_BINARY_URL=https://…/continuum-agent-linux-arm64 \
  ./install-linux.sh
```

Or copy `dist/continuum-agent-linux-arm64` next to the install script and run `./install-linux.sh`.

Piped installs (`curl … | bash`) compile from upstream Go sources when Go 1.23+ is installed.

## CLI

```bash
continuum-agent serve       # systemd ExecStart
continuum-agent health      # GET /health
continuum-agent pair        # print direct pairing URL + token
continuum-agent pair-relay  # emit signed relay bundle for Mac Settings → Devices
continuum-agent show-token  # print bearer token
```

Environment:

| Variable | Default |
|----------|---------|
| `CLAWDMETER_HTTP_PORT` | `21731` |
| `CLAWDMETER_DATA_DIR` | `/opt/clawdmeter/data` |
| `CLAWDMETER_BIND_ALL` | `1` on systemd install |
| `EXECUTION_HOST_ID` | from `/etc/clawdmeter/env` or generated |
| `CLAWDMETER_HOST_KIND` | `vps` (AWS sets `byocAWS`) |
| `CLAWDMETER_RELAY_URL` | `wss://clawdmeter-relay.continuumai.workers.dev` |
| `CLAWDMETER_RELAY_CREATION_GRANT_TOKEN` | required by `pair-relay` to mint the relay session-creation proof |

`pair-relay` refuses to emit unsigned relay credentials. The saved
`relay-pairing.json` includes the relay token hashes, signed creation proof,
and a per-host symmetric key used by the Mac relay bridge for encrypted mux
requests.

## Remote spawn API

Authenticated endpoints (bearer token from `show-token`):

- `GET /sessions` — list sessions on this host
- `POST /sessions` — spawn (accepts wire v30 `NewSessionRequest` JSON)

Spawns a detached background runner per session so work continues when the Mac client disconnects.

## AWS live E2E (Mac)

Opt-in tests that create real EC2 instances:

```bash
touch ~/.continuum-aws-e2e
CLAWDMETER_AWS_E2E=1 CLAWDMETER_AWS_REGION=us-east-1 \
  xcodebuild test -scheme 'Clawdmeter (Mac)' -destination 'platform=macOS' \
  -only-testing:ClawdmeterMacTests/AWSComputeLiveE2ETests
```

Requires `aws` CLI credentials with EC2 permissions. Tests terminate instances in `tearDown`.

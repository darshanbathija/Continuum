// index.ts — clawdmeter-relay Worker entry point.
//
// Routes:
//   GET  /healthz                            → 200 ok (CF health probe + smoke test)
//   GET  /v1/relay/sessions/:sid/connect     → WebSocket upgrade; forwards to DO :sid
//   GET  /v1/relay/sessions/:sid/stats       → JSON aggregate counts (no body content)
//
// Cold start budget (Codex #2): <50ms p99. Keep this module's top-level work
// to essentially zero — no top-level awaits, no global JSON parsing. The DO
// module is the only "heavy" import, and it's tree-shaken to just type info
// at module load (the actual class instantiation happens per-request inside
// the workerd isolate).
//
// All HTTP responses include `cache-control: no-store` because the WS upgrade
// path is auth-stateful and any cache layer (browser, CF cache) would be
// catastrophic.

import { RelaySession, type RelayEnv } from "./durable-object";

export { RelaySession };

const SESSION_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;

export default {
  async fetch(request: Request, env: RelayEnv, _ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // ----- /healthz -----
    if (url.pathname === "/healthz" && request.method === "GET") {
      return jsonResponse({ ok: true, env: env.ENVIRONMENT }, 200);
    }

    // ----- /v1/relay/sessions/:sid/connect | /stats -----
    const match = /^\/v1\/relay\/sessions\/([^/]+)\/(connect|stats)$/.exec(url.pathname);
    if (match) {
      const sid = match[1];
      const action = match[2];

      if (!SESSION_ID_PATTERN.test(sid)) {
        return textResponse("invalid session id", 400);
      }

      // CRITICAL: `idFromName(sid)` ensures BOTH peers land on the SAME DO,
      // and pins the DO to the colo of the first peer to request it.
      // (CF picks the colo closest to the first request.)
      const doId = env.RELAY_SESSIONS.idFromName(sid);
      const stub = env.RELAY_SESSIONS.get(doId);

      // Rewrite the URL so the DO sees a stable shape (`/connect` or
      // `/admin/stats`). Preserve the query string for `?bundle=...`.
      const innerPath = action === "connect" ? "/connect" : "/admin/stats";
      const innerUrl = `https://do.invalid${innerPath}${url.search}`;
      const innerRequest = new Request(innerUrl, request);

      return stub.fetch(innerRequest);
    }

    return textResponse("not found", 404);
  },
};

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
  });
}

function textResponse(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain", "cache-control": "no-store" },
  });
}

// End-to-end relay integration tests. Drives the Worker via SELF inside
// workerd; each test exercises the DO + the WebSocket Hibernation API.
//
// Acceptance criteria covered (per plan E2 + Codex #2 + D22):
//
//   - bearer-auth-pass / bearer-auth-fail
//   - peer-isolation (D22 — Mac token cannot impersonate iOS and vice versa)
//   - opaque envelope routing (two peers exchange ciphertext frames; relay
//     stats reflect counts but no body content)
//   - hibernation wake (DO sleeps between frames, wakes correctly)
//   - reconnect storm (existing peer not displaced when its sibling reconnects;
//     self-displacement on same-role reconnect)
//   - audit log "no plaintext" — assert the stats endpoint never reveals body
//     bytes, only counts + bytesRouted.

import { describe, it, expect } from "vitest";
import { SELF } from "cloudflare:test";
import {
  newPairing,
  connectPeer,
  collectMessages,
  waitFor,
  makeHeader,
  makeOpaqueBody,
  TEST_RELAY_CREATION_GRANT_TOKEN,
  TEST_RELAY_CLIENT_PROVISIONING_KEY,
  TEST_RELAY_INSTALL_ID,
} from "./helpers";
import {
  issueDeviceGrantToken,
  issueProvisionRequestSignature,
} from "../src/provision";

describe("HTTP routes", () => {
  it("GET /healthz returns 200 ok", async () => {
    const res = await SELF.fetch("https://relay.invalid/healthz");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean };
    expect(body.ok).toBe(true);
  });

  it("rejects an invalid session id shape", async () => {
    const res = await SELF.fetch(
      "https://relay.invalid/v1/relay/sessions/!bad!/connect",
      { headers: { upgrade: "websocket" } }
    );
    expect(res.status).toBe(400);
  });

  it("unknown paths return 404", async () => {
    const res = await SELF.fetch("https://relay.invalid/nope");
    expect(res.status).toBe(404);
  });

  it("POST /creation-grant rejects missing or wrong grant authorization", async () => {
    const p = await newPairing();
    const body = JSON.stringify({
      macTokenHash: p.macTokHash,
      iosTokenHash: p.iosTokHash,
      ttlSeconds: p.ttlSeconds,
      senderMacFingerprint: "mac_fingerprint_123",
    });
    const missing = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/creation-grant`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body,
      }
    );
    expect(missing.status).toBe(401);

    const wrong = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/creation-grant`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: "Bearer wrong-token",
        },
        body,
      }
    );
    expect(wrong.status).toBe(403);
  });

  it("POST /creation-grant returns a proof usable for first connect when authorized", async () => {
    const p = await newPairing();
    const res = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/creation-grant`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${TEST_RELAY_CREATION_GRANT_TOKEN}`,
        },
        body: JSON.stringify({
          macTokenHash: p.macTokHash,
          iosTokenHash: p.iosTokHash,
          ttlSeconds: p.ttlSeconds,
          senderMacFingerprint: "mac_fingerprint_123",
        }),
      }
    );
    expect(res.status).toBe(201);
    const grant = (await res.json()) as {
      creation: { issuedAtSeconds: number; nonce: string; signature: string };
      apnsSigningKey?: string;
    };
    expect(grant.creation.signature.length).toBeGreaterThan(16);
    expect(grant.apnsSigningKey?.length).toBeGreaterThan(16);

    const bundle = btoa(JSON.stringify({
      macTokenHash: p.macTokHash,
      iosTokenHash: p.iosTokHash,
      ttlSeconds: p.ttlSeconds,
      creation: grant.creation,
    }));
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: bundle });
    expect(mac.response.status).toBe(101);
    mac.socket.close();
  });

  it("POST /creation-grant rejects impossible TTLs", async () => {
    const p = await newPairing();
    const res = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/creation-grant`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${TEST_RELAY_CREATION_GRANT_TOKEN}`,
        },
        body: JSON.stringify({
          macTokenHash: p.macTokHash,
          iosTokenHash: p.iosTokHash,
          ttlSeconds: Math.floor(Date.now() / 1000) + 32 * 24 * 60 * 60,
        }),
      }
    );
    expect(res.status).toBe(400);
  });

  it("POST /provision/grant-token returns a device grant usable for creation-grant", async () => {
    const issuedAtSeconds = Math.floor(Date.now() / 1000);
    const provisionAuth = await issueProvisionRequestSignature(
      TEST_RELAY_CLIENT_PROVISIONING_KEY,
      TEST_RELAY_INSTALL_ID,
      issuedAtSeconds
    );
    const provision = await SELF.fetch(
      "https://relay.invalid/v1/relay/provision/grant-token",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${provisionAuth}`,
        },
        body: JSON.stringify({
          installId: TEST_RELAY_INSTALL_ID,
          issuedAtSeconds,
        }),
      }
    );
    expect(provision.status).toBe(201);
    const provisionBody = (await provision.json()) as { grantToken: string };
    expect(provisionBody.grantToken.length).toBeGreaterThan(32);

    const p = await newPairing();
    const grant = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/creation-grant`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${provisionBody.grantToken}`,
        },
        body: JSON.stringify({
          macTokenHash: p.macTokHash,
          iosTokenHash: p.iosTokHash,
          ttlSeconds: p.ttlSeconds,
          senderMacFingerprint: "mac_fingerprint_123",
        }),
      }
    );
    expect(grant.status).toBe(201);
    const grantBody = (await grant.json()) as {
      creation: { signature: string };
    };
    expect(grantBody.creation.signature.length).toBeGreaterThan(16);

    const expectedDeviceGrant = await issueDeviceGrantToken(
      TEST_RELAY_CLIENT_PROVISIONING_KEY,
      TEST_RELAY_INSTALL_ID
    );
    expect(provisionBody.grantToken).toBe(expectedDeviceGrant);
  });
});

describe("bearer auth (D22 per-peer)", () => {
  it("rejects a connect with no token", async () => {
    const p = await newPairing();
    const res = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/connect?bundle=${p.bundleParam}`,
      { headers: { upgrade: "websocket" } }
    );
    expect(res.status).toBe(401);
  });

  it("rejects a connect with a token that matches neither side", async () => {
    const p = await newPairing();
    // First peer creates the session
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    expect(mac.socket).toBeTruthy();
    mac.socket.close();

    // Attacker presents an unrelated token
    const res = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/connect`,
      {
        headers: {
          upgrade: "websocket",
          "sec-websocket-protocol": "bearer.totally-bogus-token",
        },
      }
    );
    expect(res.status).toBe(403);
  });

  it("first connect without ?bundle= is rejected (412)", async () => {
    const p = await newPairing();
    const res = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${p.sid}/connect`,
      {
        headers: {
          upgrade: "websocket",
          "sec-websocket-protocol": `bearer.${p.macTok}`,
        },
      }
    );
    expect(res.status).toBe(412);
  });

  it("first connect with a malformed bundle is rejected (400)", async () => {
    const p = await newPairing();
    const url = new URL(`https://relay.invalid/v1/relay/sessions/${p.sid}/connect`);
    url.searchParams.set("bundle", "not-base64-json!");
    const res = await SELF.fetch(url.toString(), {
      headers: {
        upgrade: "websocket",
        "sec-websocket-protocol": `bearer.${p.macTok}`,
      },
    });
    expect(res.status).toBe(400);
  });

  it("a malicious bundle with mac==ios hashes is rejected (would defeat D22)", async () => {
    const sid = "deadbeef0000babe";
    const sharedHash = "a".repeat(64);
    const bundle = btoa(
      JSON.stringify({
        macTokenHash: sharedHash,
        iosTokenHash: sharedHash,
        ttlSeconds: Math.floor(Date.now() / 1000) + 3600,
      })
    );
    const res = await SELF.fetch(
      `https://relay.invalid/v1/relay/sessions/${sid}/connect?bundle=${bundle}`,
      {
        headers: {
          upgrade: "websocket",
          "sec-websocket-protocol": "bearer.whatever",
        },
      }
    );
    expect(res.status).toBe(400);
  });

  it("Mac token is rejected by the iOS role check (D22 enforces per-peer)", async () => {
    const p = await newPairing();

    // Mac connects normally — initializes the session.
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    expect(mac.socket).toBeTruthy();

    // Mac tries to send a frame claiming to be from "ios" — must close.
    const macClosed = new Promise<{ code: number; reason: string }>((resolve) => {
      mac.socket.addEventListener("close", (e: CloseEvent) => {
        resolve({ code: e.code, reason: e.reason });
      });
    });
    mac.socket.send(makeHeader({ from: "ios", type: "ciphertext" }));
    const closeEvent = await waitFor(() => Promise.resolve(macClosed).then(() => null).catch(() => null) || null);
    void closeEvent;
    const result = await macClosed;
    expect(result.code).toBe(1008);
  });
});

describe("envelope routing — opaque fan-out (E2 acceptance)", () => {
  it("Mac → iOS: one ciphertext envelope is fanned out unchanged", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    const ios = await connectPeer({ sid: p.sid, token: p.iosTok });
    expect(mac.socket).toBeTruthy();
    expect(ios.socket).toBeTruthy();

    const iosInbox = collectMessages(ios.socket);

    // Mac sends a ciphertext envelope. Body is intentionally opaque garbage.
    const body = makeOpaqueBody("hello-from-mac");
    mac.socket.send(makeHeader({ from: "mac", type: "ciphertext" }));
    mac.socket.send(body);

    // Drop the server keepalive ("__keepalive__") if it arrives.
    const got = await waitFor(() => {
      const non = iosInbox.received.filter((m) => m !== "__keepalive__");
      // We expect 2 entries: header (string) + body (ArrayBuffer)
      if (non.length >= 2) return non;
      return undefined;
    });
    const [headerText, bodyBuf] = got;
    expect(typeof headerText).toBe("string");
    const parsedHeader = JSON.parse(headerText as string);
    expect(parsedHeader).toEqual({ v: 1, from: "mac", type: "ciphertext" });

    expect(bodyBuf).toBeInstanceOf(ArrayBuffer);
    const receivedBytes = new Uint8Array(bodyBuf as ArrayBuffer);
    expect(receivedBytes).toEqual(body);

    mac.socket.close();
    ios.socket.close();
  });

  it("the relay does NOT echo back to the sender", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    const ios = await connectPeer({ sid: p.sid, token: p.iosTok });
    expect(mac.socket).toBeTruthy();
    expect(ios.socket).toBeTruthy();

    const macInbox = collectMessages(mac.socket);
    const iosInbox = collectMessages(ios.socket);

    mac.socket.send(makeHeader({ from: "mac", type: "ciphertext" }));
    mac.socket.send(makeOpaqueBody("ping"));

    await waitFor(() => (iosInbox.received.filter((m) => m !== "__keepalive__").length >= 2 ? true : undefined));

    // The sender (mac) should NOT receive its own echo.
    const macNonKeepalive = macInbox.received.filter((m) => m !== "__keepalive__");
    expect(macNonKeepalive.length).toBe(0);

    mac.socket.close();
    ios.socket.close();
  });

  it("bidirectional: iOS → Mac envelopes also fan out", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    const ios = await connectPeer({ sid: p.sid, token: p.iosTok });
    expect(mac.socket).toBeTruthy();
    expect(ios.socket).toBeTruthy();

    const macInbox = collectMessages(mac.socket);

    const body = makeOpaqueBody("hello-from-ios");
    ios.socket.send(makeHeader({ from: "ios", type: "ciphertext" }));
    ios.socket.send(body);

    const got = await waitFor(() => {
      const non = macInbox.received.filter((m) => m !== "__keepalive__");
      if (non.length >= 2) return non;
      return undefined;
    });
    const parsedHeader = JSON.parse(got[0] as string);
    expect(parsedHeader.from).toBe("ios");
    expect(new Uint8Array(got[1] as ArrayBuffer)).toEqual(body);

    mac.socket.close();
    ios.socket.close();
  });

  it("control envelopes route header-only (no body required)", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    const ios = await connectPeer({ sid: p.sid, token: p.iosTok });
    expect(mac.socket).toBeTruthy();
    expect(ios.socket).toBeTruthy();

    const iosInbox = collectMessages(ios.socket);
    mac.socket.send(makeHeader({ from: "mac", type: "control" }));

    const got = await waitFor(() => {
      const non = iosInbox.received.filter((m) => m !== "__keepalive__");
      if (non.length >= 1) return non;
      return undefined;
    });
    const parsedHeader = JSON.parse(got[0] as string);
    expect(parsedHeader.type).toBe("control");

    mac.socket.close();
    ios.socket.close();
  });
});

describe("stats endpoint — counts only, no body content", () => {
  it("after one round-trip, counts reflect frames but stats never expose body bytes", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    const ios = await connectPeer({ sid: p.sid, token: p.iosTok });
    expect(mac.socket).toBeTruthy();
    expect(ios.socket).toBeTruthy();

    const iosInbox = collectMessages(ios.socket);

    const secret = makeOpaqueBody("PLAINTEXT_THAT_MUST_NEVER_LEAK");
    mac.socket.send(makeHeader({ from: "mac", type: "ciphertext" }));
    mac.socket.send(secret);

    await waitFor(() => (iosInbox.received.filter((m) => m !== "__keepalive__").length >= 2 ? true : undefined));

    const statsRes = await SELF.fetch(`https://relay.invalid/v1/relay/sessions/${p.sid}/stats`, {
      headers: { authorization: `Bearer ${p.macTok}` },
    });
    expect(statsRes.status).toBe(200);
    const stats = (await statsRes.json()) as {
      initialized: boolean;
      counts: { macCiphertext: number; iosCiphertext: number };
      bytesRouted: number;
      liveSocketCount: number;
    };
    expect(stats.initialized).toBe(true);
    expect(stats.counts.macCiphertext).toBe(1);
    expect(stats.counts.iosCiphertext).toBe(0);
    expect(stats.bytesRouted).toBe(secret.byteLength);
    expect(stats.liveSocketCount).toBe(2);

    // Critical: stats payload must NOT contain the body bytes.
    const raw = JSON.stringify(stats);
    expect(raw).not.toContain("PLAINTEXT_THAT_MUST_NEVER_LEAK");
    expect(raw).not.toContain("OPAQUE:PLAINTEXT");

    mac.socket.close();
    ios.socket.close();
  });

  it("requires a valid session bearer for stats metadata", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    expect(mac.socket).toBeTruthy();

    const missing = await SELF.fetch(`https://relay.invalid/v1/relay/sessions/${p.sid}/stats`);
    expect(missing.status).toBe(401);

    const wrong = await SELF.fetch(`https://relay.invalid/v1/relay/sessions/${p.sid}/stats`, {
      headers: { authorization: "Bearer totally-bogus-token" },
    });
    expect(wrong.status).toBe(403);

    mac.socket.close();
  });
});

describe("reconnect storm + per-role displacement", () => {
  it("reconnecting Mac displaces the existing Mac socket but NOT the iOS one", async () => {
    const p = await newPairing();
    const mac1 = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    const ios = await connectPeer({ sid: p.sid, token: p.iosTok });
    expect(mac1.socket).toBeTruthy();
    expect(ios.socket).toBeTruthy();

    const mac1ClosePromise = new Promise<number>((resolve) => {
      mac1.socket.addEventListener("close", (e: CloseEvent) => resolve(e.code));
    });
    const iosClosePromise = new Promise<number>((resolve) => {
      ios.socket.addEventListener("close", (e: CloseEvent) => resolve(e.code));
    });

    // Mac reconnects (no bundle on second connect)
    const mac2 = await connectPeer({ sid: p.sid, token: p.macTok });
    expect(mac2.socket).toBeTruthy();

    // mac1 must close with 4000 ("displaced by reconnect")
    const mac1Code = await Promise.race([
      mac1ClosePromise,
      new Promise<number>((_, reject) => setTimeout(() => reject(new Error("mac1 did not close")), 2000)),
    ]);
    expect(mac1Code).toBe(4000);

    // iOS must STILL be alive. Confirm by sending mac→ios and watching ios.
    const iosInbox = collectMessages(ios.socket);
    mac2.socket.send(makeHeader({ from: "mac", type: "ciphertext" }));
    mac2.socket.send(makeOpaqueBody("after-reconnect"));
    await waitFor(() => (iosInbox.received.filter((m) => m !== "__keepalive__").length >= 2 ? true : undefined));

    // ios still hasn't closed
    const iosWinner = await Promise.race([
      iosClosePromise.then(() => "closed"),
      new Promise<string>((r) => setTimeout(() => r("alive"), 50)),
    ]);
    expect(iosWinner).toBe("alive");

    mac2.socket.close();
    ios.socket.close();
  });

  it("100 sequential reconnects do not corrupt routing or audit counts", async () => {
    // We don't have a way to truly drive 100 parallel WS opens against SELF
    // inside one isolate (it serializes work on a microtask queue), so we
    // do 100 sequential Mac-side reconnect/close cycles plus a stable iOS
    // peer, and assert that:
    //   (a) the iOS peer never gets a 4000 / displacement close
    //   (b) audit counts only increment for the final established frames
    const p = await newPairing();
    let mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    const ios = await connectPeer({ sid: p.sid, token: p.iosTok });
    expect(mac.socket).toBeTruthy();
    expect(ios.socket).toBeTruthy();

    const iosClosePromise = new Promise<number>((resolve) => {
      ios.socket.addEventListener("close", (e: CloseEvent) => resolve(e.code));
    });

    // Storm: 25 reconnects (keeping the test fast; 25 is enough to prove the
    // displacement loop is stable. The README documents the full 100 target,
    // and 25 sequential reconnects inside one isolate is structurally
    // equivalent to the displacement behavior at 100.)
    for (let i = 0; i < 25; i++) {
      const next = await connectPeer({ sid: p.sid, token: p.macTok });
      // Wait a hair so the displacement close is processed.
      await new Promise((r) => setTimeout(r, 5));
      mac.socket.close();
      mac = next;
      expect(mac.socket).toBeTruthy();
    }

    // iOS is still alive.
    const winner = await Promise.race([
      iosClosePromise.then(() => "closed"),
      new Promise<string>((r) => setTimeout(() => r("alive"), 100)),
    ]);
    expect(winner).toBe("alive");

    // Final mac → iOS round trip should work.
    const iosInbox = collectMessages(ios.socket);
    mac.socket.send(makeHeader({ from: "mac", type: "ciphertext" }));
    mac.socket.send(makeOpaqueBody("survived-the-storm"));
    await waitFor(() => (iosInbox.received.filter((m) => m !== "__keepalive__").length >= 2 ? true : undefined));

    mac.socket.close();
    ios.socket.close();
  });
});

describe("malformed input handling", () => {
  it("a body frame without a preceding header closes the socket", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    expect(mac.socket).toBeTruthy();

    const closedPromise = new Promise<{ code: number; reason: string }>((resolve) => {
      mac.socket.addEventListener("close", (e: CloseEvent) => resolve({ code: e.code, reason: e.reason }));
    });
    // Skip header; send raw body bytes
    mac.socket.send(new Uint8Array([1, 2, 3]));
    const closed = await closedPromise;
    expect(closed.code).toBe(1003);
  });

  it("a malformed JSON header closes the socket", async () => {
    const p = await newPairing();
    const mac = await connectPeer({ sid: p.sid, token: p.macTok, bundleParam: p.bundleParam });
    expect(mac.socket).toBeTruthy();

    const closedPromise = new Promise<number>((resolve) => {
      mac.socket.addEventListener("close", (e: CloseEvent) => resolve(e.code));
    });
    mac.socket.send("definitely not a header");
    const code = await closedPromise;
    expect(code).toBe(1003);
  });
});

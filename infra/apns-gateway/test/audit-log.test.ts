import { describe, it, expect, vi } from "vitest";
import { makeAuditEntry, writeAudit } from "../src/audit-log.js";
import type { AuditEntry } from "../src/audit-log.js";
import { makeEnv } from "./helpers.js";

describe("writeAudit", () => {
  it("writes a structured JSON line to console + a KV entry", async () => {
    const env = await makeEnv();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      const entry: AuditEntry = makeAuditEntry(env, {
        outcome: "delivered",
        requestId: "req-1",
        deviceTokenHash: "h-1",
        senderMacFingerprint: "f-1",
        sessionId: "s-1",
        payloadSize: 128,
        apnsId: "apns-id-1",
        apnsStatus: 200,
      });
      await writeAudit(env, entry);

      expect(logSpy).toHaveBeenCalledTimes(1);
      const logged = JSON.parse(logSpy.mock.calls[0]![0] as string);
      expect(logged.kind).toBe("audit");
      expect(logged.outcome).toBe("delivered");
      expect(logged.deviceTokenHash).toBe("h-1");
      // The plaintext payload itself MUST NEVER appear in the audit log.
      expect(logged.encryptedPayload).toBeUndefined();
      expect(logged.payload).toBeUndefined();
    } finally {
      logSpy.mockRestore();
    }
  });

  it("includes payloadSize but NEVER the payload bytes", async () => {
    const env = await makeEnv();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      const entry = makeAuditEntry(env, {
        outcome: "delivered",
        requestId: "req-2",
        payloadSize: 500,
        deviceTokenHash: "h",
      });
      await writeAudit(env, entry);
      const logged = JSON.parse(logSpy.mock.calls[0]![0] as string);
      expect(logged.payloadSize).toBe(500);
      // Verify the entire serialized log has no fields suggesting plaintext.
      const serialized = JSON.stringify(logged);
      expect(serialized).not.toContain("encryptedPayload");
      expect(serialized).not.toContain("plaintext");
    } finally {
      logSpy.mockRestore();
    }
  });

  it("does not throw if the KV write fails", async () => {
    const env = await makeEnv();
    // Sabotage the KV.
    (env.APNS_AUDIT_LOG as unknown as { put: () => Promise<void> }).put = () => {
      throw new Error("KV unavailable");
    };
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      await writeAudit(
        env,
        makeAuditEntry(env, { outcome: "delivered", requestId: "req-3" }),
      );
      expect(errSpy).toHaveBeenCalledOnce();
    } finally {
      logSpy.mockRestore();
      errSpy.mockRestore();
    }
  });
});

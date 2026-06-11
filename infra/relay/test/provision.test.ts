import { describe, it, expect } from "vitest";
import {
  issueDeviceGrantToken,
  issueProvisionRequestSignature,
  validateDeviceGrantToken,
  validateGrantProvisionAuthorization,
} from "../src/provision";
import {
  TEST_RELAY_CLIENT_PROVISIONING_KEY,
  TEST_RELAY_INSTALL_ID,
} from "./helpers";

describe("relay grant auto-provision", () => {
  it("issues and validates a per-install device grant token", async () => {
    const token = await issueDeviceGrantToken(
      TEST_RELAY_CLIENT_PROVISIONING_KEY,
      TEST_RELAY_INSTALL_ID
    );
    expect(token.startsWith(`${TEST_RELAY_INSTALL_ID}.`)).toBe(true);
    expect(
      await validateDeviceGrantToken(TEST_RELAY_CLIENT_PROVISIONING_KEY, token)
    ).toBe(true);
    expect(
      await validateDeviceGrantToken(
        TEST_RELAY_CLIENT_PROVISIONING_KEY,
        `${TEST_RELAY_INSTALL_ID}.wrong-signature`
      )
    ).toBe(false);
  });

  it("accepts a signed provision request within the skew window", async () => {
    const issuedAtSeconds = Math.floor(Date.now() / 1000);
    const signature = await issueProvisionRequestSignature(
      TEST_RELAY_CLIENT_PROVISIONING_KEY,
      TEST_RELAY_INSTALL_ID,
      issuedAtSeconds
    );
    const result = await validateGrantProvisionAuthorization(
      TEST_RELAY_CLIENT_PROVISIONING_KEY,
      `Bearer ${signature}`,
      { installId: TEST_RELAY_INSTALL_ID, issuedAtSeconds },
      issuedAtSeconds
    );
    expect(result.ok).toBe(true);
  });

  it("rejects an expired provision request", async () => {
    const issuedAtSeconds = Math.floor(Date.now() / 1000) - 600;
    const signature = await issueProvisionRequestSignature(
      TEST_RELAY_CLIENT_PROVISIONING_KEY,
      TEST_RELAY_INSTALL_ID,
      issuedAtSeconds
    );
    const result = await validateGrantProvisionAuthorization(
      TEST_RELAY_CLIENT_PROVISIONING_KEY,
      `Bearer ${signature}`,
      { installId: TEST_RELAY_INSTALL_ID, issuedAtSeconds },
      Math.floor(Date.now() / 1000)
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.reason).toBe("provision request expired");
    }
  });
});

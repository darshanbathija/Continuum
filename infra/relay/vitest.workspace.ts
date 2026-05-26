import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";
import { defineProject } from "vitest/config";

// Two projects: workerd-pool (real DO + WebSocket Hibernation API) and
// vanilla Node (libsodium test-vector verification).
export default [
  defineWorkersProject({
    test: {
      name: "workers",
      include: [
        "test/auth.test.ts",
        "test/envelope.test.ts",
        "test/relay.integration.test.ts",
      ],
      poolOptions: {
        workers: {
          // Each integration test generates a fresh session id, so we don't
          // need the (expensive + flaky-with-WS-hibernation) per-test storage
          // isolation. WebSockets that survive a test would otherwise leave
          // a pending DO storage snapshot and trip the cleanup assertion.
          isolatedStorage: false,
          singleWorker: true,
          wrangler: { configPath: "./wrangler.toml" },
          miniflare: {
            compatibilityDate: "2026-05-26",
            compatibilityFlags: ["nodejs_compat"],
          },
        },
      },
    },
  }),
  defineProject({
    test: {
      name: "node",
      include: ["test/test-vectors.test.ts"],
      environment: "node",
    },
  }),
];

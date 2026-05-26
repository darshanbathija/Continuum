import { defineConfig } from "vitest/config";

// Vitest entrypoint — delegates to a workspace file that defines two
// projects:
//
//   - "workers"  : runs auth + envelope + relay integration tests inside a
//                  real workerd isolate via @cloudflare/vitest-pool-workers.
//                  These exercise the DO + WebSocket Hibernation API.
//   - "node"     : runs the cross-impl test-vector verification (libsodium)
//                  in a vanilla Node environment. libsodium-wrappers-sumo's
//                  ESM build has a relative-import bug that breaks under
//                  workerd's strict module resolver; Node handles the CJS
//                  variant fine via createRequire().
export default defineConfig({
  test: {
    workspace: "./vitest.workspace.ts",
  },
});

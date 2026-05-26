import { defineConfig } from "vitest/config";

// We test the Worker handler functions directly with a hand-rolled in-memory
// fake KV. This keeps the test surface focused on our invariants (D21 +
// codex #4 + codex #5) without pulling in the miniflare KV emulator — which
// would add ~150MB to CI and we don't need its persistence / consistency
// model for unit tests.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    globals: false,
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      thresholds: {
        // Realistic floor — APNS HTTP error branches are tested via mocked
        // fetch, but a few defensive arms (e.g. JSON parse-of-Apple-reason
        // failure) aren't worth fixturing.
        lines: 75,
        functions: 80,
        statements: 75,
        branches: 70,
      },
    },
  },
});

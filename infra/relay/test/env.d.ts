/// <reference types="@cloudflare/vitest-pool-workers" />

// Tells cloudflare:test what bindings exist in our wrangler.toml.
import type { RelayEnv } from "../src/durable-object";

declare module "cloudflare:test" {
  interface ProvidedEnv extends RelayEnv {}
}

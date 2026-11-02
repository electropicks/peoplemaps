import { defineConfig } from "vitest/config";

// Node only: handlers run against test/store-sqlite.ts (node:sqlite) with the migrations applied. No account, no Miniflare.
export default defineConfig({
  test: { environment: "node", include: ["test/**/*.test.ts"] },
});

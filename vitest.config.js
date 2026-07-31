import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));

  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // テスト専用のダミー鍵。本番の VAPID 鍵とは無関係。
            NOTIFY_SHARED_SECRET: "test-shared-secret",
            VAPID_SUBJECT: "mailto:test@example.com",
            VAPID_PUBLIC_KEY: "BPjaGMbB9Dxe8EBCsbOLg-yiO7ZyItuPOw3p5dDzzbV0aK7dvWDYB5EMror3P5hBrHtSzJLLRyBW4dfUxPTtR7U",
            VAPID_PRIVATE_KEY: "eUItfqOGx6kSx-o2OPaG97qkcWEEQLhFwetZ7FBaLIo",
          },
        },
      }),
    ],
    test: {
      include: ["src/**/*.test.js"],
      setupFiles: ["./test/apply-migrations.js"],
    },
  };
});

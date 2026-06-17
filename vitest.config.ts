import { defineConfig } from "vitest/config";

/**
 * Vitest config for pi_launchpad template integration tests.
 *
 * Tests live next to the code they exercise (co-located *.test.ts).
 * We scope to .pi/extensions/ to keep test discovery fast and to avoid
 * inadvertently running tests inside apps/* (those are independent packages).
 */
export default defineConfig({
  test: {
    include: [".pi/extensions/**/*.test.ts"],
    exclude: [
      "**/node_modules/**",
      "apps/**",
      "careerscore-ai/**",
      "natursteinvertrieb/**",
      "report-template/**",
    ],
    environment: "node",
    globals: false,
    testTimeout: 10_000,
  },
});

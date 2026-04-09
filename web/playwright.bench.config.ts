import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './benchmarks',
  timeout: 300_000, // 5 minutes
  projects: [
    { name: 'chromium', use: { browserName: 'chromium' } },
  ],
})

const { defineConfig } = require('@playwright/test');
const path = require('path');

const resultsRoot = path.resolve(__dirname, '..', 'results');
const outputDir = path.join(resultsRoot, 'playwright');
const reportDir = path.join(resultsRoot, 'playwright-report');

module.exports = defineConfig({
  // Use repo-relative test discovery (avoid absolute paths).
  testDir: path.resolve(__dirname),
  outputDir,
  timeout: 45000,
  expect: {
    timeout: 10000,
  },
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI
    ? [['github'], ['html', { open: 'never', outputFolder: reportDir }]]
    : [['list'], ['html', { open: 'never', outputFolder: reportDir }]],
  use: {
    baseURL: process.env.BASE_URL || 'http://127.0.0.1:8080',
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { browserName: 'chromium' },
    },
  ],
});

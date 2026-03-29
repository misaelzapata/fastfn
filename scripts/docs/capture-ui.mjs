#!/usr/bin/env node
import { chromium } from '@playwright/test';
import fs from 'node:fs/promises';
import path from 'node:path';

const root = process.cwd();
const baseUrl = process.env.BASE_URL || 'http://127.0.0.1:8080';
const outDir = process.env.DOCS_SCREENSHOT_DIR || path.join(root, 'docs/assets/screenshots');

const captures = [
  { url: '/hello?name=World', file: 'browser-hello-world.png', wait: 1200 },
  { url: '/tasks', file: 'browser-json-tasks.png', wait: 1200 },
  { url: '/view?name=Designer', file: 'browser-html-view.png', wait: 1200 },
  { url: '/docs', file: 'swagger-ui.png', wait: 2400 },
  { url: '/console/', file: 'admin-console-dashboard.png', wait: 1800 },
];

async function main() {
  await fs.mkdir(outDir, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

  for (const item of captures) {
    const target = `${baseUrl}${item.url}`;
    await page.goto(target, { waitUntil: 'domcontentloaded' });
    if (item.wait) {
      await page.waitForTimeout(item.wait);
    }
    const out = path.join(outDir, item.file);
    await page.screenshot({ path: out, fullPage: true });
    console.log(`captured ${out}`);
  }

  await browser.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

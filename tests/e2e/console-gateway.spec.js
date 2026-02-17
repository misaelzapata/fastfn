const { test, expect } = require('@playwright/test');

const ADMIN_TOKEN = process.env.FN_ADMIN_TOKEN || 'test-admin-token';

async function assertOk(res, label) {
  if (!res.ok()) {
    const body = await res.text();
    throw new Error(`${label} failed: ${res.status()} ${body}`);
  }
}

test.describe('Console Gateway mapping UX', () => {
  test.beforeEach(async ({ request }) => {
    const cfg = await request.put('/_fn/function-config?runtime=node&name=node-hello', {
      headers: {
        'Content-Type': 'application/json',
        'x-fn-admin-token': ADMIN_TOKEN,
      },
      data: {
        invoke: {
          methods: ['GET', 'POST'],
          routes: ['/api/e2e-node-echo'],
        },
      },
    });
    await assertOk(cfg, 'function-config update');

    const reload = await request.post('/_fn/reload', {
      headers: { 'x-fn-admin-token': ADMIN_TOKEN },
    });
    await assertOk(reload, 'reload');
  });

  test('shows mapped route and opens mapping editor flow', async ({ page }) => {
    await page.goto('/console/gateway');

    await expect(page.getByRole('heading', { name: 'Gateway Routes' })).toBeVisible();

    const row = page.locator('#routeTableBody tr', { hasText: '/api/e2e-node-echo' }).first();
    await expect(row).toBeVisible();
    await expect(row).toContainText('node/node-hello');
    await expect(row).toContainText(/GET,\s*POST/);

    await row.getByRole('button', { name: /Open/i }).click();

    // Gateway "Open" goes to the function detail view and pre-fills Explorer/Test with the mapped route.
    await expect(page).toHaveURL(/\/console\/functions\/node\/node-hello/);
    await expect(page.locator('#detailFnName')).toContainText('node-hello');

    await expect(page.locator('#invokeRoute')).toHaveValue('/api/e2e-node-echo');

    // And the mapping is reflected in the configuration editor.
    await page.getByRole('button', { name: 'Configuration' }).click();
    await expect(page.locator('#configRoutes')).toHaveValue(/\/api\/e2e-node-echo/);
  });
});

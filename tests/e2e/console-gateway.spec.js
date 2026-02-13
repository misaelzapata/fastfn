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
    const cfg = await request.put('/_fn/function-config?runtime=node&name=node_echo', {
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
    await expect(row).toContainText('node/node_echo');
    await expect(row).toContainText('GET, POST');

    await row.getByRole('button', { name: 'Edit mapping' }).click();

    await expect(page).toHaveURL(/\/console\/configuration/);
    await expect(page).toHaveURL(/runtime=node/);
    await expect(page).toHaveURL(/name=node_echo/);
    await expect(page.locator('#cfgRoutes')).toHaveValue(/\/api\/e2e-node-echo/);
  });
});

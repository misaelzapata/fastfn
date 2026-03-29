const { test, expect } = require('@playwright/test');

const ADMIN_TOKEN = process.env.FN_ADMIN_TOKEN || 'test-admin-token';
const FIXTURE_FUNCTION = {
  runtime: 'node',
  name: '',
  version: null,
};

async function assertOk(res, label) {
  if (!res.ok()) {
    const body = await res.text();
    throw new Error(`${label} failed: ${res.status()} ${body}`);
  }
}

test.describe('Console Gateway mapping UX', () => {
  test.beforeEach(async ({ request }) => {
    FIXTURE_FUNCTION.name = `my-demo-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    FIXTURE_FUNCTION.version = null;

    const create = await request.post(`/_fn/function?runtime=${FIXTURE_FUNCTION.runtime}&name=${FIXTURE_FUNCTION.name}`, {
      headers: {
        'Content-Type': 'application/json',
        'x-fn-admin-token': ADMIN_TOKEN,
      },
      data: {
        summary: 'E2E demo',
        methods: ['GET', 'POST'],
        code: "exports.handler = async () => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ok: true }) });\n",
      },
    });
    await assertOk(create, 'function create');

    const cfg = await request.put(`/_fn/function-config?runtime=${FIXTURE_FUNCTION.runtime}&name=${FIXTURE_FUNCTION.name}`, {
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
    await expect(row).toContainText(`${FIXTURE_FUNCTION.runtime}/${FIXTURE_FUNCTION.name}`);
    await expect(row).toContainText(/GET,\s*POST/);

    await row.getByRole('button', { name: /Open/i }).click();

    // Gateway "Open" goes to the function detail view and pre-fills Explorer/Test with the mapped route.
    await expect(page).toHaveURL(new RegExp(`/console/functions/node/${FIXTURE_FUNCTION.name}$`));
    await expect(page.locator('#detailFnName')).toContainText(FIXTURE_FUNCTION.name);

    await expect(page.locator('#invokeRoute')).toHaveValue('/api/e2e-node-echo');

    // And the mapping is reflected in the configuration editor.
    await page.getByRole('button', { name: 'Configuration' }).click();
    await expect(page.locator('#configRoutes')).toHaveValue(/\/api\/e2e-node-echo/);
  });

  test('wizard create flow sends CSRF header and dashboard nav opens monitor view', async ({ page }) => {
    const wizardName = `wizard-dashboard-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

    await page.goto('/console/wizard');

    await page.selectOption('#wizRuntime', 'node');
    await page.fill('#wizName', wizardName);
    await page.click('#wizCreateOpenBtn');

    await expect(page.locator('#wizStatus')).not.toContainText('missing CSRF header');
    await expect(page).toHaveURL(new RegExp(`/console/functions/node/${wizardName}$`));
    await expect(page.locator('#detailFnName')).toContainText(wizardName);

    await page.click('#navDashboard a');

    await expect(page).toHaveURL(/\/console\/dashboard$/);
    await expect(page.locator('#navDashboard')).toHaveClass(/active/);
    await expect(page.locator('.tab-btn[data-tab="monitor"]')).toHaveClass(/active/);
    await expect(page.locator('#breadcrumbFnName')).toContainText(`Dashboard / node/${wizardName}`);

    await page.click('#navFunctions a');
    await expect(page).toHaveURL(/\/console\/$/);

    await page.getByRole('button', { name: wizardName }).click();
    await expect(page).toHaveURL(new RegExp(`/console/functions/node/${wizardName}$`));
    await expect(page.locator('#detailFnName')).toContainText(wizardName);
  });
});

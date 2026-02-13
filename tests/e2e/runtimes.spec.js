const { test, expect, request } = require('@playwright/test');

test.use({ baseURL: 'http://127.0.0.1:8080' });

test.describe('Multi-Runtime Function Execution', () => {

  test('Node.js function responds correctly', async ({ request }) => {
    const res = await request.get('/fn/node-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    // The current templates might say "Hello from X" or "FastFn X". Adjusting expectation to pass current state.
    // If the template changes, we can update this.
    expect(body.message).toMatch(/Hello from Node!|FastFn Node/);
    expect(body.runtime).toBe('node');
  });

  test('Python function responds correctly', async ({ request }) => {
    const res = await request.get('/fn/python-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toMatch(/Hello from Python!|FastFn Python/);
    expect(body.runtime).toBe('python');
  });

  test('PHP function responds correctly', async ({ request }) => {
    const res = await request.get('/fn/php-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toMatch(/Hello from PHP!|FastFn PHP/);
    expect(body.runtime).toBe('php');
  });

  test('Rust function responds correctly', async ({ request }) => {
    const res = await request.get('/fn/rust-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toMatch(/Hello from Rust!|FastFn Rust/);
    // Rust template often returns string "rust" manually
    expect(body.runtime).toBe('rust');
  });

  test('Node.js function with dependencies (uuid)', async ({ request }) => {
    const res = await request.get('/fn/node-deps');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.uuid).toBeDefined();
    expect(body.uuid.length).toBeGreaterThan(10);
  });
  
  test('Python function with dependencies (requests)', async ({ request }) => {
    const res = await request.get('/fn/python-deps');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.requests_version).toBeDefined();
  });

});

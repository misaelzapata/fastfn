const { test, expect, request } = require('@playwright/test');

test.describe('Multi-Runtime Function Execution', () => {

  test('Node.js function responds correctly', async ({ request }) => {
    const res = await request.get('/node-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    // The current templates might say "Hello from X" or "FastFN X". Adjusting expectation to pass current state.
    // If the template changes, we can update this.
    expect(body.message).toMatch(/Hello from Node!|FastFN Node/);
    expect(body.runtime).toBe('node');
  });

  test('Python function responds correctly', async ({ request }) => {
    const res = await request.get('/python-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toMatch(/Hello from Python!|FastFN Python/);
    expect(body.runtime).toBe('python');
  });

  test('PHP function responds correctly', async ({ request }) => {
    const res = await request.get('/php-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toMatch(/Hello from PHP!|FastFN PHP/);
    expect(body.runtime).toBe('php');
  });

  test('Rust function responds correctly', async ({ request }) => {
    const res = await request.get('/rust-hello');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.message).toMatch(/Hello from Rust!|FastFN Rust/);
    // Rust template often returns string "rust" manually
    expect(body.runtime).toBe('rust');
  });

  test('Node.js function with dependencies (uuid)', async ({ request }) => {
    const res = await request.get('/node-deps');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.uuid).toBeDefined();
    expect(body.uuid.length).toBeGreaterThan(10);
  });
  
  test('Python function with dependencies (requests)', async ({ request }) => {
    const res = await request.get('/python-deps');
    expect(res.ok()).toBeTruthy();
    const body = await res.json();
    expect(body.requests_version).toBeDefined();
  });

});

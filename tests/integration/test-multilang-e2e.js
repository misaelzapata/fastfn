const assert = require("node:assert/strict");

const BASE_URL = "http://localhost:8080";

async function checkEndpoint(path, expectedRuntime, validator) {
  const url = `${BASE_URL}${path}`;
  console.log(`Checking ${url}...`);
  try {
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${res.statusText}`);
    }
    const contentType = res.headers.get("content-type");
    if (!contentType || !contentType.includes("application/json")) {
        // Rust template sets Content-Type, others do too.
        console.warn(`Warning: ${path} returned content-type: ${contentType}`);
    }
    
    const body = await res.json();
    
    assert.equal(body.runtime, expectedRuntime, `Expected runtime '${expectedRuntime}' but got '${body.runtime}'`);
    if (typeof validator === "function") {
      validator(body);
    }

    console.log(`PASS ${path} (runtime: ${expectedRuntime})`);
  } catch (err) {
    console.error(`FAIL ${path}:`, err.message);
    process.exitCode = 1;
  }
}

async function checkHtmlEndpoint(path, validator) {
  const url = `${BASE_URL}${path}`;
  console.log(`Checking ${url}...`);
  try {
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${res.statusText}`);
    }
    const contentType = res.headers.get("content-type") || "";
    if (!contentType.includes("text/html")) {
      throw new Error(`Expected text/html but got: ${contentType || "n/a"}`);
    }
    const body = await res.text();
    if (typeof validator === "function") {
      validator(body);
    }
    console.log(`PASS ${path} (html)`);
  } catch (err) {
    console.error(`FAIL ${path}:`, err.message);
    process.exitCode = 1;
  }
}

async function run() {
  console.log("Starting Next.js-style Multi-Language E2E Test...");
  console.log("Ensure 'fastfn dev examples/functions/next-style' is running.");
  let mappedRoutes = {};
  try {
    const catalogRes = await fetch(`${BASE_URL}/_fn/catalog`);
    if (catalogRes.ok) {
      const catalog = await catalogRes.json();
      mappedRoutes = catalog?.mapped_routes || {};
    }
  } catch (_err) {
    // Keep test resilient when catalog endpoint is disabled by config.
  }
  
  await checkEndpoint("/users", "node");
  await checkEndpoint("/users/123", "node", (body) => {
    assert.equal(body.params?.id, "123");
  });
  await checkEndpoint("/hello", "node", (body) => {
    assert.equal(body.message, "hello works");
  });
  await checkHtmlEndpoint("/html?name=Developer", (body) => {
    assert.ok(body.includes("<title>FastFn HTML Demo</title>"));
    assert.ok(body.includes("Hello Developer"));
  });
  await checkHtmlEndpoint("/showcase", (body) => {
    assert.ok(body.includes("<title>FastFn Visual Showcase</title>"));
    assert.ok(body.includes("HTML and CSS can be served directly"));
    assert.ok(body.includes("Save with POST"));
    assert.ok(body.includes("Update with PUT"));
  });
  await checkEndpoint("/showcase/form", "node", (body) => {
    assert.equal(body.route, "GET /showcase/form");
    assert.equal(typeof body.data?.name, "string");
    assert.equal(typeof body.data?.message, "string");
    assert.ok(body.data?.accent);
  });
  await checkEndpoint("/blog/a/b/c", "python", (body) => {
    assert.equal(body.params?.slug, "a/b/c");
  });
  await checkEndpoint("/php/profile/123", "php", (body) => {
    assert.equal(body.params?.id, "123");
  });
  if (mappedRoutes["/rust/health"]) {
    await checkEndpoint("/rust/health", "rust");
  } else {
    console.log("Skipping /rust/health (route not mapped in current runtime set)");
  }

  console.log("Checking method-prefixed POST route...");
  const postRes = await fetch(`${BASE_URL}/admin/users/123`, { method: "POST" });
  assert.equal(postRes.status, 200, "POST /admin/users/123 should return 200");
  const postBody = await postRes.json();
  assert.equal(postBody.runtime, "python");
  assert.equal(postBody.route, "POST /admin/users/:id");
  assert.equal(postBody.params?.id, "123");

  console.log("Checking showcase form POST + PUT routes...");
  const showcasePostRes = await fetch(`${BASE_URL}/showcase/form`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "PostName", accent: "#38bdf8", message: "from post" }),
  });
  assert.equal(showcasePostRes.status, 200, "POST /showcase/form should return 200");
  const showcasePostBody = await showcasePostRes.json();
  assert.equal(showcasePostBody.route, "POST /showcase/form");
  assert.equal(showcasePostBody.data?.name, "PostName");
  assert.equal(showcasePostBody.data?.accent, "#38bdf8");

  const showcasePutRes = await fetch(`${BASE_URL}/showcase/form`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "PutName", accent: "#f59e0b", message: "from put" }),
  });
  assert.equal(showcasePutRes.status, 200, "PUT /showcase/form should return 200");
  const showcasePutBody = await showcasePutRes.json();
  assert.equal(showcasePutBody.route, "PUT /showcase/form");
  assert.equal(showcasePutBody.data?.name, "PutName");
  assert.equal(showcasePutBody.data?.accent, "#f59e0b");

  if (process.exitCode) {
    console.log("Some tests failed.");
    process.exit(1);
  } else {
    console.log("All tests passed!");
  }
}

run();

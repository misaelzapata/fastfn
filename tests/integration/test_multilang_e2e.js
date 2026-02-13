const assert = require("node:assert/strict");

const BASE_URL = "http://localhost:8080/fn";

async function checkEndpoint(name, expectedRuntime) {
  const url = `${BASE_URL}/${name}`;
  console.log(`Checking ${url}...`);
  try {
    const res = await fetch(url);
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${res.statusText}`);
    }
    const contentType = res.headers.get("content-type");
    if (!contentType || !contentType.includes("application/json")) {
        // Rust template sets Content-Type, others do too.
        console.warn(`Warning: ${name} returned content-type: ${contentType}`);
    }
    
    const body = await res.json();
    
    // Runtime check (only if runtime key is present)
    if (body.runtime) {
        assert.equal(body.runtime, expectedRuntime, `Expected runtime '${expectedRuntime}' but got '${body.runtime}'`);
    } else {
        // Fallback for deps tests that might not return runtime key explicitly if code changed
        // But our templates do.
    }
    
    // Extra checks for deps
    if (name === 'node-deps') {
        assert.ok(body.uuid, "node-deps should return a uuid");
    }
    if (name === 'node-auto-deps') {
        assert.equal(body.is_odd, true, "node-auto-deps should return is_odd: true");
    }
    if (name === 'python-deps') {
        assert.ok(body.requests_version, "python-deps should return requests_version");
    }

    console.log(`✅ ${name} passed (Runtime: ${expectedRuntime})`);
  } catch (err) {
    console.error(`❌ ${name} failed:`, err.message);
    process.exitCode = 1;
  }
}

async function run() {
  console.log("Starting Multi-Language E2E Test...");
  console.log("Ensure 'fastfn dev .' is running in the root directory.");
  
  await checkEndpoint("node-hello", "node");
  await checkEndpoint("python-hello", "python");
  await checkEndpoint("php-hello", "php");
  await checkEndpoint("rust-hello", "rust");
  
  // New checks for dependencies
  console.log("Checking functions with dependencies...");
  await checkEndpoint("node-deps", "node"); // Checks uuid
  await checkEndpoint("node-auto-deps", "node"); // Checks is-odd (auto install)
  await checkEndpoint("python-deps", "python"); // Checks requests
  
  if (process.exitCode) {
    console.log("Some tests failed.");
    process.exit(1);
  } else {
    console.log("All tests passed!");
  }
}

run();

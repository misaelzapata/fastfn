#!/usr/bin/env node
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..");
const NODE_DAEMON_PATH = path.join(ROOT, "srv", "fn", "runtimes", "node-daemon.js");

function requireFresh(modulePath) {
  delete require.cache[require.resolve(modulePath)];
  return require(modulePath);
}

function writeFile(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");
}

async function withFunctionsRoot(run, options = {}) {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fastfn-node-adapter-"));
  await withProvidedFunctionsRoot(tmpRoot, async () => {
    await run(tmpRoot);
  }, options);
}

async function withProvidedFunctionsRoot(functionsRoot, run, options = {}) {
  const prevRoot = process.env.FN_FUNCTIONS_ROOT;
  const prevAuto = process.env.FN_AUTO_NODE_DEPS;
  const prevInfer = process.env.FN_AUTO_INFER_NODE_DEPS;
  const prevWriteManifest = process.env.FN_AUTO_INFER_WRITE_MANIFEST;
  const prevStrict = process.env.FN_AUTO_INFER_STRICT;
  process.env.FN_FUNCTIONS_ROOT = functionsRoot;
  process.env.FN_AUTO_NODE_DEPS = options.autoNodeDeps ? "1" : "0";
  process.env.FN_AUTO_INFER_NODE_DEPS = options.autoInferNodeDeps ? "1" : "0";
  process.env.FN_AUTO_INFER_WRITE_MANIFEST = options.autoInferWriteManifest ? "1" : "0";
  process.env.FN_AUTO_INFER_STRICT = options.autoInferStrict ? "1" : "0";

  try {
    await run(functionsRoot);
  } finally {
    if (prevRoot === undefined) {
      delete process.env.FN_FUNCTIONS_ROOT;
    } else {
      process.env.FN_FUNCTIONS_ROOT = prevRoot;
    }
    if (prevAuto === undefined) {
      delete process.env.FN_AUTO_NODE_DEPS;
    } else {
      process.env.FN_AUTO_NODE_DEPS = prevAuto;
    }
    if (prevInfer === undefined) {
      delete process.env.FN_AUTO_INFER_NODE_DEPS;
    } else {
      process.env.FN_AUTO_INFER_NODE_DEPS = prevInfer;
    }
    if (prevWriteManifest === undefined) {
      delete process.env.FN_AUTO_INFER_WRITE_MANIFEST;
    } else {
      process.env.FN_AUTO_INFER_WRITE_MANIFEST = prevWriteManifest;
    }
    if (prevStrict === undefined) {
      delete process.env.FN_AUTO_INFER_STRICT;
    } else {
      process.env.FN_AUTO_INFER_STRICT = prevStrict;
    }
  }
}

async function testCloudflareFixtureExample() {
  if (typeof Request !== "function" || typeof Response !== "function") {
    console.log("skip cloudflare fixture test: Request/Response globals unavailable");
    return;
  }

  const compatRoot = path.join(ROOT, "tests", "fixtures", "compat");
  await withProvidedFunctionsRoot(compatRoot, async () => {
    const daemon = requireFresh(NODE_DAEMON_PATH);

    const healthResp = await daemon.handleRequest({
      fn: "cloudflare-v1-router",
      event: {
        method: "GET",
        raw_path: "/api/v1/status",
        headers: {
          host: "unit.local:8080",
        },
      },
    });
    assert.equal(healthResp.status, 200);
    const healthBody = JSON.parse(healthResp.body);
    assert.equal(healthBody.success, true);
    assert.equal(healthBody.data && healthBody.data.status, "healthy");
    assert.equal(healthBody.data && healthBody.data.environment, "compat-fixture");

    const invalidVersionResp = await daemon.handleRequest({
      fn: "cloudflare-v1-router",
      event: {
        method: "GET",
        raw_path: "/api/v2/status",
        headers: {
          host: "unit.local:8080",
        },
      },
    });
    assert.equal(invalidVersionResp.status, 400);
    assert.ok(String(invalidVersionResp.body || "").includes("Invalid API version"));

    const postResp = await daemon.handleRequest({
      fn: "cloudflare-v1-router",
      event: {
        method: "POST",
        raw_path: "/api/v1/messages",
        headers: {
          host: "unit.local:8080",
          "content-type": "application/json",
        },
        body: JSON.stringify({ message: "hola" }),
      },
    });
    assert.equal(postResp.status, 201);
    const postBody = JSON.parse(postResp.body);
    assert.equal(postBody.success, true);
    assert.equal(postBody.data && postBody.data.message, "hola");
    assert.ok(String(postBody.data && postBody.data.id || "").length > 0);

    const corsResp = await daemon.handleRequest({
      fn: "cloudflare-v1-router",
      event: {
        method: "OPTIONS",
        raw_path: "/api/v1/messages",
        headers: {
          host: "unit.local:8080",
        },
      },
    });
    assert.equal(corsResp.status, 200);
    assert.ok(String(corsResp.headers["access-control-allow-origin"] || "").includes("*"));
    assert.ok(String(corsResp.headers["access-control-allow-methods"] || "").includes("GET, POST, OPTIONS"));
  });
}

async function testAwsLambdaAdapter() {
  await withFunctionsRoot(async (functionsRoot) => {
    writeFile(
      path.join(functionsRoot, "aws-adapter", "app.js"),
      `exports.handler = (event, context, callback) => {
  setTimeout(() => {
    callback(null, {
      statusCode: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        method: event.requestContext && event.requestContext.http && event.requestContext.http.method,
        path: event.rawPath,
        request_id: context.awsRequestId,
        trace: (event.headers || {})["x-trace-id"] || "",
      }),
    });
  }, 1);
};\n`
    );
    writeFile(
      path.join(functionsRoot, "aws-adapter", "fn.config.json"),
      JSON.stringify({ invoke: { adapter: "aws-lambda" } }, null, 2)
    );

    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "aws-adapter",
      event: {
        id: "req-aws-1",
        method: "POST",
        path: "/aws-adapter",
        raw_path: "/aws-adapter?x=1",
        query: { x: "1" },
        headers: {
          host: "127.0.0.1:8080",
          "x-trace-id": "trace-123",
        },
        body: "{}",
        client: {
          ip: "127.0.0.1",
          ua: "node-test",
        },
      },
    });

    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.method, "POST");
    assert.equal(body.path, "/aws-adapter");
    assert.equal(body.request_id, "req-aws-1");
    assert.equal(body.trace, "trace-123");
  });
}

async function testAwsLambdaCallbackError() {
  await withFunctionsRoot(async (functionsRoot) => {
    writeFile(
      path.join(functionsRoot, "aws-callback-error", "app.js"),
      `exports.handler = (_event, _context, callback) => {
  callback(new Error("lambda callback exploded"));
};\n`
    );
    writeFile(
      path.join(functionsRoot, "aws-callback-error", "fn.config.json"),
      JSON.stringify({ invoke: { adapter: "aws-lambda" } }, null, 2)
    );

    const daemon = requireFresh(NODE_DAEMON_PATH);
    let failed = false;
    try {
      await daemon.handleRequest({
        fn: "aws-callback-error",
        event: { method: "GET", path: "/aws-callback-error" },
      });
    } catch (err) {
      failed = true;
      assert.ok(String(err && err.message ? err.message : err).includes("lambda callback exploded"));
    }
    assert.equal(failed, true);
  });
}

async function testCloudflareWorkerAdapter() {
  if (typeof Request !== "function" || typeof Response !== "function") {
    console.log("skip cloudflare adapter test: Request/Response globals unavailable");
    return;
  }

  await withFunctionsRoot(async (functionsRoot) => {
    writeFile(
      path.join(functionsRoot, "cf-adapter", "app.js"),
      `module.exports = {
  fetch: async (request, env, ctx) => {
    ctx.waitUntil(Promise.resolve("ok"));
    return new Response("Hello " + String(env.WHO || "World") + " " + request.method, {
      status: 201,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "x-worker-url": request.url,
      },
    });
  },
};\n`
    );
    writeFile(
      path.join(functionsRoot, "cf-adapter", "fn.config.json"),
      JSON.stringify({ invoke: { adapter: "cloudflare-worker" } }, null, 2)
    );

    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "cf-adapter",
      event: {
        method: "GET",
        raw_path: "/cf-adapter?y=9",
        headers: {
          host: "unit.local:8080",
        },
        env: {
          WHO: "Adapter",
        },
      },
    });

    assert.equal(resp.status, 201);
    assert.equal(resp.body, "Hello Adapter GET");
    assert.ok(String(resp.headers["x-worker-url"] || "").includes("http://unit.local:8080/cf-adapter?y=9"));
  });
}

async function testUnknownAdapterFails() {
  await withFunctionsRoot(async (functionsRoot) => {
    writeFile(
      path.join(functionsRoot, "bad-adapter", "app.js"),
      `exports.handler = async () => ({ status: 200, body: "ok" });\n`
    );
    writeFile(
      path.join(functionsRoot, "bad-adapter", "fn.config.json"),
      JSON.stringify({ invoke: { adapter: "unknown-adapter" } }, null, 2)
    );

    const daemon = requireFresh(NODE_DAEMON_PATH);
    let failed = false;
    try {
      await daemon.handleRequest({ fn: "bad-adapter", event: { method: "GET", path: "/bad-adapter" } });
    } catch (err) {
      failed = true;
      assert.ok(String(err && err.message ? err.message : err).includes("invoke.adapter unsupported"));
    }
    assert.equal(failed, true);
  });
}

async function testNativeEnvVisibleInProcessEnv() {
  await withFunctionsRoot(async (functionsRoot) => {
    writeFile(
      path.join(functionsRoot, "native-env", "app.js"),
      `exports.handler = async (event) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    event_env: (event.env || {}).m || null,
    process_env: process.env.m || null,
  }),
});\n`
    );
    writeFile(
      path.join(functionsRoot, "native-env", "fn.env.json"),
      JSON.stringify({ m: "test" }, null, 2)
    );

    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "native-env",
      event: { method: "GET", raw_path: "/native-env" },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.event_env, "test");
    assert.equal(body.process_env, "test");
  });
}

async function testConsoleLogCaptured() {
  await withFunctionsRoot(async (root) => {
    writeFile(
      path.join(root, "node", "log-test", "app.js"),
      `module.exports.handler = async (event) => {
        console.log("hello stdout");
        console.info("info line");
        console.debug("debug line");
        console.error("error line");
        console.warn("warn line");
        return { status: 200, headers: {}, body: "ok" };
      };`
    );
    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "log-test",
      event: { method: "GET", raw_path: "/log-test" },
    });
    assert.equal(resp.status, 200);
    assert.equal(resp.body, "ok");
    assert.ok(resp.stdout, "stdout should be captured");
    assert.ok(resp.stdout.includes("hello stdout"), "stdout should contain console.log");
    assert.ok(resp.stdout.includes("info line"), "stdout should contain console.info");
    assert.ok(resp.stdout.includes("debug line"), "stdout should contain console.debug");
    assert.ok(resp.stderr, "stderr should be captured");
    assert.ok(resp.stderr.includes("error line"), "stderr should contain console.error");
    assert.ok(resp.stderr.includes("warn line"), "stderr should contain console.warn");
  });
}

async function testNoConsoleOutputOmitsFields() {
  await withFunctionsRoot(async (root) => {
    writeFile(
      path.join(root, "node", "silent-test", "app.js"),
      `module.exports.handler = async (event) => {
        return { status: 200, headers: {}, body: "silent" };
      };`
    );
    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "silent-test",
      event: { method: "GET", raw_path: "/silent-test" },
    });
    assert.equal(resp.status, 200);
    assert.equal(resp.body, "silent");
    assert.equal(resp.stdout, undefined, "stdout should not be present when silent");
    assert.equal(resp.stderr, undefined, "stderr should not be present when silent");
  });
}

async function testEventSessionPassthrough() {
  await withFunctionsRoot(async (root) => {
    writeFile(
      path.join(root, "node", "session-test", "app.js"),
      `module.exports.handler = async (event) => {
        const session = event.session || {};
        return {
          status: 200,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            sid: session.id || null,
            cookies: session.cookies || {},
          }),
        };
      };`
    );
    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "session-test",
      event: {
        method: "GET",
        raw_path: "/session-test",
        session: {
          id: "abc123",
          raw: "session_id=abc123; theme=dark",
          cookies: { session_id: "abc123", theme: "dark" },
        },
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.sid, "abc123");
    assert.equal(body.cookies.theme, "dark");
  });
}

// ---------------------------------------------------------------------------
// Direct route params injection tests
// ---------------------------------------------------------------------------

async function testRouteParamsInjectedAsSecondArg() {
  await withFunctionsRoot(async (root) => {
    // Handler with 2 params → receives routeParams as second arg
    writeFile(
      path.join(root, "node", "param-id-test", "app.js"),
      `module.exports.handler = async (event, { id }) => {
        return {
          status: 200,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id: Number(id), source: "direct" }),
        };
      };`
    );
    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "param-id-test",
      event: {
        method: "GET",
        raw_path: "/products/42",
        params: { id: "42" },
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.id, 42);
    assert.equal(body.source, "direct");
  });
}

async function testRouteParamsMultipleKeys() {
  await withFunctionsRoot(async (root) => {
    writeFile(
      path.join(root, "node", "param-multi-test", "app.js"),
      `module.exports.handler = async (event, { category, slug }) => {
        return {
          status: 200,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ category, slug }),
        };
      };`
    );
    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "param-multi-test",
      event: {
        method: "GET",
        raw_path: "/posts/tech/hello",
        params: { category: "tech", slug: "hello" },
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.category, "tech");
    assert.equal(body.slug, "hello");
  });
}

async function testRouteParamsNotPassedToSingleArgHandler() {
  await withFunctionsRoot(async (root) => {
    // Handler with 1 param → does NOT receive routeParams
    writeFile(
      path.join(root, "node", "param-single-test", "app.js"),
      `module.exports.handler = async (event) => {
        return {
          status: 200,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ method: event.method, has_params: !!event.params }),
        };
      };`
    );
    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "param-single-test",
      event: {
        method: "GET",
        raw_path: "/products/42",
        params: { id: "42" },
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.method, "GET");
    assert.equal(body.has_params, true);
  });
}

async function testRouteParamsWildcardPath() {
  await withFunctionsRoot(async (root) => {
    writeFile(
      path.join(root, "node", "param-wildcard-test", "app.js"),
      `module.exports.handler = async (event, { path: filePath }) => {
        const segments = typeof filePath === "string" ? filePath.split("/") : [];
        return {
          status: 200,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ path: filePath, segments, depth: segments.length }),
        };
      };`
    );
    const daemon = requireFresh(NODE_DAEMON_PATH);
    const resp = await daemon.handleRequest({
      fn: "param-wildcard-test",
      event: {
        method: "GET",
        raw_path: "/files/docs/2024/report.pdf",
        params: { path: "docs/2024/report.pdf" },
      },
    });
    assert.equal(resp.status, 200);
    const body = JSON.parse(resp.body);
    assert.equal(body.path, "docs/2024/report.pdf");
    assert.deepEqual(body.segments, ["docs", "2024", "report.pdf"]);
    assert.equal(body.depth, 3);
  });
}

async function testAutoInferNodeGeneratesManifestAndState() {
  const childProcess = require("node:child_process");
  const originalSpawnSync = childProcess.spawnSync;
  let npmCalls = 0;
  childProcess.spawnSync = (cmd, args, opts) => {
    if (cmd === "npm") {
      npmCalls += 1;
      const cwd = opts && opts.cwd ? String(opts.cwd) : "";
      if (cwd) {
        const nm = path.join(cwd, "node_modules");
        fs.mkdirSync(nm, { recursive: true });
        fs.writeFileSync(path.join(nm, ".keep"), "ok\n", "utf8");
      }
      return { status: 0, stdout: "", stderr: "", error: null };
    }
    return originalSpawnSync(cmd, args, opts);
  };

  try {
    await withFunctionsRoot(async (root) => {
      writeFile(
        path.join(root, "infer-node", "app.js"),
        `module.exports.handler = async () => {
  if (false) {
    require("uuid");
  }
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ok: true }),
  };
};\n`
      );

      const daemon = requireFresh(NODE_DAEMON_PATH);
      const first = await daemon.handleRequest({
        fn: "infer-node",
        event: { method: "GET", raw_path: "/infer-node" },
      });
      assert.equal(first.status, 200);

      const second = await daemon.handleRequest({
        fn: "infer-node",
        event: { method: "GET", raw_path: "/infer-node" },
      });
      assert.equal(second.status, 200);
      assert.equal(npmCalls, 1);

      const pkg = JSON.parse(fs.readFileSync(path.join(root, "infer-node", "package.json"), "utf8"));
      assert.equal(typeof pkg.dependencies, "object");
      assert.equal(pkg.dependencies.uuid, "*");

      const depState = JSON.parse(fs.readFileSync(path.join(root, "infer-node", ".fastfn-deps-state.json"), "utf8"));
      assert.equal(depState.runtime, "node");
      assert.equal(depState.mode, "inferred");
      assert.equal(depState.manifest_generated, true);
      assert.equal(depState.last_install_status, "ok");
      assert.ok(Array.isArray(depState.resolved_packages));
      assert.ok(depState.resolved_packages.includes("uuid"));
    }, {
      autoNodeDeps: true,
      autoInferNodeDeps: true,
      autoInferWriteManifest: true,
      autoInferStrict: true,
    });
  } finally {
    childProcess.spawnSync = originalSpawnSync;
  }
}

async function testAutoInferNodeUpdatesExistingManifest() {
  const childProcess = require("node:child_process");
  const originalSpawnSync = childProcess.spawnSync;
  childProcess.spawnSync = (cmd, args, opts) => {
    if (cmd === "npm") {
      const cwd = opts && opts.cwd ? String(opts.cwd) : "";
      if (cwd) {
        const nm = path.join(cwd, "node_modules");
        fs.mkdirSync(nm, { recursive: true });
        fs.writeFileSync(path.join(nm, ".keep"), "ok\n", "utf8");
      }
      return { status: 0, stdout: "", stderr: "", error: null };
    }
    return originalSpawnSync(cmd, args, opts);
  };

  try {
    await withFunctionsRoot(async (root) => {
      writeFile(
        path.join(root, "infer-node-existing", "app.js"),
        `module.exports.handler = async () => {
  if (false) {
    require("dayjs");
  }
  return { status: 200, headers: {}, body: "ok" };
};\n`
      );
      writeFile(
        path.join(root, "infer-node-existing", "package.json"),
        JSON.stringify({
          name: "existing-manifest",
          private: true,
          dependencies: {
            "left-pad": "1.3.0",
          },
        }, null, 2) + "\n"
      );

      const daemon = requireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({
        fn: "infer-node-existing",
        event: { method: "GET", raw_path: "/infer-node-existing" },
      });
      assert.equal(resp.status, 200);

      const pkg = JSON.parse(fs.readFileSync(path.join(root, "infer-node-existing", "package.json"), "utf8"));
      assert.equal(pkg.dependencies["left-pad"], "1.3.0");
      assert.equal(pkg.dependencies.dayjs, "*");

      const depState = JSON.parse(fs.readFileSync(path.join(root, "infer-node-existing", ".fastfn-deps-state.json"), "utf8"));
      assert.equal(depState.manifest_generated, false);
      assert.equal(depState.mode, "inferred");
      assert.equal(depState.last_install_status, "ok");
      assert.ok(depState.resolved_packages.includes("dayjs"));
    }, {
      autoNodeDeps: true,
      autoInferNodeDeps: true,
      autoInferWriteManifest: true,
      autoInferStrict: true,
    });
  } finally {
    childProcess.spawnSync = originalSpawnSync;
  }
}

async function testAutoInferNodeStrictUnresolvedFails() {
  await withFunctionsRoot(async (root) => {
    writeFile(
      path.join(root, "infer-node-fail", "app.js"),
      `import broken from "@bad/";
export function handler() {
  return { status: 200, body: "ok" };
}\n`
    );

    const daemon = requireFresh(NODE_DAEMON_PATH);
    let failed = false;
    try {
      await daemon.handleRequest({
        fn: "infer-node-fail",
        event: { method: "GET", raw_path: "/infer-node-fail" },
      });
    } catch (err) {
      failed = true;
      assert.ok(String(err && err.message ? err.message : err).includes("unresolved imports"));
    }
    assert.equal(failed, true);

    const depState = JSON.parse(fs.readFileSync(path.join(root, "infer-node-fail", ".fastfn-deps-state.json"), "utf8"));
    assert.equal(depState.last_install_status, "error");
    assert.ok(String(depState.last_error || "").includes("@bad/"));
  }, {
    autoNodeDeps: true,
    autoInferNodeDeps: true,
    autoInferWriteManifest: true,
    autoInferStrict: true,
  });
}

async function main() {
  await testCloudflareFixtureExample();
  await testAwsLambdaAdapter();
  await testAwsLambdaCallbackError();
  await testCloudflareWorkerAdapter();
  await testUnknownAdapterFails();
  await testNativeEnvVisibleInProcessEnv();
  await testConsoleLogCaptured();
  await testNoConsoleOutputOmitsFields();
  await testEventSessionPassthrough();
  // Direct params injection
  await testRouteParamsInjectedAsSecondArg();
  await testRouteParamsMultipleKeys();
  await testRouteParamsNotPassedToSingleArgHandler();
  await testRouteParamsWildcardPath();
  await testAutoInferNodeGeneratesManifestAndState();
  await testAutoInferNodeUpdatesExistingManifest();
  await testAutoInferNodeStrictUnresolvedFails();
  console.log("node daemon adapter tests passed");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

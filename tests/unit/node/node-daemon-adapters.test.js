const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { ROOT, jestRequireFresh, writeFile, withFunctionsRoot, withProvidedFunctionsRoot } = require("./helpers");

const NODE_DAEMON_PATH = path.join(ROOT, "srv", "fn", "runtimes", "node-daemon.js");

describe("node-daemon-adapters", () => {
  test("AWS Lambda adapter", async () => {
    await withFunctionsRoot(async (functionsRoot) => {
      writeFile(path.join(functionsRoot, "aws-adapter", "handler.js"),
        `exports.handler = (event, context, callback) => { setTimeout(() => { callback(null, { statusCode: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ method: event.requestContext && event.requestContext.http && event.requestContext.http.method, path: event.rawPath, request_id: context.awsRequestId, trace: (event.headers || {})["x-trace-id"] || "" }) }); }, 1); };\n`);
      writeFile(path.join(functionsRoot, "aws-adapter", "fn.config.json"), JSON.stringify({ invoke: { adapter: "aws-lambda" } }));
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "aws-adapter", event: { id: "req-aws-1", method: "POST", path: "/aws-adapter", raw_path: "/aws-adapter?x=1", query: { x: "1" }, headers: { host: "127.0.0.1:8080", "x-trace-id": "trace-123" }, body: "{}", client: { ip: "127.0.0.1", ua: "node-test" } } });
      assert.equal(resp.status, 200);
      const body = JSON.parse(resp.body);
      assert.equal(body.method, "POST");
      assert.equal(body.path, "/aws-adapter");
      assert.equal(body.request_id, "req-aws-1");
      assert.equal(body.trace, "trace-123");
    });
  });

  test("AWS Lambda callback error", async () => {
    await withFunctionsRoot(async (functionsRoot) => {
      writeFile(path.join(functionsRoot, "aws-err", "handler.js"), `exports.handler = (_e, _c, cb) => { cb(new Error("lambda callback exploded")); };\n`);
      writeFile(path.join(functionsRoot, "aws-err", "fn.config.json"), JSON.stringify({ invoke: { adapter: "aws-lambda" } }));
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      let failed = false;
      try { await daemon.handleRequest({ fn: "aws-err", event: { method: "GET", path: "/" } }); } catch (err) { failed = true; assert.ok(String(err.message).includes("lambda callback exploded")); }
      assert.equal(failed, true);
    });
  });

  test("Cloudflare Worker adapter", async () => {
    if (typeof Request !== "function" || typeof Response !== "function") return;
    await withFunctionsRoot(async (functionsRoot) => {
      writeFile(path.join(functionsRoot, "cf-adapter", "handler.js"),
        `module.exports = { fetch: async (request, env, ctx) => { ctx.waitUntil(Promise.resolve("ok")); return new Response("Hello " + String(env.WHO || "World") + " " + request.method, { status: 201, headers: { "Content-Type": "text/plain; charset=utf-8", "x-worker-url": request.url } }); } };\n`);
      writeFile(path.join(functionsRoot, "cf-adapter", "fn.config.json"), JSON.stringify({ invoke: { adapter: "cloudflare-worker" } }));
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "cf-adapter", event: { method: "GET", raw_path: "/cf-adapter?y=9", headers: { host: "unit.local:8080" }, env: { WHO: "Adapter" } } });
      assert.equal(resp.status, 201);
      assert.equal(resp.body, "Hello Adapter GET");
      assert.ok(String(resp.headers["x-worker-url"] || "").includes("http://unit.local:8080/cf-adapter?y=9"));
    });
  });

  test("Cloudflare fixture example", async () => {
    if (typeof Request !== "function" || typeof Response !== "function") return;
    const compatRoot = path.join(ROOT, "tests", "fixtures", "compat");
    await withProvidedFunctionsRoot(compatRoot, async () => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const healthResp = await daemon.handleRequest({ fn: "cloudflare-v1-router", event: { method: "GET", raw_path: "/api/v1/status", headers: { host: "unit.local:8080" } } });
      assert.equal(healthResp.status, 200);
      const healthBody = JSON.parse(healthResp.body);
      assert.equal(healthBody.success, true);
      assert.equal(healthBody.data && healthBody.data.status, "healthy");

      const invalidVersionResp = await daemon.handleRequest({ fn: "cloudflare-v1-router", event: { method: "GET", raw_path: "/api/v2/status", headers: { host: "unit.local:8080" } } });
      assert.equal(invalidVersionResp.status, 400);

      const postResp = await daemon.handleRequest({ fn: "cloudflare-v1-router", event: { method: "POST", raw_path: "/api/v1/messages", headers: { host: "unit.local:8080", "content-type": "application/json" }, body: JSON.stringify({ message: "hola" }) } });
      assert.equal(postResp.status, 201);
      const postBody = JSON.parse(postResp.body);
      assert.equal(postBody.success, true);
      assert.equal(postBody.data && postBody.data.message, "hola");

      const corsResp = await daemon.handleRequest({ fn: "cloudflare-v1-router", event: { method: "OPTIONS", raw_path: "/api/v1/messages", headers: { host: "unit.local:8080" } } });
      assert.equal(corsResp.status, 200);
      assert.ok(String(corsResp.headers["access-control-allow-origin"] || "").includes("*"));
    });
  });

  test("unknown adapter fails", async () => {
    await withFunctionsRoot(async (functionsRoot) => {
      writeFile(path.join(functionsRoot, "bad-adapter", "handler.js"), `exports.handler = async () => ({ status: 200, body: "ok" });\n`);
      writeFile(path.join(functionsRoot, "bad-adapter", "fn.config.json"), JSON.stringify({ invoke: { adapter: "unknown-adapter" } }));
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      let failed = false;
      try { await daemon.handleRequest({ fn: "bad-adapter", event: { method: "GET", path: "/" } }); } catch (err) { failed = true; assert.ok(String(err.message).includes("invoke.adapter unsupported")); }
      assert.equal(failed, true);
    });
  });

  test("native env visible in process.env", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "native-env", "handler.js"), `exports.handler = async (event) => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ event_env: (event.env || {}).m || null, process_env: process.env.m || null }) });\n`);
      writeFile(path.join(root, "native-env", "fn.env.json"), JSON.stringify({ m: "test" }));
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "native-env", event: { method: "GET", raw_path: "/native-env" } });
      const body = JSON.parse(resp.body);
      assert.equal(body.event_env, "test");
      assert.equal(body.process_env, "test");
    });
  });

  test("console log captured", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "node", "log-test", "handler.js"), `module.exports.handler = async (event) => { console.log("hello stdout"); console.info("info line"); console.debug("debug line"); console.error("error line"); console.warn("warn line"); return { status: 200, headers: {}, body: "ok" }; };`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "log-test", event: { method: "GET", raw_path: "/log-test" } });
      assert.equal(resp.status, 200);
      assert.ok(resp.stdout.includes("hello stdout"));
      assert.ok(resp.stdout.includes("info line"));
      assert.ok(resp.stderr.includes("error line"));
      assert.ok(resp.stderr.includes("warn line"));
    });
  });

  test("no console output omits fields", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "node", "silent-test", "handler.js"), `module.exports.handler = async (event) => { return { status: 200, headers: {}, body: "silent" }; };`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "silent-test", event: { method: "GET", raw_path: "/silent-test" } });
      assert.equal(resp.body, "silent");
      assert.equal(resp.stdout, undefined);
      assert.equal(resp.stderr, undefined);
    });
  });

  test("event session passthrough", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "node", "session-test", "handler.js"), `module.exports.handler = async (event) => { const session = event.session || {}; return { status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sid: session.id || null, cookies: session.cookies || {} }) }; };`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "session-test", event: { method: "GET", raw_path: "/session-test", session: { id: "abc123", raw: "session_id=abc123; theme=dark", cookies: { session_id: "abc123", theme: "dark" } } } });
      const body = JSON.parse(resp.body);
      assert.equal(body.sid, "abc123");
      assert.equal(body.cookies.theme, "dark");
    });
  });

  test("route params injected as second arg", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "node", "param-id-test", "handler.js"), `module.exports.handler = async (event, { id }) => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id: Number(id), source: "direct" }) });`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "param-id-test", event: { method: "GET", raw_path: "/products/42", params: { id: "42" } } });
      const body = JSON.parse(resp.body);
      assert.equal(body.id, 42);
      assert.equal(body.source, "direct");
    });
  });

  test("route params multiple keys", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "node", "param-multi-test", "handler.js"), `module.exports.handler = async (event, { category, slug }) => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ category, slug }) });`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "param-multi-test", event: { method: "GET", raw_path: "/posts/tech/hello", params: { category: "tech", slug: "hello" } } });
      const body = JSON.parse(resp.body);
      assert.equal(body.category, "tech");
      assert.equal(body.slug, "hello");
    });
  });

  test("route params not passed to single arg handler", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "node", "param-single-test", "handler.js"), `module.exports.handler = async (event) => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ method: event.method, has_params: !!event.params }) });`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "param-single-test", event: { method: "GET", raw_path: "/products/42", params: { id: "42" } } });
      const body = JSON.parse(resp.body);
      assert.equal(body.method, "GET");
      assert.equal(body.has_params, true);
    });
  });

  test("route params wildcard path", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "node", "param-wildcard-test", "handler.js"),
        `module.exports.handler = async (event, { path: filePath }) => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ path: filePath, segments: filePath.split("/"), depth: filePath.split("/").length }) });`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const resp = await daemon.handleRequest({ fn: "param-wildcard-test", event: { method: "GET", raw_path: "/files/docs/2024/report.pdf", params: { path: "docs/2024/report.pdf" } } });
      const body = JSON.parse(resp.body);
      assert.equal(body.path, "docs/2024/report.pdf");
      assert.deepEqual(body.segments, ["docs", "2024", "report.pdf"]);
      assert.equal(body.depth, 3);
    });
  });

  test("auto-infer generates manifest and state", async () => {
    const childProcess = require("node:child_process");
    const originalSpawnSync = childProcess.spawnSync;
    let npmCalls = 0;
    childProcess.spawnSync = (cmd, args, opts) => {
      if (cmd === "npm") {
        npmCalls += 1;
        const cwd = opts && opts.cwd ? String(opts.cwd) : "";
        if (cwd) { const nm = path.join(cwd, "node_modules"); fs.mkdirSync(nm, { recursive: true }); fs.writeFileSync(path.join(nm, ".keep"), "ok\n", "utf8"); }
        return { status: 0, stdout: "", stderr: "", error: null };
      }
      return originalSpawnSync(cmd, args, opts);
    };
    try {
      await withFunctionsRoot(async (root) => {
        writeFile(path.join(root, "infer-node", "handler.js"), `module.exports.handler = async () => { if (false) { require("uuid"); } return { status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ok: true }) }; };\n`);
        const daemon = jestRequireFresh(NODE_DAEMON_PATH);
        const first = await daemon.handleRequest({ fn: "infer-node", event: { method: "GET", raw_path: "/infer-node" } });
        assert.equal(first.status, 200);
        const second = await daemon.handleRequest({ fn: "infer-node", event: { method: "GET", raw_path: "/infer-node" } });
        assert.equal(second.status, 200);
        assert.equal(npmCalls, 1);
        const pkg = JSON.parse(fs.readFileSync(path.join(root, "infer-node", "package.json"), "utf8"));
        assert.equal(pkg.dependencies.uuid, "*");
        const depState = JSON.parse(fs.readFileSync(path.join(root, "infer-node", ".fastfn-deps-state.json"), "utf8"));
        assert.equal(depState.runtime, "node");
        assert.equal(depState.mode, "inferred");
        assert.equal(depState.manifest_generated, true);
        assert.equal(depState.last_install_status, "ok");
        assert.ok(depState.resolved_packages.includes("uuid"));
      }, { autoNodeDeps: true, autoInferNodeDeps: true, autoInferWriteManifest: true, autoInferStrict: true });
    } finally {
      childProcess.spawnSync = originalSpawnSync;
    }
  });

  test("auto-infer updates existing manifest", async () => {
    const childProcess = require("node:child_process");
    const originalSpawnSync = childProcess.spawnSync;
    childProcess.spawnSync = (cmd, args, opts) => {
      if (cmd === "npm") {
        const cwd = opts && opts.cwd ? String(opts.cwd) : "";
        if (cwd) { const nm = path.join(cwd, "node_modules"); fs.mkdirSync(nm, { recursive: true }); fs.writeFileSync(path.join(nm, ".keep"), "ok\n", "utf8"); }
        return { status: 0, stdout: "", stderr: "", error: null };
      }
      return originalSpawnSync(cmd, args, opts);
    };
    try {
      await withFunctionsRoot(async (root) => {
        writeFile(path.join(root, "infer-node-existing", "handler.js"), `module.exports.handler = async () => { if (false) { require("dayjs"); } return { status: 200, headers: {}, body: "ok" }; };\n`);
        writeFile(path.join(root, "infer-node-existing", "package.json"), JSON.stringify({ name: "existing-manifest", private: true, dependencies: { "left-pad": "1.3.0" } }, null, 2) + "\n");
        const daemon = jestRequireFresh(NODE_DAEMON_PATH);
        const resp = await daemon.handleRequest({ fn: "infer-node-existing", event: { method: "GET", raw_path: "/infer-node-existing" } });
        assert.equal(resp.status, 200);
        const pkg = JSON.parse(fs.readFileSync(path.join(root, "infer-node-existing", "package.json"), "utf8"));
        assert.equal(pkg.dependencies["left-pad"], "1.3.0");
        assert.equal(pkg.dependencies.dayjs, "*");
        const depState = JSON.parse(fs.readFileSync(path.join(root, "infer-node-existing", ".fastfn-deps-state.json"), "utf8"));
        assert.equal(depState.manifest_generated, false);
        assert.equal(depState.mode, "inferred");
        assert.ok(depState.resolved_packages.includes("dayjs"));
      }, { autoNodeDeps: true, autoInferNodeDeps: true, autoInferWriteManifest: true, autoInferStrict: true });
    } finally {
      childProcess.spawnSync = originalSpawnSync;
    }
  });

  test("auto-infer strict unresolved fails", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "infer-fail", "handler.js"), `import broken from "@bad/";\nexport function handler() { return { status: 200, body: "ok" }; }\n`);
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      let failed = false;
      try { await daemon.handleRequest({ fn: "infer-fail", event: { method: "GET", raw_path: "/" } }); } catch (err) { failed = true; assert.ok(String(err.message).includes("unresolved imports")); }
      assert.equal(failed, true);
      const depState = JSON.parse(fs.readFileSync(path.join(root, "infer-fail", ".fastfn-deps-state.json"), "utf8"));
      assert.equal(depState.last_install_status, "error");
      assert.ok(String(depState.last_error || "").includes("@bad/"));
    }, { autoNodeDeps: true, autoInferNodeDeps: true, autoInferWriteManifest: true, autoInferStrict: true });
  });
});

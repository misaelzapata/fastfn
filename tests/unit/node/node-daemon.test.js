const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { ROOT, jestRequireFresh, writeFile, withFunctionsRoot } = require("./helpers");

const NODE_DAEMON_PATH = path.join(ROOT, "srv", "fn", "runtimes", "node-daemon.js");

async function withMockedNodeDaemon(mocks, run) {
  jest.resetModules();
  for (const [moduleName, mockFactory] of Object.entries(mocks || {})) {
    const factory = typeof mockFactory === "function" ? mockFactory : () => mockFactory;
    jest.doMock(moduleName, factory, { virtual: moduleName !== "child_process" });
  }
  try {
    const daemon = require(NODE_DAEMON_PATH);
    return await run(daemon);
  } finally {
    for (const moduleName of Object.keys(mocks || {})) {
      jest.dontMock(moduleName);
      if (typeof jest.unmock === "function") {
        jest.unmock(moduleName);
      }
    }
    jest.resetModules();
  }
}

describe("node-daemon", () => {
  test("handleRequest validation", async () => {
    await withFunctionsRoot(async () => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      let err;
      try { await daemon.handleRequest(null); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("request must be an object"));
      try { await daemon.handleRequest([]); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("request must be an object"));
      try { await daemon.handleRequest({}); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("fn is required"));
      try { await daemon.handleRequest({ fn: "" }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("fn is required"));
      try { await daemon.handleRequest({ fn: 123 }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("fn is required"));
      try { await daemon.handleRequest({ fn: "test", event: [] }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("event must be an object"));
    });
  });

  test("unknown function", async () => {
    await withFunctionsRoot(async () => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      let err;
      try { await daemon.handleRequest({ fn: "nonexistent-xyz", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err);
      assert.equal(err.code, "ENOENT");
    });
  });

  test("invalid function names", async () => {
    await withFunctionsRoot(async () => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      for (const name of ["../etc/passwd", "/absolute", "foo/../bar", "foo/bar/.."]) {
        let err;
        try { await daemon.handleRequest({ fn: name, event: { method: "GET" } }); } catch (e) { err = e; }
        assert.ok(err, `expected error for fn name: ${JSON.stringify(name)}`);
      }
    });
  });

  test("collectHandlerPaths skips configured assets directory", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "fn.config.json"), JSON.stringify({
        assets: { directory: "public" },
      }));
      writeFile(path.join(root, "hello", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "public", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "asset" });\n');

      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const paths = daemon.__test__.collectHandlerPaths();

      assert.equal(paths.length, 1);
      assert.ok(paths[0].endsWith(path.join("hello", "handler.js")));
      assert.ok(!paths.some((p) => p.includes(path.join("public", "handler.js"))));
    });
  });

  test("collectHandlerPaths keeps handlers when no assets directory is configured", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "hello", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "public", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "asset" });\n');

      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const paths = daemon.__test__.collectHandlerPaths().map((p) => path.basename(path.dirname(p))).sort();

      assert.deepEqual(paths, ["hello", "public"]);
    });
  });

  test("magic responses", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      writeFile(path.join(root, "magic-null", "handler.js"), 'module.exports.handler = async () => null;\n');
      const r1 = await daemon.handleRequest({ fn: "magic-null", event: { method: "GET" } });
      assert.equal(r1.status, 200);
      assert.equal(r1.body, "");

      writeFile(path.join(root, "magic-undef", "handler.js"), 'module.exports.handler = async () => undefined;\n');
      const r2 = await daemon.handleRequest({ fn: "magic-undef", event: { method: "GET" } });
      assert.equal(r2.body, "");

      writeFile(path.join(root, "magic-str", "handler.js"), 'module.exports.handler = async () => "hello plain";\n');
      const r3 = await daemon.handleRequest({ fn: "magic-str", event: { method: "GET" } });
      assert.equal(r3.body, "hello plain");
      assert.ok(r3.headers["Content-Type"].includes("text/plain"));

      writeFile(path.join(root, "magic-empty", "handler.js"), 'module.exports.handler = async () => "";\n');
      const r4 = await daemon.handleRequest({ fn: "magic-empty", event: { method: "GET" } });
      assert.equal(r4.body, "");

      writeFile(path.join(root, "magic-html", "handler.js"), 'module.exports.handler = async () => "<!doctype html><html><body>hi</body></html>";\n');
      const r5 = await daemon.handleRequest({ fn: "magic-html", event: { method: "GET" } });
      assert.ok(r5.headers["Content-Type"].includes("text/html"));

      writeFile(path.join(root, "magic-num", "handler.js"), 'module.exports.handler = async () => 42;\n');
      const r6 = await daemon.handleRequest({ fn: "magic-num", event: { method: "GET" } });
      assert.equal(r6.body, "42");
      assert.ok(r6.headers["Content-Type"].includes("text/plain"));

      writeFile(path.join(root, "magic-obj", "handler.js"), 'module.exports.handler = async () => ({ foo: "bar" });\n');
      const r7 = await daemon.handleRequest({ fn: "magic-obj", event: { method: "GET" } });
      assert.ok(r7.headers["Content-Type"].includes("application/json"));
      assert.equal(JSON.parse(r7.body).foo, "bar");

      writeFile(path.join(root, "magic-buf", "handler.js"), 'module.exports.handler = async () => Buffer.from("binary data");\n');
      const r8 = await daemon.handleRequest({ fn: "magic-buf", event: { method: "GET" } });
      assert.equal(r8.is_base64, true);
      assert.equal(Buffer.from(r8.body_base64, "base64").toString(), "binary data");

      writeFile(path.join(root, "magic-u8", "handler.js"), 'module.exports.handler = async () => new Uint8Array([72, 105]);\n');
      const r9 = await daemon.handleRequest({ fn: "magic-u8", event: { method: "GET" } });
      assert.equal(r9.is_base64, true);
      assert.equal(Buffer.from(r9.body_base64, "base64").toString(), "Hi");

      for (const [html, desc] of [
        ["<html><body>test</body></html>", "html-tag"],
        ["<body>test</body>", "body-tag"],
        ["test</html>", "close-html"],
      ]) {
        writeFile(path.join(root, `html-${desc}`, "handler.js"), `module.exports.handler = async () => ${JSON.stringify(html)};\n`);
        const r = await daemon.handleRequest({ fn: `html-${desc}`, event: { method: "GET" } });
        assert.ok(r.headers["Content-Type"].includes("text/html"), `${desc} should detect HTML`);
      }
    });
  });

  test("contract responses", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      writeFile(path.join(root, "statuscode", "handler.js"), 'module.exports.handler = async () => ({ statusCode: 201, headers: {}, body: "created" });\n');
      assert.equal((await daemon.handleRequest({ fn: "statuscode", event: { method: "POST" } })).status, 201);

      writeFile(path.join(root, "bad-status", "handler.js"), 'module.exports.handler = async () => ({ status: 99, headers: {}, body: "" });\n');
      let err;
      try { await daemon.handleRequest({ fn: "bad-status", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("status must be a valid HTTP code"));

      writeFile(path.join(root, "b64-resp", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, is_base64: true, body_base64: Buffer.from("hello").toString("base64") });\n`);
      const r3 = await daemon.handleRequest({ fn: "b64-resp", event: { method: "GET" } });
      assert.equal(r3.is_base64, true);
      assert.equal(Buffer.from(r3.body_base64, "base64").toString(), "hello");

      writeFile(path.join(root, "b64-buf", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, is_base64: true, body_base64: Buffer.from("bufdata") });\n`);
      assert.equal(Buffer.from((await daemon.handleRequest({ fn: "b64-buf", event: { method: "GET" } })).body_base64, "base64").toString(), "bufdata");

      writeFile(path.join(root, "b64-empty", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, is_base64: true, body_base64: "" });\n`);
      err = null;
      try { await daemon.handleRequest({ fn: "b64-empty", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("body_base64 must be a non-empty string"));

      writeFile(path.join(root, "b64-aws", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, isBase64Encoded: true, body: Buffer.from("awsdata").toString("base64") });\n`);
      assert.equal((await daemon.handleRequest({ fn: "b64-aws", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "body-buf", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, body: Buffer.from("bufbody") });\n`);
      assert.equal((await daemon.handleRequest({ fn: "body-buf", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "body-null", "handler.js"), `module.exports.handler = async () => ({ status: 204, headers: {}, body: null });\n`);
      assert.equal((await daemon.handleRequest({ fn: "body-null", event: { method: "DELETE" } })).body, "");

      writeFile(path.join(root, "body-obj", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, body: { key: "val" } });\n`);
      assert.equal(JSON.parse((await daemon.handleRequest({ fn: "body-obj", event: { method: "GET" } })).body).key, "val");

      writeFile(path.join(root, "body-num", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, body: 42 });\n`);
      assert.equal((await daemon.handleRequest({ fn: "body-num", event: { method: "GET" } })).body, "42");

      writeFile(path.join(root, "proxy-resp", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "text/plain" }, body: "proxied", proxy: { target: "http://example.com" } });\n`);
      const r8 = await daemon.handleRequest({ fn: "proxy-resp", event: { method: "GET" } });
      assert.ok(r8.proxy);
      assert.equal(r8.proxy.target, "http://example.com");

      writeFile(path.join(root, "proxy-bad", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, body: "no proxy", proxy: "not-an-object" });\n`);
      assert.equal((await daemon.handleRequest({ fn: "proxy-bad", event: { method: "GET" } })).proxy, undefined);

      writeFile(path.join(root, "binary-ct", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "application/octet-stream" }, body: "binary" });\n`);
      assert.equal((await daemon.handleRequest({ fn: "binary-ct", event: { method: "GET" } })).is_base64, true);

      for (const [ct, label] of [["text/plain", "text"], ["application/json", "json"], ["application/xml", "xml"], ["application/javascript", "js"], ["application/x-www-form-urlencoded", "form"]]) {
        writeFile(path.join(root, `ct-${label}`, "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "${ct}" }, body: "content" });\n`);
        assert.equal((await daemon.handleRequest({ fn: `ct-${label}`, event: { method: "GET" } })).is_base64, undefined, `${ct} should not be binary`);
      }

      writeFile(path.join(root, "no-contract", "handler.js"), 'module.exports.handler = async () => ({ foo: "bar" });\n');
      const r11 = await daemon.handleRequest({ fn: "no-contract", event: { method: "GET" } });
      assert.ok(r11.headers["Content-Type"].includes("application/json"));
      assert.equal(JSON.parse(r11.body).foo, "bar");
    });
  });

  test("csv responses", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const csv = (name, bodyExpr) => {
        writeFile(path.join(root, name, "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "text/csv" }, body: ${bodyExpr} });\n`);
      };
      csv("csv-obj", '[{ name: "Alice", age: 30 }, { name: "Bob", age: 25 }]');
      assert.ok((await daemon.handleRequest({ fn: "csv-obj", event: { method: "GET" } })).body.includes("Alice,30"));
      csv("csv-arr", '[["a", "b"], ["1", "2"]]');
      assert.ok((await daemon.handleRequest({ fn: "csv-arr", event: { method: "GET" } })).body.includes("a,b"));
      csv("csv-empty", '[]');
      assert.equal((await daemon.handleRequest({ fn: "csv-empty", event: { method: "GET" } })).body, "");
      csv("csv-scalar", '["hello", "world"]');
      assert.ok((await daemon.handleRequest({ fn: "csv-scalar", event: { method: "GET" } })).body.includes("hello"));
      csv("csv-single", '{ a: 1, b: 2 }');
      assert.ok((await daemon.handleRequest({ fn: "csv-single", event: { method: "GET" } })).body.includes("a,b"));
      csv("csv-empty-obj", '{}');
      assert.equal((await daemon.handleRequest({ fn: "csv-empty-obj", event: { method: "GET" } })).body, "");
      csv("csv-esc", '[{ name: \'has,comma\', val: \'has"quote\' }, { name: \'has\\nnewline\', val: null }]');
      assert.ok((await daemon.handleRequest({ fn: "csv-esc", event: { method: "GET" } })).body.includes('"has,comma"'));
      csv("csv-prim", '42');
      assert.equal((await daemon.handleRequest({ fn: "csv-prim", event: { method: "GET" } })).body, "42");
      csv("csv-cell-obj", '[{ data: { nested: true } }]');
      assert.ok((await daemon.handleRequest({ fn: "csv-cell-obj", event: { method: "GET" } })).body.includes("nested"));
      csv("csv-cell-undef", '[{ a: undefined, b: "ok" }]');
      assert.ok((await daemon.handleRequest({ fn: "csv-cell-undef", event: { method: "GET" } })).body.includes("a,b"));
    });
  });

  test("handler and adapter config", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const fn = (name, code, cfg) => { writeFile(path.join(root, name, "handler.js"), code); if (cfg) writeFile(path.join(root, name, "fn.config.json"), typeof cfg === "string" ? cfg : JSON.stringify(cfg)); };

      fn("custom-handler", 'module.exports.myHandler = async () => ({ status: 200, body: "custom" });\n', { invoke: { handler: "myHandler" } });
      assert.equal((await daemon.handleRequest({ fn: "custom-handler", event: { method: "GET" } })).body, "custom");

      fn("bad-handler", 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n', { invoke: { handler: "123invalid" } });
      let err;
      try { await daemon.handleRequest({ fn: "bad-handler", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("invoke.handler must be a valid identifier"));

      fn("empty-handler", 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n', { invoke: { handler: "  " } });
      assert.equal((await daemon.handleRequest({ fn: "empty-handler", event: { method: "GET" } })).status, 200);

      fn("num-handler", 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n', { invoke: { handler: 42 } });
      assert.equal((await daemon.handleRequest({ fn: "num-handler", event: { method: "GET" } })).status, 200);

      for (const alias of ["native", "none", "default"]) {
        fn(`native-${alias}`, 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n', { invoke: { adapter: alias } });
        assert.equal((await daemon.handleRequest({ fn: `native-${alias}`, event: { method: "GET" } })).status, 200);
      }

      fn("default-exp", 'module.exports.default = { handler: async () => ({ status: 200, body: "from default" }) };\n');
      assert.equal((await daemon.handleRequest({ fn: "default-exp", event: { method: "GET" } })).body, "from default");

      fn("no-handler", 'module.exports.something = async () => ({ status: 200, body: "ok" });\n');
      err = null;
      try { await daemon.handleRequest({ fn: "no-handler", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("handler(event) is required"));

      fn("cfg-array", 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n', "[1,2,3]");
      assert.equal((await daemon.handleRequest({ fn: "cfg-array", event: { method: "GET" } })).status, 200);

      fn("cfg-bad", 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n', "{bad json}");
      assert.equal((await daemon.handleRequest({ fn: "cfg-bad", event: { method: "GET" } })).status, 200);
    });
  });

  test("handleRequest resolves explicit functions through fn_source_dir", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      writeFile(path.join(root, "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "root explicit" });\n');
      writeFile(path.join(root, "apps", "demo", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "nested explicit" });\n');
      writeFile(path.join(root, "apps", "demo", "v2", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "nested v2" });\n');

      assert.equal((await daemon.handleRequest({ fn: "public-root", fn_source_dir: ".", event: { method: "GET" } })).body, "root explicit");
      assert.equal((await daemon.handleRequest({ fn: "public-demo", fn_source_dir: "apps/demo", event: { method: "GET" } })).body, "nested explicit");
      assert.equal((await daemon.handleRequest({ fn: "public-demo", fn_source_dir: "apps/demo", version: "v2", event: { method: "GET" } })).body, "nested v2");

      await assert.rejects(
        () => daemon.handleRequest({ fn: "public-demo", fn_source_dir: "../escape", event: { method: "GET" } }),
        /invalid function source dir/
      );
      await assert.rejects(
        () => daemon.handleRequest({ fn: "public-demo", fn_source_dir: "missing/demo", event: { method: "GET" } }),
        /unknown function source dir/
      );
    });
  });

  test("lambda adapter", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const fn = (name, code) => { writeFile(path.join(root, name, "handler.js"), code); writeFile(path.join(root, name, "fn.config.json"), JSON.stringify({ invoke: { adapter: "aws-lambda" } })); };

      for (const alias of ["aws-lambda", "lambda", "apigw-v2", "api-gateway-v2"]) {
        const fnName = `lambda-${alias.replace(/[^a-z0-9]/g, "")}`;
        writeFile(path.join(root, fnName, "handler.js"), `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: JSON.stringify({ method: event.requestContext.http.method }) });\n`);
        writeFile(path.join(root, fnName, "fn.config.json"), JSON.stringify({ invoke: { adapter: alias } }));
        assert.equal((await daemon.handleRequest({ fn: fnName, event: { method: "GET", path: `/${fnName}` } })).status, 200);
      }

      fn("lambda-sync", `exports.handler = function(event, context, callback) { return { statusCode: 200, headers: {}, body: "sync" }; };\n`);
      assert.equal((await daemon.handleRequest({ fn: "lambda-sync", event: { method: "GET", path: "/test" } })).status, 200);

      fn("lambda-throw", `exports.handler = function() { throw new Error("sync boom"); };\n`);
      let err;
      try { await daemon.handleRequest({ fn: "lambda-throw", event: { method: "GET", path: "/test" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("sync boom"));

      fn("lambda-str-err", `exports.handler = (event, context, callback) => { callback("string error"); };\n`);
      err = null;
      try { await daemon.handleRequest({ fn: "lambda-str-err", event: { method: "GET", path: "/test" } }); } catch (e) { err = e; }
      assert.ok(err instanceof Error && err.message.includes("string error"));

      fn("lambda-double", `exports.handler = (event, context, callback) => { callback(null, { statusCode: 200, headers: {}, body: "first" }); callback(null, { statusCode: 200, headers: {}, body: "second" }); };\n`);
      assert.equal((await daemon.handleRequest({ fn: "lambda-double", event: { method: "GET", path: "/test" } })).body, "first");

      fn("lambda-promise", `exports.handler = function(event, context, callback) { return Promise.resolve({ statusCode: 200, headers: {}, body: "promise" }); };\n`);
      assert.equal((await daemon.handleRequest({ fn: "lambda-promise", event: { method: "GET", path: "/test" } })).body, "promise");

      fn("lambda-reject", `exports.handler = function(event, context, callback) { return Promise.reject(new Error("async fail")); };\n`);
      err = null;
      try { await daemon.handleRequest({ fn: "lambda-reject", event: { method: "GET", path: "/test" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("async fail"));

      fn("lambda-noret", `exports.handler = function(event, context) {};\n`);
      assert.equal((await daemon.handleRequest({ fn: "lambda-noret", event: { method: "GET", path: "/test" } })).body, "");

      fn("lambda-ctx", `exports.handler = async (event, context) => { context.done(); context.fail(); context.succeed(); return { statusCode: 200, headers: {}, body: JSON.stringify({ rid: context.awsRequestId, remaining: context.getRemainingTimeInMillis(), cb_wait: context.callbackWaitsForEmptyEventLoop }) }; };\n`);
      const r8 = await daemon.handleRequest({ fn: "lambda-ctx", event: { method: "POST", path: "/test", raw_path: "/test?a=1", query: { a: "1" }, headers: { cookie: "sid=abc", host: "localhost" }, body: '{"x":1}', is_base64: true, body_base64: "aGVsbG8=", client: { ip: "10.0.0.1", ua: "test-agent" }, context: { request_id: "req-42", timeout_ms: 5000 } } });
      const b8 = JSON.parse(r8.body);
      assert.equal(b8.rid, "req-42");
      assert.equal(b8.remaining, 5000);

      fn("lambda-path", `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: event.rawPath });\n`);
      assert.equal((await daemon.handleRequest({ fn: "lambda-path", event: { method: "GET" } })).body, "/");
      assert.equal((await daemon.handleRequest({ fn: "lambda-path", event: { method: "GET", path: "noslash" } })).body, "/noslash");
      assert.equal((await daemon.handleRequest({ fn: "lambda-path", event: { method: "GET", raw_path: "https://example.com/api" } })).body, "https://example.com/api");
      assert.equal((await daemon.handleRequest({ fn: "lambda-path", event: { method: "GET", raw_path: "", path: "/fallback" } })).body, "/fallback");

      fn("lambda-qs", `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: event.rawQueryString });\n`);
      assert.ok((await daemon.handleRequest({ fn: "lambda-qs", event: { method: "GET", query: { tags: ["a", "b", null], empty: null, val: "x" } } })).body.includes("tags=a"));
      assert.equal((await daemon.handleRequest({ fn: "lambda-qs", event: { method: "GET", raw_path: "/test?inline=1" } })).body, "inline=1");
      assert.equal((await daemon.handleRequest({ fn: "lambda-qs", event: { method: "GET", raw_path: "/test?" } })).body, "");
      assert.equal((await daemon.handleRequest({ fn: "lambda-qs", event: { method: "GET" } })).body, "");

      fn("lambda-numbody", `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: String(typeof event.body) });\n`);
      assert.equal((await daemon.handleRequest({ fn: "lambda-numbody", event: { method: "POST", path: "/test", body: 42 } })).body, "string");
    });
  });

  test("cloudflare adapter", async () => {
    if (typeof Request !== "function" || typeof Response !== "function") return;
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      const cf = (name, code) => { writeFile(path.join(root, name, "handler.js"), code); writeFile(path.join(root, name, "fn.config.json"), JSON.stringify({ invoke: { adapter: "cloudflare-worker" } })); };

      for (const alias of ["cloudflare-worker", "cloudflare-workers", "worker", "workers"]) {
        const fnName = `cf-${alias.replace(/[^a-z0-9]/g, "")}`;
        writeFile(path.join(root, fnName, "handler.js"), 'module.exports = { fetch: async (req) => new Response("ok " + req.method, { status: 200 }) };\n');
        writeFile(path.join(root, fnName, "fn.config.json"), JSON.stringify({ invoke: { adapter: alias } }));
        assert.equal((await daemon.handleRequest({ fn: fnName, event: { method: "GET", raw_path: `/${fnName}`, headers: { host: "test" } } })).status, 200);
      }

      cf("cf-default", 'module.exports.default = { fetch: async (req) => new Response("default " + req.method) };\n');
      assert.ok((await daemon.handleRequest({ fn: "cf-default", event: { method: "POST", raw_path: "/test", headers: { host: "t" } } })).body.includes("default POST"));

      cf("cf-nofetch", 'module.exports = { notFetch: true };\n');
      let err;
      try { await daemon.handleRequest({ fn: "cf-nofetch", event: { method: "GET", raw_path: "/test", headers: { host: "t" } } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("cloudflare-worker adapter requires fetch"));

      cf("cf-named", 'module.exports.handler = async (req, env, ctx) => new Response("named handler");\n');
      assert.ok((await daemon.handleRequest({ fn: "cf-named", event: { method: "GET", raw_path: "/test", headers: { host: "t" } } })).body.includes("named handler"));

      cf("cf-post", `module.exports = { fetch: async (req) => { const text = await req.text(); return new Response("got: " + text); } };\n`);
      assert.ok((await daemon.handleRequest({ fn: "cf-post", event: { method: "POST", raw_path: "/", headers: { host: "t" }, body: "hello body" } })).body.includes("got: hello body"));

      cf("cf-b64", `module.exports = { fetch: async (req) => { const buf = await req.arrayBuffer(); return new Response("len: " + buf.byteLength); } };\n`);
      assert.ok((await daemon.handleRequest({ fn: "cf-b64", event: { method: "POST", raw_path: "/", headers: { host: "t" }, is_base64: true, body_base64: Buffer.from("binary").toString("base64") } })).body.includes("len: 6"));

      cf("cf-wait", `module.exports = { fetch: async (req, env, ctx) => { ctx.waitUntil(Promise.reject(new Error("bg fail"))); ctx.waitUntil("not a promise"); ctx.passThroughOnException(); return new Response("ok"); } };\n`);
      assert.equal((await daemon.handleRequest({ fn: "cf-wait", event: { method: "GET", raw_path: "/", headers: { host: "t" } } })).status, 200);

      cf("cf-url", 'module.exports = { fetch: async (req) => new Response(req.url) };\n');
      assert.ok((await daemon.handleRequest({ fn: "cf-url", event: { method: "GET", raw_path: "https://example.com/api", headers: { host: "t" } } })).body.includes("https://example.com/api"));
      assert.ok((await daemon.handleRequest({ fn: "cf-url", event: { method: "GET", raw_path: "/test", headers: { host: "myhost", "x-forwarded-proto": "https" } } })).body.includes("https://myhost/test"));

      cf("cf-binary", `module.exports = { fetch: async () => new Response(new Uint8Array([1,2,3]), { status: 200, headers: { "Content-Type": "application/octet-stream" } }) };\n`);
      assert.equal((await daemon.handleRequest({ fn: "cf-binary", event: { method: "GET", raw_path: "/", headers: { host: "t" } } })).is_base64, true);

      cf("cf-empty-body", 'module.exports = { fetch: async () => new Response("", { status: 200 }) };\n');
      assert.equal((await daemon.handleRequest({ fn: "cf-empty-body", event: { method: "GET", raw_path: "/", headers: { host: "t" } } })).body, "");

      cf("cf-headers", `module.exports = { fetch: async (req) => { const hdrs = {}; req.headers.forEach((v, k) => { hdrs[k] = v; }); return new Response(JSON.stringify(hdrs)); } };\n`);
      const b11 = JSON.parse((await daemon.handleRequest({ fn: "cf-headers", event: { method: "GET", raw_path: "/test", headers: { host: "myhost", "content-length": "100", connection: "keep-alive", "x-custom": "allowed" } } })).body);
      assert.equal(b11.host, undefined);
      assert.equal(b11["x-custom"], "allowed");

      cf("cf-get-nobody", 'module.exports = { fetch: async (req) => new Response(req.method) };\n');
      assert.equal((await daemon.handleRequest({ fn: "cf-get-nobody", event: { method: "GET", raw_path: "/", headers: { host: "t" }, body: "ignored" } })).body, "GET");
      assert.equal((await daemon.handleRequest({ fn: "cf-get-nobody", event: { method: "HEAD", raw_path: "/", headers: { host: "t" } } })).body, "HEAD");

      cf("cf-num-body", `module.exports = { fetch: async (req) => { const text = await req.text(); return new Response("body: " + text); } };\n`);
      assert.ok((await daemon.handleRequest({ fn: "cf-num-body", event: { method: "POST", raw_path: "/", headers: { host: "t" }, body: 42 } })).body.includes("body: 42"));

      cf("cf-no-env", 'module.exports = { fetch: async (req, env) => new Response(JSON.stringify(env)) };\n');
      assert.equal((await daemon.handleRequest({ fn: "cf-no-env", event: { method: "GET", raw_path: "/", headers: { host: "t" } } })).body, "{}");
    });
  });

  test("entrypoint discovery", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      writeFile(path.join(root, "handler-file", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "from handler.js" });\n');
      assert.equal((await daemon.handleRequest({ fn: "handler-file", event: { method: "GET" } })).body, "from handler.js");

      writeFile(path.join(root, "index-file", "index.js"), 'module.exports.handler = async () => ({ status: 200, body: "from index.js" });\n');
      assert.equal((await daemon.handleRequest({ fn: "index-file", event: { method: "GET" } })).body, "from index.js");

      writeFile(path.join(root, "custom-entry", "fn.config.json"), JSON.stringify({ entrypoint: "src/main.js" }));
      writeFile(path.join(root, "custom-entry", "src", "main.js"), 'module.exports.handler = async () => ({ status: 200, body: "custom entry" });\n');
      assert.equal((await daemon.handleRequest({ fn: "custom-entry", event: { method: "GET" } })).body, "custom entry");

      writeFile(path.join(root, "escape-entry", "fn.config.json"), JSON.stringify({ entrypoint: "../../etc/passwd" }));
      writeFile(path.join(root, "escape-entry", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "fallback" });\n');
      assert.equal((await daemon.handleRequest({ fn: "escape-entry", event: { method: "GET" } })).body, "fallback");

      writeFile(path.join(root, "symlink-entry", "fn.config.json"), JSON.stringify({ entrypoint: "linked.js" }));
      writeFile(path.join(root, "symlink-entry", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "symlink fallback" });\n');
      const outsidePath = path.join(root, "..", "outside-entry.js");
      fs.writeFileSync(outsidePath, 'module.exports.handler = async () => ({ status: 200, body: "outside" });\n');
      fs.symlinkSync(outsidePath, path.join(root, "symlink-entry", "linked.js"));
      assert.equal((await daemon.handleRequest({ fn: "symlink-entry", event: { method: "GET" } })).body, "symlink fallback");

      const outsideFnDir = path.join(root, "..", "outside-linked-fn");
      writeFile(path.join(outsideFnDir, "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "outside dir" });\n');
      fs.symlinkSync(outsideFnDir, path.join(root, "linked-out-fn"), "dir");
      await assert.rejects(
        daemon.handleRequest({ fn: "linked-out-fn", event: { method: "GET" } }),
        (err) => err && err.code === "ENOENT",
      );

      writeFile(path.join(root, "handlers", "list.js"), 'module.exports.handler = async () => ({ status: 200, body: "direct" });\n');
      assert.equal((await daemon.handleRequest({ fn: "handlers/list.js", event: { method: "GET" } })).body, "direct");

      writeFile(path.join(root, "versioned", "v2", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "v2" });\n');
      assert.equal((await daemon.handleRequest({ fn: "versioned", version: "v2", event: { method: "GET" } })).body, "v2");

      writeFile(path.join(root, "node", "scoped-fn", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "scoped" });\n');
      assert.equal((await daemon.handleRequest({ fn: "scoped-fn", event: { method: "GET" } })).body, "scoped");
    });
  });

  test("hot reload", async () => {
    await withFunctionsRoot(async (root) => {
      const filePath = path.join(root, "hot-fn", "handler.js");
      // Write v1 with a specific old mtime
      writeFile(filePath, 'module.exports.handler = async () => ({ status: 200, body: "v1" });\n');
      const oldTime = new Date(Date.now() - 60000);
      fs.utimesSync(filePath, oldTime, oldTime);

      // Use child_process.execFileSync to run the test in a fresh Node
      // process, since Jest intercepts require() which prevents the
      // daemon's hot-reload mechanism from working.
      const { execFileSync } = require("node:child_process");
      const script = `
        const daemon = require(${JSON.stringify(NODE_DAEMON_PATH)});
        const fs = require("fs");
        (async () => {
          const r1 = await daemon.handleRequest({ fn: "hot-fn", event: { method: "GET" } });
          if (r1.body !== "v1") { process.exit(1); }
          fs.writeFileSync(${JSON.stringify(filePath)},
            'module.exports.handler = async () => ({ status: 200, body: "v2" });\\n');
          const t = new Date(Date.now() + 60000);
          fs.utimesSync(${JSON.stringify(filePath)}, t, t);
          const r2 = await daemon.handleRequest({ fn: "hot-fn", event: { method: "GET" } });
          if (r2.body !== "v2") {
            console.error("expected v2, got", r2.body);
            process.exit(1);
          }
        })();
      `;
      const env = { ...process.env, FN_FUNCTIONS_ROOT: root, FN_HOT_RELOAD: "1", FN_AUTO_NODE_DEPS: "0", FN_AUTO_INFER_NODE_DEPS: "0", FN_AUTO_INFER_WRITE_MANIFEST: "0", FN_AUTO_INFER_STRICT: "0", FN_STRICT_FS: "0", FN_NODE_RUNTIME_PROCESS_POOL: "0", FN_PREINSTALL_NODE_DEPS_ON_START: "0" };
      execFileSync(process.execPath, ["-e", script], { env, timeout: 10000 });
    });
  });

  test("env features", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      writeFile(path.join(root, "env-obj", "handler.js"), `module.exports.handler = async (event) => ({ status: 200, headers: { "Content-Type": "application/json" }, body: JSON.stringify({ a: (event.env || {}).A || "missing", b: (event.env || {}).B || "missing" }) });\n`);
      writeFile(path.join(root, "env-obj", "fn.env.json"), JSON.stringify({ A: { value: "wrapped" }, B: { value: null }, C: null }));
      const b1 = JSON.parse((await daemon.handleRequest({ fn: "env-obj", event: { method: "GET" } })).body);
      assert.equal(b1.a, "wrapped");
      assert.equal(b1.b, "missing");

      writeFile(path.join(root, "env-arr", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "env-arr", "fn.env.json"), "[1,2]");
      assert.equal((await daemon.handleRequest({ fn: "env-arr", event: { method: "GET" } })).status, 200);

      writeFile(path.join(root, "env-bad", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "env-bad", "fn.env.json"), "{bad}");
      assert.equal((await daemon.handleRequest({ fn: "env-bad", event: { method: "GET" } })).status, 200);

      const originalVal = process.env.FN_ADMIN_TEST_KEY;
      process.env.FN_ADMIN_TEST_KEY = "secret";
      const originalDb = process.env.DATABASE_URL;
      process.env.DATABASE_URL = "postgres://secret";
      writeFile(path.join(root, "env-block", "handler.js"), `module.exports.handler = async () => ({ status: 200, body: JSON.stringify({ admin: process.env.FN_ADMIN_TEST_KEY || "blocked", has: "FN_ADMIN_TEST_KEY" in process.env }) });\n`);
      const b4 = JSON.parse((await daemon.handleRequest({ fn: "env-block", event: { method: "GET" } })).body);
      assert.equal(b4.admin, "blocked");
      assert.equal(b4.has, false);
      if (originalVal === undefined) delete process.env.FN_ADMIN_TEST_KEY;
      else process.env.FN_ADMIN_TEST_KEY = originalVal;
      writeFile(path.join(root, "env-host-block", "handler.js"), `module.exports.handler = async () => ({ status: 200, body: JSON.stringify({ database: process.env.DATABASE_URL || "blocked", has: "DATABASE_URL" in process.env }) });\n`);
      const hostBlocked = JSON.parse((await daemon.handleRequest({ fn: "env-host-block", event: { method: "GET" } })).body);
      assert.equal(hostBlocked.database, "blocked");
      assert.equal(hostBlocked.has, false);
      if (originalDb === undefined) delete process.env.DATABASE_URL;
      else process.env.DATABASE_URL = originalDb;

      writeFile(path.join(root, "env-iso", "handler.js"), `module.exports.handler = async () => ({ status: 200, body: JSON.stringify({ custom: process.env.MY_CUSTOM_VAR_TEST || "not set" }) });\n`);
      writeFile(path.join(root, "env-iso", "fn.env.json"), JSON.stringify({ MY_CUSTOM_VAR_TEST: "isolated" }));
      assert.equal(JSON.parse((await daemon.handleRequest({ fn: "env-iso", event: { method: "GET" } })).body).custom, "isolated");
      assert.equal(process.env.MY_CUSTOM_VAR_TEST, undefined);

      writeFile(path.join(root, "env-proxy", "handler.js"), `module.exports.handler = async () => { const keys = Object.keys(process.env); const desc = Object.getOwnPropertyDescriptor(process.env, "MY_PROXY_VAR"); return { status: 200, body: JSON.stringify({ hasKey: keys.includes("MY_PROXY_VAR"), descVal: desc ? desc.value : null }) }; };\n`);
      writeFile(path.join(root, "env-proxy", "fn.env.json"), JSON.stringify({ MY_PROXY_VAR: "present" }));
      const b6 = JSON.parse((await daemon.handleRequest({ fn: "env-proxy", event: { method: "GET" } })).body);
      assert.equal(b6.hasKey, true);
      assert.equal(b6.descVal, "present");
    });
  });

  test("misc features", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      writeFile(path.join(root, "throws-fn", "handler.js"), 'module.exports.handler = async () => { throw new Error("boom"); };\n');
      let err;
      try { await daemon.handleRequest({ fn: "throws-fn", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("boom"));

      if (typeof Response === "function") {
        writeFile(path.join(root, "fetch-resp", "handler.js"), `module.exports.handler = async () => new Response("fetch body", { status: 201, headers: { "X-Custom": "yes" } });\n`);
        const r2 = await daemon.handleRequest({ fn: "fetch-resp", event: { method: "GET" } });
        assert.equal(r2.status, 201);
        assert.equal(r2.body, "fetch body");
      }

      writeFile(path.join(root, "pool-fn", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "pool off" });\n');
      assert.equal((await daemon.handleRequestWithProcessPool({ fn: "pool-fn", event: { method: "GET" } })).body, "pool off");
      assert.equal((await daemon.handleRequestWithProcessPool({ fn: "pool-fn", event: { method: "GET", context: { timeout_ms: 3000, worker_pool: { enabled: false, max_workers: 4, min_warm: 2, idle_ttl_seconds: 60 } } } })).status, 200);
      assert.equal((await daemon.handleRequestWithProcessPool({ fn: "pool-fn", event: { method: "GET", context: { worker_pool: { enabled: true, max_workers: 0 } } } })).status, 200);

      writeFile(path.join(root, "strict-off", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "strict-off", "fn.config.json"), JSON.stringify({ strict_fs: false }));
      assert.equal((await daemon.handleRequest({ fn: "strict-off", event: { method: "GET" } })).status, 200);

      writeFile(path.join(root, "shared-deps", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "shared-deps", "fn.config.json"), JSON.stringify({ shared_deps: ["valid-pack", 42, "", "  ", "valid-pack"] }));
      err = null;
      try { await daemon.handleRequest({ fn: "shared-deps", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("shared pack not found"));
      assert.ok(err && err.message.includes(path.join(root, ".fastfn", "packs", "node", "valid-pack")));

      writeFile(path.join(root, "log-test", "handler.js"), `module.exports.handler = async () => { console.log("hello stdout"); console.info("info line"); console.debug("debug line"); console.error("error line"); console.warn("warn line"); return { status: 200, headers: {}, body: "ok" }; };\n`);
      const r6 = await daemon.handleRequest({ fn: "log-test", event: { method: "GET" } });
      assert.ok(r6.stdout.includes("hello stdout"));
      assert.ok(r6.stderr.includes("error line"));

      writeFile(path.join(root, "silent-test", "handler.js"), 'module.exports.handler = async () => ({ status: 200, headers: {}, body: "silent" });\n');
      const r7 = await daemon.handleRequest({ fn: "silent-test", event: { method: "GET" } });
      assert.equal(r7.stdout, undefined);
      assert.equal(r7.stderr, undefined);

      writeFile(path.join(root, "param-test", "handler.js"), `module.exports.handler = async (event, { id }) => ({ status: 200, body: JSON.stringify({ id: Number(id) }) });\n`);
      assert.equal(JSON.parse((await daemon.handleRequest({ fn: "param-test", event: { method: "GET", raw_path: "/42", params: { id: "42" } } })).body).id, 42);

      writeFile(path.join(root, "param-single", "handler.js"), `module.exports.handler = async (event) => ({ status: 200, body: JSON.stringify({ has_params: !!event.params }) });\n`);
      assert.equal(JSON.parse((await daemon.handleRequest({ fn: "param-single", event: { method: "GET", params: { id: "42" } } })).body).has_params, true);

      writeFile(path.join(root, "session-test", "handler.js"), `module.exports.handler = async (event) => ({ status: 200, body: JSON.stringify({ sid: (event.session || {}).id || null }) });\n`);
      assert.equal(JSON.parse((await daemon.handleRequest({ fn: "session-test", event: { method: "GET", session: { id: "abc123" } } })).body).sid, "abc123");
    });
  });

  test("sanitizeWorkerEnv keeps only allowlisted ambient vars", async () => {
    const daemon = jestRequireFresh(NODE_DAEMON_PATH);
    assert.equal(daemon.__test__.isWorkerEnvKeyAllowed(""), false);
    assert.equal(daemon.__test__.isWorkerEnvKeyAllowed(42), false);
    assert.equal(daemon.__test__.isWorkerEnvKeyAllowed("PATH"), true);
    assert.equal(daemon.__test__.isWorkerEnvKeyAllowed("LC_ALL"), true);
    const env = daemon.__test__.sanitizeWorkerEnv({
      "": "skip-empty",
      PATH: "/usr/bin",
      LANG: "en_US.UTF-8",
      DATABASE_URL: "postgres://secret",
      FN_FUNCTIONS_ROOT: "/srv/functions",
      FN_STRICT_FS: "1",
      FN_ADMIN_TOKEN: "secret",
      LC_ALL: "C.UTF-8",
      npm_config_cache: "/tmp/npm-cache",
    });
    assert.deepEqual(env, {
      PATH: "/usr/bin",
      LANG: "en_US.UTF-8",
      FN_FUNCTIONS_ROOT: "/srv/functions",
      FN_STRICT_FS: "1",
      LC_ALL: "C.UTF-8",
      npm_config_cache: "/tmp/npm-cache",
    });
  });

  test("shared packs resolve from shared and runtime-scoped roots", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "shared-pack-ok", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "shared-root" });\n');
      writeFile(path.join(root, "shared-pack-ok", "fn.config.json"), JSON.stringify({ shared_deps: ["valid-pack"] }));
      fs.mkdirSync(path.join(root, ".fastfn", "packs", "node", "valid-pack"), { recursive: true });

      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.equal(
        daemon.__test__.resolveSharedPackDir("valid-pack"),
        path.resolve(path.join(root, ".fastfn", "packs", "node", "valid-pack")),
      );
      const resp = await daemon.handleRequest({ fn: "shared-pack-ok", event: { method: "GET" } });
      assert.equal(resp.status, 200);
      assert.equal(resp.body, "shared-root");
    });

    const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fastfn-nd-runtime-root-"));
    const previous = {
      root: process.env.FN_FUNCTIONS_ROOT,
      auto: process.env.FN_AUTO_NODE_DEPS,
      infer: process.env.FN_AUTO_INFER_NODE_DEPS,
      write: process.env.FN_AUTO_INFER_WRITE_MANIFEST,
      strict: process.env.FN_AUTO_INFER_STRICT,
      backend: process.env.FN_NODE_INFER_BACKEND,
      strictFs: process.env.FN_STRICT_FS,
      hotReload: process.env.FN_HOT_RELOAD,
      pool: process.env.FN_NODE_RUNTIME_PROCESS_POOL,
      preinstall: process.env.FN_PREINSTALL_NODE_DEPS_ON_START,
    };

    try {
      const sharedRoot = path.join(tempRoot, "functions");
      const runtimeRoot = path.join(sharedRoot, "node");
      fs.mkdirSync(path.join(runtimeRoot, "shared-pack-runtime"), { recursive: true });
      fs.mkdirSync(path.join(sharedRoot, ".fastfn", "packs", "node", "valid-pack"), { recursive: true });
      writeFile(path.join(runtimeRoot, "shared-pack-runtime", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "runtime-root" });\n');
      writeFile(path.join(runtimeRoot, "shared-pack-runtime", "fn.config.json"), JSON.stringify({ shared_deps: ["valid-pack"] }));

      process.env.FN_FUNCTIONS_ROOT = runtimeRoot;
      process.env.FN_AUTO_NODE_DEPS = "0";
      process.env.FN_AUTO_INFER_NODE_DEPS = "0";
      process.env.FN_AUTO_INFER_WRITE_MANIFEST = "0";
      process.env.FN_AUTO_INFER_STRICT = "0";
      process.env.FN_NODE_INFER_BACKEND = "native";
      process.env.FN_STRICT_FS = "0";
      process.env.FN_HOT_RELOAD = "1";
      process.env.FN_NODE_RUNTIME_PROCESS_POOL = "0";
      process.env.FN_PREINSTALL_NODE_DEPS_ON_START = "0";

      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.equal(
        daemon.__test__.resolveSharedPackDir("valid-pack"),
        path.resolve(path.join(sharedRoot, ".fastfn", "packs", "node", "valid-pack")),
      );
      const resp = await daemon.handleRequest({ fn: "shared-pack-runtime", event: { method: "GET" } });
      assert.equal(resp.status, 200);
      assert.equal(resp.body, "runtime-root");
    } finally {
      const restore = (key, value) => {
        if (value === undefined) delete process.env[key];
        else process.env[key] = value;
      };
      restore("FN_FUNCTIONS_ROOT", previous.root);
      restore("FN_AUTO_NODE_DEPS", previous.auto);
      restore("FN_AUTO_INFER_NODE_DEPS", previous.infer);
      restore("FN_AUTO_INFER_WRITE_MANIFEST", previous.write);
      restore("FN_AUTO_INFER_STRICT", previous.strict);
      restore("FN_NODE_INFER_BACKEND", previous.backend);
      restore("FN_STRICT_FS", previous.strictFs);
      restore("FN_HOT_RELOAD", previous.hotReload);
      restore("FN_NODE_RUNTIME_PROCESS_POOL", previous.pool);
      restore("FN_PREINSTALL_NODE_DEPS_ON_START", previous.preinstall);
      fs.rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  test("internal helper guards and package inference", async () => {
    const daemon = jestRequireFresh(NODE_DAEMON_PATH);

    assert.equal(daemon.__test__.isSafeRootRelativePath("public"), true);
    assert.equal(daemon.__test__.isSafeRootRelativePath("/abs"), false);
    assert.equal(daemon.__test__.isSafeRootRelativePath("nested\\bad"), false);
    assert.equal(daemon.__test__.isSafeRootRelativePath("../up"), false);

    assert.deepEqual(daemon.__test__.normalizePackageFromSpecifier(""), { kind: "ignore" });
    assert.deepEqual(daemon.__test__.normalizePackageFromSpecifier("./local"), { kind: "ignore" });
    assert.deepEqual(daemon.__test__.normalizePackageFromSpecifier("node:fs"), { kind: "ignore" });
    assert.deepEqual(daemon.__test__.normalizePackageFromSpecifier("@bad/"), { kind: "unresolved", value: "@bad/" });
    assert.deepEqual(daemon.__test__.normalizePackageFromSpecifier("@scope/pkg/subpath"), { kind: "resolved", value: "@scope/pkg" });
    assert.deepEqual(daemon.__test__.normalizePackageFromSpecifier("dayjs/plugin/utc"), { kind: "resolved", value: "dayjs" });
    assert.deepEqual(
      daemon.__test__.resolveNodePackages(
        ["dayjs/plugin/utc", "@scope/pkg/subpath", "@bad/", "./local", "node:fs", "dayjs"],
        { ignorePackages: new Set(["@scope/pkg"]) }
      ),
      { resolved: ["dayjs"], unresolved: ["@bad/"] }
    );
  });

  test("node inference backends resolve optional tools explicitly", async () => {
    const realChildProcess = jest.requireActual("child_process");

    await withFunctionsRoot(async () => {
      await withMockedNodeDaemon({
        detective: () => (source) => (source.includes("uuid") ? ["uuid"] : []),
      }, async () => {
        const daemon = require(NODE_DAEMON_PATH);
        assert.equal(typeof daemon.__test__.loadOptionalNodeTool("detective"), "function");
      });
    }, { autoInferNodeDeps: true, nodeInferBackend: "detective" });

    await withFunctionsRoot(async (root) => {
      const globalRoot = path.join(root, ".global-node-tools");
      writeFile(
        path.join(globalRoot, "detective", "index.js"),
        'module.exports = () => ["dayjs/plugin/utc", "uuid", "./local"];\n'
      );

      await withMockedNodeDaemon({
        child_process: () => ({
          ...realChildProcess,
          spawnSync(command, args) {
            if (args && args[0] === "root" && args[1] === "-g") {
              return { status: 0, stdout: `${globalRoot}\n`, stderr: "" };
            }
            return realChildProcess.spawnSync(command, args);
          },
        }),
      }, async () => {
        const daemon = require(NODE_DAEMON_PATH);
        const tool = daemon.__test__.loadOptionalNodeTool("detective");
        assert.equal(typeof tool, "function");
        assert.deepEqual(tool("ignored"), ["dayjs/plugin/utc", "uuid", "./local"]);
        assert.deepEqual(daemon.__test__.inferNodeImportsWithDetective(path.join(root, "missing.js")), []);
      });
    }, { autoInferNodeDeps: true, nodeInferBackend: "detective" });

    await withFunctionsRoot(async () => {
      await withMockedNodeDaemon({
        child_process: () => ({
          ...realChildProcess,
          spawnSync() {
            return { status: 1, stdout: "", stderr: "missing npm root" };
          },
        }),
      }, async () => {
        const daemon = require(NODE_DAEMON_PATH);
        assert.equal(daemon.__test__.loadOptionalNodeTool("missing-fastfn-tool"), null);
      });
    }, { autoInferNodeDeps: true, nodeInferBackend: "detective" });
  });

  test("node inference backend validation and missing detective errors are explicit", async () => {
    await withFunctionsRoot(async () => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.equal(daemon.__test__.resolveNodeInferBackend(), "native");
    }, { autoInferNodeDeps: true, nodeInferBackend: "native" });

    await withFunctionsRoot(async () => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.throws(
        () => daemon.__test__.resolveNodeInferBackend(),
        /node dependency inference backend unsupported/
      );
    }, { autoInferNodeDeps: true, nodeInferBackend: "not-real" });

    await withFunctionsRoot(async () => {
      await withMockedNodeDaemon({ detective: () => null }, async () => {
        const daemon = require(NODE_DAEMON_PATH);
        assert.throws(
          () => daemon.__test__.inferNodeImportsWithDetective("/tmp/fastfn-missing.js"),
          /detective/
        );
      });
    }, { autoInferNodeDeps: true, nodeInferBackend: "detective" });
  });

  test("detective backend can generate a manifest for multiple inferred dependencies", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(
        path.join(root, "auto-infer-detective", "handler.js"),
        [
          "module.exports.handler = async () => ({",
          '  status: 200,',
          '  headers: { "Content-Type": "application/json" },',
          '  body: JSON.stringify({ ok: true, backend: "detective" }),',
          "});",
          "",
        ].join("\n")
      );

      await withMockedNodeDaemon({
        detective: () => () => ["dayjs/plugin/utc", "uuid", "./local"],
      }, async () => {
        const daemon = require(NODE_DAEMON_PATH);
        const resp = await daemon.handleRequest({ fn: "auto-infer-detective", event: { method: "GET" } });
        assert.equal(resp.status, 200);

        const pkg = JSON.parse(fs.readFileSync(path.join(root, "auto-infer-detective", "package.json"), "utf8"));
        assert.deepEqual(Object.keys(pkg.dependencies).sort(), ["dayjs", "uuid"]);

        const state = JSON.parse(fs.readFileSync(path.join(root, "auto-infer-detective", ".fastfn-deps-state.json"), "utf8"));
        assert.equal(state.mode, "inferred");
        assert.equal(state.manifest_generated, true);
        assert.equal(state.infer_backend, "detective");
        assert.equal(state.last_install_status, "skipped");
        assert.ok(state.inference_duration_ms >= 0);
        assert.deepEqual(state.resolved_packages, ["dayjs", "uuid"]);
        assert.deepEqual(state.unresolved_imports, []);
      });
    }, {
      autoInferNodeDeps: true,
      autoInferWriteManifest: true,
      autoInferStrict: true,
      nodeInferBackend: "detective",
    });
  });

  test("require-analyzer backend can infer multiple dependencies and report metadata", async () => {
    const realChildProcess = jest.requireActual("child_process");

    await withFunctionsRoot(async (root) => {
      writeFile(
        path.join(root, "auto-infer-require-analyzer", "handler.js"),
        [
          "module.exports.handler = async () => ({",
          '  status: 200,',
          '  headers: { "Content-Type": "application/json" },',
          '  body: JSON.stringify({ ok: true, backend: "require-analyzer" }),',
          "});",
          "",
        ].join("\n")
      );

      await withMockedNodeDaemon({
        child_process: () => ({
          ...realChildProcess,
          spawnSync(command, args) {
            if (args && args[0] === "root" && args[1] === "-g") {
              return { status: 0, stdout: "/tmp/fake-global-modules\n", stderr: "" };
            }
            if (command === process.execPath) {
              return {
                status: 0,
                stdout: `${JSON.stringify({ imports: ["uuid", "nanoid", "./local"], packages: ["uuid", "nanoid"] })}\n`,
                stderr: "",
              };
            }
            return realChildProcess.spawnSync(command, args);
          },
        }),
      }, async () => {
        const daemon = require(NODE_DAEMON_PATH);
        const resp = await daemon.handleRequest({ fn: "auto-infer-require-analyzer", event: { method: "GET" } });
        assert.equal(resp.status, 200);

        const pkg = JSON.parse(fs.readFileSync(path.join(root, "auto-infer-require-analyzer", "package.json"), "utf8"));
        assert.deepEqual(Object.keys(pkg.dependencies).sort(), ["nanoid", "uuid"]);

        const state = JSON.parse(fs.readFileSync(path.join(root, "auto-infer-require-analyzer", ".fastfn-deps-state.json"), "utf8"));
        assert.equal(state.mode, "inferred");
        assert.equal(state.manifest_generated, true);
        assert.equal(state.infer_backend, "require-analyzer");
        assert.equal(state.last_install_status, "skipped");
        assert.ok(state.inference_duration_ms >= 0);
        assert.deepEqual(state.resolved_packages, ["uuid", "nanoid"]);
        assert.deepEqual(state.unresolved_imports, []);
      });
    }, {
      autoInferNodeDeps: true,
      autoInferWriteManifest: true,
      autoInferStrict: true,
      nodeInferBackend: "require-analyzer",
    });
  });

  test("require-analyzer helper surfaces missing, failed, invalid, and packages-only analyzer results", async () => {
    const realChildProcess = jest.requireActual("child_process");

    const withAnalyzerSpawn = async (spawnImpl, run) => {
      await withFunctionsRoot(async () => {
        await withMockedNodeDaemon({
          child_process: () => ({
            ...realChildProcess,
            spawnSync: spawnImpl,
          }),
        }, async () => {
          const daemon = require(NODE_DAEMON_PATH);
          await run(daemon);
        });
      }, { autoInferNodeDeps: true, nodeInferBackend: "require-analyzer" });
    };

    await withAnalyzerSpawn((command, args) => {
      if (args && args[0] === "root" && args[1] === "-g") {
        return { status: 0, stdout: "/tmp/fake-global-modules\n", stderr: "" };
      }
      if (command === process.execPath) {
        return { status: 3, stdout: "", stderr: "MISSING_REQUIRE_ANALYZER" };
      }
      return realChildProcess.spawnSync(command, args);
    }, async (daemon) => {
      assert.throws(
        () => daemon.__test__.inferNodePackagesWithRequireAnalyzer("/tmp/fastfn-node-handler.js"),
        /require-analyzer/
      );
    });

    await withAnalyzerSpawn((command, args) => {
      if (args && args[0] === "root" && args[1] === "-g") {
        return { status: 0, stdout: "/tmp/fake-global-modules\n", stderr: "" };
      }
      if (command === process.execPath) {
        return { status: 2, stdout: "", stderr: "explode-now" };
      }
      return realChildProcess.spawnSync(command, args);
    }, async (daemon) => {
      assert.throws(
        () => daemon.__test__.inferNodePackagesWithRequireAnalyzer("/tmp/fastfn-node-handler.js"),
        /failed: explode-now/
      );
    });

    await withAnalyzerSpawn((command, args) => {
      if (args && args[0] === "root" && args[1] === "-g") {
        return { status: 0, stdout: "/tmp/fake-global-modules\n", stderr: "" };
      }
      if (command === process.execPath) {
        return { status: 0, stdout: "{not-json}\n", stderr: "" };
      }
      return realChildProcess.spawnSync(command, args);
    }, async (daemon) => {
      assert.throws(
        () => daemon.__test__.inferNodePackagesWithRequireAnalyzer("/tmp/fastfn-node-handler.js"),
        /invalid JSON/
      );
    });

    await withAnalyzerSpawn((command, args) => {
      if (args && args[0] === "root" && args[1] === "-g") {
        return { status: 0, stdout: "/tmp/fake-global-modules\n", stderr: "" };
      }
      if (command === process.execPath) {
        return {
          status: 0,
          stdout: `${JSON.stringify({ imports: [], packages: ["uuid", "@scope/pkg/subpath", "node:fs"] })}\n`,
          stderr: "",
        };
      }
      return realChildProcess.spawnSync(command, args);
    }, async (daemon) => {
      assert.deepEqual(
        daemon.__test__.inferNodeDependencySelection("/tmp/fastfn-node-handler.js", new Set()),
        {
          backend: "require-analyzer",
          imports: ["uuid", "@scope/pkg/subpath", "node:fs"],
          resolved: ["uuid", "@scope/pkg"],
          unresolved: [],
        }
      );
    });
  });

  test("root assets directory config and function config helpers", async () => {
    await withFunctionsRoot(async (root) => {
      writeFile(path.join(root, "hello", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "hello" });\n');
      writeFile(path.join(root, "public", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "public" });\n');

      writeFile(path.join(root, "cfg-array", "fn.config.json"), JSON.stringify([1, 2, 3]));
      let daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.deepEqual(daemon.__test__.readFunctionConfig(path.join(root, "cfg-array", "handler.js")), {});

      writeFile(path.join(root, "cfg-object", "fn.config.json"), JSON.stringify({ invoke: { handler: "myHandler" } }));
      daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.deepEqual(
        daemon.__test__.readFunctionConfig(path.join(root, "cfg-object", "handler.js")),
        { invoke: { handler: "myHandler" } }
      );

      writeFile(path.join(root, "fn.config.json"), JSON.stringify([1, 2, 3]));
      daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.equal(daemon.__test__.rootAssetsDirectory, "");
      assert.equal(daemon.__test__.pathIsInAssetsDirectory(path.join(root, "public", "handler.js")), false);

      writeFile(path.join(root, "fn.config.json"), JSON.stringify({ assets: true }));
      daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.equal(daemon.__test__.rootAssetsDirectory, "");
      assert.equal(daemon.__test__.pathIsInAssetsDirectory(path.join(root, "public", "handler.js")), false);

      writeFile(path.join(root, "fn.config.json"), JSON.stringify({ assets: { directory: "public" } }));
      daemon = jestRequireFresh(NODE_DAEMON_PATH);
      assert.equal(daemon.__test__.rootAssetsDirectory, "public");
      assert.equal(daemon.__test__.pathIsInAssetsDirectory(path.join(root, "public", "handler.js")), true);
      assert.equal(daemon.__test__.pathIsInAssetsDirectory(path.join(root, "hello", "handler.js")), false);
      assert.equal(daemon.__test__.pathIsInAssetsDirectory(path.join(path.dirname(root), "outside", "index.html")), false);
    });
  });

  test("deps isolation between functions", async () => {
    await withFunctionsRoot(async (root) => {
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      const fnA = path.join(root, "fn-iso-a");
      writeFile(path.join(fnA, "node_modules", "sharedpkg", "index.js"),
        'module.exports = { VALUE: "version_A" };\n');
      writeFile(path.join(fnA, "handler.js"),
        'const pkg = require("sharedpkg");\nmodule.exports.handler = () => ({ status: 200, body: pkg.VALUE });\n');

      const fnB = path.join(root, "fn-iso-b");
      writeFile(path.join(fnB, "node_modules", "sharedpkg", "index.js"),
        'module.exports = { VALUE: "version_B" };\n');
      writeFile(path.join(fnB, "handler.js"),
        'const pkg = require("sharedpkg");\nmodule.exports.handler = () => ({ status: 200, body: pkg.VALUE });\n');

      const rA = await daemon.handleRequest({ fn: "fn-iso-a", event: { method: "GET" } });
      assert.equal(rA.body, "version_A", "Function A should get version_A");

      const rB = await daemon.handleRequest({ fn: "fn-iso-b", event: { method: "GET" } });
      assert.equal(rB.body, "version_B", "Function B should get version_B, not A's");

      const rA2 = await daemon.handleRequest({ fn: "fn-iso-a", event: { method: "GET" } });
      assert.equal(rA2.body, "version_A", "Function A should still return version_A");
    });
  });

  // This comprehensive test MUST be the last test in the suite.
  // It exercises all internal code paths in a single daemon instance so c8
  // can track coverage for internal functions.
  test("comprehensive coverage (single module load)", async () => {
    await withFunctionsRoot(async (root) => {
      const prevPool = process.env.FN_NODE_RUNTIME_PROCESS_POOL;
      const prevLogFile = process.env.FN_RUNTIME_LOG_FILE;
      process.env.FN_NODE_RUNTIME_PROCESS_POOL = "1";
      process.env.FN_RUNTIME_LOG_FILE = path.join(root, "runtime.log");
      writeFile(path.join(root, "fn.config.json"), JSON.stringify({ assets: { directory: "public" } }));
      writeFile(path.join(root, "cov-handler-path", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "public", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "asset" });\n');
      const daemon = jestRequireFresh(NODE_DAEMON_PATH);

      // --- handleRequest validation ---
      let err;
      try { await daemon.handleRequest(null); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("request must be an object"));
      try { await daemon.handleRequest({}); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("fn is required"));
      try { await daemon.handleRequest({ fn: "test", event: [] }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("event must be an object"));

      const collected = daemon.__test__.collectHandlerPaths();
      assert.ok(collected.some((p) => p.endsWith(path.join("cov-handler-path", "handler.js"))));
      assert.ok(!collected.some((p) => p.includes(path.join("public", "handler.js"))));

      // --- magic responses (normalizeMagicResponse, looksLikeHtml, withDefaultHeader) ---
      writeFile(path.join(root, "cov-null", "handler.js"), 'module.exports.handler = async () => null;\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-null", event: { method: "GET" } })).body, "");

      writeFile(path.join(root, "cov-str", "handler.js"), 'module.exports.handler = async () => "hello";\n');
      const rStr = await daemon.handleRequest({ fn: "cov-str", event: { method: "GET" } });
      assert.ok(rStr.headers["Content-Type"].includes("text/plain"));

      writeFile(path.join(root, "cov-html", "handler.js"), 'module.exports.handler = async () => "<html><body>hi</body></html>";\n');
      assert.ok((await daemon.handleRequest({ fn: "cov-html", event: { method: "GET" } })).headers["Content-Type"].includes("text/html"));

      writeFile(path.join(root, "cov-num", "handler.js"), 'module.exports.handler = async () => 42;\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-num", event: { method: "GET" } })).body, "42");

      writeFile(path.join(root, "cov-obj", "handler.js"), 'module.exports.handler = async () => ({ foo: 1 });\n');
      assert.ok((await daemon.handleRequest({ fn: "cov-obj", event: { method: "GET" } })).headers["Content-Type"].includes("application/json"));

      writeFile(path.join(root, "cov-buf", "handler.js"), 'module.exports.handler = async () => Buffer.from("bin");\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-buf", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "cov-u8", "handler.js"), 'module.exports.handler = async () => new Uint8Array([1]);\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-u8", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "cov-empty", "handler.js"), 'module.exports.handler = async () => "";\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-empty", event: { method: "GET" } })).body, "");

      // --- contract responses (normalizeResponse, hasResponseContractShape, expectsBinaryContentType, isCsvContentType, hasHeader, getHeaderValue) ---
      writeFile(path.join(root, "cov-contract", "handler.js"), 'module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "text/plain" }, body: "ok" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-contract", event: { method: "GET" } })).status, 200);

      writeFile(path.join(root, "cov-sc", "handler.js"), 'module.exports.handler = async () => ({ statusCode: 201, headers: {}, body: "created" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-sc", event: { method: "POST" } })).status, 201);

      writeFile(path.join(root, "cov-b64", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, is_base64: true, body_base64: Buffer.from("hello").toString("base64") });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-b64", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "cov-b64buf", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, is_base64: true, body_base64: Buffer.from("bufdata") });\n`);
      assert.ok((await daemon.handleRequest({ fn: "cov-b64buf", event: { method: "GET" } })).body_base64);

      writeFile(path.join(root, "cov-aws-b64", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, isBase64Encoded: true, body: Buffer.from("aws").toString("base64") });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-aws-b64", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "cov-body-buf", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, body: Buffer.from("buf") });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-body-buf", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "cov-body-null", "handler.js"), 'module.exports.handler = async () => ({ status: 204, headers: {}, body: null });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-body-null", event: { method: "DELETE" } })).body, "");

      writeFile(path.join(root, "cov-body-obj", "handler.js"), 'module.exports.handler = async () => ({ status: 200, headers: {}, body: { k: "v" } });\n');
      assert.ok(JSON.parse((await daemon.handleRequest({ fn: "cov-body-obj", event: { method: "GET" } })).body).k);

      writeFile(path.join(root, "cov-body-num", "handler.js"), 'module.exports.handler = async () => ({ status: 200, headers: {}, body: 42 });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-body-num", event: { method: "GET" } })).body, "42");

      writeFile(path.join(root, "cov-bin-ct", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "application/octet-stream" }, body: "binary" });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-bin-ct", event: { method: "GET" } })).is_base64, true);

      writeFile(path.join(root, "cov-proxy", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, body: "p", proxy: { target: "http://x.com" } });\n`);
      assert.ok((await daemon.handleRequest({ fn: "cov-proxy", event: { method: "GET" } })).proxy);

      writeFile(path.join(root, "cov-bad-status", "handler.js"), 'module.exports.handler = async () => ({ status: 99, headers: {}, body: "" });\n');
      err = null;
      try { await daemon.handleRequest({ fn: "cov-bad-status", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("status must be a valid HTTP code"));

      writeFile(path.join(root, "cov-no-contract", "handler.js"), 'module.exports.handler = async () => ({ foo: "bar" });\n');
      assert.ok((await daemon.handleRequest({ fn: "cov-no-contract", event: { method: "GET" } })).headers["Content-Type"].includes("application/json"));

      // --- CSV responses (toCsv, csvEscapeCell, isCsvContentType) ---
      const csvFn = (name, bodyExpr) => {
        writeFile(path.join(root, name, "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "text/csv" }, body: ${bodyExpr} });\n`);
      };
      csvFn("cov-csv-obj", '[{ name: "Alice", age: 30 }, { name: "Bob", age: 25 }]');
      assert.ok((await daemon.handleRequest({ fn: "cov-csv-obj", event: { method: "GET" } })).body.includes("Alice,30"));
      csvFn("cov-csv-arr", '[["a", "b"], ["1", "2"]]');
      assert.ok((await daemon.handleRequest({ fn: "cov-csv-arr", event: { method: "GET" } })).body.includes("a,b"));
      csvFn("cov-csv-empty", '[]');
      assert.equal((await daemon.handleRequest({ fn: "cov-csv-empty", event: { method: "GET" } })).body, "");
      csvFn("cov-csv-scalar", '["hello", "world"]');
      assert.ok((await daemon.handleRequest({ fn: "cov-csv-scalar", event: { method: "GET" } })).body.includes("hello"));
      csvFn("cov-csv-single", '{ a: 1, b: 2 }');
      assert.ok((await daemon.handleRequest({ fn: "cov-csv-single", event: { method: "GET" } })).body.includes("a,b"));
      csvFn("cov-csv-empty-obj", '{}');
      assert.equal((await daemon.handleRequest({ fn: "cov-csv-empty-obj", event: { method: "GET" } })).body, "");
      csvFn("cov-csv-esc", '[{ name: \'has,comma\', val: \'has"quote\' }, { name: \'has\\nnewline\', val: null }]');
      assert.ok((await daemon.handleRequest({ fn: "cov-csv-esc", event: { method: "GET" } })).body.includes('"has,comma"'));
      csvFn("cov-csv-prim", '42');
      assert.equal((await daemon.handleRequest({ fn: "cov-csv-prim", event: { method: "GET" } })).body, "42");
      csvFn("cov-csv-cell-obj", '[{ data: { nested: true } }]');
      assert.ok((await daemon.handleRequest({ fn: "cov-csv-cell-obj", event: { method: "GET" } })).body.includes("nested"));
      csvFn("cov-csv-undef", '[{ a: undefined, b: "ok" }]');
      assert.ok((await daemon.handleRequest({ fn: "cov-csv-undef", event: { method: "GET" } })).body.includes("a,b"));

      // --- Lambda adapter (buildLambdaEvent, buildLambdaContext, buildRawPath, encodeQueryString, buildRawQueryString, getHeaderCaseInsensitive) ---
      const lambdaFn = (name, code) => {
        writeFile(path.join(root, name, "handler.js"), code);
        writeFile(path.join(root, name, "fn.config.json"), JSON.stringify({ invoke: { adapter: "aws-lambda" } }));
      };

      lambdaFn("cov-lambda-basic", `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: JSON.stringify({ method: event.requestContext.http.method, path: event.rawPath }) });\n`);
      const lb = JSON.parse((await daemon.handleRequest({ fn: "cov-lambda-basic", event: { method: "GET", path: "/test" } })).body);
      assert.equal(lb.method, "GET");
      assert.equal(lb.path, "/test");

      lambdaFn("cov-lambda-full", `exports.handler = async (event, context) => {
        context.done(); context.fail(); context.succeed();
        return { statusCode: 200, headers: {}, body: JSON.stringify({
          rid: context.awsRequestId, remaining: context.getRemainingTimeInMillis(),
          qs: event.rawQueryString, cookies: event.cookies,
          isB64: event.isBase64Encoded, body: event.body,
          params: event.pathParameters, qp: event.queryStringParameters
        }) };
      };\n`);
      const lf = JSON.parse((await daemon.handleRequest({ fn: "cov-lambda-full", event: {
        method: "POST", path: "/test", raw_path: "/test?a=1", query: { a: "1", tags: ["x", "y", null], empty: null },
        headers: { cookie: "sid=abc", host: "localhost" }, body: '{"x":1}',
        is_base64: true, body_base64: "aGVsbG8=",
        client: { ip: "10.0.0.1", ua: "test-agent" },
        context: { request_id: "req-42", timeout_ms: 5000 }
      } })).body);
      assert.equal(lf.rid, "req-42");
      assert.equal(lf.remaining, 5000);

      lambdaFn("cov-lambda-sync", `exports.handler = function(event, context, callback) { return { statusCode: 200, headers: {}, body: "sync" }; };\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-sync", event: { method: "GET", path: "/test" } })).body, "sync");

      lambdaFn("cov-lambda-throw", `exports.handler = function() { throw new Error("sync boom"); };\n`);
      err = null;
      try { await daemon.handleRequest({ fn: "cov-lambda-throw", event: { method: "GET", path: "/t" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("sync boom"));

      lambdaFn("cov-lambda-cb-err", `exports.handler = (event, context, callback) => { callback("string error"); };\n`);
      err = null;
      try { await daemon.handleRequest({ fn: "cov-lambda-cb-err", event: { method: "GET", path: "/t" } }); } catch (e) { err = e; }
      assert.ok(err instanceof Error);

      lambdaFn("cov-lambda-double", `exports.handler = (event, context, callback) => { callback(null, { statusCode: 200, headers: {}, body: "first" }); callback(null, { statusCode: 200, headers: {}, body: "second" }); };\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-double", event: { method: "GET", path: "/t" } })).body, "first");

      lambdaFn("cov-lambda-promise", `exports.handler = function(event, context, callback) { return Promise.resolve({ statusCode: 200, headers: {}, body: "promise" }); };\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-promise", event: { method: "GET", path: "/t" } })).body, "promise");

      lambdaFn("cov-lambda-reject", `exports.handler = function() { return Promise.reject(new Error("async fail")); };\n`);
      err = null;
      try { await daemon.handleRequest({ fn: "cov-lambda-reject", event: { method: "GET", path: "/t" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("async fail"));

      lambdaFn("cov-lambda-noret", `exports.handler = function(event, context) {};\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-noret", event: { method: "GET", path: "/t" } })).body, "");

      lambdaFn("cov-lambda-path", `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: event.rawPath });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-path", event: { method: "GET" } })).body, "/");
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-path", event: { method: "GET", path: "noslash" } })).body, "/noslash");
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-path", event: { method: "GET", raw_path: "https://example.com/api" } })).body, "https://example.com/api");

      lambdaFn("cov-lambda-qs", `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: event.rawQueryString });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-qs", event: { method: "GET", raw_path: "/test?inline=1" } })).body, "inline=1");
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-qs", event: { method: "GET", raw_path: "/test?" } })).body, "");
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-qs", event: { method: "GET" } })).body, "");

      lambdaFn("cov-lambda-numbody", `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: String(typeof event.body) });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-lambda-numbody", event: { method: "POST", path: "/t", body: 42 } })).body, "string");

      // --- Cloudflare adapter (buildWorkersRequest, buildWorkersUrl, buildWorkersHeaders, buildWorkersContext) ---
      if (typeof Request === "function" && typeof Response === "function") {
        const cfFn = (name, code) => {
          writeFile(path.join(root, name, "handler.js"), code);
          writeFile(path.join(root, name, "fn.config.json"), JSON.stringify({ invoke: { adapter: "cloudflare-worker" } }));
        };

        cfFn("cov-cf-basic", 'module.exports = { fetch: async (req) => new Response("ok " + req.method, { status: 200 }) };\n');
        assert.equal((await daemon.handleRequest({ fn: "cov-cf-basic", event: { method: "GET", raw_path: "/test", headers: { host: "t" } } })).status, 200);

        cfFn("cov-cf-default", 'module.exports.default = { fetch: async (req) => new Response("default") };\n');
        assert.ok((await daemon.handleRequest({ fn: "cov-cf-default", event: { method: "GET", raw_path: "/t", headers: { host: "t" } } })).body.includes("default"));

        cfFn("cov-cf-nofetch", 'module.exports = { notFetch: true };\n');
        err = null;
        try { await daemon.handleRequest({ fn: "cov-cf-nofetch", event: { method: "GET", raw_path: "/t", headers: { host: "t" } } }); } catch (e) { err = e; }
        assert.ok(err && err.message.includes("cloudflare-worker adapter requires fetch"));

        cfFn("cov-cf-named", 'module.exports.handler = async (req, env, ctx) => new Response("named");\n');
        assert.ok((await daemon.handleRequest({ fn: "cov-cf-named", event: { method: "GET", raw_path: "/t", headers: { host: "t" } } })).body.includes("named"));

        cfFn("cov-cf-post", `module.exports = { fetch: async (req) => { const text = await req.text(); return new Response("got: " + text); } };\n`);
        assert.ok((await daemon.handleRequest({ fn: "cov-cf-post", event: { method: "POST", raw_path: "/", headers: { host: "t" }, body: "hello" } })).body.includes("got: hello"));

        cfFn("cov-cf-b64", `module.exports = { fetch: async (req) => { const buf = await req.arrayBuffer(); return new Response("len: " + buf.byteLength); } };\n`);
        assert.ok((await daemon.handleRequest({ fn: "cov-cf-b64", event: { method: "POST", raw_path: "/", headers: { host: "t" }, is_base64: true, body_base64: Buffer.from("binary").toString("base64") } })).body.includes("len: 6"));

        cfFn("cov-cf-wait", `module.exports = { fetch: async (req, env, ctx) => { ctx.waitUntil(Promise.reject(new Error("bg"))); ctx.waitUntil("not a promise"); ctx.passThroughOnException(); return new Response("ok"); } };\n`);
        assert.equal((await daemon.handleRequest({ fn: "cov-cf-wait", event: { method: "GET", raw_path: "/", headers: { host: "t" } } })).status, 200);

        cfFn("cov-cf-url", 'module.exports = { fetch: async (req) => new Response(req.url) };\n');
        assert.ok((await daemon.handleRequest({ fn: "cov-cf-url", event: { method: "GET", raw_path: "https://example.com/api", headers: { host: "t" } } })).body.includes("https://example.com/api"));
        assert.ok((await daemon.handleRequest({ fn: "cov-cf-url", event: { method: "GET", raw_path: "/test", headers: { host: "myhost", "x-forwarded-proto": "https" } } })).body.includes("https://myhost/test"));

        cfFn("cov-cf-bin", `module.exports = { fetch: async () => new Response(new Uint8Array([1,2,3]), { status: 200, headers: { "Content-Type": "application/octet-stream" } }) };\n`);
        assert.equal((await daemon.handleRequest({ fn: "cov-cf-bin", event: { method: "GET", raw_path: "/", headers: { host: "t" } } })).is_base64, true);

        cfFn("cov-cf-empty", 'module.exports = { fetch: async () => new Response("", { status: 200 }) };\n');
        assert.equal((await daemon.handleRequest({ fn: "cov-cf-empty", event: { method: "GET", raw_path: "/", headers: { host: "t" } } })).body, "");

        cfFn("cov-cf-hdrs", `module.exports = { fetch: async (req) => { const h = {}; req.headers.forEach((v, k) => { h[k] = v; }); return new Response(JSON.stringify(h)); } };\n`);
        const ch = JSON.parse((await daemon.handleRequest({ fn: "cov-cf-hdrs", event: { method: "GET", raw_path: "/", headers: { host: "h", "x-custom": "yes", "content-length": "100", connection: "keep-alive" } } })).body);
        assert.equal(ch.host, undefined);
        assert.equal(ch["x-custom"], "yes");

        cfFn("cov-cf-get-nobody", 'module.exports = { fetch: async (req) => new Response(req.method) };\n');
        assert.equal((await daemon.handleRequest({ fn: "cov-cf-get-nobody", event: { method: "GET", raw_path: "/", headers: { host: "t" }, body: "ignored" } })).body, "GET");
        assert.equal((await daemon.handleRequest({ fn: "cov-cf-get-nobody", event: { method: "HEAD", raw_path: "/", headers: { host: "t" } } })).body, "HEAD");

        cfFn("cov-cf-num-body", `module.exports = { fetch: async (req) => { const t = await req.text(); return new Response("body: " + t); } };\n`);
        assert.ok((await daemon.handleRequest({ fn: "cov-cf-num-body", event: { method: "POST", raw_path: "/", headers: { host: "t" }, body: 42 } })).body.includes("body: 42"));
      }

      // --- Handler config edge cases ---
      assert.equal(daemon.__test__.resolveHandlerName(null), "handler");
      assert.equal(daemon.__test__.resolveHandlerName({}), "handler");
      assert.equal(daemon.__test__.resolveHandlerName({ invoke: { handler: "  " } }), "handler");
      assert.throws(
        () => daemon.__test__.resolveHandlerName({ invoke: { handler: "123invalid" } }),
        /invoke\.handler must be a valid identifier/
      );
      assert.equal(daemon.__test__.resolveHandlerName({ invoke: { handler: "myHandler" } }), "myHandler");

      assert.equal(daemon.__test__.resolveInvokeAdapter(null), "native");
      assert.equal(daemon.__test__.resolveInvokeAdapter({}), "native");
      assert.equal(daemon.__test__.resolveInvokeAdapter({ invoke: { adapter: "native" } }), "native");
      assert.equal(daemon.__test__.resolveInvokeAdapter({ invoke: { adapter: "default" } }), "native");
      assert.equal(daemon.__test__.resolveInvokeAdapter({ invoke: { adapter: "aws-lambda" } }), "aws-lambda");
      assert.equal(daemon.__test__.resolveInvokeAdapter({ invoke: { adapter: "api-gateway-v2" } }), "aws-lambda");
      assert.equal(daemon.__test__.resolveInvokeAdapter({ invoke: { adapter: "cloudflare-worker" } }), "cloudflare-worker");
      assert.equal(daemon.__test__.resolveInvokeAdapter({ invoke: { adapter: "workers" } }), "cloudflare-worker");

      writeFile(path.join(root, "cov-custom-handler", "handler.js"), 'module.exports.myHandler = async () => ({ status: 200, body: "custom" });\n');
      writeFile(path.join(root, "cov-custom-handler", "fn.config.json"), JSON.stringify({ invoke: { handler: "myHandler" } }));
      assert.equal((await daemon.handleRequest({ fn: "cov-custom-handler", event: { method: "GET" } })).body, "custom");

      writeFile(path.join(root, "cov-bad-handler", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-bad-handler", "fn.config.json"), JSON.stringify({ invoke: { handler: "123invalid" } }));
      err = null;
      try { await daemon.handleRequest({ fn: "cov-bad-handler", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("invoke.handler must be a valid identifier"));

      writeFile(path.join(root, "cov-no-handler", "handler.js"), 'module.exports.something = async () => ({ status: 200, body: "ok" });\n');
      err = null;
      try { await daemon.handleRequest({ fn: "cov-no-handler", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("handler(event) is required"));

      writeFile(path.join(root, "cov-default-exp", "handler.js"), 'module.exports.default = { handler: async () => ({ status: 200, body: "from default" }) };\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-default-exp", event: { method: "GET" } })).body, "from default");

      // unsupported adapter
      writeFile(path.join(root, "cov-bad-adapter", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-bad-adapter", "fn.config.json"), JSON.stringify({ invoke: { adapter: "unsupported-xyz" } }));
      err = null;
      try { await daemon.handleRequest({ fn: "cov-bad-adapter", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("invoke.adapter unsupported"));

      // --- Env features (readFunctionEnv, withPatchedProcessEnv, processEnv proxy) ---
      writeFile(path.join(root, "cov-env", "handler.js"), `module.exports.handler = async (event) => {
        const keys = Object.keys(process.env);
        const desc = Object.getOwnPropertyDescriptor(process.env, "MY_COV_VAR");
        const hasVar = "MY_COV_VAR" in process.env;
        return { status: 200, body: JSON.stringify({ val: process.env.MY_COV_VAR, keys: keys.includes("MY_COV_VAR"), descVal: desc ? desc.value : null, hasVar }) };
      };\n`);
      writeFile(path.join(root, "cov-env", "fn.env.json"), JSON.stringify({ MY_COV_VAR: "test_value" }));
      const envBody = JSON.parse((await daemon.handleRequest({ fn: "cov-env", event: { method: "GET" } })).body);
      assert.equal(envBody.val, "test_value");
      assert.equal(envBody.keys, true);
      assert.equal(envBody.descVal, "test_value");
      assert.equal(envBody.hasVar, true);

      // blocked env
      const origAdmin = process.env.FN_ADMIN_COV_TEST;
      process.env.FN_ADMIN_COV_TEST = "secret";
      writeFile(path.join(root, "cov-env-block", "handler.js"), `module.exports.handler = async () => ({ status: 200, body: JSON.stringify({ admin: process.env.FN_ADMIN_COV_TEST || "blocked", has: "FN_ADMIN_COV_TEST" in process.env }) });\n`);
      const eb = JSON.parse((await daemon.handleRequest({ fn: "cov-env-block", event: { method: "GET" } })).body);
      assert.equal(eb.admin, "blocked");
      assert.equal(eb.has, false);
      if (origAdmin === undefined) delete process.env.FN_ADMIN_COV_TEST;
      else process.env.FN_ADMIN_COV_TEST = origAdmin;

      // --- Entrypoint discovery ---
      writeFile(path.join(root, "cov-handler-file", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "from handler.js" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-handler-file", event: { method: "GET" } })).body, "from handler.js");

      writeFile(path.join(root, "cov-index-file", "index.js"), 'module.exports.handler = async () => ({ status: 200, body: "from index.js" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-index-file", event: { method: "GET" } })).body, "from index.js");

      writeFile(path.join(root, "cov-custom-entry", "fn.config.json"), JSON.stringify({ entrypoint: "src/main.js" }));
      writeFile(path.join(root, "cov-custom-entry", "src", "main.js"), 'module.exports.handler = async () => ({ status: 200, body: "custom entry" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-custom-entry", event: { method: "GET" } })).body, "custom entry");

      // direct file path
      writeFile(path.join(root, "handlers", "cov-list.js"), 'module.exports.handler = async () => ({ status: 200, body: "direct" });\n');
      assert.equal((await daemon.handleRequest({ fn: "handlers/cov-list.js", event: { method: "GET" } })).body, "direct");

      // versioned
      writeFile(path.join(root, "cov-versioned", "v2", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "v2" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-versioned", version: "v2", event: { method: "GET" } })).body, "v2");

      // runtime-scoped
      writeFile(path.join(root, "node", "cov-scoped", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "scoped" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-scoped", event: { method: "GET" } })).body, "scoped");

      // unknown function
      err = null;
      try { await daemon.handleRequest({ fn: "nonexistent-xyz-cov", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.code === "ENOENT");

      // invalid function name
      err = null;
      try { await daemon.handleRequest({ fn: "../etc/passwd", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err);

      // --- Fetch Response ---
      if (typeof Response === "function") {
        writeFile(path.join(root, "cov-fetch-resp", "handler.js"), `module.exports.handler = async () => new Response("fetch body", { status: 201, headers: { "X-Custom": "yes" } });\n`);
        const fr = await daemon.handleRequest({ fn: "cov-fetch-resp", event: { method: "GET" } });
        assert.equal(fr.status, 201);
        assert.equal(fr.body, "fetch body");
      }

      // --- Logging (console capture) ---
      writeFile(path.join(root, "cov-log", "handler.js"), `module.exports.handler = async () => { console.log("stdout-line"); console.info("info-line"); console.debug("debug-line"); console.error("stderr-line"); console.warn("warn-line"); return { status: 200, headers: {}, body: "ok" }; };\n`);
      const logR = await daemon.handleRequest({ fn: "cov-log", event: { method: "GET" } });
      assert.ok(logR.stdout.includes("stdout-line"));
      assert.ok(logR.stderr.includes("stderr-line"));

      // --- Throws ---
      writeFile(path.join(root, "cov-throw", "handler.js"), 'module.exports.handler = async () => { throw new Error("boom"); };\n');
      err = null;
      try { await daemon.handleRequest({ fn: "cov-throw", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("boom"));

      // --- Worker pool settings normalization ---
      assert.equal((await daemon.handleRequestWithProcessPool({ fn: "cov-contract", event: { method: "GET" } })).status, 200);
      assert.equal((await daemon.handleRequestWithProcessPool({ fn: "cov-contract", event: { method: "GET", context: { timeout_ms: 3000, worker_pool: { enabled: false, max_workers: 4, min_warm: 2, idle_ttl_seconds: 60 } } } })).status, 200);
      assert.equal((await daemon.handleRequestWithProcessPool({ fn: "cov-contract", event: { method: "GET", context: { worker_pool: { enabled: true, max_workers: 0 } } } })).status, 200);

      // --- Shared deps (extractSharedDeps with non-existent pack) ---
      writeFile(path.join(root, "cov-shared", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-shared", "fn.config.json"), JSON.stringify({ shared_deps: ["valid-pack", 42, "", "  ", "valid-pack"] }));
      err = null;
      try { await daemon.handleRequest({ fn: "cov-shared", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("shared pack not found"));
      assert.ok(err && err.message.includes(path.join(root, ".fastfn", "packs", "node", "valid-pack")));

      // --- Params ---
      writeFile(path.join(root, "cov-params", "handler.js"), `module.exports.handler = async (event, { id }) => ({ status: 200, body: JSON.stringify({ id: Number(id) }) });\n`);
      assert.equal(JSON.parse((await daemon.handleRequest({ fn: "cov-params", event: { method: "GET", params: { id: "42" } } })).body).id, 42);

      // --- b64 empty error ---
      writeFile(path.join(root, "cov-b64-empty", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, is_base64: true, body_base64: "" });\n`);
      err = null;
      try { await daemon.handleRequest({ fn: "cov-b64-empty", event: { method: "GET" } }); } catch (e) { err = e; }
      assert.ok(err && err.message.includes("body_base64 must be a non-empty string"));

      // --- text content types that are NOT binary ---
      for (const ct of ["text/plain", "application/json", "application/xml", "application/javascript", "application/x-www-form-urlencoded"]) {
        const label = ct.replace(/[^a-z]/g, "");
        writeFile(path.join(root, `cov-ct-${label}`, "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: { "Content-Type": "${ct}" }, body: "content" });\n`);
        assert.equal((await daemon.handleRequest({ fn: `cov-ct-${label}`, event: { method: "GET" } })).is_base64, undefined);
      }

      // --- Config edge cases ---
      writeFile(path.join(root, "cov-cfg-array", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-cfg-array", "fn.config.json"), "[1,2,3]");
      assert.equal((await daemon.handleRequest({ fn: "cov-cfg-array", event: { method: "GET" } })).status, 200);

      writeFile(path.join(root, "cov-cfg-bad", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-cfg-bad", "fn.config.json"), "{bad json}");
      assert.equal((await daemon.handleRequest({ fn: "cov-cfg-bad", event: { method: "GET" } })).status, 200);

      // --- Env edge cases ---
      writeFile(path.join(root, "cov-env-arr", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-env-arr", "fn.env.json"), "[1,2]");
      assert.equal((await daemon.handleRequest({ fn: "cov-env-arr", event: { method: "GET" } })).status, 200);

      writeFile(path.join(root, "cov-env-bad", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-env-bad", "fn.env.json"), "{bad}");
      assert.equal((await daemon.handleRequest({ fn: "cov-env-bad", event: { method: "GET" } })).status, 200);

      writeFile(path.join(root, "cov-env-val", "handler.js"), `module.exports.handler = async (event) => ({ status: 200, body: JSON.stringify({ a: (event.env || {}).A || "missing", b: (event.env || {}).B || "missing" }) });\n`);
      writeFile(path.join(root, "cov-env-val", "fn.env.json"), JSON.stringify({ A: { value: "wrapped" }, B: { value: null }, C: null }));
      const ev = JSON.parse((await daemon.handleRequest({ fn: "cov-env-val", event: { method: "GET" } })).body);
      assert.equal(ev.a, "wrapped");
      assert.equal(ev.b, "missing");

      // --- Escape entrypoint ---
      writeFile(path.join(root, "cov-escape-entry", "fn.config.json"), JSON.stringify({ entrypoint: "../../etc/passwd" }));
      writeFile(path.join(root, "cov-escape-entry", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "fallback" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-escape-entry", event: { method: "GET" } })).body, "fallback");

      // --- Proxy bad ---
      writeFile(path.join(root, "cov-proxy-bad", "handler.js"), `module.exports.handler = async () => ({ status: 200, headers: {}, body: "no proxy", proxy: "not-an-object" });\n`);
      assert.equal((await daemon.handleRequest({ fn: "cov-proxy-bad", event: { method: "GET" } })).proxy, undefined);

      // --- strict_fs: false ---
      writeFile(path.join(root, "cov-strict-off", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-strict-off", "fn.config.json"), JSON.stringify({ strict_fs: false }));
      assert.equal((await daemon.handleRequest({ fn: "cov-strict-off", event: { method: "GET" } })).status, 200);

      // --- Empty/whitespace handler name and non-string handler ---
      writeFile(path.join(root, "cov-empty-handler", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-empty-handler", "fn.config.json"), JSON.stringify({ invoke: { handler: "  " } }));
      assert.equal((await daemon.handleRequest({ fn: "cov-empty-handler", event: { method: "GET" } })).status, 200);

      writeFile(path.join(root, "cov-num-handler", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
      writeFile(path.join(root, "cov-num-handler", "fn.config.json"), JSON.stringify({ invoke: { handler: 42 } }));
      assert.equal((await daemon.handleRequest({ fn: "cov-num-handler", event: { method: "GET" } })).status, 200);

      // --- Native adapter aliases ---
      for (const alias of ["native", "none", "default"]) {
        writeFile(path.join(root, `cov-native-${alias}`, "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "ok" });\n');
        writeFile(path.join(root, `cov-native-${alias}`, "fn.config.json"), JSON.stringify({ invoke: { adapter: alias } }));
        assert.equal((await daemon.handleRequest({ fn: `cov-native-${alias}`, event: { method: "GET" } })).status, 200);
      }

      // --- Lambda adapter aliases ---
      for (const alias of ["lambda", "apigw-v2", "api-gateway-v2"]) {
        const fnName = `cov-la-${alias.replace(/[^a-z0-9]/g, "")}`;
        writeFile(path.join(root, fnName, "handler.js"), `exports.handler = async (event) => ({ statusCode: 200, headers: {}, body: "ok" });\n`);
        writeFile(path.join(root, fnName, "fn.config.json"), JSON.stringify({ invoke: { adapter: alias } }));
        assert.equal((await daemon.handleRequest({ fn: fnName, event: { method: "GET", path: `/${fnName}` } })).status, 200);
      }

      // --- Cloudflare adapter aliases ---
      if (typeof Request === "function" && typeof Response === "function") {
        for (const alias of ["cloudflare-worker", "cloudflare-workers", "worker", "workers"]) {
          assert.equal(daemon.__test__.resolveInvokeAdapter({ invoke: { adapter: alias } }), "cloudflare-worker");
        }

        for (const alias of ["cloudflare-workers", "worker", "workers"]) {
          const fnName = `cov-cfa-${alias.replace(/[^a-z0-9]/g, "")}`;
          writeFile(path.join(root, fnName, "handler.js"), 'module.exports = { fetch: async (req) => new Response("ok") };\n');
          writeFile(path.join(root, fnName, "fn.config.json"), JSON.stringify({ invoke: { adapter: alias } }));
          assert.equal((await daemon.handleRequest({ fn: fnName, event: { method: "GET", raw_path: `/${fnName}`, headers: { host: "t" } } })).status, 200);
        }
      }

      // --- Handler cache hit (call same function twice) ---
      writeFile(path.join(root, "cov-cache", "handler.js"), 'module.exports.handler = async () => ({ status: 200, body: "cached" });\n');
      assert.equal((await daemon.handleRequest({ fn: "cov-cache", event: { method: "GET" } })).body, "cached");
      assert.equal((await daemon.handleRequest({ fn: "cov-cache", event: { method: "GET" } })).body, "cached");

      for (const pool of daemon.__test__.runtimeProcessPools.values()) {
        for (const worker of [...pool.workers]) {
          try {
            worker.proc.kill("SIGKILL");
          } catch (_) {
            // ignore cleanup races
          }
        }
        pool.workers.length = 0;
        pool.waiters.length = 0;
      }
      daemon.__test__.runtimeProcessPools.clear();
    });
  });

});

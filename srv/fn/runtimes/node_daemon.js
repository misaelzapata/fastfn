#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const net = require("net");
const childProcess = require("child_process");
const Module = require("module");
const { AsyncLocalStorage } = require("async_hooks");

const SOCKET_PATH = process.env.FN_NODE_SOCKET || "/tmp/fastfn/fn-node.sock";
const MAX_FRAME_BYTES = Number(process.env.FN_MAX_FRAME_BYTES || 2 * 1024 * 1024);
const HOT_RELOAD = !["0", "false", "off", "no"].includes(String(process.env.FN_HOT_RELOAD || "1").toLowerCase());
const AUTO_NODE_DEPS = !["0", "false", "off", "no"].includes(String(process.env.FN_AUTO_NODE_DEPS || "1").toLowerCase());
const PREINSTALL_NODE_DEPS_ON_START = !["0", "false", "off", "no"].includes(String(process.env.FN_PREINSTALL_NODE_DEPS_ON_START || "0").toLowerCase());
const STRICT_FS = !["0", "false", "off", "no"].includes(String(process.env.FN_STRICT_FS || "1").toLowerCase());
const STRICT_FS_EXTRA_ALLOW = String(process.env.FN_STRICT_FS_ALLOW || "");

const BASE_DIR = path.resolve(__dirname, "..");
const FUNCTIONS_DIR = path.join(BASE_DIR, "functions", "node");
const PACKS_DIR = path.join(BASE_DIR, "functions", ".fastfn", "packs", "node");

const NAME_RE = /^[A-Za-z0-9_-]+$/;
const VERSION_RE = /^[A-Za-z0-9_.-]+$/;
const HANDLER_RE = /^[A-Za-z_$][A-Za-z0-9_$]*$/;
const PROTECTED_FN_FILES = new Set(["fn.config.json", "fn.env.json"]);
const STRICT_SYSTEM_ROOTS = ["/tmp", "/etc/ssl", "/etc/pki", "/usr/share/zoneinfo"];

const handlerCache = new Map();
const depsCache = new Map();
const packDepsCache = new Map();
const tsBuildCache = new Map();
const strictFsContext = new AsyncLocalStorage();
let strictFsHooksInstalled = false;

function readFunctionConfig(modulePath) {
  try {
    const cfgPath = path.join(path.dirname(modulePath), "fn.config.json");
    if (!fs.existsSync(cfgPath)) {
      return {};
    }
    const parsed = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return {};
    }
    return parsed;
  } catch (_) {
    return {};
  }
}

function resolveHandlerName(fnConfig) {
  const invoke = fnConfig && typeof fnConfig === "object" ? fnConfig.invoke : null;
  const raw = invoke && typeof invoke === "object" ? invoke.handler : null;
  if (typeof raw !== "string") {
    return "handler";
  }
  const name = raw.trim();
  if (!name) {
    return "handler";
  }
  if (!HANDLER_RE.test(name)) {
    throw new Error("invoke.handler must be a valid identifier");
  }
  return name;
}

function extractSharedDeps(fnConfig) {
  const raw = fnConfig && typeof fnConfig === "object" ? fnConfig.shared_deps : null;
  if (!Array.isArray(raw)) {
    return [];
  }
  const out = [];
  const seen = new Set();
  for (const item of raw) {
    if (typeof item !== "string") {
      continue;
    }
    const name = item.trim();
    if (!name || !NAME_RE.test(name) || seen.has(name)) {
      continue;
    }
    seen.add(name);
    out.push(name);
  }
  return out;
}

function readFunctionEnv(modulePath) {
  try {
    const cfgPath = path.join(path.dirname(modulePath), "fn.env.json");
    if (!fs.existsSync(cfgPath)) {
      return {};
    }
    const parsed = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return {};
    }
    const out = {};
    for (const [k, v] of Object.entries(parsed)) {
      if (typeof k !== "string") {
        continue;
      }
      if (v && typeof v === "object" && !Array.isArray(v) && Object.prototype.hasOwnProperty.call(v, "value")) {
        const value = v.value;
        if (value === null || value === undefined) {
          continue;
        }
        out[k] = String(value);
        continue;
      }
      if (v === null || v === undefined) {
        continue;
      }
      out[k] = String(v);
    }
    return out;
  } catch (_) {
    // Never fail invocation because env file is missing/denied/corrupt.
    return {};
  }
}

function ensureNodeDependencies(modulePath) {
  if (!AUTO_NODE_DEPS) {
    return;
  }

  const fnDir = path.dirname(modulePath);
  ensureNodeDependenciesInDir(fnDir);
}

function ensureNodeDependenciesInDir(fnDir) {
  if (!AUTO_NODE_DEPS) {
    return;
  }

  const packageJson = path.join(fnDir, "package.json");
  if (!fs.existsSync(packageJson)) {
    return;
  }

  let parsedPkg;
  try {
    parsedPkg = JSON.parse(fs.readFileSync(packageJson, "utf8"));
  } catch (_) {
    parsedPkg = {};
  }
  const depsCount = Object.keys((parsedPkg && parsedPkg.dependencies) || {}).length;
  const optDepsCount = Object.keys((parsedPkg && parsedPkg.optionalDependencies) || {}).length;
  if (depsCount === 0 && optDepsCount === 0) {
    depsCache.set(fnDir, "no-deps");
    return;
  }

  const lockFile = fs.existsSync(path.join(fnDir, "package-lock.json"))
    ? path.join(fnDir, "package-lock.json")
    : (fs.existsSync(path.join(fnDir, "npm-shrinkwrap.json")) ? path.join(fnDir, "npm-shrinkwrap.json") : null);
  const nodeModulesDir = path.join(fnDir, "node_modules");

  const sig = `${fs.statSync(packageJson).mtimeMs}:${lockFile ? fs.statSync(lockFile).mtimeMs : "no-lock"}`;
  if (depsCache.get(fnDir) === sig) {
    if (fs.existsSync(nodeModulesDir)) {
      return;
    }
    depsCache.delete(fnDir);
  }

  const args = lockFile
    ? ["ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"]
    : ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"];

  const runNpm = (npmArgs) => childProcess.spawnSync("npm", npmArgs, {
    cwd: fnDir,
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 180000,
    encoding: "utf8",
  });

  let installResult;
  try {
    installResult = runNpm(args);
  } catch (err) {
    depsCache.delete(fnDir);
    throw new Error(`npm install failed for ${fnDir}: ${String(err && err.message ? err.message : err)}`);
  }

  // If npm ci fails (lock drift/corruption), fallback once to npm install.
  if (installResult.error || installResult.status !== 0) {
    if (lockFile) {
      try {
        installResult = runNpm(["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"]);
      } catch (err) {
        depsCache.delete(fnDir);
        throw new Error(`npm install failed for ${fnDir}: ${String(err && err.message ? err.message : err)}`);
      }
    }
  }

  if (installResult.error || installResult.status !== 0) {
    depsCache.delete(fnDir);
    const stderr = String(installResult.stderr || "").trim();
    const tail = stderr ? stderr.split("\n").slice(-4).join(" | ") : "unknown error";
    throw new Error(`npm dependencies install failed for ${fnDir}: ${tail}`);
  }

  depsCache.set(fnDir, sig);
}

function ensurePackDependencies(packDir) {
  if (!AUTO_NODE_DEPS) {
    return;
  }

  const packageJson = path.join(packDir, "package.json");
  if (!fs.existsSync(packageJson)) {
    return;
  }

  const lockFile = fs.existsSync(path.join(packDir, "package-lock.json"))
    ? path.join(packDir, "package-lock.json")
    : (fs.existsSync(path.join(packDir, "npm-shrinkwrap.json")) ? path.join(packDir, "npm-shrinkwrap.json") : null);

  const sig = `${fs.statSync(packageJson).mtimeMs}:${lockFile ? fs.statSync(lockFile).mtimeMs : "no-lock"}`;
  if (packDepsCache.get(packDir) === sig) {
    if (fs.existsSync(path.join(packDir, "node_modules"))) {
      return;
    }
    packDepsCache.delete(packDir);
  }

  ensureNodeDependenciesInDir(packDir);
  packDepsCache.set(packDir, sig);
}

function errorResponse(message, status = 500) {
  return {
    status,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ error: String(message) }),
  };
}

function normalizeResponse(resp) {
  if (!resp || typeof resp !== "object") {
    throw new Error("handler response must be an object");
  }

  let statusKey = "status";
  if (resp.statusCode !== undefined && resp.status === undefined) {
    statusKey = "statusCode";
  }
  const headersKey = "headers";
  const bodyKey = "body";

  let isBase64Key = "is_base64";
  let bodyBase64Key = "body_base64";
  if (resp.isBase64Encoded !== undefined && resp.is_base64 === undefined) {
    isBase64Key = "isBase64Encoded";
    bodyBase64Key = "body";
  }

  const status = Number(resp[statusKey] ?? 200);
  if (!Number.isInteger(status) || status < 100 || status > 599) {
    throw new Error("status must be a valid HTTP code");
  }

  const headers = resp[headersKey] ?? {};
  if (headers === null || typeof headers !== "object" || Array.isArray(headers)) {
    throw new Error("headers must be an object");
  }

  const isBase64 = resp[isBase64Key] === true;
  if (isBase64) {
    const b64 = resp[bodyBase64Key];
    if (typeof b64 !== "string" || b64.length === 0) {
      throw new Error("body_base64 must be a non-empty string when is_base64=true");
    }
    return { status, headers, is_base64: true, body_base64: b64 };
  }

  let body = resp[bodyKey] ?? "";
  if (typeof body !== "string") {
    body = String(body);
  }

  const proxy = (resp.proxy && typeof resp.proxy === "object" && !Array.isArray(resp.proxy)) ? resp.proxy : null;
  if (proxy) {
    return { status, headers, body, proxy };
  }

  return { status, headers, body };
}

function resolveHandlerSourcePath(fnName, version) {
  if (typeof fnName !== "string" || !NAME_RE.test(fnName)) {
    throw new Error("invalid function name");
  }

  let modulePath;
  if (version === undefined || version === null || version === "") {
    const appTs = path.join(FUNCTIONS_DIR, fnName, "app.ts");
    const appJs = path.join(FUNCTIONS_DIR, fnName, "app.js");
    const handlerTs = path.join(FUNCTIONS_DIR, fnName, "handler.ts");
    const handlerJs = path.join(FUNCTIONS_DIR, fnName, "handler.js");
    modulePath = fs.existsSync(appTs) ? appTs : (fs.existsSync(appJs) ? appJs : (fs.existsSync(handlerTs) ? handlerTs : handlerJs));
  } else {
    if (typeof version !== "string" || !VERSION_RE.test(version)) {
      throw new Error("invalid function version");
    }
    const appTs = path.join(FUNCTIONS_DIR, fnName, version, "app.ts");
    const appJs = path.join(FUNCTIONS_DIR, fnName, version, "app.js");
    const handlerTs = path.join(FUNCTIONS_DIR, fnName, version, "handler.ts");
    const handlerJs = path.join(FUNCTIONS_DIR, fnName, version, "handler.js");
    modulePath = fs.existsSync(appTs) ? appTs : (fs.existsSync(appJs) ? appJs : (fs.existsSync(handlerTs) ? handlerTs : handlerJs));
  }

  if (!fs.existsSync(modulePath)) {
    const err = new Error("unknown function");
    err.code = "ENOENT";
    throw err;
  }

  return modulePath;
}

function ensureTsBuild(sourcePath, extraNodeModulePaths) {
  if (!String(sourcePath).endsWith(".ts")) {
    return sourcePath;
  }
  const fnDir = path.dirname(sourcePath);
  const outDir = path.join(fnDir, ".fastfn", "build");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, path.basename(sourcePath).replace(/\.ts$/, ".js"));

  const pkgPath = path.join(fnDir, "package.json");
  const lockPath = fs.existsSync(path.join(fnDir, "package-lock.json"))
    ? path.join(fnDir, "package-lock.json")
    : (fs.existsSync(path.join(fnDir, "npm-shrinkwrap.json")) ? path.join(fnDir, "npm-shrinkwrap.json") : null);

  const srcStat = fs.statSync(sourcePath);
  const pkgSig = fs.existsSync(pkgPath) ? fs.statSync(pkgPath).mtimeMs : 0;
  const lockSig = lockPath ? fs.statSync(lockPath).mtimeMs : 0;
  const sig = `${srcStat.mtimeMs}:${pkgSig}:${lockSig}`;
  if (tsBuildCache.get(sourcePath) === sig && fs.existsSync(outPath)) {
    return outPath;
  }

  // esbuild must be available in either the function's node_modules or a shared pack.
  const bases = [fnDir];
  if (Array.isArray(extraNodeModulePaths)) {
    for (const nm of extraNodeModulePaths) {
      if (typeof nm === "string" && nm) {
        bases.push(path.dirname(nm));
      }
    }
  }
  let esbuild = null;
  for (const base of bases) {
    try {
      const req = Module.createRequire(path.join(base, "__fastfn_tsbuild__.js"));
      esbuild = req("esbuild");
      break;
    } catch (_) {
      // try next
    }
  }
  if (!esbuild) {
    throw new Error("TypeScript function requires esbuild. Add shared_deps: [\"ts_pack\"] or add esbuild to package.json.");
  }

  esbuild.buildSync({
    entryPoints: [sourcePath],
    outfile: outPath,
    platform: "node",
    format: "cjs",
    bundle: false,
    sourcemap: false,
    target: ["node18"],
  });

  tsBuildCache.set(sourcePath, sig);
  return outPath;
}

function collectHandlerPaths() {
  const out = [];
  if (!fs.existsSync(FUNCTIONS_DIR)) {
    return out;
  }

  const fnEntries = fs.readdirSync(FUNCTIONS_DIR, { withFileTypes: true });
  for (const fnEntry of fnEntries) {
    if (!fnEntry.isDirectory() || !NAME_RE.test(fnEntry.name)) {
      continue;
    }
    const fnDir = path.join(FUNCTIONS_DIR, fnEntry.name);
    const appDefaultTs = path.join(fnDir, "app.ts");
    const appDefault = path.join(fnDir, "app.js");
    const handlerDefaultTs = path.join(fnDir, "handler.ts");
    const handlerDefault = path.join(fnDir, "handler.js");
    if (fs.existsSync(appDefaultTs)) {
      out.push(appDefaultTs);
    } else if (fs.existsSync(appDefault)) {
      out.push(appDefault);
    } else if (fs.existsSync(handlerDefaultTs)) {
      out.push(handlerDefaultTs);
    } else if (fs.existsSync(handlerDefault)) {
      out.push(handlerDefault);
    }

    const maybeVersions = fs.readdirSync(fnDir, { withFileTypes: true });
    for (const verEntry of maybeVersions) {
      if (!verEntry.isDirectory() || !VERSION_RE.test(verEntry.name)) {
        continue;
      }
      const verDir = path.join(fnDir, verEntry.name);
      const appVersionTs = path.join(verDir, "app.ts");
      const appVersion = path.join(verDir, "app.js");
      const handlerVersionTs = path.join(verDir, "handler.ts");
      const handlerVersion = path.join(verDir, "handler.js");
      if (fs.existsSync(appVersionTs)) {
        out.push(appVersionTs);
      } else if (fs.existsSync(appVersion)) {
        out.push(appVersion);
      } else if (fs.existsSync(handlerVersionTs)) {
        out.push(handlerVersionTs);
      } else if (fs.existsSync(handlerVersion)) {
        out.push(handlerVersion);
      }
    }
  }

  return out;
}

function preinstallNodeDependenciesOnStart() {
  if (!PREINSTALL_NODE_DEPS_ON_START || !AUTO_NODE_DEPS) {
    return;
  }
  for (const modulePath of collectHandlerPaths()) {
    try {
      ensureNodeDependencies(modulePath);
    } catch (_) {
      // best effort
    }
  }
}

function parseExtraAllowRoots() {
  const out = [];
  for (const chunk of STRICT_FS_EXTRA_ALLOW.split(",")) {
    const trimmed = chunk.trim();
    if (!trimmed) {
      continue;
    }
    out.push(path.resolve(trimmed));
  }
  return out;
}

const STRICT_EXTRA_ROOTS = parseExtraAllowRoots();

function isUnderRoot(candidate, root) {
  if (candidate === root) {
    return true;
  }
  return candidate.startsWith(root.endsWith(path.sep) ? root : root + path.sep);
}

function buildStrictPolicy(modulePath, extraRoots) {
  const fnDir = path.resolve(path.dirname(modulePath));
  const allowedRoots = [
    fnDir,
    path.resolve(path.join(fnDir, ".deps")),
    path.resolve(path.join(fnDir, "node_modules")),
    ...STRICT_SYSTEM_ROOTS.map((x) => path.resolve(x)),
    ...STRICT_EXTRA_ROOTS,
  ];
  if (Array.isArray(extraRoots)) {
    for (const root of extraRoots) {
      if (typeof root === "string" && root) {
        allowedRoots.push(path.resolve(root));
      }
    }
  }
  return { fnDir, allowedRoots };
}

function resolveCandidatePath(target) {
  if (typeof target !== "string") {
    return null;
  }
  if (!target) {
    return null;
  }
  return path.resolve(target);
}

function assertAllowedPath(policy, target) {
  const candidate = resolveCandidatePath(target);
  if (!candidate) {
    return;
  }
  const base = path.basename(candidate);
  if (PROTECTED_FN_FILES.has(base) && isUnderRoot(candidate, policy.fnDir)) {
    throw new Error(`access to protected function config/env file denied: ${candidate}`);
  }
  for (const root of policy.allowedRoots) {
    if (isUnderRoot(candidate, root)) {
      return;
    }
  }
  throw new Error(`path outside strict function sandbox: ${candidate}`);
}

function strictFsError(policy, p) {
  try {
    assertAllowedPath(policy, p);
  } catch (err) {
    const e = new Error(err.message || "strict fs denied");
    e.code = "EACCES";
    return e;
  }
  return null;
}

function activeStrictPolicy() {
  return strictFsContext.getStore() || null;
}

function strictFsErrorActive(pathArg) {
  const policy = activeStrictPolicy();
  if (!policy) {
    return null;
  }
  return strictFsError(policy, pathArg);
}

function markPatched(fn) {
  Object.defineProperty(fn, "__fnStrictPatched", {
    value: true,
    enumerable: false,
    configurable: false,
    writable: false,
  });
}

function patchMethodOnce(obj, name, patchFactory) {
  if (!obj || typeof obj[name] !== "function") {
    return;
  }
  const current = obj[name];
  if (current.__fnStrictPatched) {
    return;
  }
  const patched = patchFactory(current);
  markPatched(patched);
  obj[name] = patched;
}

function installStrictFsHooks() {
  if (strictFsHooksInstalled) {
    return;
  }
  strictFsHooksInstalled = true;

  const syncFns = [
    "readFileSync",
    "writeFileSync",
    "appendFileSync",
    "openSync",
    "statSync",
    "lstatSync",
    "readdirSync",
    "accessSync",
    "unlinkSync",
    "rmSync",
    "createReadStream",
    "createWriteStream",
    "existsSync",
  ];
  for (const name of syncFns) {
    patchMethodOnce(fs, name, (original) => function patched(...args) {
      const err = strictFsErrorActive(args[0]);
      if (err) {
        throw err;
      }
      return original.apply(this, args);
    });
  }

  const callbackFns = [
    "readFile",
    "writeFile",
    "appendFile",
    "open",
    "stat",
    "lstat",
    "readdir",
    "access",
    "unlink",
    "rm",
  ];
  for (const name of callbackFns) {
    patchMethodOnce(fs, name, (original) => function patched(...args) {
      const err = strictFsErrorActive(args[0]);
      if (err) {
        const cb = args.find((x) => typeof x === "function");
        if (cb) {
          cb(err);
          return;
        }
        throw err;
      }
      return original.apply(this, args);
    });
  }

  if (fs.promises) {
    const promiseFns = [
      "readFile",
      "writeFile",
      "appendFile",
      "open",
      "stat",
      "lstat",
      "readdir",
      "access",
      "unlink",
      "rm",
    ];
    for (const name of promiseFns) {
      patchMethodOnce(fs.promises, name, (original) => function patched(...args) {
        const err = strictFsErrorActive(args[0]);
        if (err) {
          return Promise.reject(err);
        }
        return original.apply(this, args);
      });
    }
  }

  const cpMethods = ["exec", "execFile", "fork", "spawn", "spawnSync", "execSync", "execFileSync"];
  for (const name of cpMethods) {
    patchMethodOnce(childProcess, name, (original) => function patched(...args) {
      if (activeStrictPolicy()) {
        const err = new Error("subprocess disabled by strict function sandbox");
        err.code = "EACCES";
        throw err;
      }
      return original.apply(this, args);
    });
  }
}

function withStrictFs(modulePath, extraRoots, work) {
  if (!STRICT_FS) {
    return work();
  }
  installStrictFsHooks();
  const policy = buildStrictPolicy(modulePath, extraRoots);
  return strictFsContext.run(policy, () => work());
}

function loadHandler(modulePath, extraNodeModulePaths, handlerName) {
  const stat = fs.statSync(modulePath);
  const mtimeMs = stat.mtimeMs;
  const extraSig = Array.isArray(extraNodeModulePaths) && extraNodeModulePaths.length > 0
    ? extraNodeModulePaths.map((p) => String(p)).sort().join(";")
    : "";
  const cacheKey = `${modulePath}::${extraSig}::${String(handlerName || "handler")}`;

  if (handlerCache.has(cacheKey)) {
    const cached = handlerCache.get(cacheKey);
    if (!HOT_RELOAD || cached.mtimeMs === mtimeMs) {
      return cached.handler;
    }
  }

  const resolved = require.resolve(modulePath);
  delete require.cache[resolved];

  let mod;
  if (Array.isArray(extraNodeModulePaths) && extraNodeModulePaths.length > 0) {
    const m = new Module(resolved, module);
    m.filename = resolved;
    m.paths = [...extraNodeModulePaths, ...Module._nodeModulePaths(path.dirname(resolved))];
    m.load(resolved);
    mod = m.exports;
  } else {
    mod = require(resolved);
  }
  const fn = mod && mod[handlerName];
  if (typeof fn !== "function") {
    throw new Error(`${handlerName}(event) is required`);
  }

  handlerCache.set(cacheKey, {
    handler: fn,
    mtimeMs,
  });

  return mod.handler;
}

function sendFrame(socket, obj) {
  const payload = Buffer.from(JSON.stringify(obj));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  socket.write(Buffer.concat([header, payload]));
}

async function handleRequest(req) {
  if (!req || typeof req !== "object" || Array.isArray(req)) {
    throw new Error("request must be an object");
  }

  const fnName = req.fn;
  if (typeof fnName !== "string" || !fnName) {
    throw new Error("fn is required");
  }

  const event = req.event ?? {};
  if (event === null || typeof event !== "object" || Array.isArray(event)) {
    throw new Error("event must be an object");
  }

  const sourcePath = resolveHandlerSourcePath(fnName, req.version);
  const fnConfig = readFunctionConfig(sourcePath);
  const handlerName = resolveHandlerName(fnConfig);
  const sharedDeps = extractSharedDeps(fnConfig);
  const extraRoots = [];
  const extraNodeModules = [];
  for (const packName of sharedDeps) {
    const packDir = path.resolve(path.join(PACKS_DIR, packName));
    if (!fs.existsSync(packDir) || !fs.statSync(packDir).isDirectory()) {
      throw new Error(`shared pack not found: ${packName}`);
    }
    ensurePackDependencies(packDir);
    const nm = path.resolve(path.join(packDir, "node_modules"));
    if (fs.existsSync(nm) && fs.statSync(nm).isDirectory()) {
      extraRoots.push(nm);
      extraNodeModules.push(nm);
    }
  }
  const fnEnv = readFunctionEnv(sourcePath);
  ensureNodeDependencies(sourcePath);
  const execPath = ensureTsBuild(sourcePath, extraNodeModules);
  const handler = loadHandler(execPath, extraNodeModules, handlerName);
  const eventWithEnv = { ...event };
  if (fnEnv && Object.keys(fnEnv).length > 0) {
    eventWithEnv.env = { ...(eventWithEnv.env || {}), ...fnEnv };
  }
  const response = await withStrictFs(sourcePath, extraRoots, () => handler(eventWithEnv));
  return normalizeResponse(response);
}

function ensureSocketDir(socketPath) {
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
}

function parseFrames(socket, onFrame) {
  let buffer = Buffer.alloc(0);

  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);

    while (buffer.length >= 4) {
      const length = buffer.readUInt32BE(0);
      if (length <= 0 || length > MAX_FRAME_BYTES) {
        sendFrame(socket, errorResponse("invalid frame length", 400));
        socket.end();
        return;
      }

      if (buffer.length < 4 + length) {
        break;
      }

      const payload = buffer.subarray(4, 4 + length);
      buffer = buffer.subarray(4 + length);

      let req;
      try {
        req = JSON.parse(payload.toString("utf8"));
      } catch {
        sendFrame(socket, errorResponse("invalid json request", 400));
        socket.end();
        return;
      }

      Promise.resolve(onFrame(req))
        .then((resp) => {
          if (resp && typeof resp.status === "number" && resp.status >= 400) {
            let body = "";
            if (typeof resp.body === "string") {
              body = resp.body.length > 800 ? `${resp.body.slice(0, 800)}...<truncated>` : resp.body;
            }
            console.error(
              JSON.stringify({
                t: new Date().toISOString(),
                component: "node_daemon",
                event: "handler_non_2xx",
                fn: req && req.fn,
                version: req && req.version ? req.version : "default",
                status: resp.status,
                body,
              })
            );
          }
          sendFrame(socket, resp);
          socket.end();
        })
        .catch((err) => {
          const msg = err && err.message ? err.message : String(err);
          const status = err && err.code === "ENOENT" ? 404 : 500;
          console.error(
            JSON.stringify({
              t: new Date().toISOString(),
              component: "node_daemon",
              event: "handler_exception",
              fn: req && req.fn,
              version: req && req.version ? req.version : "default",
              status,
              error: msg,
            })
          );
          sendFrame(socket, errorResponse(msg, status));
          socket.end();
        });
    }
  });
}

function main() {
  ensureSocketDir(SOCKET_PATH);
  preinstallNodeDependenciesOnStart();

  if (fs.existsSync(SOCKET_PATH)) {
    fs.unlinkSync(SOCKET_PATH);
  }

  const server = net.createServer((socket) => {
    parseFrames(socket, handleRequest);
  });

  server.listen(SOCKET_PATH, () => {
    fs.chmodSync(SOCKET_PATH, 0o666);
  });
}

main();

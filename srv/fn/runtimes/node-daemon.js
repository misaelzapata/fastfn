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
const PREINSTALL_NODE_DEPS_CONCURRENCY = Math.max(1, Number(process.env.FN_PREINSTALL_NODE_DEPS_CONCURRENCY || 4));
const STRICT_FS = !["0", "false", "off", "no"].includes(String(process.env.FN_STRICT_FS || "1").toLowerCase());
const STRICT_FS_EXTRA_ALLOW = String(process.env.FN_STRICT_FS_ALLOW || "");

const BASE_DIR = path.resolve(__dirname, "..");
const FUNCTIONS_DIR = process.env.FN_FUNCTIONS_ROOT || path.join(BASE_DIR, "functions", "node");
const RUNTIME_FUNCTIONS_DIR = path.join(FUNCTIONS_DIR, "node");

const PACKS_DIR = path.join(BASE_DIR, "functions", ".fastfn", "packs", "node");

const NAME_RE = /^[A-Za-z0-9._/\-\[\]]+$/;
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
const ENABLE_RUNTIME_PROCESS_POOL = !["0", "false", "off", "no"].includes(String(process.env.FN_NODE_RUNTIME_PROCESS_POOL || "1").toLowerCase());
const RUNTIME_POOL_ACQUIRE_TIMEOUT_MS = Number(process.env.FN_NODE_POOL_ACQUIRE_TIMEOUT_MS || 5000);
const RUNTIME_POOL_IDLE_TTL_MS = Number(process.env.FN_NODE_POOL_IDLE_TTL_MS || 300000);
const RUNTIME_POOL_REAPER_INTERVAL_MS = Number(process.env.FN_NODE_POOL_REAPER_INTERVAL_MS || 2000);
const WORKER_CHILD_SCRIPT = path.join(__dirname, "node-function-worker.js");
const runtimeProcessPools = new Map();
let runtimePoolReaperTimer = null;
let runtimeWorkerRequestSeq = 0;
const preinstallState = {
  running: false,
  done: false,
  hadError: false,
  startedAtMs: 0,
  finishedAtMs: 0,
};

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

function isFunctionStrictFsEnabled(fnConfig) {
  if (!STRICT_FS) {
    return false;
  }
  if (!fnConfig || typeof fnConfig !== "object" || Array.isArray(fnConfig)) {
    return true;
  }
  if (Object.prototype.hasOwnProperty.call(fnConfig, "strict_fs")) {
    return fnConfig.strict_fs !== false;
  }
  return true;
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

function hasInstallableDependencies(fnDir) {
  const packageJson = path.join(fnDir, "package.json");
  if (!fs.existsSync(packageJson)) {
    return false;
  }
  let parsedPkg;
  try {
    parsedPkg = JSON.parse(fs.readFileSync(packageJson, "utf8"));
  } catch (_) {
    parsedPkg = {};
  }
  const depsCount = Object.keys((parsedPkg && parsedPkg.dependencies) || {}).length;
  const optDepsCount = Object.keys((parsedPkg && parsedPkg.optionalDependencies) || {}).length;
  return depsCount > 0 || optDepsCount > 0;
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
  if (!hasInstallableDependencies(fnDir)) {
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

function runNpmAsync(fnDir, npmArgs, timeoutMs = 180000) {
  return new Promise((resolve) => {
    let stderr = "";
    let timedOut = false;
    const child = childProcess.spawn("npm", npmArgs, {
      cwd: fnDir,
      stdio: ["ignore", "ignore", "pipe"],
    });

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, timeoutMs);

    if (child.stderr) {
      child.stderr.on("data", (chunk) => {
        stderr += String(chunk || "");
        if (stderr.length > 24000) {
          stderr = stderr.slice(-24000);
        }
      });
    }

    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({
        error,
        status: null,
        stderr,
      });
    });

    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (timedOut) {
        resolve({
          error: new Error("npm install timed out"),
          status: null,
          stderr,
        });
        return;
      }
      if (signal) {
        resolve({
          error: new Error(`npm install terminated by signal ${signal}`),
          status: null,
          stderr,
        });
        return;
      }
      resolve({
        status: code,
        stderr,
      });
    });
  });
}

async function ensureNodeDependenciesInDirAsync(fnDir) {
  if (!AUTO_NODE_DEPS) {
    return;
  }

  const packageJson = path.join(fnDir, "package.json");
  if (!fs.existsSync(packageJson)) {
    return;
  }
  if (!hasInstallableDependencies(fnDir)) {
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

  let installResult = await runNpmAsync(fnDir, args, 180000);

  // If npm ci fails (lock drift/corruption), fallback once to npm install.
  if ((installResult.error || installResult.status !== 0) && lockFile) {
    installResult = await runNpmAsync(fnDir, ["install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"], 180000);
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

const RESPONSE_CONTRACT_KEYS = new Set([
  "status",
  "statusCode",
  "headers",
  "body",
  "is_base64",
  "isBase64Encoded",
  "body_base64",
  "proxy",
]);

function hasResponseContractShape(obj) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) {
    return false;
  }
  for (const key of RESPONSE_CONTRACT_KEYS) {
    if (Object.prototype.hasOwnProperty.call(obj, key)) {
      return true;
    }
  }
  return false;
}

function hasHeader(headers, name) {
  const target = String(name || "").toLowerCase();
  return Object.keys(headers || {}).some((k) => String(k).toLowerCase() === target);
}

function getHeaderValue(headers, name) {
  const target = String(name || "").toLowerCase();
  for (const key of Object.keys(headers || {})) {
    if (String(key).toLowerCase() === target) {
      return String(headers[key]);
    }
  }
  return "";
}

function withDefaultHeader(headers, name, value) {
  const out = { ...(headers || {}) };
  if (!hasHeader(out, name)) {
    out[name] = value;
  }
  return out;
}

function isCsvContentType(headers) {
  return getHeaderValue(headers, "Content-Type").toLowerCase().includes("text/csv");
}

function expectsBinaryContentType(headers) {
  const contentType = getHeaderValue(headers, "Content-Type").toLowerCase().trim();
  if (!contentType) {
    return false;
  }
  if (contentType.startsWith("text/")) {
    return false;
  }
  if (
    contentType.includes("json") ||
    contentType.includes("xml") ||
    contentType.includes("javascript") ||
    contentType.includes("x-www-form-urlencoded")
  ) {
    return false;
  }
  return true;
}

function looksLikeHtml(text) {
  const trimmed = String(text || "").trim().toLowerCase();
  return (
    trimmed.startsWith("<!doctype html") ||
    trimmed.startsWith("<html") ||
    trimmed.includes("<body") ||
    trimmed.includes("</html>")
  );
}

function csvEscapeCell(value) {
  let s = "";
  if (value === null || value === undefined) {
    s = "";
  } else if (typeof value === "object") {
    s = JSON.stringify(value);
  } else {
    s = String(value);
  }
  if (s.includes('"')) {
    s = s.replace(/"/g, '""');
  }
  if (s.includes(",") || s.includes("\n") || s.includes("\r") || s.includes('"')) {
    return `"${s}"`;
  }
  return s;
}

function toCsv(value) {
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return "";
    }
    if (Array.isArray(value[0])) {
      return value.map((row) => row.map(csvEscapeCell).join(",")).join("\n");
    }
    if (value.every((row) => row && typeof row === "object" && !Array.isArray(row))) {
      const keys = Object.keys(value[0]);
      const lines = [keys.map(csvEscapeCell).join(",")];
      for (const row of value) {
        lines.push(keys.map((k) => csvEscapeCell(row[k])).join(","));
      }
      return lines.join("\n");
    }
    return value.map((row) => csvEscapeCell(row)).join("\n");
  }

  if (value && typeof value === "object") {
    const keys = Object.keys(value);
    if (keys.length === 0) {
      return "";
    }
    return `${keys.map(csvEscapeCell).join(",")}\n${keys.map((k) => csvEscapeCell(value[k])).join(",")}`;
  }

  return csvEscapeCell(value);
}

function normalizeMagicResponse(value, status = 200, headers = {}) {
  if (value === undefined || value === null) {
    return { status, headers, body: "" };
  }

  if (Buffer.isBuffer(value) || value instanceof Uint8Array) {
    return {
      status,
      headers: withDefaultHeader(headers, "Content-Type", "application/octet-stream"),
      is_base64: true,
      body_base64: Buffer.from(value).toString("base64"),
    };
  }

  if (typeof value === "object") {
    if (isCsvContentType(headers)) {
      return {
        status,
        headers: withDefaultHeader(headers, "Content-Type", "text/csv; charset=utf-8"),
        body: toCsv(value),
      };
    }
    return {
      status,
      headers: withDefaultHeader(headers, "Content-Type", "application/json"),
      body: JSON.stringify(value),
    };
  }

  if (typeof value === "string") {
    if (value === "") {
      return { status, headers, body: "" };
    }
    const inferredType = looksLikeHtml(value) ? "text/html; charset=utf-8" : "text/plain; charset=utf-8";
    return {
      status,
      headers: withDefaultHeader(headers, "Content-Type", inferredType),
      body: value,
    };
  }

  return {
    status,
    headers: withDefaultHeader(headers, "Content-Type", "text/plain; charset=utf-8"),
    body: String(value),
  };
}

function normalizeResponse(resp) {
  if (!resp || typeof resp !== "object") {
    return normalizeMagicResponse(resp);
  }

  if (!hasResponseContractShape(resp)) {
    return normalizeMagicResponse(resp);
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

  const headersRaw = resp[headersKey] ?? {};
  const headers = { ...headersRaw };
  if (headers === null || typeof headers !== "object" || Array.isArray(headers)) {
    throw new Error("headers must be an object");
  }

  const isBase64 = resp[isBase64Key] === true;
  if (isBase64) {
    let b64 = resp[bodyBase64Key];
    if (Buffer.isBuffer(b64) || b64 instanceof Uint8Array) {
      b64 = Buffer.from(b64).toString("base64");
    }
    if (typeof b64 !== "string" || b64.length === 0) {
      throw new Error("body_base64 must be a non-empty string when is_base64=true");
    }
    return { status, headers, is_base64: true, body_base64: b64 };
  }

  let body = resp[bodyKey];
  if (Buffer.isBuffer(body) || body instanceof Uint8Array) {
    return {
      status,
      headers: withDefaultHeader(headers, "Content-Type", "application/octet-stream"),
      is_base64: true,
      body_base64: Buffer.from(body).toString("base64"),
    };
  }
  if (body === undefined || body === null) {
    body = "";
  } else if (typeof body === "object") {
    if (isCsvContentType(headers)) {
      body = toCsv(body);
      headers["Content-Type"] = getHeaderValue(headers, "Content-Type") || "text/csv; charset=utf-8";
    } else {
      body = JSON.stringify(body);
      if (body === undefined) {
        body = "";
      }
      if (body !== "") {
        headers["Content-Type"] = getHeaderValue(headers, "Content-Type") || "application/json";
      }
    }
  } else if (typeof body !== "string") {
    body = String(body);
  }

  if (body !== "" && expectsBinaryContentType(headers)) {
    return {
      status,
      headers: withDefaultHeader(headers, "Content-Type", "application/octet-stream"),
      is_base64: true,
      body_base64: Buffer.from(body).toString("base64"),
    };
  }

  const proxy = (resp.proxy && typeof resp.proxy === "object" && !Array.isArray(resp.proxy)) ? resp.proxy : null;
  if (proxy) {
    return { status, headers, body, proxy };
  }

  return { status, headers, body };
}

function resolveHandlerSourcePath(fnName, version) {
  if (typeof fnName !== "string" || fnName.trim() === "") {
    throw new Error(`invalid function name: ${JSON.stringify(fnName)}`);
  }
  const normalizedName = String(fnName).replace(/\\/g, "/");
  if (
    normalizedName.startsWith("/") ||
    normalizedName === ".." ||
    normalizedName.startsWith("../") ||
    normalizedName.endsWith("/..") ||
    normalizedName.includes("/../")
  ) {
    throw new Error(`invalid function name: ${JSON.stringify(fnName)}`);
  }

  // New Logic: Check direct file paths for Zero-Config / fn.routes.json
  // e.g. fnName="handlers/list.js", version=null
  if (!version) {
     const directCheck = path.join(FUNCTIONS_DIR, fnName);
     try {
       if (fs.existsSync(directCheck) && fs.statSync(directCheck).isFile()) {
           return directCheck;
       }
     } catch (e) {}

     const runtimeCheck = path.join(RUNTIME_FUNCTIONS_DIR, fnName);
     try {
        if (fs.existsSync(runtimeCheck) && fs.statSync(runtimeCheck).isFile()) {
            return runtimeCheck;
        }
      } catch (e) {}
  }

  let baseDir = version
    ? path.join(FUNCTIONS_DIR, fnName, version)
    : path.join(FUNCTIONS_DIR, fnName);

  // Fallback to runtime-scoped layout: <functions_root>/node/<fnName>/<version?>
  if (!fs.existsSync(baseDir)) {
    const runtimeBase = version
      ? path.join(RUNTIME_FUNCTIONS_DIR, fnName, version)
      : path.join(RUNTIME_FUNCTIONS_DIR, fnName);
    if (fs.existsSync(runtimeBase)) {
      baseDir = runtimeBase;
    }
  }

  // 1. Check fn.config.json for explicit entrypoint
  const configPath = path.join(baseDir, "fn.config.json");
  if (fs.existsSync(configPath)) {
    try {
      const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
      if (config.entrypoint && typeof config.entrypoint === "string") {
        const explicitPath = path.join(baseDir, config.entrypoint);
        if (fs.existsSync(explicitPath)) {
          return explicitPath;
        }
      }
    } catch (e) {
      // ignore config errors
    }
  }

  const candidates = [];
  // Discovery Order: app -> handler -> index, TS before JS
  const names = ["app.ts", "app.js", "handler.ts", "handler.js", "index.ts", "index.js"];
  
  for (const name of names) {
    candidates.push(path.join(baseDir, name));
  }

  let modulePath = null;
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      modulePath = candidate;
      break;
    }
  }

  if (!modulePath) {
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

function collectDependencyDirs() {
  const out = [];
  const seen = new Set();
  for (const modulePath of collectHandlerPaths()) {
    const fnDir = path.dirname(modulePath);
    if (seen.has(fnDir)) {
      continue;
    }
    seen.add(fnDir);
    if (!hasInstallableDependencies(fnDir)) {
      continue;
    }
    out.push(fnDir);
  }
  return out;
}

function preinstallNodeDependenciesOnStart() {
  if (!PREINSTALL_NODE_DEPS_ON_START || !AUTO_NODE_DEPS) {
    return;
  }
  if (preinstallState.running || preinstallState.done) {
    return;
  }
  preinstallState.running = true;
  preinstallState.startedAtMs = Date.now();
  setImmediate(async () => {
    const dependencyDirs = collectDependencyDirs();
    if (dependencyDirs.length === 0) {
      preinstallState.running = false;
      preinstallState.done = true;
      preinstallState.finishedAtMs = Date.now();
      return;
    }
    console.log(JSON.stringify({
      t: new Date().toISOString(),
      component: "node_daemon",
      event: "deps_preinstall_start",
      functions: dependencyDirs.length,
      concurrency: PREINSTALL_NODE_DEPS_CONCURRENCY,
    }));

    const queue = dependencyDirs.slice();
    const workerCount = Math.min(PREINSTALL_NODE_DEPS_CONCURRENCY, queue.length || 1);
    const workers = Array.from({ length: workerCount }, async () => {
      while (queue.length > 0) {
        const fnDir = queue.shift();
        if (!fnDir) {
          return;
        }
        try {
          await ensureNodeDependenciesInDirAsync(fnDir);
        } catch (_) {
          preinstallState.hadError = true;
        }
      }
    });

    try {
      await Promise.all(workers);
    } finally {
      preinstallState.running = false;
      preinstallState.done = true;
      preinstallState.finishedAtMs = Date.now();
      console.log(JSON.stringify({
        t: new Date().toISOString(),
        component: "node_daemon",
        event: "deps_preinstall_done",
        duration_ms: preinstallState.finishedAtMs - preinstallState.startedAtMs,
        had_error: preinstallState.hadError,
      }));
    }
  });
}

function isNodeDependencyPreparationPending(modulePath) {
  if (!PREINSTALL_NODE_DEPS_ON_START || !AUTO_NODE_DEPS) {
    return false;
  }
  if (!preinstallState.running) {
    return false;
  }
  const fnDir = path.dirname(modulePath);
  if (!hasInstallableDependencies(fnDir)) {
    return false;
  }
  return !fs.existsSync(path.join(fnDir, "node_modules"));
}

function preparingResponse() {
  return {
    status: 503,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Retry-After": "2",
    },
    body: "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width, initial-scale=1'><title>Preparing</title><style>body{margin:0;display:grid;place-items:center;min-height:100vh;font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif;background:linear-gradient(135deg,#0f172a,#1e293b);color:#e2e8f0}.card{padding:24px 28px;border-radius:14px;background:rgba(15,23,42,.55);border:1px solid rgba(148,163,184,.3)}h1{margin:0 0 8px;font-size:20px}p{margin:0;color:#cbd5e1}</style></head><body><div class='card'><h1>Preparing some awesomess</h1><p>Node dependencies are being installed in background. Refresh in a few seconds.</p></div></body></html>",
  };
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

  return fn;
}

function isBenignSocketError(err) {
  if (!err || typeof err !== "object") return false;
  return err.code === "EPIPE" || err.code === "ECONNRESET";
}

function sendFrame(socket, obj) {
  if (!socket || socket.destroyed || socket.writableEnded) {
    return false;
  }
  const payload = Buffer.from(JSON.stringify(obj));
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  try {
    socket.write(Buffer.concat([header, payload]), (err) => {
      if (err && !isBenignSocketError(err)) {
        console.error(
          JSON.stringify({
            t: new Date().toISOString(),
            component: "node_daemon",
            event: "socket_write_error",
            error: String(err.message || err),
            code: err.code || null,
          })
        );
      }
    });
    return true;
  } catch (err) {
    if (!isBenignSocketError(err)) {
      console.error(
        JSON.stringify({
          t: new Date().toISOString(),
          component: "node_daemon",
          event: "socket_write_exception",
          error: String(err && err.message ? err.message : err),
          code: err && err.code ? err.code : null,
        })
      );
    }
    return false;
  }
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
  if (isNodeDependencyPreparationPending(sourcePath)) {
    return preparingResponse();
  }
  const fnConfig = readFunctionConfig(sourcePath);
  const strictFsEnabled = isFunctionStrictFsEnabled(fnConfig);
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
  const response = strictFsEnabled
    ? await withStrictFs(sourcePath, extraRoots, () => handler(eventWithEnv))
    : await handler(eventWithEnv);
  return normalizeResponse(response);
}

function runtimePoolKey(fnName, version) {
  const v = version && String(version).trim() !== "" ? String(version) : "default";
  return `${String(fnName)}@${v}`;
}

function normalizeWorkerPoolSettings(req) {
  const context = (((req || {}).event || {}).context || {});
  const raw = context.worker_pool && typeof context.worker_pool === "object" ? context.worker_pool : {};
  const enabled = raw.enabled === true;
  const maxWorkers = Math.max(0, Number(raw.max_workers || 0) | 0);
  const minWarm = Math.max(0, Number(raw.min_warm || 0) | 0);
  const idleTtlMs = Math.max(1000, Math.floor((Number(raw.idle_ttl_seconds || 0) || 0) * 1000) || RUNTIME_POOL_IDLE_TTL_MS);
  const requestTimeoutMs = Math.max(100, Number(context.timeout_ms || 0) | 0);
  const acquireTimeoutMs = Math.max(
    100,
    Math.min(
      requestTimeoutMs > 0 ? requestTimeoutMs + 500 : RUNTIME_POOL_ACQUIRE_TIMEOUT_MS,
      RUNTIME_POOL_ACQUIRE_TIMEOUT_MS
    )
  );

  return {
    enabled,
    maxWorkers,
    minWarm,
    idleTtlMs,
    requestTimeoutMs,
    acquireTimeoutMs,
  };
}

function startRuntimePoolReaper() {
  if (runtimePoolReaperTimer || RUNTIME_POOL_REAPER_INTERVAL_MS <= 0) {
    return;
  }
  runtimePoolReaperTimer = setInterval(() => {
    const now = Date.now();
    for (const [key, pool] of runtimeProcessPools.entries()) {
      if (!pool || !Array.isArray(pool.workers)) {
        runtimeProcessPools.delete(key);
        continue;
      }

      const keep = Math.max(0, Math.min(pool.minWarm || 0, pool.maxWorkers || 0));
      let idleCount = pool.workers.filter((w) => !w.busy).length;
      for (const worker of [...pool.workers]) {
        if (worker.busy) {
          continue;
        }
        const idleFor = now - (worker.lastUsedAt || now);
        if (idleCount <= keep) {
          break;
        }
        if (idleFor < (pool.idleTtlMs || RUNTIME_POOL_IDLE_TTL_MS)) {
          continue;
        }
        idleCount -= 1;
        try {
          worker.proc.kill("SIGTERM");
        } catch (_) {
          // ignore
        }
      }

      if (pool.workers.length === 0 && (!pool.waiters || pool.waiters.length === 0)) {
        runtimeProcessPools.delete(key);
      }
    }
  }, Math.max(500, RUNTIME_POOL_REAPER_INTERVAL_MS));
  if (runtimePoolReaperTimer && typeof runtimePoolReaperTimer.unref === "function") {
    runtimePoolReaperTimer.unref();
  }
}

function ensureRuntimeProcessPool(poolKey, settings) {
  let pool = runtimeProcessPools.get(poolKey);
  if (!pool) {
    pool = {
      key: poolKey,
      maxWorkers: settings.maxWorkers,
      minWarm: settings.minWarm,
      idleTtlMs: settings.idleTtlMs,
      workers: [],
      waiters: [],
    };
    runtimeProcessPools.set(poolKey, pool);
  } else {
    pool.maxWorkers = settings.maxWorkers;
    pool.minWarm = settings.minWarm;
    pool.idleTtlMs = settings.idleTtlMs;
  }
  startRuntimePoolReaper();
  return pool;
}

function settleRuntimePoolWaiters(pool) {
  if (!pool || !Array.isArray(pool.waiters) || pool.waiters.length === 0) {
    return;
  }
  while (pool.waiters.length > 0) {
    const idle = pool.workers.find((w) => !w.busy);
    if (!idle) {
      break;
    }
    const waiter = pool.waiters.shift();
    if (!waiter || waiter.done) {
      continue;
    }
    waiter.done = true;
    clearTimeout(waiter.timer);
    idle.busy = true;
    waiter.resolve(idle);
  }
}

function removeRuntimeWorker(pool, worker) {
  if (!pool || !worker) {
    return;
  }
  const idx = pool.workers.indexOf(worker);
  if (idx >= 0) {
    pool.workers.splice(idx, 1);
  }
  if (worker.pending) {
    for (const [, pending] of worker.pending) {
      clearTimeout(pending.timer);
      pending.reject(new Error("worker process exited"));
    }
    worker.pending.clear();
  }
  settleRuntimePoolWaiters(pool);
}

function spawnRuntimeWorker(pool) {
  const proc = childProcess.fork(WORKER_CHILD_SCRIPT, [], {
    stdio: ["ignore", "inherit", "inherit", "ipc"],
    env: { ...process.env },
  });

  const worker = {
    proc,
    busy: false,
    lastUsedAt: Date.now(),
    pending: new Map(),
  };
  pool.workers.push(worker);

  proc.on("message", (msg) => {
    if (!msg || msg.type !== "invoke_result") {
      return;
    }
    const pending = worker.pending.get(msg.id);
    if (!pending) {
      return;
    }
    worker.pending.delete(msg.id);
    clearTimeout(pending.timer);
    worker.busy = false;
    worker.lastUsedAt = Date.now();
    settleRuntimePoolWaiters(pool);
    if (msg.ok === true) {
      pending.resolve(msg.response);
      return;
    }
    const err = new Error(msg.error || "worker invoke failed");
    if (msg.code) {
      err.code = msg.code;
    }
    if (Number.isInteger(msg.status)) {
      err.status = msg.status;
    }
    pending.reject(err);
  });

  proc.on("exit", () => {
    removeRuntimeWorker(pool, worker);
  });

  proc.on("error", () => {
    // exit handler performs cleanup/reject.
  });

  return worker;
}

function ensurePoolMinWarm(pool) {
  const keep = Math.max(0, Math.min(pool.minWarm || 0, pool.maxWorkers || 0));
  while (pool.workers.length < keep) {
    spawnRuntimeWorker(pool);
  }
}

function acquireRuntimeWorker(pool, timeoutMs) {
  const idle = pool.workers.find((w) => !w.busy);
  if (idle) {
    idle.busy = true;
    return Promise.resolve(idle);
  }

  if (pool.workers.length < Math.max(0, pool.maxWorkers || 0)) {
    const worker = spawnRuntimeWorker(pool);
    worker.busy = true;
    return Promise.resolve(worker);
  }

  return new Promise((resolve, reject) => {
    const waiter = { done: false, resolve, reject, timer: null };
    waiter.timer = setTimeout(() => {
      if (waiter.done) {
        return;
      }
      waiter.done = true;
      pool.waiters = pool.waiters.filter((w) => w !== waiter);
      const err = new Error("runtime worker acquire timeout");
      err.code = "ETIMEDOUT";
      err.status = 504;
      reject(err);
    }, Math.max(100, Number(timeoutMs) || 1000));
    pool.waiters.push(waiter);
  });
}

function invokeRuntimeWorker(pool, worker, req, timeoutMs) {
  return new Promise((resolve, reject) => {
    const id = `wrk-${Date.now()}-${++runtimeWorkerRequestSeq}`;
    const effectiveTimeout = Math.max(200, Number(timeoutMs) || 2000);
    const timer = setTimeout(() => {
      worker.pending.delete(id);
      worker.busy = false;
      worker.lastUsedAt = Date.now();
      settleRuntimePoolWaiters(pool);
      try {
        worker.proc.kill("SIGKILL");
      } catch (_) {
        // ignore
      }
      const err = new Error("worker invoke timeout");
      err.code = "ETIMEDOUT";
      err.status = 504;
      reject(err);
    }, effectiveTimeout + 250);

    worker.pending.set(id, { resolve, reject, timer });
    try {
      worker.proc.send({
        type: "invoke",
        id,
        request: req,
        timeout_ms: effectiveTimeout,
      });
    } catch (err) {
      clearTimeout(timer);
      worker.pending.delete(id);
      worker.busy = false;
      worker.lastUsedAt = Date.now();
      settleRuntimePoolWaiters(pool);
      reject(err);
    }
  });
}

async function handleRequestWithProcessPool(req) {
  const settings = normalizeWorkerPoolSettings(req);
  if (!ENABLE_RUNTIME_PROCESS_POOL || !settings.enabled || settings.maxWorkers <= 0) {
    return handleRequest(req);
  }

  const key = runtimePoolKey(req.fn, req.version);
  const pool = ensureRuntimeProcessPool(key, settings);
  ensurePoolMinWarm(pool);
  const worker = await acquireRuntimeWorker(pool, settings.acquireTimeoutMs);
  return invokeRuntimeWorker(pool, worker, req, settings.requestTimeoutMs);
}

function ensureSocketDir(socketPath) {
  fs.mkdirSync(path.dirname(socketPath), { recursive: true });
}

function parseFrames(socket, onFrame) {
  let buffer = Buffer.alloc(0);
  socket.on("error", (err) => {
    if (!isBenignSocketError(err)) {
      console.error(
        JSON.stringify({
          t: new Date().toISOString(),
          component: "node_daemon",
          event: "socket_error",
          error: String(err && err.message ? err.message : err),
          code: err && err.code ? err.code : null,
        })
      );
    }
  });

  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);

    while (buffer.length >= 4) {
      const length = buffer.readUInt32BE(0);
      if (length <= 0 || length > MAX_FRAME_BYTES) {
        if (sendFrame(socket, errorResponse("invalid frame length", 400))) {
          socket.end();
        } else {
          socket.destroy();
        }
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
        if (sendFrame(socket, errorResponse("invalid json request", 400))) {
          socket.end();
        } else {
          socket.destroy();
        }
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
          if (sendFrame(socket, resp)) {
            socket.end();
          } else {
            socket.destroy();
          }
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
          if (sendFrame(socket, errorResponse(msg, status))) {
            socket.end();
          } else {
            socket.destroy();
          }
        });
    }
  });
}

function main() {
  ensureSocketDir(SOCKET_PATH);

  if (fs.existsSync(SOCKET_PATH)) {
    fs.unlinkSync(SOCKET_PATH);
  }

  const server = net.createServer((socket) => {
    parseFrames(socket, handleRequestWithProcessPool);
  });

  server.listen(SOCKET_PATH, () => {
    fs.chmodSync(SOCKET_PATH, 0o666);
    preinstallNodeDependenciesOnStart();
  });
}

if (require.main === module) {
  main();
}

module.exports = {
  handleRequest,
  handleRequestWithProcessPool,
};

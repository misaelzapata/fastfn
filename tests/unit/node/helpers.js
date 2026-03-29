const path = require("node:path");
const Module = require("node:module");
const fs = require("node:fs");
const os = require("node:os");

const ROOT = path.resolve(__dirname, "..", "..", "..");

async function withPatchedModuleLoad(patches, run) {
  const originalLoad = Module._load;
  Module._load = function patchedLoad(request, parent, isMain) {
    if (Object.prototype.hasOwnProperty.call(patches, request)) {
      return patches[request];
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  try {
    return await run();
  } finally {
    Module._load = originalLoad;
  }
}

function requireFresh(modulePath) {
  delete require.cache[require.resolve(modulePath)];
  return require(modulePath);
}

/**
 * Like requireFresh but also resets Jest's module registry so that
 * module-level constants read from process.env are re-evaluated.
 * Use this for modules like node-daemon.js that capture env vars at load time.
 */
function jestRequireFresh(modulePath) {
  if (typeof jest !== "undefined" && typeof jest.resetModules === "function") {
    jest.resetModules();
  }
  return require(modulePath);
}

function resetWhatsappRuntimeState() {
  const state = global.__fastfn_wa;
  if (!state || typeof state !== "object") {
    return;
  }
  if (state.reconnectTimer) {
    clearTimeout(state.reconnectTimer);
  }
  state.socket = null;
  state.connecting = false;
  state.connected = false;
  state.me = null;
  state.lastQr = null;
  state.lastQrAt = null;
  state.lastError = null;
  state.reconnectTimer = null;
  state.inbox = [];
  state.outbox = [];
}

function writeFile(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");
}

async function withFunctionsRoot(run, options = {}) {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fastfn-nd-cov-"));
  const prevRoot = process.env.FN_FUNCTIONS_ROOT;
  const prevAuto = process.env.FN_AUTO_NODE_DEPS;
  const prevInfer = process.env.FN_AUTO_INFER_NODE_DEPS;
  const prevWriteManifest = process.env.FN_AUTO_INFER_WRITE_MANIFEST;
  const prevStrict = process.env.FN_AUTO_INFER_STRICT;
  const prevBackend = process.env.FN_NODE_INFER_BACKEND;
  const prevStrictFs = process.env.FN_STRICT_FS;
  const prevHotReload = process.env.FN_HOT_RELOAD;
  const prevPool = process.env.FN_NODE_RUNTIME_PROCESS_POOL;
  const prevPreinstall = process.env.FN_PREINSTALL_NODE_DEPS_ON_START;

  process.env.FN_FUNCTIONS_ROOT = tmpRoot;
  process.env.FN_AUTO_NODE_DEPS = options.autoNodeDeps ? "1" : "0";
  process.env.FN_AUTO_INFER_NODE_DEPS = options.autoInferNodeDeps ? "1" : "0";
  process.env.FN_AUTO_INFER_WRITE_MANIFEST = options.autoInferWriteManifest ? "1" : "0";
  process.env.FN_AUTO_INFER_STRICT = options.autoInferStrict ? "1" : "0";
  process.env.FN_NODE_INFER_BACKEND = options.nodeInferBackend || "native";
  process.env.FN_STRICT_FS = options.strictFs !== undefined ? (options.strictFs ? "1" : "0") : "0";
  process.env.FN_HOT_RELOAD = "1";
  process.env.FN_NODE_RUNTIME_PROCESS_POOL = "0";
  process.env.FN_PREINSTALL_NODE_DEPS_ON_START = "0";

  try {
    await run(tmpRoot);
  } finally {
    const restore = (key, prev) => {
      if (prev === undefined) delete process.env[key];
      else process.env[key] = prev;
    };
    restore("FN_FUNCTIONS_ROOT", prevRoot);
    restore("FN_AUTO_NODE_DEPS", prevAuto);
    restore("FN_AUTO_INFER_NODE_DEPS", prevInfer);
    restore("FN_AUTO_INFER_WRITE_MANIFEST", prevWriteManifest);
    restore("FN_AUTO_INFER_STRICT", prevStrict);
    restore("FN_NODE_INFER_BACKEND", prevBackend);
    restore("FN_STRICT_FS", prevStrictFs);
    restore("FN_HOT_RELOAD", prevHotReload);
    restore("FN_NODE_RUNTIME_PROCESS_POOL", prevPool);
    restore("FN_PREINSTALL_NODE_DEPS_ON_START", prevPreinstall);
  }
}

async function withProvidedFunctionsRoot(functionsRoot, run, options = {}) {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "fastfn-nd-provided-"));
  const prevRoot = process.env.FN_FUNCTIONS_ROOT;
  const prevAuto = process.env.FN_AUTO_NODE_DEPS;
  const prevInfer = process.env.FN_AUTO_INFER_NODE_DEPS;
  const prevWriteManifest = process.env.FN_AUTO_INFER_WRITE_MANIFEST;
  const prevStrict = process.env.FN_AUTO_INFER_STRICT;
  const prevBackend = process.env.FN_NODE_INFER_BACKEND;
  fs.cpSync(functionsRoot, tmpRoot, { recursive: true });
  process.env.FN_FUNCTIONS_ROOT = tmpRoot;
  process.env.FN_AUTO_NODE_DEPS = options.autoNodeDeps ? "1" : "0";
  process.env.FN_AUTO_INFER_NODE_DEPS = options.autoInferNodeDeps ? "1" : "0";
  process.env.FN_AUTO_INFER_WRITE_MANIFEST = options.autoInferWriteManifest ? "1" : "0";
  process.env.FN_AUTO_INFER_STRICT = options.autoInferStrict ? "1" : "0";
  process.env.FN_NODE_INFER_BACKEND = options.nodeInferBackend || "native";

  try {
    await run(tmpRoot);
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
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
    if (prevBackend === undefined) {
      delete process.env.FN_NODE_INFER_BACKEND;
    } else {
      process.env.FN_NODE_INFER_BACKEND = prevBackend;
    }
  }
}

module.exports = {
  ROOT,
  withPatchedModuleLoad,
  requireFresh,
  jestRequireFresh,
  resetWhatsappRuntimeState,
  writeFile,
  withFunctionsRoot,
  withProvidedFunctionsRoot,
};

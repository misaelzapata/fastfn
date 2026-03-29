#!/usr/bin/env node

const { handleRequest } = require("./node-daemon.js");

function sendResult(msg) {
  if (typeof process.send === "function") {
    process.send(msg);
  }
}

process.on("message", async (msg) => {
  if (!msg || msg.type !== "invoke") {
    return;
  }

  const id = msg.id;
  const req = msg.request;

  try {
    const resp = await handleRequest(req);
    sendResult({
      type: "invoke_result",
      id,
      ok: true,
      response: resp,
    });
  } catch (err) {
    const status = err && err.code === "ENOENT" ? 404 : (Number.isInteger(err && err.status) ? err.status : 500);
    sendResult({
      type: "invoke_result",
      id,
      ok: false,
      status,
      code: err && err.code ? String(err.code) : undefined,
      error: err && err.message ? String(err.message) : String(err),
    });
  }
});

const assert = require("node:assert/strict");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");
const handlerPath = path.join(root, "test", "usuarios-api", "handler.js");
const handler = require(handlerPath).handler;

async function testUsuariosApi() {
  const event = {
    path: "/fn/usuarios-api",
    method: "GET"
  };
  const context = { requestId: "test-req" };
  
  const resp = await handler(event, context);
  
  assert.equal(resp.status, 200);
  assert.equal(resp.headers["Content-Type"], "application/json");
  
  const body = JSON.parse(resp.body);
  assert.equal(body.message, "Hello from FastFn Node!");
  assert.deepEqual(body.input, event);
  
  console.log("testUsuariosApi passed");
}

testUsuariosApi().catch(err => {
  console.error(err);
  process.exit(1);
});

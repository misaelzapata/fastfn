'use strict';

const assert = require('assert');
const { Response } = require('./index.js');

const json = Response.json({ ok: true });
assert.strictEqual(json.status, 200);
assert.strictEqual(json.headers['Content-Type'], 'application/json');
assert.strictEqual(json.body, '{"ok":true}');

const txt = Response.text('hello', 201, { 'X-Test': '1' });
assert.strictEqual(txt.status, 201);
assert.strictEqual(txt.headers['Content-Type'], 'text/plain; charset=utf-8');
assert.strictEqual(txt.headers['X-Test'], '1');
assert.strictEqual(txt.body, 'hello');

const pxy = Response.proxy('/request-inspector', 'post', { 'X-Trace': 'abc' });
assert.strictEqual(pxy.proxy.path, '/request-inspector');
assert.strictEqual(pxy.proxy.method, 'POST');
assert.strictEqual(pxy.proxy.headers['X-Trace'], 'abc');

console.log('JS SDK: OK');

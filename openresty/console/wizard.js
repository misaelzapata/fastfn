import { getJson } from './base.js';

function publicLabel(name, version) {
  return version ? `${name}@${version}` : name;
}

function qsFromObject(obj) {
  if (!obj || typeof obj !== 'object') return '';
  const parts = [];
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    if (v === undefined || v === null) continue;
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`);
  }
  return parts.join('&');
}

function curlFor(baseUrl, route, method, queryExample, bodyExample) {
  const q = (method === 'GET' || method === 'DELETE') ? qsFromObject(queryExample) : qsFromObject(queryExample);
  const url = `${baseUrl}${route}${q ? `?${q}` : ''}`;
  if (method === 'GET') return `curl -sS '${url}'`;
  if (method === 'DELETE') return `curl -sS -X DELETE '${url}'`;

  const body = (typeof bodyExample === 'string' && bodyExample !== '') ? bodyExample : '';
  const hasBody = body !== '' && (method === 'POST' || method === 'PUT' || method === 'PATCH');
  if (!hasBody) {
    return `curl -sS -X ${method} '${url}'`;
  }
  // Body is treated as a raw string by the gateway.
  return `curl -sS -X ${method} '${url}' -H 'Content-Type: text/plain' --data ${JSON.stringify(body)}`;
}

function wizardTemplate(runtime, template) {
  const rt = String(runtime || 'python');
  const t = String(template || 'hello-json');

  if (t === 'hello-json') {
    if (rt === 'python') {
      return {
        summary: 'Hello JSON',
        methods: ['GET'],
        query_example: { name: 'World' },
        code: `import json\n\n# @summary Hello JSON\n# @methods GET\n# @query {\"name\":\"World\"}\n\ndef handler(event):\n    q = event.get(\"query\") or {}\n    name = q.get(\"name\", \"World\")\n    return {\n        \"status\": 200,\n        \"headers\": {\"Content-Type\": \"application/json\"},\n        \"body\": json.dumps({\"hello\": name}, separators=(\",\", \":\")),\n    }\n`,
      };
    }
    if (rt === 'node') {
      return {
        summary: 'Hello JSON',
        methods: ['GET'],
        query_example: { name: 'World' },
        code: `// @summary Hello JSON\n// @methods GET\n// @query {\"name\":\"World\"}\nexports.handler = async (event) => {\n  const q = event.query || {};\n  const name = q.name || 'World';\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'application/json' },\n    body: JSON.stringify({ hello: name }),\n  };\n};\n`,
      };
    }
  }

  if (t === 'hello-ts') {
    if (rt === 'node') {
      return {
        summary: 'Hello (TypeScript)',
        methods: ['GET'],
        query_example: { name: 'World' },
        filename: 'app.ts',
        code: `// @summary Hello (TypeScript)\n// @methods GET\n// @query {\"name\":\"World\"}\nexport const handler = async (event: any) => {\n  const q = event.query || {};\n  const name = q.name || 'World';\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'application/json' },\n    body: JSON.stringify({ hello: name }),\n  };\n};\n`,
        extraConfig: { shared_deps: ['ts_pack'] },
      };
    }
  }

  if (t === 'echo') {
    if (rt === 'python') {
      return {
        summary: 'Echo',
        methods: ['GET', 'POST'],
        query_example: { key: 'test' },
        body_example: 'hello',
        code: `import json\n\n# @summary Echo\n# @methods GET,POST\n# @query {\"key\":\"test\"}\n# @body hello\n\ndef handler(event):\n    return {\n        \"status\": 200,\n        \"headers\": {\"Content-Type\": \"application/json\"},\n        \"body\": json.dumps({\n            \"method\": event.get(\"method\"),\n            \"query\": event.get(\"query\") or {},\n            \"body\": event.get(\"body\") or \"\",\n            \"context\": event.get(\"context\") or {},\n        }, separators=(\",\", \":\")),\n    }\n`,
      };
    }
    if (rt === 'node') {
      return {
        summary: 'Echo',
        methods: ['GET', 'POST'],
        query_example: { key: 'test' },
        body_example: 'hello',
        code: `// @summary Echo\n// @methods GET,POST\n// @query {\"key\":\"test\"}\n// @body hello\nexports.handler = async (event) => {\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'application/json' },\n    body: JSON.stringify({\n      method: event.method,\n      query: event.query || {},\n      body: event.body || '',\n      context: event.context || {},\n    }),\n  };\n};\n`,
      };
    }
  }

  if (t === 'html') {
    if (rt === 'python') {
      return {
        summary: 'HTML page',
        methods: ['GET'],
        code: `# @summary HTML demo\n# @methods GET\n# @content_type text/html\n\ndef handler(event):\n    return {\n        \"status\": 200,\n        \"headers\": {\"Content-Type\": \"text/html; charset=utf-8\"},\n        \"body\": \"<h1>fastfn</h1><p>Hello from HTML.</p>\",\n    }\n`,
      };
    }
    if (rt === 'node') {
      return {
        summary: 'HTML page',
        methods: ['GET'],
        code: `// @summary HTML demo\n// @methods GET\n// @content_type text/html\nexports.handler = async (event) => {\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'text/html; charset=utf-8' },\n    body: '<h1>fastfn</h1><p>Hello from HTML.</p>',\n  };\n};\n`,
      };
    }
  }

  if (t === 'csv') {
    if (rt === 'python') {
      return {
        summary: 'CSV export',
        methods: ['GET'],
        code: `# @summary CSV demo\n# @methods GET\n# @content_type text/csv\n\ndef handler(event):\n    rows = [\"name,score\", \"alice,10\", \"bob,20\"]\n    return {\n        \"status\": 200,\n        \"headers\": {\"Content-Type\": \"text/csv; charset=utf-8\"},\n        \"body\": \"\\n\".join(rows) + \"\\n\",\n    }\n`,
      };
    }
    if (rt === 'node') {
      return {
        summary: 'CSV export',
        methods: ['GET'],
        code: `// @summary CSV demo\n// @methods GET\n// @content_type text/csv\nexports.handler = async () => {\n  const rows = ['name,score', 'alice,10', 'bob,20'];\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'text/csv; charset=utf-8' },\n    body: rows.join('\\n') + '\\n',\n  };\n};\n`,
      };
    }
  }

  if (t === 'png') {
    if (rt === 'python') {
      return {
        summary: 'PNG demo',
        methods: ['GET'],
        code: `import base64\n\n# @summary PNG demo\n# @methods GET\n\ndef handler(event):\n    # 1x1 transparent PNG\n    b64 = \"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axlYt8AAAAASUVORK5CYII=\"\n    return {\n        \"status\": 200,\n        \"headers\": {\"Content-Type\": \"image/png\"},\n        \"is_base64\": True,\n        \"body_base64\": b64,\n    }\n`,
      };
    }
    if (rt === 'node') {
      return {
        summary: 'PNG demo',
        methods: ['GET'],
        code: `// @summary PNG demo\n// @methods GET\nexports.handler = async () => {\n  const b64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/axlYt8AAAAASUVORK5CYII=';\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'image/png' },\n    is_base64: true,\n    body_base64: b64,\n  };\n};\n`,
      };
    }
  }

  if (t === 'edge-proxy') {
    if (rt === 'python') {
      return {
        summary: 'Edge passthrough (proxy)',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { key: 'demo' },
        body_example: 'hello',
        code: `import json\n\n# @summary Edge passthrough (proxy)\n# @methods GET,POST,PUT,PATCH,DELETE\n# @query {\"key\":\"demo\"}\n# @body hello\n\ndef handler(event):\n    # Return a proxy directive; fastfn will perform the outbound request.\n    # For local demos, proxy to /_fn/health.\n    return {\n        \"status\": 200,\n        \"headers\": {\"Content-Type\": \"application/json\"},\n        \"proxy\": {\n            \"path\": \"/_fn/health\",\n            \"method\": event.get(\"method\") or \"GET\",\n            \"headers\": {\"x-fastfn-edge\": \"1\"},\n            \"body\": event.get(\"body\") or \"\",\n            \"timeout_ms\": (event.get(\"context\") or {}).get(\"timeout_ms\", 2000),\n        },\n    }\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
    if (rt === 'node') {
      return {
        summary: 'Edge passthrough (proxy)',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { key: 'demo' },
        body_example: 'hello',
        code: `// @summary Edge passthrough (proxy)\n// @methods GET,POST,PUT,PATCH,DELETE\n// @query {\"key\":\"demo\"}\n// @body hello\nexports.handler = async (event) => {\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'application/json' },\n    proxy: {\n      path: '/_fn/health',\n      method: event.method || 'GET',\n      headers: { 'x-fastfn-edge': '1' },\n      body: event.body || '',\n      timeout_ms: (event.context || {}).timeout_ms || 2000,\n    },\n  };\n};\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
  }

  if (t === 'edge-filter') {
    if (rt === 'node') {
      return {
        summary: 'Edge filter (auth + rewrite)',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { user_id: '123' },
        body_example: 'hello',
        code: `// @summary Edge filter (auth + rewrite)\n// @methods GET,POST,PUT,PATCH,DELETE\n// @query {\"user_id\":\"123\"}\n// @body hello\nfunction header(event, name) {\n  const h = event.headers || {};\n  return h[name] || h[name.toLowerCase()] || h[name.toUpperCase()] || null;\n}\n\nfunction json(status, payload) {\n  return { status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) };\n}\n\nexports.handler = async (event) => {\n  const env = event.env || {};\n  const ctx = event.context || {};\n\n  // 1) Filter: auth\n  const expected = String(env.EDGE_FILTER_API_KEY || '');\n  const provided = String(header(event, 'x-api-key') || '');\n  if (!expected || provided !== expected) {\n    return json(401, { error: 'unauthorized' });\n  }\n\n  // 2) Filter: validate\n  const q = event.query || {};\n  const userId = String(q.user_id || q.userId || '');\n  if (!/^[0-9]+$/.test(userId)) {\n    return json(400, { error: 'user_id must be numeric' });\n  }\n\n  // 3) Rewrite + passthrough\n  return {\n    proxy: {\n      path: '/openapi.json?edge_user_id=' + encodeURIComponent(userId),\n      method: 'GET',\n      headers: {\n        'x-fastfn-edge': '1',\n        'x-fastfn-request-id': String(ctx.request_id || ''),\n        'x-fastfn-user-id': userId,\n      },\n      body: '',\n      timeout_ms: ctx.timeout_ms || 2000,\n    },\n  };\n};\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_hosts: ['127.0.0.1:8080'], allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
    if (rt === 'python') {
      return {
        summary: 'Edge filter (auth + rewrite)',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { user_id: '123' },
        body_example: 'hello',
        code: `import json\n\n# @summary Edge filter (auth + rewrite)\n# @methods GET,POST,PUT,PATCH,DELETE\n# @query {\"user_id\":\"123\"}\n# @body hello\n\ndef handler(event):\n    env = event.get(\"env\") or {}\n    ctx = event.get(\"context\") or {}\n    headers = event.get(\"headers\") or {}\n\n    expected = str(env.get(\"EDGE_FILTER_API_KEY\") or \"\")\n    provided = str(headers.get(\"x-api-key\") or headers.get(\"X-API-KEY\") or \"\")\n    if not expected or provided != expected:\n        return {\n            \"status\": 401,\n            \"headers\": {\"Content-Type\": \"application/json\"},\n            \"body\": json.dumps({\"error\": \"unauthorized\"}),\n        }\n\n    q = event.get(\"query\") or {}\n    user_id = str(q.get(\"user_id\") or q.get(\"userId\") or \"\")\n    if not user_id.isdigit():\n        return {\n            \"status\": 400,\n            \"headers\": {\"Content-Type\": \"application/json\"},\n            \"body\": json.dumps({\"error\": \"user_id must be numeric\"}),\n        }\n\n    return {\n        \"proxy\": {\n            \"path\": \"/openapi.json?edge_user_id=\" + user_id,\n            \"method\": \"GET\",\n            \"headers\": {\n                \"x-fastfn-edge\": \"1\",\n                \"x-fastfn-request-id\": str(ctx.get(\"request_id\") or \"\"),\n                \"x-fastfn-user-id\": user_id,\n            },\n            \"body\": \"\",\n            \"timeout_ms\": int(ctx.get(\"timeout_ms\") or 2000),\n        }\n    }\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_hosts: ['127.0.0.1:8080'], allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
  }

  if (t === 'edge-auth-gateway') {
    if (rt === 'node') {
      return {
        summary: 'Edge gateway auth (Bearer) + passthrough',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { target: 'openapi' },
        body_example: 'hello',
        code: `// @summary Edge gateway auth (Bearer) + passthrough\n// @methods GET,POST,PUT,PATCH,DELETE\n// @query {\"target\":\"openapi\"}\n// @body hello\nfunction header(event, name) {\n  const h = event.headers || {};\n  return h[name] || h[name.toLowerCase()] || h[name.toUpperCase()] || null;\n}\n\nfunction json(status, payload, extraHeaders) {\n  return { status, headers: { 'Content-Type': 'application/json', ...(extraHeaders || {}) }, body: JSON.stringify(payload) };\n}\n\nfunction normalizeTarget(raw) {\n  const t = String(raw || 'openapi').trim().toLowerCase();\n  if (t === 'health') return '/_fn/health';\n  if (t === 'openapi') return '/openapi.json';\n  return null;\n}\n\nexports.handler = async (event) => {\n  const env = event.env || {};\n  const ctx = event.context || {};\n\n  const expected = String(env.EDGE_AUTH_TOKEN || '');\n  const auth = String(header(event, 'authorization') || '');\n  if (!expected || auth !== 'Bearer ' + expected) {\n    return json(401, { error: 'unauthorized' }, { 'WWW-Authenticate': 'Bearer' });\n  }\n\n  const q = event.query || {};\n  const targetPath = normalizeTarget(q.target);\n  if (!targetPath) return json(400, { error: 'invalid target (use ?target=openapi or ?target=health)' });\n\n  return {\n    proxy: {\n      path: targetPath,\n      method: event.method || 'GET',\n      headers: { 'x-fastfn-edge': '1', 'x-fastfn-request-id': String(ctx.request_id || '') },\n      body: event.body || '',\n      timeout_ms: ctx.timeout_ms || 2000,\n    },\n  };\n};\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_hosts: ['127.0.0.1:8080'], allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
    if (rt === 'python') {
      return {
        summary: 'Edge gateway auth (Bearer) + passthrough',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { target: 'openapi' },
        body_example: 'hello',
        code: `import json\n\n# @summary Edge gateway auth (Bearer) + passthrough\n# @methods GET,POST,PUT,PATCH,DELETE\n# @query {\"target\":\"openapi\"}\n# @body hello\n\ndef handler(event):\n    env = event.get(\"env\") or {}\n    ctx = event.get(\"context\") or {}\n    headers = event.get(\"headers\") or {}\n\n    expected = str(env.get(\"EDGE_AUTH_TOKEN\") or \"\")\n    auth = str(headers.get(\"authorization\") or headers.get(\"Authorization\") or \"\")\n    if not expected or auth != \"Bearer \" + expected:\n        return {\n            \"status\": 401,\n            \"headers\": {\"Content-Type\": \"application/json\", \"WWW-Authenticate\": \"Bearer\"},\n            \"body\": json.dumps({\"error\": \"unauthorized\"}),\n        }\n\n    q = event.get(\"query\") or {}\n    target = str(q.get(\"target\") or \"openapi\").strip().lower()\n    if target == \"health\":\n        path = \"/_fn/health\"\n    elif target == \"openapi\":\n        path = \"/openapi.json\"\n    else:\n        return {\"status\": 400, \"headers\": {\"Content-Type\": \"application/json\"}, \"body\": json.dumps({\"error\": \"invalid target\"})}\n\n    return {\n        \"proxy\": {\n            \"path\": path,\n            \"method\": event.get(\"method\") or \"GET\",\n            \"headers\": {\"x-fastfn-edge\": \"1\", \"x-fastfn-request-id\": str(ctx.get(\"request_id\") or \"\")},\n            \"body\": event.get(\"body\") or \"\",\n            \"timeout_ms\": int(ctx.get(\"timeout_ms\") or 2000),\n        }\n    }\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_hosts: ['127.0.0.1:8080'], allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
  }

  if (t === 'github-webhook-guard') {
    if (rt === 'node') {
      return {
        summary: 'GitHub webhook guard (signature verify)',
        methods: ['POST'],
        body_example: '{"zen":"Keep it logically awesome.","hook_id":123}',
        code: `// @summary GitHub webhook guard (signature verify)\n// @methods POST\n// @body {\"zen\":\"Keep it logically awesome.\",\"hook_id\":123}\nconst crypto = require('node:crypto');\n\nfunction header(event, name) {\n  const h = event.headers || {};\n  return h[name] || h[name.toLowerCase()] || h[name.toUpperCase()] || null;\n}\n\nfunction json(status, payload) {\n  return { status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) };\n}\n\nfunction timingSafeEq(a, b) {\n  const ab = Buffer.from(String(a || ''), 'utf8');\n  const bb = Buffer.from(String(b || ''), 'utf8');\n  if (ab.length !== bb.length) return false;\n  return crypto.timingSafeEqual(ab, bb);\n}\n\nfunction computeSig(secret, body) {\n  return 'sha256=' + crypto.createHmac('sha256', Buffer.from(secret, 'utf8')).update(Buffer.from(body || '', 'utf8')).digest('hex');\n}\n\nexports.handler = async (event) => {\n  const env = event.env || {};\n  const ctx = event.context || {};\n  const secret = String(env.GITHUB_WEBHOOK_SECRET || '');\n  if (!secret) return json(500, { error: 'GITHUB_WEBHOOK_SECRET not configured' });\n\n  const body = typeof event.body === 'string' ? event.body : '';\n  const provided = String(header(event, 'x-hub-signature-256') || '');\n  if (!provided) return json(400, { error: 'missing x-hub-signature-256' });\n\n  const expected = computeSig(secret, body);\n  if (!timingSafeEq(provided, expected)) return json(401, { error: 'invalid signature' });\n\n  const q = event.query || {};\n  const forward = String(q.forward || '').trim() === '1';\n  if (!forward) return json(200, { ok: true, verified: true });\n\n  return {\n    proxy: {\n      path: '/request-inspector',\n      method: 'POST',\n      headers: { 'x-fastfn-edge': '1', 'x-fastfn-request-id': String(ctx.request_id || ''), 'x-webhook-verified': '1' },\n      body,\n      timeout_ms: ctx.timeout_ms || 2000,\n    },\n  };\n};\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_hosts: ['127.0.0.1:8080'], allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
    if (rt === 'python') {
      return {
        summary: 'GitHub webhook guard (signature verify)',
        methods: ['POST'],
        body_example: '{"zen":"Keep it logically awesome.","hook_id":123}',
        code: `import hmac\nimport hashlib\nimport json\n\n# @summary GitHub webhook guard (signature verify)\n# @methods POST\n# @body {\"zen\":\"Keep it logically awesome.\",\"hook_id\":123}\n\ndef handler(event):\n    env = event.get(\"env\") or {}\n    headers = event.get(\"headers\") or {}\n    secret = str(env.get(\"GITHUB_WEBHOOK_SECRET\") or \"\")\n    if not secret:\n        return {\"status\": 500, \"headers\": {\"Content-Type\": \"application/json\"}, \"body\": json.dumps({\"error\": \"GITHUB_WEBHOOK_SECRET not configured\"})}\n\n    body = event.get(\"body\") or \"\"\n    provided = headers.get(\"x-hub-signature-256\") or headers.get(\"X-Hub-Signature-256\")\n    if not provided:\n        return {\"status\": 400, \"headers\": {\"Content-Type\": \"application/json\"}, \"body\": json.dumps({\"error\": \"missing x-hub-signature-256\"})}\n\n    mac = hmac.new(secret.encode(\"utf-8\"), body.encode(\"utf-8\"), hashlib.sha256).hexdigest()\n    expected = \"sha256=\" + mac\n    if not hmac.compare_digest(str(provided), expected):\n        return {\"status\": 401, \"headers\": {\"Content-Type\": \"application/json\"}, \"body\": json.dumps({\"error\": \"invalid signature\"})}\n\n    return {\"status\": 200, \"headers\": {\"Content-Type\": \"application/json\"}, \"body\": json.dumps({\"ok\": True, \"verified\": True})}\n`,
      };
    }
  }

  if (t === 'edge-header-inject') {
    if (rt === 'node') {
      return {
        summary: 'Edge header injection + passthrough',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { tenant: 'demo' },
        body_example: 'hello',
        code: `// @summary Edge header injection + passthrough\n// @methods GET,POST,PUT,PATCH,DELETE\n// @query {\"tenant\":\"demo\"}\n// @body hello\nexports.handler = async (event) => {\n  const ctx = event.context || {};\n  const q = event.query || {};\n  const tenant = String(q.tenant || 'demo');\n  return {\n    proxy: {\n      path: '/request-inspector',\n      method: event.method || 'GET',\n      headers: {\n        'x-fastfn-edge': '1',\n        'x-fastfn-request-id': String(ctx.request_id || ''),\n        'x-tenant': tenant,\n      },\n      body: event.body || '',\n      timeout_ms: ctx.timeout_ms || 2000,\n    },\n  };\n};\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_hosts: ['127.0.0.1:8080'], allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
    if (rt === 'python') {
      return {
        summary: 'Edge header injection + passthrough',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { tenant: 'demo' },
        body_example: 'hello',
        code: `# @summary Edge header injection + passthrough\n# @methods GET,POST,PUT,PATCH,DELETE\n# @query {\"tenant\":\"demo\"}\n# @body hello\n\ndef handler(event):\n    ctx = event.get(\"context\") or {}\n    q = event.get(\"query\") or {}\n    tenant = str(q.get(\"tenant\") or \"demo\")\n    return {\n        \"proxy\": {\n            \"path\": \"/request-inspector\",\n            \"method\": event.get(\"method\") or \"GET\",\n            \"headers\": {\n                \"x-fastfn-edge\": \"1\",\n                \"x-fastfn-request-id\": str(ctx.get(\"request_id\") or \"\"),\n                \"x-tenant\": tenant,\n            },\n            \"body\": event.get(\"body\") or \"\",\n            \"timeout_ms\": int(ctx.get(\"timeout_ms\") or 2000),\n        }\n    }\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_hosts: ['127.0.0.1:8080'], allow_private: true, max_response_bytes: 1048576 },
        },
      };
    }
  }

  if (t === 'edge-proxy-ts') {
    if (rt === 'node') {
      return {
        summary: 'Edge passthrough (proxy) (TypeScript)',
        methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
        query_example: { key: 'demo' },
        body_example: 'hello',
        filename: 'app.ts',
        code: `// @summary Edge passthrough (proxy) (TypeScript)\n// @methods GET,POST,PUT,PATCH,DELETE\n// @query {\"key\":\"demo\"}\n// @body hello\nexport const handler = async (event: any) => {\n  const ctx = event.context || {};\n  return {\n    status: 200,\n    headers: { 'Content-Type': 'application/json' },\n    proxy: {\n      path: '/_fn/health',\n      method: event.method || 'GET',\n      headers: { 'x-fastfn-edge': '1' },\n      body: event.body || '',\n      timeout_ms: ctx.timeout_ms || 2000,\n    },\n  };\n};\n`,
        edgeConfig: {
          edge: { base_url: 'http://127.0.0.1:8080', allow_private: true, max_response_bytes: 1048576 },
        },
        extraConfig: { shared_deps: ['ts_pack'] },
      };
    }
  }

  return null;
}

export function initWizard(opts) {
  const state = opts && opts.state ? opts.state : {};
  const loadCatalog = opts && typeof opts.loadCatalog === 'function' ? opts.loadCatalog : null;
  const selectFn = opts && typeof opts.selectFn === 'function' ? opts.selectFn : null;

  const wizRuntimeEl = document.getElementById('wizRuntime');
  const wizNameEl = document.getElementById('wizName');
  const wizVersionEl = document.getElementById('wizVersion');
  const wizTemplateEl = document.getElementById('wizTemplate');
  const wizCreateBtn = document.getElementById('wizCreateBtn');
  const wizCreateOpenBtn = document.getElementById('wizCreateOpenBtn');
  const wizStatusEl = document.getElementById('wizStatus');

  async function create(openAfter) {
    if (!wizRuntimeEl || !wizNameEl || !wizTemplateEl) return;
    const runtime = String(wizRuntimeEl.value || '').trim();
    const name = String(wizNameEl.value || '').trim();
    const version = wizVersionEl ? String(wizVersionEl.value || '').trim() : '';
    const template = String(wizTemplateEl.value || 'hello-json');
    if (!runtime || !name) {
      if (wizStatusEl) wizStatusEl.textContent = 'Runtime and name are required.';
      return;
    }
    const tpl = wizardTemplate(runtime, template);
    if (!tpl) {
      if (wizStatusEl) wizStatusEl.textContent = `No template for ${runtime}/${template}`;
      return;
    }

    if (wizStatusEl) wizStatusEl.textContent = 'Creating...';
    const q = new URLSearchParams({ runtime, name });
    if (version) q.set('version', version);

    const created = await getJson(`/_fn/function?${q.toString()}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        summary: tpl.summary || 'Wizard function',
        methods: tpl.methods || ['GET'],
        query_example: tpl.query_example || {},
        body_example: tpl.body_example || '',
        code: tpl.code || '',
        filename: tpl.filename,
      }),
    });

    if (tpl.edgeConfig) {
      await getJson(`/_fn/function-config?${q.toString()}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(tpl.edgeConfig),
      });
    }
    if (tpl.extraConfig) {
      await getJson(`/_fn/function-config?${q.toString()}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(tpl.extraConfig),
      });
    }

    if (wizStatusEl) {
      const baseUrl = 'http://127.0.0.1:8080';
      const route = `/${name}${version ? `@${version}` : ''}`;
      const methods = Array.isArray(tpl.methods) && tpl.methods.length > 0 ? tpl.methods : ['GET'];
      const queryEx = tpl.query_example || {};
      const bodyEx = tpl.body_example || '';

      const examples = [];
      // Keep the output short: show GET and POST if supported, otherwise show first method.
      if (methods.includes('GET')) examples.push(curlFor(baseUrl, route, 'GET', queryEx, bodyEx));
      if (methods.includes('POST')) examples.push(curlFor(baseUrl, route, 'POST', queryEx, bodyEx));
      if (examples.length === 0) examples.push(curlFor(baseUrl, route, String(methods[0] || 'GET'), queryEx, bodyEx));

      const lines = [];
      lines.push(`Created ${runtime}/${publicLabel(name, version || null)}`);
      lines.push(`Route: ${route}`);
      lines.push(`Methods: ${methods.join(', ')}`);
      if (created && created.file_path) lines.push(`Code: ${created.file_path}`);
      if (created && created.config_path) lines.push(`Config: ${created.config_path}`);
      lines.push('Try:');
      for (const ex of examples) lines.push(`  ${ex}`);
      wizStatusEl.textContent = lines.join('\n');
    }

    if (loadCatalog) await loadCatalog({ refreshSelected: true });
    if (openAfter && selectFn) await selectFn(runtime, name, version || null, { activateTab: 'explorer' });
  }

  if (wizCreateBtn) wizCreateBtn.addEventListener('click', () => create(false).catch((e) => { if (wizStatusEl) wizStatusEl.textContent = e.message; }));
  if (wizCreateOpenBtn) wizCreateOpenBtn.addEventListener('click', () => create(true).catch((e) => { if (wizStatusEl) wizStatusEl.textContent = e.message; }));
}

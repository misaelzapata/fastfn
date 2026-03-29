function escapeHtml(input) {
  return String(input)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

exports.handler = async (event) => {
  const name = escapeHtml(event.query?.name || 'FastFN');

  return {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
    body: `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>FastFN HTML Demo</title>
    <style>
      body { font-family: ui-sans-serif, -apple-system, Segoe UI, sans-serif; margin: 0; background: #f7f9fc; color: #101828; }
      main { max-width: 760px; margin: 48px auto; padding: 0 20px; }
      .card { background: #fff; border: 1px solid #d0d5dd; border-radius: 16px; padding: 24px; box-shadow: 0 12px 36px rgba(16, 24, 40, 0.08); }
      h1 { margin: 0 0 12px; font-size: 32px; line-height: 1.15; }
      p { margin: 0 0 10px; line-height: 1.6; }
      code { background: #f2f4f7; border-radius: 6px; padding: 2px 6px; }
    </style>
  </head>
  <body>
    <main>
      <section class="card">
        <h1>Hello ${name}</h1>
        <p>This endpoint returns real HTML from a file-based function route.</p>
        <p>Try: <code>/html?name=Developer</code></p>
      </section>
    </main>
  </body>
</html>`,
  };
};

/**
 * Session & cookie demo — shows how to access event.session in Node.js.
 *
 * Usage:
 *   Send a request with Cookie header: session_id=abc123; theme=dark
 *   The handler reads event.session.cookies, event.session.id, and logs debug info.
 *
 * event.session shape:
 *   - id:      auto-detected from session_id / sessionid / sid cookies (or null)
 *   - raw:     the full Cookie header string
 *   - cookies: object of parsed cookie key/value pairs
 */
module.exports.handler = async (event) => {
  const session = event.session || {};
  const cookies = session.cookies || {};

  // Demonstrate stdout capture — this will appear in Quick Test > stdout
  console.log(`[session-demo] session_id = ${session.id}`);
  console.log(`[session-demo] cookies =`, JSON.stringify(cookies));

  // Check for authentication
  if (!session.id) {
    return {
      status: 401,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        error: "No session cookie found",
        hint: "Send Cookie: session_id=your-token",
      }),
    };
  }

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      authenticated: true,
      session_id: session.id,
      theme: cookies.theme || "light",
      all_cookies: cookies,
    }),
  };
};

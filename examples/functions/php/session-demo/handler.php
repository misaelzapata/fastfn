<?php
/**
 * Session & cookie demo — shows how to access event.session in PHP.
 *
 * Usage:
 *   Send a request with Cookie header: session_id=abc123; theme=dark
 *   The handler reads event.session.cookies, event.session.id, and logs debug info.
 *
 * event.session shape:
 *   - id:      auto-detected from session_id / sessionid / sid cookies (or null)
 *   - raw:     the full Cookie header string
 *   - cookies: assoc array of parsed cookie key/value pairs
 */

function handler($event) {
    $session = $event['session'] ?? [];
    $cookies = $session['cookies'] ?? [];

    // Demonstrate stderr capture — this will appear in Quick Test > stderr
    error_log("[session-demo] session_id = " . ($session['id'] ?? 'null'));
    error_log("[session-demo] cookies = " . json_encode($cookies));

    // Check for authentication
    if (empty($session['id'])) {
        return [
            'status' => 401,
            'headers' => ['Content-Type' => 'application/json'],
            'body' => json_encode([
                'error' => 'No session cookie found',
                'hint' => 'Send Cookie: session_id=your-token',
            ]),
        ];
    }

    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode([
            'authenticated' => true,
            'session_id' => $session['id'],
            'theme' => $cookies['theme'] ?? 'light',
            'all_cookies' => $cookies,
        ]),
    ];
}

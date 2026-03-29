package main

import "encoding/json"

// Session & cookie demo — shows how to access event["session"] in Go.
//
// Usage:
//   Send a request with Cookie header: session_id=abc123; theme=dark

func handler(event map[string]interface{}) interface{} {
	session, _ := event["session"].(map[string]interface{})
	if session == nil {
		session = map[string]interface{}{}
	}

	sessionID, _ := session["id"].(string)
	cookies, _ := session["cookies"].(map[string]interface{})
	if cookies == nil {
		cookies = map[string]interface{}{}
	}

	if sessionID == "" {
		body, _ := json.Marshal(map[string]interface{}{
			"error": "No session cookie found",
			"hint":  "Send Cookie: session_id=your-token",
		})
		return map[string]interface{}{
			"status":  401,
			"headers": map[string]string{"Content-Type": "application/json"},
			"body":    string(body),
		}
	}

	theme, _ := cookies["theme"].(string)
	if theme == "" {
		theme = "light"
	}

	body, _ := json.Marshal(map[string]interface{}{
		"authenticated": true,
		"session_id":    sessionID,
		"theme":         theme,
		"all_cookies":   cookies,
	})
	return map[string]interface{}{
		"status":  200,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

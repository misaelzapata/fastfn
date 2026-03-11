// Session & cookie demo — shows how to access event.session in Go.
//
// Usage:
//   Send a request with Cookie header: session_id=abc123; theme=dark
//   The handler reads event.session.cookies, event.session.id, and prints debug info.
//
// event.session shape:
//   - id:      auto-detected from session_id / sessionid / sid cookies (or "")
//   - raw:     the full Cookie header string
//   - cookies: map of parsed cookie key/value pairs

package main

import (
	"encoding/json"
	"fmt"
	"os"
)

type Event struct {
	Session *Session               `json:"session"`
	Query   map[string]interface{} `json:"query"`
}

type Session struct {
	ID      string            `json:"id"`
	Raw     string            `json:"raw"`
	Cookies map[string]string `json:"cookies"`
}

type Payload struct {
	Event Event `json:"event"`
}

type Response struct {
	Status  int               `json:"status"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}

func main() {
	var payload Payload
	if err := json.NewDecoder(os.Stdin).Decode(&payload); err != nil {
		writeError(500, "failed to decode input")
		return
	}

	event := payload.Event
	session := event.Session
	if session == nil {
		session = &Session{Cookies: map[string]string{}}
	}

	// Demonstrate stderr capture — this will appear in Quick Test > stderr
	fmt.Fprintf(os.Stderr, "[session-demo] session_id = %s\n", session.ID)
	fmt.Fprintf(os.Stderr, "[session-demo] cookies = %v\n", session.Cookies)

	if session.ID == "" {
		body, _ := json.Marshal(map[string]interface{}{
			"error": "No session cookie found",
			"hint":  "Send Cookie: session_id=your-token",
		})
		writeResponse(401, string(body))
		return
	}

	theme := session.Cookies["theme"]
	if theme == "" {
		theme = "light"
	}

	body, _ := json.Marshal(map[string]interface{}{
		"authenticated": true,
		"session_id":    session.ID,
		"theme":         theme,
		"all_cookies":   session.Cookies,
	})
	writeResponse(200, string(body))
}

func writeResponse(status int, body string) {
	resp := Response{
		Status:  status,
		Headers: map[string]string{"Content-Type": "application/json"},
		Body:    body,
	}
	json.NewEncoder(os.Stdout).Encode(resp)
}

func writeError(status int, msg string) {
	body, _ := json.Marshal(map[string]string{"error": msg})
	writeResponse(status, string(body))
}

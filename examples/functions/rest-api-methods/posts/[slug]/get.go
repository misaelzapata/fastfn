package main

import "encoding/json"

// GET /posts/:slug — slug merged into event from [slug] filename
func handler(event map[string]interface{}) interface{} {
	slug, _ := event["slug"].(string)

	body, _ := json.Marshal(map[string]interface{}{
		"slug": slug, "title": "Post: " + slug, "content": "Lorem ipsum...",
	})
	return map[string]interface{}{
		"status":  200,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

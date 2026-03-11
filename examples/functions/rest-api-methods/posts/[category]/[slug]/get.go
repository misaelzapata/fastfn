package main

import "encoding/json"

// GET /posts/:category/:slug — both params merged into event
func handler(event map[string]interface{}) interface{} {
	category, _ := event["category"].(string)
	slug, _ := event["slug"].(string)

	body, _ := json.Marshal(map[string]interface{}{
		"category": category,
		"slug":     slug,
		"title":    category + "/" + slug,
		"url":      "/posts/" + category + "/" + slug,
	})
	return map[string]interface{}{
		"status":  200,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

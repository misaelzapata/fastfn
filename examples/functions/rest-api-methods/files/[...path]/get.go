package main

import (
	"encoding/json"
	"strings"
)

// GET /files/* — catch-all, path captures everything after /files/
func handler(event map[string]interface{}) interface{} {
	pathStr, _ := event["path"].(string)
	var segments []string
	if pathStr != "" {
		segments = strings.Split(pathStr, "/")
	}

	body, _ := json.Marshal(map[string]interface{}{
		"path": pathStr, "segments": segments, "depth": len(segments),
	})
	return map[string]interface{}{
		"status":  200,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

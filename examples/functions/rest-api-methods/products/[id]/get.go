package main

import (
	"encoding/json"
	"strconv"
)

// GET /products/:id — id merged into event from [id] filename
func handler(event map[string]interface{}) interface{} {
	idStr, _ := event["id"].(string)
	id, _ := strconv.Atoi(idStr)

	body, _ := json.Marshal(map[string]interface{}{
		"id": id, "name": "Widget", "price": 9.99,
	})
	return map[string]interface{}{
		"status":  200,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

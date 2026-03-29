package main

import (
	"encoding/json"
	"strconv"
)

// PUT /products/:id — id merged into event from [id] filename
func handler(event map[string]interface{}) interface{} {
	idStr, _ := event["id"].(string)
	id, _ := strconv.Atoi(idStr)

	bodyRaw, _ := event["body"].(string)
	var data map[string]interface{}
	if err := json.Unmarshal([]byte(bodyRaw), &data); err != nil {
		errBody, _ := json.Marshal(map[string]string{"error": "Invalid JSON"})
		return map[string]interface{}{"status": 400, "body": string(errBody)}
	}

	data["id"] = id
	data["updated"] = true
	body, _ := json.Marshal(data)
	return map[string]interface{}{
		"status":  200,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

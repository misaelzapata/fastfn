package main

import "encoding/json"

// POST /products — create a product
func handler(event map[string]interface{}) interface{} {
	bodyRaw, _ := event["body"].(string)
	var data map[string]interface{}
	if err := json.Unmarshal([]byte(bodyRaw), &data); err != nil {
		errBody, _ := json.Marshal(map[string]string{"error": "Invalid JSON"})
		return map[string]interface{}{"status": 400, "body": string(errBody)}
	}

	name, _ := data["name"].(string)
	if name == "" {
		errBody, _ := json.Marshal(map[string]string{"error": "name is required"})
		return map[string]interface{}{"status": 400, "body": string(errBody)}
	}

	price, _ := data["price"].(float64)
	body, _ := json.Marshal(map[string]interface{}{
		"id": 42, "name": name, "price": price, "created": true,
	})
	return map[string]interface{}{
		"status":  201,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

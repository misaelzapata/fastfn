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
		return jsonResponse(400, map[string]string{"error": "name is required"})
	}

	price, _ := data["price"].(float64)
	return jsonResponse(201, map[string]interface{}{
		"id": 42, "name": name, "price": price, "created": true,
	})
}

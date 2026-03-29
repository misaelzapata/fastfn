package main

import "encoding/json"

type Product struct {
	ID    int     `json:"id"`
	Name  string  `json:"name"`
	Price float64 `json:"price"`
}

func catalogProducts() []Product {
	return []Product{
		{ID: 1, Name: "Widget", Price: 9.99},
		{ID: 2, Name: "Gadget", Price: 24.99},
	}
}

func jsonResponse(status int, payload interface{}) map[string]interface{} {
	body, _ := json.Marshal(payload)
	return map[string]interface{}{
		"status":  status,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

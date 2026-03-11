package main

import "encoding/json"

// GET /products — list all products
func handler(event map[string]interface{}) interface{} {
	type Product struct {
		ID    int     `json:"id"`
		Name  string  `json:"name"`
		Price float64 `json:"price"`
	}
	products := []Product{
		{ID: 1, Name: "Widget", Price: 9.99},
		{ID: 2, Name: "Gadget", Price: 24.99},
	}
	body, _ := json.Marshal(map[string]interface{}{
		"products": products,
		"total":    len(products),
	})
	return map[string]interface{}{
		"status":  200,
		"headers": map[string]string{"Content-Type": "application/json"},
		"body":    string(body),
	}
}

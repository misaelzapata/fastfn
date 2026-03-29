package main

// GET /products — list all products
func handler(event map[string]interface{}) interface{} {
	products := catalogProducts()
	return jsonResponse(200, map[string]interface{}{
		"products": products,
		"total":    len(products),
	})
}

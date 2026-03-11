<?php
// POST /products — create a product
function handler($event) {
    $body = $event["body"] ?? "";
    $data = is_string($body) ? json_decode($body, true) : ($body ?: []);

    $name = trim($data["name"] ?? "");
    $price = $data["price"] ?? 0;

    if ($name === "") {
        return [
            "status" => 400,
            "body" => json_encode(["error" => "name is required"]),
        ];
    }

    return [
        "status" => 201,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(["id" => 42, "name" => $name, "price" => $price, "created" => true]),
    ];
}

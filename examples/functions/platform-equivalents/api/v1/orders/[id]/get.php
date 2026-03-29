<?php
// GET /api/v1/orders/:id — Fetch a single order by ID
// The [id] folder name captures the path parameter automatically.

function handler($event, $params = []) {
    $id = (int)($params["id"] ?? 0);

    // Load orders from shared state file
    $state_file = dirname(__DIR__) . "/.state/orders.json";
    $orders = is_file($state_file)
        ? json_decode(file_get_contents($state_file), true) ?? []
        : [];

    // Find the matching order
    foreach ($orders as $order) {
        if (($order["id"] ?? 0) === $id) {
            return [
                "status" => 200,
                "headers" => ["Content-Type" => "application/json"],
                "body" => json_encode(["ok" => true, "order" => $order]),
            ];
        }
    }

    return [
        "status" => 404,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(["error" => "Order not found"]),
    ];
}

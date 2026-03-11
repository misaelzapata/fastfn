<?php

function json_response($status, $payload) {
    return [
        "status" => $status,
        "headers" => ["Content-Type" => "application/json; charset=utf-8"],
        "body" => json_encode($payload),
    ];
}

function load_orders() {
    $state_file = "/tmp/fastfn-platform-equivalents/orders.json";
    if (!is_file($state_file)) {
        return [];
    }
    $raw = @file_get_contents($state_file);
    if (!is_string($raw) || $raw === "") {
        return [];
    }
    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : [];
}

function handler($event, $params = []) {
    $id = isset($params["id"]) ? (int)$params["id"] : 0;
    if ($id <= 0) {
        return json_response(400, ["error" => "validation_error", "message" => "id must be a positive integer."]);
    }

    $orders = load_orders();
    foreach ($orders as $order) {
        if ((int)($order["id"] ?? 0) === $id) {
            return json_response(200, ["ok" => true, "order" => $order]);
        }
    }

    return json_response(404, ["error" => "not_found", "message" => "Order not found."]);
}

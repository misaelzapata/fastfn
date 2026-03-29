<?php
// PUT /products/:id — id arrives directly from [id] filename
function handler($event, $params) {
    $id = $params["id"] ?? "";
    $body = $event["body"] ?? "";
    $data = is_string($body) ? json_decode($body, true) : ($body ?: []);

    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(array_merge(
            ["id" => (int)$id],
            $data,
            ["updated" => true]
        )),
    ];
}

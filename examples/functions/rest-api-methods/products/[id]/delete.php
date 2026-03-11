<?php
// DELETE /products/:id — id arrives directly from [id] filename
function handler($event, $params) {
    $id = $params["id"] ?? "";
    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(["id" => (int)$id, "deleted" => true]),
    ];
}

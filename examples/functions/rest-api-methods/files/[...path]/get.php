<?php
// GET /files/* — catch-all, path captures everything after /files/
function handler($event, $params) {
    $path = $params["path"] ?? "";
    $segments = $path !== "" ? explode("/", $path) : [];
    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode([
            "path" => $path,
            "segments" => $segments,
            "depth" => count($segments),
        ]),
    ];
}

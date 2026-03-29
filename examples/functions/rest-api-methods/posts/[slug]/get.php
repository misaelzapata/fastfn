<?php
// GET /posts/:slug — slug arrives directly from [slug] filename
function handler($event, $params) {
    $slug = $params["slug"] ?? "";
    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(["slug" => $slug, "title" => "Post: $slug", "content" => "Lorem ipsum..."]),
    ];
}

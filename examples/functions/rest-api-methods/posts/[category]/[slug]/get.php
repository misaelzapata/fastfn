<?php
// GET /posts/:category/:slug — both params arrive directly
function handler($event, $params) {
    $category = $params["category"] ?? "";
    $slug = $params["slug"] ?? "";
    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode([
            "category" => $category,
            "slug" => $slug,
            "title" => "$category/$slug",
            "url" => "/posts/$category/$slug",
        ]),
    ];
}

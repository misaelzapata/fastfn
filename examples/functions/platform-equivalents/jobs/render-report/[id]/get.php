<?php

function json_response($status, $payload) {
    return [
        "status" => $status,
        "headers" => ["Content-Type" => "application/json; charset=utf-8"],
        "body" => json_encode($payload),
    ];
}

function resolve_job_file($job_id) {
    return "/tmp/fastfn-platform-equivalents/jobs/" . $job_id . ".json";
}

function handler($event, $params = []) {
    $job_id = trim((string)($params["id"] ?? ""));
    if ($job_id === "") {
        return json_response(400, ["error" => "validation_error", "message" => "id is required."]);
    }

    $job_file = resolve_job_file($job_id);
    if ($job_file === "" || !is_file($job_file)) {
        return json_response(404, ["error" => "not_found", "message" => "Job not found."]);
    }

    $raw = @file_get_contents($job_file);
    if (!is_string($raw) || $raw === "") {
        return json_response(500, ["error" => "state_error", "message" => "Job state cannot be read."]);
    }
    $job = json_decode($raw, true);
    if (!is_array($job)) {
        return json_response(500, ["error" => "state_error", "message" => "Job state is invalid JSON."]);
    }

    $created_at_ms = (int)($job["created_at_ms"] ?? 0);
    $elapsed_ms = (int)floor(microtime(true) * 1000) - $created_at_ms;
    $status = "queued";
    if ($elapsed_ms >= 1200 && $elapsed_ms < 2600) {
        $status = "running";
    } elseif ($elapsed_ms >= 2600) {
        $status = "succeeded";
    }

    $response = [
        "ok" => true,
        "job_id" => $job_id,
        "status" => $status,
        "report_type" => $job["report_type"] ?? null,
        "items_count" => (int)($job["items_count"] ?? 0),
    ];

    if ($status === "succeeded") {
        $response["result"] = [
            "generated_at" => gmdate("c"),
            "summary" => "Report generated successfully.",
            "rows" => (int)($job["items_count"] ?? 0),
        ];
    }

    return json_response(200, $response);
}

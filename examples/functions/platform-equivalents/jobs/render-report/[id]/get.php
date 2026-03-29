<?php
// GET /jobs/render-report/:id — Poll a job's status
// Simulates progress: queued -> running -> succeeded based on elapsed time.

function handler($event, $params = []) {
    $job_id = $params["id"] ?? "";
    $job_file = dirname(__DIR__) . "/.state/jobs/" . $job_id . ".json";

    if (!is_file($job_file)) {
        return [
            "status" => 404,
            "headers" => ["Content-Type" => "application/json"],
            "body" => json_encode(["error" => "Job not found"]),
        ];
    }

    $job = json_decode(file_get_contents($job_file), true);
    $elapsed_ms = floor(microtime(true) * 1000) - ($job["created_at_ms"] ?? 0);

    // Simulate async processing stages
    if ($elapsed_ms >= 2600) {
        $status = "succeeded";
    } elseif ($elapsed_ms >= 1200) {
        $status = "running";
    } else {
        $status = "queued";
    }

    $response = [
        "job_id" => $job_id,
        "status" => $status,
        "report_type" => $job["report_type"] ?? null,
    ];

    if ($status === "succeeded") {
        $response["result"] = [
            "summary" => "Report generated successfully.",
            "rows" => (int)($job["items_count"] ?? 0),
        ];
    }

    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode($response),
    ];
}

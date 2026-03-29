package main

import "encoding/json"

func handler(_ map[string]interface{}) interface{} {
    body, _ := json.Marshal(map[string]interface{}{
        "runtime": "go",
        "title": "Go worker endpoint",
        "summary": "Worker-first mode checks routes before static assets when both could answer.",
        "path": "/api-go",
    })

    return map[string]interface{}{
        "status": 200,
        "headers": map[string]string{"Content-Type": "application/json"},
        "body": string(body),
    }
}

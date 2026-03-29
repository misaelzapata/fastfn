package main

import (
    "encoding/json"
    "time"
)

func handler(event map[string]interface{}) interface{} {
    time.Sleep(200 * time.Millisecond)
    body, _ := json.Marshal(map[string]interface{}{
        "runtime": "go",
        "ok": true,
    })
    return map[string]interface{}{
        "status": 200,
        "headers": map[string]string{"Content-Type": "application/json"},
        "body": string(body),
    }
}

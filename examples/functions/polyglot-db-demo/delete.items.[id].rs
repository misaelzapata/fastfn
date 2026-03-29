use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::TcpStream;

fn resolve_internal_delete_path(event: &Value, id: &str) -> String {
    let req_path = event
        .get("path")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let suffix = format!("/items/{}", id);
    if req_path.ends_with(&suffix) {
        let prefix = &req_path[..req_path.len() - suffix.len()];
        return format!("{}/internal/items/{}", prefix, id);
    }
    format!("/internal/items/{}", id)
}

fn parse_http_status(status_line: &str) -> u16 {
    let parts: Vec<&str> = status_line.split_whitespace().collect();
    if parts.len() < 2 {
        return 502;
    }
    parts[1].parse::<u16>().unwrap_or(502)
}

fn decode_chunked_body(raw: &str) -> Result<String, String> {
    let bytes = raw.as_bytes();
    let mut i: usize = 0;
    let mut out: Vec<u8> = Vec::new();

    while i < bytes.len() {
        let mut line_end = None;
        let mut j = i;
        while j + 1 < bytes.len() {
            if bytes[j] == b'\r' && bytes[j + 1] == b'\n' {
                line_end = Some(j);
                break;
            }
            j += 1;
        }
        let end = line_end.ok_or_else(|| "invalid chunk header".to_string())?;
        let size_line = std::str::from_utf8(&bytes[i..end])
            .map_err(|e| format!("invalid chunk header utf8: {}", e))?;
        let size_token = size_line.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_token, 16)
            .map_err(|e| format!("invalid chunk size '{}': {}", size_token, e))?;
        i = end + 2;

        if size == 0 {
            break;
        }
        if i + size > bytes.len() {
            return Err("chunk size exceeds payload length".to_string());
        }
        out.extend_from_slice(&bytes[i..i + size]);
        i += size;
        if i + 1 >= bytes.len() || bytes[i] != b'\r' || bytes[i + 1] != b'\n' {
            return Err("missing chunk terminator".to_string());
        }
        i += 2;
    }

    String::from_utf8(out).map_err(|e| format!("invalid chunked body utf8: {}", e))
}

fn call_internal_delete(path: &str) -> Result<(u16, String), String> {
    let mut stream =
        TcpStream::connect("127.0.0.1:8080").map_err(|e| format!("connect failed: {}", e))?;
    let request = format!(
        "DELETE {} HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: close\r\nAccept: application/json\r\nx-fastfn-internal-call: 1\r\n\r\n",
        path
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("write failed: {}", e))?;
    stream
        .flush()
        .map_err(|e| format!("flush failed: {}", e))?;

    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|e| format!("read failed: {}", e))?;

    let split = response
        .find("\r\n\r\n")
        .ok_or_else(|| "invalid http response".to_string())?;
    let headers = &response[..split];
    let mut body = response[split + 4..].to_string();
    let mut lines = headers.lines();
    let status_line = lines.next().unwrap_or("HTTP/1.1 502 Bad Gateway");
    let status = parse_http_status(status_line);

    let mut chunked = false;
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            if k.trim().eq_ignore_ascii_case("transfer-encoding")
                && v.to_ascii_lowercase().contains("chunked")
            {
                chunked = true;
            }
        }
    }
    if chunked {
        body = decode_chunked_body(&body)?;
    }

    Ok((status, body))
}

pub fn handler(event: Value) -> Value {
    let id = event
        .get("params")
        .and_then(|p| p.get("id"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();

    if id.is_empty() {
        return json!({
            "status": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json!({"error": "id is required"}).to_string()
        });
    }

    let internal_path = resolve_internal_delete_path(&event, &id);
    let (status, raw_body) = match call_internal_delete(&internal_path) {
        Ok(v) => v,
        Err(err) => {
            return json!({
                "status": 502,
                "headers": {"Content-Type": "application/json"},
                "body": json!({
                    "error": "internal sqlite delete failed",
                    "runtime": "rust",
                    "forwarded_to": internal_path,
                    "details": err
                }).to_string()
            });
        }
    };

    let parsed: Value = serde_json::from_str(&raw_body).unwrap_or_else(|_| json!({
        "error": "invalid internal response",
        "raw": raw_body
    }));

    if status < 200 || status >= 300 {
        return json!({
            "status": status,
            "headers": {"Content-Type": "application/json"},
            "body": json!({
                "runtime": "rust",
                "route": "DELETE /items/:id",
                "forwarded_to": internal_path,
                "error": parsed.get("error").cloned().unwrap_or_else(|| json!("delete failed")),
                "details": parsed
            }).to_string()
        });
    }

    json!({
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json!({
            "runtime": "rust",
            "route": "DELETE /items/:id",
            "forwarded_to": internal_path,
            "db_kind": "sqlite",
            "deleted": parsed.get("deleted").cloned().unwrap_or_else(|| json!(null)),
            "count": parsed.get("count").cloned().unwrap_or_else(|| json!(null)),
            "db_file": parsed.get("db_file").cloned().unwrap_or_else(|| json!(null))
        }).to_string()
    })
}

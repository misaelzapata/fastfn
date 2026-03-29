use serde_json::{json, Map, Value};
use std::env;
use std::io::{self, Read, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};

mod user_handler;

fn error_response(message: &str) -> Value {
    json!({
        "status": 500,
        "headers": {"Content-Type": "application/json"},
        "body": json!({"error": message}).to_string()
    })
}

fn read_frame<R: Read>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err),
    }
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 {
        return Ok(None);
    }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload)?;
    Ok(Some(payload))
}

fn write_frame<W: Write>(writer: &mut W, payload: &Value) -> io::Result<()> {
    let encoded = serde_json::to_vec(payload).unwrap_or_else(|_| serde_json::to_vec(&error_response("failed to encode rust handler output")).unwrap());
    let header = (encoded.len() as u32).to_be_bytes();
    writer.write_all(&header)?;
    writer.write_all(&encoded)?;
    writer.flush()
}

fn merge_params_into_event(event: &mut Value) {
    let params = event.get("params").cloned();
    if let Some(params_value) = params {
        if let (Some(event_map), Some(params_map)) = (event.as_object_mut(), params_value.as_object()) {
            for (key, value) in params_map {
                if !event_map.contains_key(key) {
                    event_map.insert(key.clone(), value.clone());
                }
            }
        }
    }
}

fn apply_runtime_env(event: &Value) -> Vec<(String, Option<String>)> {
    let mut previous: Vec<(String, Option<String>)> = Vec::new();
    let Some(env_map) = event.get("env").and_then(|value| value.as_object()) else {
        return previous;
    };

    for (key, value) in env_map {
        let prior = env::var(key).ok();
        previous.push((key.clone(), prior));
        if value.is_null() {
            env::remove_var(key);
        } else {
            let string_value = value.as_str().map(|item| item.to_string()).unwrap_or_else(|| value.to_string());
            env::set_var(key, string_value);
        }
    }
    previous
}

fn restore_runtime_env(previous: Vec<(String, Option<String>)>) {
    for (key, value) in previous {
        if let Some(item) = value {
            env::set_var(key, item);
        } else {
            env::remove_var(key);
        }
    }
}

fn handle_event(mut event: Value) -> Value {
    merge_params_into_event(&mut event);
    match catch_unwind(AssertUnwindSafe(|| user_handler::handler(event))) {
        Ok(out) => out,
        Err(_) => error_response("rust handler panicked"),
    }
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();

    loop {
        let frame = match read_frame(&mut reader) {
            Ok(Some(payload)) => payload,
            Ok(None) => break,
            Err(_) => {
                let _ = write_frame(&mut writer, &error_response("failed to read stdin"));
                break;
            }
        };

        let req: Value = serde_json::from_slice(&frame).unwrap_or_else(|_| json!({}));
        let event = req.get("event").cloned().unwrap_or_else(|| Value::Object(Map::new()));
        let previous_env = apply_runtime_env(&event);
        let out = handle_event(event);
        restore_runtime_env(previous_env);
        if write_frame(&mut writer, &out).is_err() {
            break;
        }
    }
}

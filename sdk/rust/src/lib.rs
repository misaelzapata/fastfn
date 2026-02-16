use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Deserialize, Serialize)]
pub struct ClientInfo {
    pub ip: String,
    pub ua: Option<String>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub struct Context {
    pub request_id: String,
    pub function_name: Option<String>,
    pub runtime: Option<String>,
    pub version: Option<String>,
    #[serde(default)]
    pub debug: serde_json::Value,
    #[serde(default)]
    pub user: serde_json::Value,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Request {
    pub id: String,
    pub ts: i64,
    pub method: String,
    pub path: String,
    pub raw_path: String,
    #[serde(default)]
    pub query: HashMap<String, String>,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default)]
    pub body: serde_json::Value,
    #[serde(default)]
    pub client: Option<ClientInfo>,
    #[serde(default)]
    pub context: Context,
    #[serde(default)]
    pub env: HashMap<String, String>,
}

#[derive(Debug, Serialize)]
pub struct ProxyDirective {
    pub path: String,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub headers: Option<HashMap<String, String>>,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub status: u16,
    pub headers: HashMap<String, String>,
    // Body can be string or JSON value. We use Value to catch-all.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proxy: Option<ProxyDirective>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_base64: Option<bool>,
}

impl Response {
    pub fn new(status: u16, body: String) -> Self {
        Response {
            status,
            headers: HashMap::new(),
            body: Some(body),
            proxy: None,
            is_base64: None,
        }
    }

    pub fn json<T: Serialize>(status: u16, data: T) -> Self {
        let mut headers = HashMap::new();
        headers.insert("Content-Type".to_string(), "application/json".to_string());
        
        let body_str = serde_json::to_string(&data).unwrap_or_default();
        
        Response {
            status,
            headers,
            body: Some(body_str),
            proxy: None,
            is_base64: None,
        }
    }

    pub fn proxy(path: &str, method: &str) -> Self {
        Response {
            status: 200, // Ignored by runtime in proxy mode usually, but technically required by struct
            headers: HashMap::new(),
            body: None,
            proxy: Some(ProxyDirective {
                path: path.to_string(),
                method: method.to_string(),
                headers: None,
            }),
            is_base64: None,
        }
    }
}

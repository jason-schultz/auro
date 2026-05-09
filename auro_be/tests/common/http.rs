use axum::body::{to_bytes, Body};
use axum::http::{Method, Request, Response};
use serde_json::Value;

pub fn request(method: Method, uri: &str, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if body.is_some() {
        builder = builder.header("content-type", "application/json");
    }

    let body = match body {
        Some(value) => Body::from(value.to_string()),
        None => Body::empty(),
    };

    builder.body(body).unwrap()
}

#[allow(dead_code)]
pub fn request_raw_json(method: Method, uri: &str, raw_body: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .body(Body::from(raw_body.to_string()))
        .unwrap()
}

pub async fn response_json(response: Response<Body>) -> Value {
    let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

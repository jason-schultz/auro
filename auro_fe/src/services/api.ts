const RUST_BASE = "/api";
const OPUS_BASE = "/opus/api";

async function request<T>(base: string, path: string, options?: RequestInit): Promise<T> {
  const response = await fetch(`${base}${path}`, {
    headers: {
      "Content-Type": "application/json",
    },
    ...options,
  });

  if (!response.ok) {
    throw new Error(`API error: ${response.status} ${response.statusText}`);
  }

  return response.json();
}

export const api = {
  get: <T>(path: string) => request<T>(RUST_BASE, path),
  post: <T>(path: string, body: unknown) =>
    request<T>(RUST_BASE, path, { method: "POST", body: JSON.stringify(body) }),
  put: <T>(path: string, body: unknown) =>
    request<T>(RUST_BASE, path, { method: "PUT", body: JSON.stringify(body) }),
  delete: <T>(path: string) => request<T>(RUST_BASE, path, { method: "DELETE" }),
};

export const opusApi = {
  get: <T>(path: string) => request<T>(OPUS_BASE, path),
  post: <T>(path: string, body: unknown) =>
    request<T>(OPUS_BASE, path, { method: "POST", body: JSON.stringify(body) }),
};

const RUST_BASE = "/api";
const OPUS_BASE = "/opus/api";

export class ApiError extends Error {
  status: number;
  body: unknown;

  constructor(status: number, body: unknown, message?: string) {
    super(message ?? `API error: ${status}`);
    this.name = "ApiError";
    this.status = status;
    this.body = body;
  }
}

export function isApiError(error: unknown): error is ApiError {
  return error instanceof ApiError;
}

export function getApiErrorStatus(error: unknown): number | null {
  return isApiError(error) ? error.status : null;
}

export function getApiErrorMessage(error: unknown, fallbackMessage: string): string {
  if (isApiError(error)) {
    if (typeof error.body === "string" && error.body.length > 0) {
      return error.body;
    }

    if (error.body && typeof error.body === "object") {
      const maybeError = (error.body as { error?: unknown }).error;
      if (typeof maybeError === "string" && maybeError.length > 0) {
        return maybeError;
      }
    }

    return error.message;
  }

  if (error instanceof Error && error.message.length > 0) {
    return error.message;
  }

  return fallbackMessage;
}

async function request<T>(base: string, path: string, options?: RequestInit): Promise<T> {
  const headers = {
    "Content-Type": "application/json",
    ...(options?.headers ?? {}),
  };

  const response = await fetch(`${base}${path}`, { ...options, headers });

  const rawBody = await response.text();
  const parsedBody = parseResponseBody(rawBody);

  if (!response.ok) {
    const message = buildApiErrorMessage(response.status, response.statusText, parsedBody);
    throw new ApiError(response.status, parsedBody, message);
  }

  return parsedBody as T;
}

function parseResponseBody(raw: string): unknown {
  if (!raw) return null;

  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

function buildApiErrorMessage(status: number, statusText: string, body: unknown): string {
  if (body && typeof body === "object") {
    const maybeError = (body as { error?: unknown }).error;
    if (typeof maybeError === "string" && maybeError.length > 0) {
      return `API error: ${status} ${maybeError}`;
    }
  }

  return `API error: ${status} ${statusText}`;
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

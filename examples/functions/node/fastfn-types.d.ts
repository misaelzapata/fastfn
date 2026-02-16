/**
 * FastFN Runtime Types
 * Copy this file or reference it to get intellisense in your handlers.
 */

export interface Request<TBody = any, TQuery = Record<string, string>> {
  /** unique request id (e.g. "req-123") */
  id: string;
  /** HTTP method */
  method: "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "OPTIONS" | "HEAD";
  /** URL path */
  path: string;
  /** Query string parameters */
  query: TQuery;
  /** Request headers (lowercase) */
  headers: Record<string, string>;
  /** Parsed body (JSON) or raw string */
  body: TBody;
  /** Internal request context (user, debug info) */
  context?: Record<string, any>;
}

export interface ProxyDirective {
  /** Target path (e.g., "/hello") or full URL */
  path: string;
  /** HTTP method for the upstream request */
  method?: string;
  /** Headers to forward */
  headers?: Record<string, string>;
}

export interface Response {
  /** HTTP Status Code (default: 200) */
  status?: number;
  /** Response headers */
  headers?: Record<string, string>;
  /** Response body (string, object, or buffer) */
  body?: string | object;
  /** Instead of body, return a proxy directive */
  proxy?: ProxyDirective;
}

export type Handler = (req: Request) => Promise<Response | object> | Response | object;

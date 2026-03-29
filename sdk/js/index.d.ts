/**
 * FastFN Runtime Types
 * 
 * To use in your handler:
 * /** @type {import('@fastfn/runtime').Handler} */
 * exports.handler = async (req) => { ... }
 */

export interface Request<TQuery = Record<string, string>, TBody = any> {
  /** Unique request ID (e.g. "req-123abc456") */
  id: string;
  
  /** HTTP Method */
  method: "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "OPTIONS" | "HEAD";
  
  /** URL Path, relative to the functions root */
  path: string;
  
  /** Parsed query parameters */
  query: TQuery;
  
  /** 
   * Request headers (keys are lower-cased).
   * Note: Headers are read-only.
   */
  headers: Record<string, string>;
  
  /** 
   * Request body.
   * - If Content-Type is application/json, this is a parsed object.
   * - Otherwise, it is a string.
   */
  body: TBody;

  /** Timestamp of the request (ms since epoch) */
  ts: number;

  /** Raw path (including query string) */
  raw_path: string;

  /** Client information */
  client: {
    ip: string;
    ua?: string;
  };
  
  /** Internal context (trace IDs, user info, debug flags) */
  context: Context;

  /** Environment variables available to the function */
  env: Record<string, string>;
}

export interface Context {
  /** Request ID (same as req.id) */
  request_id: string;

  /** Name of the function being executed */
  function_name: string;

  /** Runtime usage (e.g. "node", "python") */
  runtime: string;

  /** Version label (e.g. "latest", "v1") */
  version: string;

  /** Debug flags */
  debug?: {
    enabled?: boolean;
    [key: string]: any;
  };
  /** Authenticated user info (if configured) */
  user?: {
    id?: string;
    sub?: string;
    [key: string]: any;
  };
  [key: string]: any;
}

export interface ProxyDirective {
  /** Target path (e.g., "/hello") or absolute URL if allowed */
  path: string;
  /** HTTP method for the upstream request */
  method?: string;
  /** Headers to forward to the upstream */
  headers?: Record<string, string>;
}

export interface ResponseBody {
  /** HTTP Status Code (default: 200) */
  status?: number;
  /** Response headers */
  headers?: Record<string, string>;
  /** Response body */
  body?: string | object | Buffer;
  /** Use this to perform an Edge Proxy request instead of returning body */
  proxy?: ProxyDirective;
  /** Set to true if body is base64 encoded */
  is_base64?: boolean;
}

/** 
 * FastFN Handler Function
 */
export type Handler = (req: Request) => Promise<ResponseBody | object> | ResponseBody | object;

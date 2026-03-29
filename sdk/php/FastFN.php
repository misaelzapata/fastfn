<?php

namespace FastFN;

/**
 * FastFN PHP Runtime SDK.
 * Include this file to get type hints in your IDE.
 */

class Request {
    /** @var string Unique ID for the request */
    public string $id;

    /** @var string HTTP Method (GET, POST, etc) */
    public string $method;

    /** @var string Request Path */
    public string $path;

    /** @var array<string, string> Query parameters */
    public array $query;

    /** @var array<string, string> Headers (lowercase keys) */
    public array $headers;

    /** @var mixed Request body (array if JSON, string otherwise) */
    public mixed $body;

    /** @var int Request timestamp (ms) */
    public int $ts;

    /** @var string Raw path with query string */
    public string $raw_path;

    /** @var array Client info (ip, ua) */
    public array $client;

    /** @var array Context (env, debug, user info) */
    public array $context;

    /** @var array Environment variables */
    public array $env;

    public function __construct(array $data) {
        $this->id = $data['id'] ?? '';
        $this->ts = $data['ts'] ?? 0;
        $this->method = $data['method'] ?? 'GET';
        $this->path = $data['path'] ?? '/';
        $this->raw_path = $data['raw_path'] ?? '/';
        $this->query = $data['query'] ?? [];
        $this->headers = $data['headers'] ?? [];
        $this->body = $data['body'] ?? '';
        $this->client = $data['client'] ?? ['ip' => '0.0.0.0'];
        $this->context = $data['context'] ?? [];
        $this->env = $data['env'] ?? [];
    }
}

class Response {
    /**
     * @param int $status HTTP Status code
     * @param array $headers Response headers
     * @param mixed $body Content (string or array for JSON)
     * @param array|null $proxy Proxy directive (optional)
     */
    public static function json($body, int $status = 200, array $headers = []): array {
        return [
            'status' => $status,
            'headers' => array_merge(['Content-Type' => 'application/json'], $headers),
            'body' => json_encode($body)
        ];
    }

    public static function text(string $body, int $status = 200, array $headers = []): array {
        return [
            'status' => $status,
            'headers' => array_merge(['Content-Type' => 'text/plain; charset=utf-8'], $headers),
            'body' => $body
        ];
    }

    public static function proxy(string $path, string $method = 'GET', array $headers = []): array {
        return [
            'proxy' => [
                'path' => $path,
                'method' => strtoupper($method),
                'headers' => $headers
            ]
        ];
    }

    public static function startProxy(string $path, string $method = 'GET', array $headers = []): array {
        return self::proxy($path, $method, $headers);
    }
}

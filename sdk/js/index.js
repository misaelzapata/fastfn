'use strict';

class Response {
  static json(body, status = 200, headers = {}) {
    return {
      status: Number(status),
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body),
    };
  }

  static text(body, status = 200, headers = {}) {
    return {
      status: Number(status),
      headers: { 'Content-Type': 'text/plain; charset=utf-8', ...headers },
      body: String(body),
    };
  }

  static proxy(path, method = 'GET', headers = {}) {
    return {
      proxy: {
        path: String(path),
        method: String(method).toUpperCase(),
        headers: { ...headers },
      },
    };
  }
}

module.exports = {
  Response,
};

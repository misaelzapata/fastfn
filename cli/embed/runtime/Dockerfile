# THIS FILE IS EMBEDDED IN THE CLI BINARY

FROM openresty/openresty:1.27.1.2-0-alpine-fat

WORKDIR /app

# Copy embedded resources (Must match embed structure)
COPY openresty /app/openresty
COPY srv/fn/runtimes /app/srv/fn/runtimes
# COPY srv/fn/functions /app/srv/fn/functions # Functions are mounted by user
COPY docker/openresty/start.sh /app/docker/openresty/start.sh

RUN apk add --no-cache python3 py3-pip nodejs npm git openssh-client php php-phar rust cargo go luarocks5.1 \
  && luarocks-5.1 install luacov 0.17.0-1 \
  && mkdir -p /app/openresty/logs /tmp/fastfn /app/srv/fn/functions \
  && chmod +x /app/docker/openresty/start.sh

ENV FN_FUNCTIONS_ROOT=/app/srv/fn/functions
ENV FN_SOCKET_BASE_DIR=/tmp/fastfn
ENV FN_RUNTIMES=python,node,php,lua
ENV FN_HOT_RELOAD=1
ENV FN_HOT_RELOAD_INTERVAL=2
ENV FN_PREINSTALL_PY_DEPS_ON_START=0
ENV FN_PREINSTALL_NODE_DEPS_ON_START=0
ENV FN_PY_SOCKET=/tmp/fastfn/fn-python.sock
ENV FN_NODE_SOCKET=/tmp/fastfn/fn-node.sock
ENV FN_PHP_SOCKET=/tmp/fastfn/fn-php.sock
ENV FN_RUST_SOCKET=/tmp/fastfn/fn-rust.sock
ENV FN_GO_SOCKET=/tmp/fastfn/fn-go.sock

EXPOSE 8080

CMD ["/app/docker/openresty/start.sh"]

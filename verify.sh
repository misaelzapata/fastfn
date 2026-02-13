#!/bin/bash
# verify.sh
set -e

# Start background
./bin/fastfn dev test > dev.log 2>&1 &
PID=$!
echo "Started PID $PID"

# Wait for healthy
echo "Waiting for start..."
sleep 10

# Check mount
echo "Checking mount..."
docker compose exec -T openresty ls -l /app/srv/fn/functions/node/my-demo/

# Check logs
echo "Checking logs..."
docker compose logs openresty | tail -n 20

# Test
echo "Curling..."
curl -v http://localhost:8080/my-demo/ || true

# Cleanup
kill $PID || true
docker compose down
echo "Done."

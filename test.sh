#!/bin/bash
# 统一跑所有库的测试（单元测试随库走，见各 lib/*/test/）
set -e
cd "$(dirname "$0")"

echo "=== promise 库测试（luv 后端） ==="
lua lib/promise/test/test_promise.lua

echo
echo "=== promise 并发验证 ==="
lua lib/promise/test/test_concurrency.lua

echo
echo "=== promise await 接管 thenable ==="
lua lib/promise/test/test_await_thenable.lua

echo
echo "=== promise 未处理 rejection 检测 ==="
lua lib/promise/test/test_unhandled_rejection.lua

echo
echo "=== 编译 http C 绑定 ==="
bash lib/http/build.sh

echo
echo "=== http 库测试 ==="
PORT=8000
python3 lib/http/test/http_server.py "$PORT" >/tmp/jm_async_http_server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
sleep 0.5
lua lib/http/test/test_http.lua "$PORT"

echo
echo "=== http withTimeout 不取消底层请求 ==="
timeout 10 lua lib/http/test/test_timeout_cancel.lua "$PORT"

echo
echo "=== http server 自测 ==="
timeout 30 lua lib/http/test/test_server.lua

echo
echo "=== 全部通过 ==="

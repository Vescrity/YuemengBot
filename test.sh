#!/bin/bash
# 统一跑所有库的测试（单元测试随库走，见各 lib/*/test/）
set -e
cd "$(dirname "$0")"

echo "=== promise 库测试（luv 后端，默认） ==="
lua lib/promise/test/test_promise.lua

echo
echo "=== promise 库测试（luasocket 后端） ==="
PROMISE_BACKEND=luasocket lua lib/promise/test/test_promise.lua

echo
echo "=== promise 并发验证（luv 后端） ==="
lua lib/promise/test/test_concurrency.lua

echo
echo "=== 全部通过 ==="

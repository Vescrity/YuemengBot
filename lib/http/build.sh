#!/bin/bash
# 编译 _http_curl C 绑定 -> _http_curl.so（Lua 5.5 + libcurl + pthread）
set -e
cd "$(dirname "$0")"

cc -shared -fPIC -O2 -I/usr/include _http_curl.c -lcurl -llua -lm -pthread -o _http_curl.so

echo "已生成 _http_curl.so"

#!/bin/bash
# 编译 regex C 绑定（PCRE2-8）-> regex.so（Lua 5.5）
set -e
cd "$(dirname "$0")"

cc -shared -fPIC -O2 $(pkg-config --cflags libpcre2-8) regex.c \
    $(pkg-config --libs libpcre2-8) -llua -lm -o regex.so

echo "已生成 regex.so"

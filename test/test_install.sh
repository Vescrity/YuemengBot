#!/bin/bash
# 安装冒烟：安装到临时前缀，用指定 config 目录启动
set -e
cd "$(dirname "$0")/.."

PREFIX=/tmp/opencode/yuemeng-install-test
CONFIG_DIR=/tmp/opencode/yuemeng-install-config

rm -rf "$PREFIX" "$CONFIG_DIR"
make install PREFIX="$PREFIX"

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/yuemeng.lua" <<'EOF'
local core = require("core")
assert(core.perm.root == 100)
core.service.log.get("smoke"):info("装配成功")
EOF

"$PREFIX/bin/yuemeng" --config "$CONFIG_DIR"

echo "安装冒烟通过"

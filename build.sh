#!/bin/bash
# 编译脚本 - 在本地执行，生成 Linux 二进制文件

set -e

VERSION=${1:-"v1.0.0"}
BINARY_NAME="go-ipv6-pool"

echo "编译版本: $VERSION"

# 编译 Linux amd64
echo "编译 Linux amd64..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o ${BINARY_NAME}-linux-amd64 .

# 编译 Linux arm64
echo "编译 Linux arm64..."
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-s -w" -o ${BINARY_NAME}-linux-arm64 .

echo "编译完成！"
ls -lh ${BINARY_NAME}-linux-*

echo ""
echo "请将以下文件上传到 GitHub Release ($VERSION):"
echo "  - ${BINARY_NAME}-linux-amd64"
echo "  - ${BINARY_NAME}-linux-arm64"

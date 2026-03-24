#!/usr/bin/env bash
set -euo pipefail

BINARY="podlet-x86_64-unknown-linux-gnu"
BASE_URL="https://github.com/containers/podlet/releases/latest/download"

echo "========================================="
echo " Podlet 安裝腳本"
echo "========================================="

# 下載最新版及其 checksum
echo ""
echo "[1/5] 下載最新版..."
if curl -fLO "${BASE_URL}/${BINARY}.tar.xz" && \
   curl -fLO "${BASE_URL}/${BINARY}.tar.xz.sha256"; then
    echo "  ✅ 下載成功"
else
    echo "  ❌ 下載失敗，請檢查網路連線"; exit 1
fi

# 驗證 checksum
echo ""
echo "[2/5] 驗證 checksum..."
if sha256sum -c "${BINARY}.tar.xz.sha256"; then
    echo "  ✅ Checksum 驗證通過"
else
    echo "  ❌ Checksum 驗證失敗，檔案可能損毀或被竄改"
    rm -f "${BINARY}.tar.xz" "${BINARY}.tar.xz.sha256"
    exit 1
fi

# 解壓縮並安裝
echo ""
echo "[3/5] 解壓縮並安裝到 /usr/local/bin/..."
if tar -xf "${BINARY}.tar.xz" && \
   sudo mv "${BINARY}/podlet" /usr/local/bin/; then
    echo "  ✅ 安裝成功"
else
    echo "  ❌ 安裝失敗"; exit 1
fi

# 清除暫存檔案
echo ""
echo "[4/5] 清除暫存檔案..."
rm -rf "${BINARY}.tar.xz" "${BINARY}.tar.xz.sha256" "${BINARY}/"
echo "  ✅ 清除完成"

# 驗證安裝
echo ""
echo "[5/5] 驗證安裝..."
if command -v podlet &>/dev/null; then
    echo "  ✅ podlet $(podlet --version) 安裝完成"
else
    echo "  ❌ podlet 未在 PATH 中找到"; exit 1
fi

echo ""
echo "========================================="
echo " 安裝完成！執行 podlet -h 查看用法"
echo "========================================="

#!/usr/bin/env bash
# 扫描已跟踪文件中的真实内网 / Tailscale IP、H5 token、Tailscale Auth Key 与私钥。
# 占位符（100.64.0.0/1/2、192.168.1.20）不算泄露。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PATTERN='(192\.168\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|h5_[A-Za-z0-9]{16,}|tskey-auth-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'
ALLOW='100\.64\.0\.(0|1|2)|192\.168\.1\.20'

matches="$(git grep -nE "$PATTERN" -- \
  ':!*.png' ':!*.jpg' ':!*.jpeg' ':!*.hap' ':!*.so' ':!*.p12' ':!*.p7b' ':!*.cer' \
  ':!test-artifacts/*' ':!docs/legacy/pc-bridge/*' 2>/dev/null || true)"

if [ -n "$matches" ]; then
  matches="$(printf '%s\n' "$matches" | grep -vE "$ALLOW" || true)"
fi

if [ -n "$matches" ]; then
  echo "检测到潜在敏感信息（真实内网/Tailscale IP、H5 token、Auth Key 或私钥）：" >&2
  echo "$matches" >&2
  exit 1
fi

echo "secret scan: OK"

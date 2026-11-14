# Tailscale 原生库构建记录

`entry/libs/arm64-v8a/libtailscale_go.so` 由以下工具链在 2026-11-07 构建。目标是让换机器时能复现，而不是依赖本机临时改动。

## 版本

| 组件 | 版本 / 提交 |
|---|---|
| Go bootstrap | 1.27.3 官方发行版 |
| `flypigJ/go-ohos` | 提交 `9f8bcc7`，bootstrap 出 `go1.27.3-ohos-devel` |
| `flypigJ/tailscale-ohos-core` | Tailscale 1.104.5，上游 `73a4805`，已 `prepare` 并应用 patches |
| DevEco Studio | 6.1.1 |
| HarmonyOS native SDK | 本机只有 API 24（未安装 API 26） |

## 本机 SDK 偏差

上游脚本要求 `apiVersion == 26`。本机 DevEco 6.1.1 只带 API 24 native SDK，为打通构建，在**仓库外的构建目录**里把校验放宽为接受 24/26：

- `_tailscale-build/go-ohos/ohos/scripts/common.py`
- `_tailscale-build/tailscale-ohos-core/scripts/common.py`

改动内容：将 `apiVersion == 26` 的判断改为 `apiVersion in (24, 26)`（或等价条件）。该改动不在本仓库内，换机器复现时需手动应用，或安装 API 26 Release native SDK 后还原校验。

`sdk-smoke` 用 API 24 native SDK 通过；产物在 API 26 真机（HBN-AL80）加载、运行正常。

## 构建命令

```bash
cd C:/Users/Administrator/DevEcoProjects/_tailscale-build/tailscale-ohos-core
python scripts/manage.py build \
  --go-root C:/Users/Administrator/DevEcoProjects/_tailscale-build/go-ohos \
  --sdk "C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
```

产物：

- `out/arm64-v8a/libtailscale_go.so`（41 个 `TS*` 导出，AArch64；`llvm-strip --strip-debug` 后约 26MB）
- `libtailscale_go.h`
- `build.json`

## 校验

`entry/libs/arm64-v8a/SHA256SUMS` 记录当前产物的 SHA-256，`tools/build-sign-install.sh` 会在构建前校验。更新 `.so` 后请同步更新该文件。

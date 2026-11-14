# cc-haha-mobile

cc-haha 的 HarmonyOS NEXT 客户端：连接 PC 端 cc-haha 的本地 HTTP/WebSocket 服务，
在手机上查看会话、接收流式回复、切换模型/权限模式，并可选内置 Tailscale 实现外网访问。

> 私有仓库。运行需要 PC 端配套软件；本仓库不包含完整的 PC 服务端。

## 目录结构

```
harmony-app/            HarmonyOS 应用（ArkTS + NAPI）
  entry/src/main/ets/   页面、组件、服务
  entry/src/main/cpp/   libtailscale_ohos_bridge NAPI 桥
  entry/libs/arm64-v8a/ 预编译 libtailscale_go.so（Git LFS）
pc-bridge/              PC 端桥接/协议参考实现（TypeScript）
tools/                  构建 + 签名 + 安装脚本
INSTALL.md              安装、配对与常见问题
HANDOVER.md             开发/真机测试记录
THIRD_PARTY_NOTICES.md  第三方组件许可（完整文本见 licenses/）
```

## 快速开始

```bash
git lfs install          # 首次克隆后需要拉取预编译 .so
```

构建、签名、安装见 **[INSTALL.md](INSTALL.md)**。脚本方式：

```bash
KEY_PWD='<keystore密码>' STORE_PWD='<keystore密码>' tools/build-sign-install.sh
```

调试签名 profile 绑定设备 UDID，换设备需重新生成签名；不要把签名材料提交到仓库。

### 用小白调试助手安装（第三方侧载工具，常称“小白调试工具”）

适合不想安装 DevEco Studio 的用户。工具本身由第三方提供，请从可信来源获取并自行评估风险。

1. 先在 Windows / macOS / Android 设备上按工具说明部署“小白调试助手”（首次需要非鸿蒙设备）。
2. 手机开启开发者模式；如工具要求，同时打开 USB 调试。
3. 打开小白调试助手，选择 Release 中的 `cc-haha-mobile-1.0.0-unsigned.hap`。
4. 按工具提示完成签名/安装。不同版本的界面和按钮可能不同，以工具内说明为准。
5. 安装完成后打开 App，按 [INSTALL.md](INSTALL.md) 完成配对。

注意：
- 本仓库提供的是**未签名 HAP**。如果小白调试助手提示签名失败，请改用 DevEco Studio 自动签名，或 `tools/build-sign-install.sh` 自行签名。
- 调试签名绑定设备 UDID，不能把别人的签名包直接拿来用。
- Release 附件下载：[latest release](https://github.com/KOTMMMMM/cc-haha-mobile/releases/latest)。

## 安全与发布注意

- `signing/`、`test-artifacts/`、构建产物、备份目录均已加入 `.gitignore`，不要强制添加。
- 签名密码只通过 `KEY_PWD`/`STORE_PWD` 环境变量传入。
- 预签名 HAP 不适合公开分发（调试 profile 仅对登记设备有效）。
- 内置 Tailscale 属于 VPN 能力，公开分发/上架前需评估合规要求。
- 本仓库原创代码采用 MIT 许可证；随包分发的第三方组件仍按其各自许可证（见 `THIRD_PARTY_NOTICES.md`）。

## License

MIT © 2026 KOTMMMMM

第三方组件（Tailscale、Go、MeshArc、LLVM libc++ 等）保留其原有许可证，详见 `THIRD_PARTY_NOTICES.md` 与 `licenses/`。

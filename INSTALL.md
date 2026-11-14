# 安装与配对指南

本文档覆盖三种场景：用 DevEco Studio 自动签名运行、命令行签名安装、以及用第三方「小白安装器」侧载。所有方式都需要你自己生成/持有签名材料，**不要把证书、profile、密码提交到仓库**。

## 前置条件

- HarmonyOS NEXT 真机（本项目在 HBN-AL80 / HarmonyOS 7.0 / API 26 验证）
- 手机与 PC 在同一局域网，或双方都已登录同一 Tailscale 账号
- PC 端已安装并开启 cc-haha 的 H5 访问（固定端口 65499）
- 构建工具：DevEco Studio 6.1.1（自带 Node/JBR/hvigor）

## 方式 A：DevEco Studio 自动签名（最省事）

1. 用 DevEco Studio 打开 `harmony-app`。
2. 登录华为账号，进入 **File → Project Structure → Signing Configs**，勾选「Automatically generate signature」。
3. 在 `build-profile.json5` 的 `products[0]` 增加 `"signingConfig": "default"`（只勾选不会自动绑定）。
4. 连接手机（开启开发者模式和 USB 调试），点击 Run。

注意：调试签名 profile 会绑定设备 UDID；换设备需要重新生成签名。

## 方式 B：命令行签名（本仓库脚本）

准备签名材料（示例路径）：

```
signing/cchaha_debug.p12
signing/cchaha_debug.cer
signing/cchaha_debug_profile.p7b
```

运行：

```bash
KEY_PWD='你的keystore密码' STORE_PWD='你的keystore密码' \
  tools/build-sign-install.sh
```

脚本会依次执行 hvigor 构建、`hap-sign-tool` 签名、`hdc install -r`。只想构建和签名时加 `SKIP_INSTALL=1`。

可选环境变量：

| 变量 | 说明 |
|---|---|
| `DEVECO_HOME` | DevEco Studio 安装目录 |
| `KEYSTORE` / `CERT` / `PROFILE` | 签名材料路径 |
| `KEY_ALIAS` | keystore 别名，默认 `cchaha_debug` |
| `COMPAT_VERSION` | 与 `compatibleSdkVersion` 一致，默认 `23` |
| `HDC` | hdc 可执行文件路径 |

## 方式 C：小白安装器

第三方「小白安装器」本质上是帮你完成 hdc 安装/自动签名，适合不熟悉 DevEco 的用户。通用步骤：

1. 开启手机开发者模式和 USB 调试。
2. 用安装器选择已签名的 HAP。
3. 如果提示证书不匹配，需要用自己的华为账号重新签名（调试 profile 绑定 UDID，不能直接复用别人的签名包）。

> 一个预签名 HAP **不能**直接分享给所有人：调试 profile 只对签发时登记的设备有效。公开分发时应引导用户自行签名，或改为上架应用市场。

## 首次连接（扫码 / 剪贴板）

1. PC 端 cc-haha → 设置 → H5 访问 → 启用，复制 H5 链接（含 `serverUrl` 和 `h5Token`），或展示二维码。
2. 手机打开 App，在配对页：
   - **扫码配对**：调用系统扫码 UI 识别二维码；内容支持 H5 链接或 JSON（`{host, port, token, alt}`）。
   - **从剪贴板导入**：把 H5 链接复制到手机剪贴板后点一下即可。
   - 也可以手动粘贴链接或填写 host/port/token。
3. 如果 PC 有 Tailscale IP，把 `100.x.x.x` 填入备用地址，出门时会自动切换。

## 内置 Tailscale 登录

首次开启内置 Tailscale 后有两种登录方式：

- **应用内登录**：设置页点「应用内登录」，在 App 内 WebView 完成 Tailscale 账号授权，扩展检测到 `running` 后自动返回。
- **Auth Key 登录**：在 Tailscale 管理后台生成 `tskey-auth-...`，粘贴到设置页的 Auth Key 输入框。密钥只写一次到 `request.json`，扩展读取后会立即清除。

登录态会持久化；冷启动、停止/重开都不需要重新登录。

## 常见问题

| 现象 | 处理 |
|---|---|
| `Invalid URL format` / 一直显示缓存 | 确认手机当前网络能访问 PC；等 Tailscale running 后会自动重试 |
| 创建 VPN 失败 `2203002` | 系统里已有其他 VPN（如 ClashBox），先断开再开启内置 Tailscale |
| 扫码后连不上 | 二维码里的地址可能只在局域网可用；补充 Tailscale 备用地址，或在家/外网分别测试 |
| 安装提示签名不一致 | 需要卸载旧包或使用同一份签名材料；卸载会清除 App 数据 |
| 设备锁屏导致安装失败 | 保持屏幕解锁后重试 |
| 回复很慢 | 检查会话上下文占用；超大会话建议新开 |

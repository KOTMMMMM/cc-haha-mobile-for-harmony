# 发布信息与平台建议

## 长文

- 文件：`docs/blog/2026-11-14-tailscale-ohos-port.md`
- 标题候选：
  1. 把 Tailscale 搬进鸿蒙：从 go-ohos 交叉编译到 VPN 扩展的完整踩坑
  2. 鸿蒙没有官方 Tailscale，我从源码编了一个：go-ohos + NAPI + VPN 扩展实录
  3. 一次把 Tailscale 1.104.5 带进 HarmonyOS NEXT：探针 TUN、路由与登录态修复
- 摘要（短）：
  把 Tailscale 1.104.5 从源码编译成 OHOS arm64 动态库，通过 NAPI 交给鸿蒙 VPN 扩展进程，跑通探针 TUN、生产 TUN、路由防环与登录态恢复。记录 go-ohos bootstrap、NAPI 桥、VpnConfig 配置和一次“启动早期调用 authUrl 导致反复登录”的排查过程。
- 摘要（长）：
  鸿蒙没有官方 Tailscale 客户端。本文记录如何用 flypigJ/go-ohos 与 tailscale-ohos-core 交叉编译 Tailscale 1.104.5，通过 NAPI 桥暴露给 VPN 扩展进程；如何先建探针 TUN 完成登录、再切换生产 TUN；如何配置 100.64.0.0/10 路由、trustedApplications 和 protectProcessNet 避免流量绕过与路由环；以及一个隐蔽的登录态丢失问题——启动第一秒调用 authUrl 会触发 StartLoginInteractive，打断本地节点密钥自动重连，修复方式是 NeedsLogin 连续 5 秒后才请求登录链接。

## 标签

`HarmonyOS` `鸿蒙` `HarmonyOS NEXT` `ArkTS` `OHOS` `Tailscale` `Go` `NAPI` `VPN` `Claude Code`

## 封面建议

- 首选：手机设置页 Tailscale 显示 `running` 的截图 + 右侧架构图（UI 进程 / VPN 扩展 / Go 后端）。
- 次选：`status.json` 心跳截图或真机信号栏 VPN 图标。
- 不要使用含真实 IP、token、聊天内容的截图。

## 各平台发布要点

### 掘金

- 直接粘贴长文，使用 Markdown 代码块。
- 标签选 `HarmonyOS`、`Tailscale`、`Go`、`NAPI`。
- 首段加 TL;DR，方便移动端阅读。
- 分两次发布可选：第一篇讲 go-ohos + NAPI，第二篇讲 VPN 扩展与登录态修复。

### 知乎

- 以文章形式发布，标题用候选 2 更偏故事性。
- 开头补 3–5 行背景：为什么要在鸿蒙上折腾 Tailscale。
- 文末加仓库链接和“非官方项目”声明。

### CSDN

- 同长文，开头加「适用人群 / 前置知识 / 环境版本」三段。
- 关键词填：鸿蒙、HarmonyOS、Tailscale、go-ohos、NAPI、VPN 扩展。

### V2EX

- 发布到「分享创造」节点，使用短版 `2026-11-14-tailscale-ohos-port-short.md` 的 V2EX 段落。
- 标题避免“求 star”，以分享踩坑和征求反馈为主。
- 附仓库链接，说明需要 PC 端配套，避免用户误解为开箱即用。

### 即刻 / 小红书

- 使用短版的即刻段落，配 2–3 张真机截图（脱敏）。
- 小红书标题更口语化，正文分点，文末放标签。

### B 站（可选）

- 1–3 分钟演示：冷启动自动连 tailnet → 蜂窝网络打开 App → 发送消息 → 通知。
- 视频简介放仓库链接与短版文案。

## 发布顺序建议

1. GitHub README 与仓库元数据先完善；
2. 掘金 / CSDN 发长文（便于被搜索）；
3. V2EX / 即刻发短版（带来第一波真实反馈）；
4. 根据评论补充 FAQ 后再发知乎；
5. 一周后整理评论区的共性问题，发第二篇（如“鸿蒙 NAPI 内存管理”或“VPN 扩展状态机”）。

## 隐私与合规检查

- 不出现真实局域网 IP、Tailscale IP、H5 Token、签名密码、个人姓名与本机绝对路径。
- 截图先裁掉会话标题、聊天内容、通知内容。
- 明确声明：非官方项目，与 Anthropic、Tailscale Inc. 无关联；内置 Tailscale 属于 VPN 能力，分发前自行评估合规要求。
- 发布前再次确认仓库可见性为 public，README 不再包含“私有仓库”字样。

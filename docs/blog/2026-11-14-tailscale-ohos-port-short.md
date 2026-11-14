# 短版发布稿（V2EX / 即刻 / 小红书）

## 标题候选

1. 不用卓易通：我把 Tailscale 1.104.5 编译进了鸿蒙 App
2. 鸿蒙没有官方 Tailscale，我自己从源码编了一个
3. 给鸿蒙 App 内置 Tailscale：go-ohos、NAPI 和 VPN 扩展踩坑

## V2EX「分享创造」版

做了一个给 Claude Code 用的鸿蒙手机客户端，最大的坑是外网访问。

鸿蒙没有官方 Tailscale。之前的方案是在卓易通里跑 Android 版，再把流量转给鸿蒙应用，启动、保活、路由都不可控。于是干脆把 Tailscale 1.104.5 从源码编译成 OHOS arm64 动态库，通过 NAPI 交给 VPN 扩展进程，由扩展持有 TUN。

最终链路：

- `flypigJ/go-ohos` bootstrap 出 OHOS 版 Go 工具链；
- `flypigJ/tailscale-ohos-core` 编译出 `libtailscale_go.so`（41 个 C ABI 导出，约 26MB）；
- NAPI 桥暴露 start/login/status/vpnConfig/networkChanged 等接口；
- 先建 `192.0.2.1/32` 的探针 TUN，登录后拿配置，再切生产 TUN；
- 只下发 `100.64.0.0/10` 等 tailnet 路由，不下发默认路由；
- `trustedApplications` 加入自身包名，不设置 `blockedApplications`；
- 修了一个“每次重启都要求重新登录”的 bug：启动早期调用 `authUrl()` 会触发 `StartLoginInteractive()`，打断本地密钥自动重连；现在连续 `NeedsLogin` 超过 5 秒才请求登录链接。

真机上冷启动约 3 秒恢复 `running`，蜂窝网络下能连回家里 PC，WS 心跳 4–7ms。

项目是非官方的，只做自动连接 tailnet，不支持 exit node / MagicDNS / Taildrop，且与其它 VPN 互斥。完整踩坑记录和代码都在仓库里：

https://github.com/KOTMMMMM/cc-haha-mobile-for-harmony

欢迎拍砖，尤其是鸿蒙 VPN 扩展和 NAPI 内存管理部分。

## 即刻 / 小红书版

鸿蒙没有官方 Tailscale，我把 1.104.5 从源码编进了自己的 App。

过程比想象中折腾：go-ohos bootstrap、NAPI 桥、探针 TUN、生产 TUN、路由防环，还有一个“每次重启都要重新登录”的隐蔽 bug——启动第一秒调用 authUrl 会打断本地节点密钥的自动重连。

现在冷启动 3 秒自动连回 tailnet，蜂窝网络下也能连家里的 Claude Code。非官方项目，记录都写下来了：

https://github.com/KOTMMMMM/cc-haha-mobile-for-harmony

#鸿蒙 #HarmonyOS #Tailscale #独立开发

## 一句话简介（转发用）

把 Tailscale 1.104.5 从源码编译进 HarmonyOS NEXT：go-ohos、NAPI 桥、VPN 扩展与探针 TUN 的完整踩坑记录。

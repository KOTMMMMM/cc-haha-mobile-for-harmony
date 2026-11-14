# 已废弃：pc-bridge

这是项目早期独立 PC 桥接服务（HTTP 3457、UDP 发现 3458）的参考实现。

**当前客户端不使用本目录代码。** 现版本直接连接 PC 端 cc-haha 内置 HTTP/WebSocket 服务（固定端口 65499），协议为：

- REST：`/health`、`/api/sessions`、`/api/sessions/:id/messages?cursor=`
- WS：`/ws/<sessionId>?token=<h5Token>`

保留本目录仅用于历史协议对照；不要据此判断当前客户端行为。其依赖（`ws`、`uuid`、`tree-kill`）也不参与应用构建。

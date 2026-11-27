# 源码说明

本次公开 App 版本为 **0.5.39（59）**，对应同号已处理完成、进入内部测试的 TestFlight 构建。公开 TestFlight 链接当前提供 **0.5.38（58）**；两者的发放范围不同。

- App 快照源提交：`6599ef6e1bbfaa3f9cf5ef5f01cfaeb594c511cd`。
- 服务器：2026-11-27 已上线的体验码管理、批量新增和结果反馈服务；服务器独立于 App 发版。源文件校验值如下。
- 网站 HTML：2026-11-27 从线上公开页面读取，公开副本移除个人邮箱、补齐安装入口。此处的副本不表示线上网站已重新部署。
- 公开处理：移除内部构建步骤与私有评测材料；第三方示例封面、海报和人物照片替换为占位图；公开源码和新提交不附带个人联系邮箱。
- 此快照不包含尚未发布的 iPad 布局修复、无故事时的直接反馈入口或新的后台布局草稿。

## 服务器源文件 SHA-256

```text
7897bf426c238152498d5bc1c7fe02e3450127812dc320f7ed38438a8c2ad95e  Server/relay/cli.go
ee445e227799c88b197500500b25f953b8b0136d277222c85706b983c1f93fa4  Server/relay/feedback.go
6e10bca87b7a86933ab9afd0ab7599dd651f4e35b6813494ed6423e6c09f3b7a  Server/relay/feedback_test.go
9eb1a5802978f992a52ec5d97849ce1fccdb1a3f71f0de3b3f39ad9a661de77c  Server/relay/go.mod
9e98dbad0b634b863cc51c179d5e142e0d3b1b1352a9e63ffe06591c04efc750  Server/relay/main.go
60546085c70fd375ef350a3056eed49ec8b06ff23f3eace6f95085a47a66e344  Server/relay/main_test.go
a1ce8cb17a31de41be5045af30c4ec1807115b94c0fe8d5e2991ce0d08079d3c  Server/relay/management.go
aa29bbcad2abd530b024b916981dbd9bc52c4fba6dc3985f3d241ae285dfb24e  Server/relay/management.html
6f03d3948a4c2f10bc4e035c4775922ed0b7492b6ce4705a6965ea0b54e53e6c  Server/relay/management_test.go
```

源码只供阅读，使用条件见 [LICENSE](LICENSE)。

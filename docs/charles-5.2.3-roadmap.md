# 流迹的 Charles 5.2.3 功能路线图

参考版本为本机安装的 macOS Charles 5.2.3，应用包中的版本号和构建号均为 `5.2.3`。官方版本历史记载该版本发布于 2026 年 11 月 13 日，并新增了会话警告的展示与存档。流迹采用原生 macOS 界面和独立的配色、图标及控件样式。 [Charles 版本历史](https://www.charlesproxy.com/documentation/version-history/)

## 抓包操作

1. 启动本机代理，将要调试的客户端指向代理端口。流迹在「代理接入」中提供地址、端口和系统设置指引。 [Charles 入门](https://www.charlesproxy.com/documentation/getting-started/)
2. 按主机和路径浏览同类请求，或按请求发起顺序查看流量。选中请求后，在详情区查看概览、请求和响应，并结合搜索和筛选定位所需会话。 [Charles 请求与响应](https://www.charlesproxy.com/documentation/using-charles/requests-responses/)
3. 在工具面板编辑并保存规则，观察后续请求如何命中规则。保存抓包文件可供后来重新打开，HAR 可交给其他分析工具。 [Charles 工具](https://www.charlesproxy.com/documentation/tools/)、[会话保存与重开](https://www.charlesproxy.com/documentation/using-charles/sessions/)、[HAR 与会话格式版本记录](https://www.charlesproxy.com/documentation/version-history/)

## 已实现与本轮交付

| 阶段 | 流迹的功能与适用范围 |
| --- | --- |
| 初版 | macOS 14+ 本机 HTTP/1.x 代理，显示会话、请求与响应头、正文预览、耗时和字节数。HTTPS 通过 CONNECT 透传，记录目标、状态、耗时及传输量，正文保持加密。代理仅监听回环地址，系统代理由用户在系统设置中配置。 |
| 0.2 代理工具 | 远程映射连接本机后端并保留查询参数。本地映射使用选定的文件响应匹配的 `GET` 和 `HEAD`。改写支持替换路径和设置 `X-Debug-` 标头。域名覆盖把 `.test`、`.localhost` 开发域名引向 `127.0.0.1`，保留主机名与端口。黑名单和白名单按主机控制 HTTP 和新建 CONNECT 连接，黑名单优先。映射、改写和域名覆盖面向本机开发的明文 HTTP 流量。 [Map Remote](https://www.charlesproxy.com/documentation/tools/map-remote/)、[Map Local](https://www.charlesproxy.com/documentation/tools/map-local/)、[Rewrite](https://www.charlesproxy.com/documentation/tools/rewrite/)、[DNS Spoofing](https://www.charlesproxy.com/documentation/tools/dns-spoofing/)、[Block List](https://www.charlesproxy.com/documentation/tools/block-list/)、[版本历史中的名单功能](https://www.charlesproxy.com/documentation/version-history/) |
| 0.3 会话浏览与文件 | 增加按主机和路径浏览的结构视图与按时间浏览的时序视图。支持保存和打开流迹抓包文件，以及导出 HAR。流迹抓包文件使用自己的格式，HAR 用于交换已记录的会话数据。 [Structure 与 Sequence](https://www.charlesproxy.com/documentation/using-charles/requests-responses/)、[会话](https://www.charlesproxy.com/documentation/using-charles/sessions/) |
| 0.4 导航、代理与手机 | 左侧会话树按加密隧道、主机端口和单次连接显示。两种会话视图提供右键操作。代理监听与录制独立控制，并提供限速、本机请求断点和回环端口转发。工具增加缓存与 Cookie 规则、本机响应镜像、会话自动保存及规则配置方案。Mac 和同网段配对手机可同时接入，手机通过独立端口及认证连接。 [录制](https://www.charlesproxy.com/documentation/using-charles/recording/)、[限速](https://www.charlesproxy.com/documentation/proxying/throttling/)、[断点](https://www.charlesproxy.com/documentation/proxying/breakpoints/) |
| 0.5 macOS 接入与会话调试 | 新增系统 HTTP/HTTPS 代理接管与恢复、关注主机、录制忽略、精确位置双阶段断点、自有 HTTPS 身份、查找和 HAR 导入。以[本版验收表](charles-5.2.3-acceptance.md)、[菜单清单](charles-5.2.3-menu-inventory.md)及[Proxy / Tools 明细](charles-5.2.3-proxy-tools.md)为准。 |

## 初始规划（各项最新状态见 0.5 验收表）

1. **会话定位和对比。** 增加关注主机、状态与方法组合筛选、列显示设置和正文内查找。验收时用同一组会话在两个视图定位同一条请求，并在重开应用后恢复列设置。 [Charles Focus](https://www.charlesproxy.com/documentation/using-charles/focus/)、[Charles 版本历史](https://www.charlesproxy.com/documentation/version-history/)
2. **请求与响应阅读。** 增加查询参数、表单、JSON 树和十六进制视图。在概览中显示正文截断和代理错误，支持复制和保存捕获的正文。 [Charles 请求与响应](https://www.charlesproxy.com/documentation/using-charles/requests-responses/)
3. **录制和文件交换。** 提供独立暂停录制、按主机忽略记录和录制容量设置。增加选择会话导出及分享前的脱敏预览，验证暂停时代理仍可转发。 [Charles 录制](https://www.charlesproxy.com/documentation/using-charles/recording/)、[Charles 录制设置](https://www.charlesproxy.com/documentation/configuration/recording-settings/)、[Charles 版本历史](https://www.charlesproxy.com/documentation/version-history/)
4. **本机调试配置。** 提供可命名的规则组合、命中预览和本机网络延迟预设。用本地测试服务验证规则顺序、启停切换及预设耗时。 [Charles 版本历史中的 Profiles](https://www.charlesproxy.com/documentation/version-history/)、[Charles 带宽与延迟模拟](https://www.charlesproxy.com/documentation/proxying/throttling/)

## 便于后续定制的实现约定

- 网络层提供会话和规则命中数据。主机树、时间排序、列和筛选由界面层根据同一批会话计算，用同一个会话 ID 维持选中状态。
- 抓包文件保存带版本号的会话快照。界面偏好和规则配置单独保存，打开抓包文件只加载历史数据。
- 录制筛选、视图筛选和代理规则各自控制是否记录、显示或转发。规则编辑先验证整组配置，再应用到新请求。

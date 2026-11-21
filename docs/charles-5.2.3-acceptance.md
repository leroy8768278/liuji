# 流迹 0.5 对照验收

基线为 2026 年 11 月 21 日本机 Charles 5.2.3 的可见菜单、用户提供的 CONNECT 会话右键截图与官方说明。流迹采用 MIT 许可证。注册、购买和试用流程排除在产品范围之外。[Charles 许可](https://www.charlesproxy.com/buy/eula/) · [流迹许可证](../LICENSE)

完整主菜单与 Help 子菜单见[本机菜单清单](charles-5.2.3-menu-inventory.md)。代理、工具设置与策略分别记录在 [Proxy / Tools 37 项对照](charles-5.2.3-proxy-tools.md)。下表中“部分”明确指出工作流边界。“源码核对”表示找到了实现，和“实测”分开记录；Charles 每个设置对话框的全部字段、组合及默认值尚未穷尽。

## 会话右键菜单

| Charles 项目 | 流迹行为与范围 | 核查依据 |
| --- | --- | --- |
| Copy URL | 复制此条记录的 URL，保留查询串和显式端口 | 源码核对 |
| Copy cURL Request | 部分。对可完整表示的本机 HTTP 请求生成命令，跳过认证、Cookie 和跳间标头。CONNECT 无正文可重建 | 源码核对 |
| Copy Response | 部分。复制所捕获的响应预览；文本可解码，二进制以数据写入剪贴板 | 源码核对 |
| Save Response… | 部分。可把已捕获的响应字节另存到本地，正文有预览上限 | 源码核对 |
| Find In… | 在当前条目的 URL、标头、文本正文查找，并切换前后命中 | 单请求查找、原生界面和测试 |
| Export Session… | 导出选中条目为 .flowsession，顶部文件菜单还支持 HAR | 归档、HAR 测试 |
| Compose | 部分。本机 HTTP 请求可以预填并手工编辑、发送，生成新记录 | 本机请求链路测试 |
| Repeat | 部分。本机 HTTP 支持手工重复，敏感请求标头与 Cookie 去除 | 本机请求链路测试 |
| Repeat Advanced… | Charles 的多目标适用范围和并发负载设置有缺口 | 见工具表 |
| Validate | 部分。流迹提供本地 JSON 语法校验；Charles 的 W3C HTML/CSS/Feed 校验有缺口 | 源码核对 |
| Publish Gist | 未实现。流迹支持本地文件导出 | 菜单核对 |
| Terminate | 活动的实时会话可中止，停止上游和客户端连接 | 引擎与菜单核对 |
| View Request As ▶ | 自动、格式化 JSON、文本和十六进制，按内容决定可用视图 | 原生菜单与模型核对 |
| View Response As ▶ | 与请求相同，MIME 默认映射与单次显式选择各自生效 | 查看器规则测试 |
| Viewer Mappings… | 部分。能配置 MIME 默认查看器，二级入口位于显示菜单 | 查看器规则测试 |
| Show in Sequence / Structure | 跨视图定位同一会话，按会话 ID 选择 | 原生界面实测 |
| Sort By ▶ | 最新、最早、状态码、耗时。结构树的分组仍按名称排列 | 源码核对 |
| Focus | 关注主机置顶，其他主机放入可展开的分组。时序可只看关注，多主机名单可编辑 | 原生窗口实测；归一化、分组与持久化测试。[Charles Focus](https://www.charlesproxy.com/documentation/using-charles/focus/) |
| Ignore | 对新录制生效。主机节点忽略协议/主机/有效端口，请求节点忽略精确路径，名单可加整主机。旧记录保留，取消规则后已忽略的在途连接仍保持忽略 | 生命周期与位置匹配测试。Charles 确认录制位置名单，右键生成字段的粒度尚未逐字段实测。[录制设置](https://www.charlesproxy.com/documentation/configuration/recording-settings/) |
| Clear / Clear Others | 清除选中实时记录或其余记录；已清除的在途记录不会因后续更新重新出现 | 源码核对 |
| SSL Proxying 状态 / Enable / Disable | 部分。显示状态并预填主机和端口，可启停自有服务。需持有服务端 PKCS#12 且源站受系统信任。身份只在内存使用，普通 HTTPS 继续透传。通用站点自动签证及客户端 CA 安装存在差异 | 原生右键与预填实测；精确端口、TLS 双向及错误路径测试。[Charles SSL Proxying](https://www.charlesproxy.com/documentation/proxying/ssl-proxying/) |
| Breakpoints | 部分。会话行添加精确位置，主机行可选全部路径；设置选择请求、响应或两阶段。命中可查看标头、放行或中止。自有服务支持改调试标头。通用正文编辑与任意模式匹配有缺口 | 两阶段本机端到端验证。[Charles Breakpoints](https://www.charlesproxy.com/documentation/proxying/breakpoints/) |
| No Caching / Block Cookies | 部分。对受支持的本机开发 HTTP 请求预填位置、维护规则 | 规则与引擎核对 |
| Block List / Allow List | 从选中位置建立主机名单，生效于后续 HTTP 请求及 CONNECT | 规则与引擎核对 |
| Client Process | 部分。可选识别新回环连接的当前用户进程，显示进程名和 PID，短连接可能显示未知 | 真实本机子进程连接测试 |
| Map Remote… / Map Local… | 部分。本机开发 HTTP 后端与选定本地文件，预填源主机和路径 | 规则与引擎核对 |

## 展示与系统接入

| 功能 | 流迹现状 | 验证 |
| --- | --- | --- |
| Structure / Sequence | 支持加密分组、主机端口、每条 CONNECT、明文路径树、时序、搜索、来源筛选 | 原生窗口、结构模型 |
| Highlight Rules / Viewer Mappings | 部分。可配置请求颜色与 MIME 查看器，支持应用重启后的偏好恢复 | 查看器和高亮规则测试 |
| Focused Hosts | 支持添加、移除，保留多个主机 | 原生窗口与名单测试 |
| Protobuf Viewer Settings | 尚缺描述符映射与按消息类型解析的查看器 | 菜单与源码核对 |
| Overview / Contents / Notes | 部分。请求响应标头、有限正文预览、JSON、查询参数、字节数、总耗时及会话备注。可将备注保存到流迹归档 | 查看器、归档及源码 |
| Summary / Chart / TLS 细节 | 尚缺完整聚合统计、请求瀑布图、每阶段精确计时和完整 TLS 证书查看器 | 源码核对 |
| 5.2.3 交易警告 | 部分。可显示失败原因及正文截断，归档保留相关数据。Charles 的证书诊断分类、可配置警告列等有缺口 | 源码与[版本说明](https://www.charlesproxy.com/documentation/version-history/) |
| macOS Proxy | 当前网络服务 HTTP、HTTPS 可切到流迹，记录旧设置并在停用、正常退出或异常退出后的下次启动尝试恢复。保留其他工具之后已改动的端点。PAC/WPAD 在面板单独提示 | 本机只读核对、独立窗口、真实本地监听及模拟网络设置事务测试。未切换用户正在用的代理 |
| External Proxies | 部分。可显式选择原有数值 IPv4 回环 HTTP 代理；本机开发目标直连，其他 HTTP 与 HTTPS 隧道共用出口 | 临时本机上游验证 HTTP、CONNECT 双向数据、407 隔离、自循环和绕过 |
| 手机 Wi-Fi 接入 | 精确匹配同网段设备，独立端口及本次认证，Mac 和手机会话可筛选 | 合成局域网接口验证地址、配对凭据以及错误和重复认证的处理。实体手机有待联调 |
| Window / Error Log / Active Connections | 部分。可回看会话分组，查看当前录制会话中的错误与活动连接。尚非所有网络连接和程序日志的完整查看器 | 菜单及源码 |
| 应用/Help | 应用信息、窗口管理由 macOS 提供，使用说明和许可证随包发布，手机接入页列出可用局域网地址。没有 Java 运行时、Charles CA 管理、自动更新发布链路 | 菜单与包内容 |

## 复验

2026-11-21 在本机运行全部 35 项 XCTest，全部通过。另用临时 HTTPS 源站验证了 6 个 TLS 场景，包括请求和响应断点改写。两套架构的发布二进制均已构建并通过本地签名校验。

本机 Wi-Fi 原有的 HTTP、HTTPS 和 SOCKS 都指向 `127.0.0.1:7897`。诊断时 `8888` 由旧版流迹监听，显式送入该端口的本机 HTTP 请求和 CONNECT 隧道均成功。此次原生界面核对了当前代理地址、关注分组和 HTTPS 主机预填。系统代理写入、恢复、路由未生效时的回滚及多实例互斥使用隔离配置验证，用户的系统代理维持原值。

1. 在完整 Xcode 环境运行 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`。系统代理测试写入独立数据夹与模拟网络设置，使用真实回环监听检查端口冲突与开始/停止顺序。
2. 在 macOS 15+ 运行 `python3 scripts/test-owned-https.py`。临时 TLS 服务验证请求和响应断点、改后的标头、受信任且匹配的源站、错误 SAN、错误叶证书、未受信任证书和错误请求目标。测试 CA 只在测试进程使用。
3. 构建 `./scripts/build-app.sh` 后运行产物。进入「Mac 抓包」对照监听端口和系统代理。用示例会话右键选择关注，展开「其他主机」，再在 HTTPS 会话上打开调试设置，核对预填的主机、端口和证书要求。如需真实系统接入，点击面板内「开始 Mac 抓包」。

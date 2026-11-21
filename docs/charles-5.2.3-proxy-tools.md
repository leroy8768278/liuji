# Charles 5.2.3 的 Proxy、Tools 菜单与流迹对照

核对日期为 2026 年 11 月 21 日。用户提供的两张菜单截图确定了 macOS 上的命令名称、顺序和快捷键。本机 Charles 安装包的 `CFBundleShortVersionString` 和 `CFBundleVersion` 均为 `5.2.3`。官方发布日为 2026 年 11 月 13 日。该版增加交易警告的展示和存档，改进 SSL 握手错误说明。Windows、Linux 的配置导出修复也在这版发行说明中。[官方版本历史][history]

**开源情况。** Charles 桌面应用由 XK72 以商业许可分发，有 30 天试用和按主版本授权的付费许可。官方 EULA 保留软件权利，并限制分发应用及其中的代码。官方单列随附第三方库的许可。本次查到的是桌面产品的使用许可，未找到 Charles 5.2.3 应用源码的公开授权。流迹对照的是公开可观察的行为。[官方 EULA](https://www.charlesproxy.com/buy/eula/) · [许可类型](https://www.charlesproxy.com/buy/) · [第三方库](https://www.charlesproxy.com/documentation/additional/3rd-party-libraries/)

**表格读法。** “已实现”限于该行明确列出的命令行为。“部分”表示两者的适用对象、配置或动作有差异。“未实现”表示未找到对应的流迹功能。Charles 的设置子项来自官方文档或版本记录，精确字段缺证据时会标出。流迹列来自当前工作区的菜单、配置模型和执行代码。本表未逐项操作 Charles 的设置窗口。另有一份[菜单清单](charles-5.2.3-menu-inventory.md)说明对界面的核查范围。官网的通用手册包含历史版本表述，菜单位置与名称以所给 5.2.3 截图为准。[Charles 文档说明](https://www.charlesproxy.com/documentation/)

## Proxy 菜单

| Charles 菜单项 | Charles 的行为和设置 | 流迹状态及差异 |
| --- | --- | --- |
| Start / Stop Recording（当前 Session） ⌘R | 启停记录。暂停时请求仍可转发。5.1 起，停止录制会结束已开启交易的时间统计。[录制][record] · [版本历史][history] | **部分**。⌘R 开始或暂停实时工作区的录制，暂停后仍转发。可新建并切换会话，先前录制中的连接继续更新到结束。 |
| Start / Stop SSL Proxying ⌘L | 启停对选定目的地主机的 HTTPS 解密。[SSL Proxying][ssl] | **部分**。⌘L 可切换自有服务 HTTPS 调试。也可按服务启停。普通 CONNECT 记录目标及传输统计。通用签发证书解密仍缺。 |
| Start / Stop Throttling ⌘T | 开关带宽与延迟模拟。[限速][throttle] | **已实现**。代理菜单 ⌘T 切换当前限速配置。参数范围见下方设置行。 |
| Enable / Disable Breakpoints ⌘K | 启停配置好的断点，命中时等待用户操作。[断点][breakpoints] | **已实现**。⌘K 全局切换已配置的断点。关掉时会放行等待中的请求。作用范围见下方设置行。 |
| Recording Settings… | 调整录制大小上限、忽略指定位置。也可从结构树把主机加入录制忽略名单。[录制设置][record-config] | **部分**。可保留最近 50–1,000 条记录，默认 500。正文每方向保留 256 KiB 预览。“录制忽略名单”可按主机、来源地址（协议、主机、端口）或精确路径排除之后的记录，历史记录仍可浏览。“隐藏此主机”仅影响显示。缺可设置的字节上限。 |
| SSL Proxying Settings… ⇧⌘L | 管理主机及通配匹配、排除列表。版本记录还列有导入自有服务端证书的选项。[SSL Proxying][ssl] · [版本历史][history] | **部分**。⇧⌘L 可为精确主机、端口添加或关闭自有服务身份。macOS 15+ 可导入服务自己的 PKCS#12 文件，核对源站证书后查看 HTTP/1.1。身份仅在本次运行使用。缺通配、排除列表及通用 CA 签发。 |
| Throttling Settings… ⇧⌘T | 可指定带宽和延迟。官方另列网络预设和异常网络条件模拟。[限速][throttle] · [版本历史][history] | **部分**。⇧⌘T 配置单向首次延迟 0–2,000 ms、每连接单向带宽 16–10,240 KiB/s。上下行共用一组数值，缺预设和异常条件模拟。 |
| Breakpoints Settings… ⇧⌘K | 可按协议、主机、端口、路径和通配符匹配。选择请求、响应或两者，可编辑后放行、中止、放弃修改后放行。[断点][breakpoints] | **部分**。⇧⌘K 管理从会话添加的位置与请求、响应或双阶段断点，另有回环请求精确路径选项。等待时可继续或中止。回环及已验证自有服务支持修改调试标头。缺通配配置和通用正文编辑。 |
| Reverse Proxies… | 本地监听端口可映射到 HTTP 或 HTTPS 服务，代理记录请求与响应。[反向代理][reverse] | **部分**。“本机反向映射”借用主监听端口与路径规则把明文 HTTP 导向回环开发服务。缺独立反向代理端口列表和 HTTPS 目标。 |
| Port Forwarding… | TCP 或 UDP 可从本地端口转发到指定远端主机并供检查。[端口转发][port-forward] | **部分**。可在指定的两个本机 IPv4 回环端口间转发 TCP，支持半关闭。缺远端主机、UDP 及逐连接的端口转发会话查看器。 |
| macOS Proxy ⇧⌘P | 运行时可切换系统代理，支持按配置在应用启动和退出时调整系统设置。[系统接入][system] | **部分**。流迹有活动网络服务的 HTTP/HTTPS 检测、切换、备份与恢复逻辑，保留独立的 SOCKS 设置。默认需要显式启用。真实网络的授权切换未经本次对照实测。 |
| Proxy Settings… | 设置 HTTP、SOCKS 端口或动态选端口，管理系统/浏览器自动配置、绕过的主机和 SOCKS 模式。[代理设置][proxy-config] | **部分**。“代理设置”提供本机 HTTP 地址与监听端口。手机接入使用独立 IPv4 监听。缺 SOCKS 服务、主监听端口的自动选择和绕过名单编辑。 |
| DNS Settings… | 截图确认有独立设置入口。官网配置目录没有列出对应字段，具体选项、默认值待核。[配置目录][config] | **未实现**。流迹没有独立 DNS 设置面板。工具菜单的“域名覆盖”见下表。 |
| Access Control Settings… | 本机默认允许，可增添单个 IP 和带掩码的网段，对首次遇到的未授权来源提示。[访问控制][acl] | **部分**。“手机接入与访问控制”允许一个同网段手机 IPv4，使用单独账号口令，可停止手机监听。缺多条 IP/网段 ACL 和新设备接入提示工作流。 |
| External Proxies Settings… | 为 HTTP、HTTPS、SOCKS 设置独立上游、端口、认证。支持绕过地址和可选端口的匹配。[外部代理][upstream] | **部分**。可启用数值 IPv4 回环 HTTP 上游，用同一出口转发 HTTP 及 HTTPS CONNECT。回环、匹配的本机开发规则和自有 TLS 源站直连。独立协议上游、远程或 SOCKS 上游、上游认证、自定义绕过规则仍有差异。已验证本机 HTTP 转发、CONNECT 握手、407 隔离和端口自循环保护。 |
| External DNS Resolver Settings… | 指定外部 DNS 解析器以替代系统解析。该选项在 4.6 引入。5.2.3 窗口内字段待核。[版本历史][history] | **未实现**。无外部 DNS 解析器设置。 |
| Web Interface Settings… | 开关浏览器控制页面，可配置匿名或账号访问。可选限速预设、启停录制及工具、清空或导出会话、退出应用。[Web 界面][web-interface] | **未实现**。现有入口是本地 macOS 应用。 |

## Tools 菜单

| Charles 菜单项 | Charles 的行为和设置 | 流迹状态及差异 |
| --- | --- | --- |
| No Caching… ⌥⌘N | 全部请求或按位置生效。调整条件请求标头，移除响应中的到期和缓存验证标头，并设置新的缓存指令。[禁用缓存][no-cache] | **部分**。按回环开发 HTTP 的主机、路径生效。GET/HEAD 移除条件标头，响应写入 `Cache-Control: no-store`。尚缺同范围的全局规则，响应的到期与验证标头处理也有差异。 |
| Block Cookies… ⌥⌘C | 全部或特定位置生效，过滤请求 Cookie 与响应 Set-Cookie。[阻止 Cookie][cookies] | **部分**。双向过滤已接入本机开发 HTTP，需按主机和路径配置。 |
| Map Remote… ⌥⌘M | 按协议、主机、端口、路径/模式重映射目录或文件，支持 HTTP 和 HTTPS 间映射。5.2.1 新增默认启用的 Preserve base path。[远程映射][remote] · [版本历史][history] | **部分**。本机开发 HTTP 支持精确及前缀路径、回环 HTTP 目标并保留查询串。缺通用目标、跨协议、按文件后缀匹配和基路径选项。 |
| Map Local… ⌥⌘L | 可映射单文件、整目录或文件模式。匹配时忽略查询串，缺少本地文件时可回到远端。[本地映射][local] | **部分**。GET/HEAD 可按开发主机和精确路径读取指定文件，上限 2 MiB。缺目录树、文件模式和文件缺失回源。 |
| Rewrite… ⌥⌘R | 规则集可独立启停，选请求或响应，处理 URL、查询参数、头部、正文。可用正则或整值匹配，并选择替换首项或全部。[改写][rewrite] | **部分**。可替换本机开发请求的路径、设置请求或响应的 `X-Debug-` 头。缺通用查询、正文、正则替换及独立规则集作用域。 |
| DNS Spoofing… ⌥⇧⌘D | 为域名指定代理所用的目标 IP，并保留 HTTP Host。[域名映射][dns-spoof] | **部分**。本机开发明文 HTTP 支持把 `.test` 和 `.localhost` 域名映射到 `127.0.0.1`，保留原域名和端口。 |
| Block List… | 支持域名、子域名通配及不同拦截方式。[黑名单][block] · [版本历史][history] | **部分**。按精确主机或 `*.` 子域匹配，拒绝 HTTP 与新建 CONNECT，返回 403。缺按规则选择直接终止连接的方式。 |
| Allow List… | 允许名单与阻止名单相配合，官方历史中也列出两类名单的拦截模式。[版本历史][history] | **部分**。显式启用后，只允许名单内主机，黑名单优先。支持精确主机及子域。缺可选拦截模式。 |
| Mirror… | 流式保存选定位置的响应，按站点目录组织，同 URL 保留最新一份，支持超出录制上限的响应。[镜像][mirror] | **部分**。只镜像所选回环主机上完整且不超过 256 KiB 的明文 HTTP 响应，各自使用唯一文件名。缺站点目录、同 URL 更新和大响应流式镜像。 |
| Auto Save… | 设置保存目录和分钟间隔，周期性保存并清空当前录制。可选择随启动生效，或对齐到整点的间隔倍数。[自动保存][auto-save] | **部分**。选定目录后，在暂停录制或停止代理时保存快照。缺定时分卷清空、按钟点对齐及启动预设。 |
| Client Process… | 显示本机发出请求的进程名，可限制作用位置，在请求备注中显示。[客户端进程][process] | **部分**。工具菜单可开启本机进程识别。在新 loopback 连接的概览和右键菜单显示 PID、进程名。按当前用户和监听端口后台查询，查询时已关闭、归属不唯一或不可见的连接显示未知。暂无 Charles 按目标位置配置。 |
| Compose ⌘M | 可基于已有请求调整 URL、头部、查询或表单后发送。通用手册称此工作流为 Edit，5.2.3 截图使用 Compose。[编辑请求][edit] · [版本历史][history] | **部分**。⌘M 或会话右键将已完成的本机 HTTP 请求带入编辑器。可修改方法、URL、指定标头和完整 UTF-8 正文，确认后通过流迹监听发送一次。 |
| Compose New… ⇧⌘M | 新建请求。版本记录还列有 multipart POST 图片支持。[版本历史][history] | **部分**。⇧⌘M 或会话右键新建请求，可向 IPv4/IPv6 回环服务发送单条明文 HTTP 请求，支持手填查询参数和文本正文。缺文件、表单与 multipart 专用编辑。 |
| Repeat ⇧⌘R | 重发选中请求，在 Charles 中记录新的响应。[重复请求][repeat] | **部分**。⇧⌘R 或会话右键可预览并单次重发已完成的本机 HTTP 文本请求。保留指定内容标头，排除认证、Cookie 等原始头部。真实经过流迹监听，重定向响应记录后即结束。 |
| Repeat Advanced… | 设置重复次数及并发度。[高级重复][repeat-advanced] | **未实现**。无高级重复面板。 |
| Validate | 对录到的 HTML、CSS 或 Feed 调用 W3C 验证，错误可定位到源码行，支持重新验证。[验证][validate] | **未实现**。流迹右键的 JSON 语法检查属于不同的检查项目。 |
| Publish Gist | 把一条或多条请求/响应记录发布为 GitHub Gist。[版本历史][history] | **未实现**。本地保存与导出可用。 |
| Import/Export Settings… | 导入导出程序设置，多个工具的设置属于此范围。5.2.3 修复了 Windows/Linux 曾漏掉工具设置的问题。[版本历史][history] | **部分**。可导入和导出流迹的 `.flowrules` 规则文件。未涵盖监听、限速及其他设置，也没有 Charles 配置文件兼容性。 |
| Publish Gist Settings… | 截图确认独立设置入口，历史版本已取消匿名 Gist 发布并调整 GitHub OAuth。本次未核实窗口中的字段、默认可见性。[版本历史][history] | **未实现**。无 Gist 账号或发布偏好配置。 |
| Profiles… | 创建并切换不同的设置组合。[版本历史][history] | **部分**。支持保存、选择、应用、移除命名规则方案。方案只包含流迹规则及白名单开关。 |

流迹已为禁用缓存、阻止 Cookie、远程映射、本地映射、改写、域名覆盖绑定表中六组快捷键。两个菜单共覆盖截图中的 37 项入口（Proxy 17 项，Tools 20 项）。此数量只统计一级命令。

## Focus 与 Ignore 的交互验收

- **Focus**。在主机节点或会话上选择“关注主机”，结构树应将该主机置于“其他主机”之前，其他流量仍可展开。时序视图的“仅显示关注的主机”单独开关。可在“显示”菜单的“关注的主机…”中增加或移除主机，设置跨重启保存。[官方 Focus 说明](https://www.charlesproxy.com/documentation/using-charles/focus/)
- **Ignore**。流迹结构树的主机节点按协议、主机与有效端口忽略，普通请求按精确路径忽略且不区分查询参数，CONNECT 按来源地址忽略。也可在录制设置里输入整台主机。加入前的已录记录继续显示，后续匹配请求照常转发。取消后，新请求重新记录，已忽略连接的后续进度继续排除。Charles 官方记录了位置名单及主机右键入口，未说明该版本右击每类节点时具体生成哪些字段。[官方录制设置][record-config]

## 核查入口

- 菜单命令、快捷键和状态分派见 [PacketScopeApp.swift](../Sources/PacketScope/PacketScopeApp.swift)、[CaptureStore.swift](../Sources/PacketScope/CaptureStore.swift)。
- 代理配置和请求处理见 [ProxySettings.swift](../Sources/PacketScope/ProxySettings.swift)、[ProxyEngine.swift](../Sources/PacketScope/ProxyEngine.swift)、[LocalPortForwarder.swift](../Sources/PacketScope/LocalPortForwarder.swift)、[MobileProxySettings.swift](../Sources/PacketScope/MobileProxySettings.swift)。系统代理的读取、变更与恢复见 [MacProxyRoute.swift](../Sources/PacketScope/MacProxyRoute.swift)、[MacSystemProxyController.swift](../Sources/PacketScope/MacSystemProxyController.swift)。
- 手动发送的目标校验、请求生成和本机连接见 [LocalRequestComposer.swift](../Sources/PacketScope/LocalRequestComposer.swift)。[本机端到端测试](../Tests/PacketScopeTests/LocalRequestComposerTests.swift) 用产生 302 的开发服务验证两次明确发送生成两个不同会话并保留正文。
- 工具匹配、保存和应用见 [ProxyRules.swift](../Sources/PacketScope/ProxyRules.swift)、[CaptureOutput.swift](../Sources/PacketScope/CaptureOutput.swift)、[RuleProfilesSheet.swift](../Sources/PacketScope/RuleProfilesSheet.swift)、[RuleConfigurationDocument.swift](../Sources/PacketScope/RuleConfigurationDocument.swift)。会话右键的不同入口见 [SessionContextMenu.swift](../Sources/PacketScope/SessionContextMenu.swift)。

[history]: https://www.charlesproxy.com/documentation/version-history/
[record]: https://www.charlesproxy.com/documentation/using-charles/recording/
[record-config]: https://www.charlesproxy.com/documentation/configuration/recording-settings/
[proxy-config]: https://www.charlesproxy.com/documentation/configuration/proxy-settings/
[system]: https://www.charlesproxy.com/documentation/configuration/browser-and-system-configuration/
[ssl]: https://www.charlesproxy.com/documentation/proxying/ssl-proxying/
[throttle]: https://www.charlesproxy.com/documentation/proxying/throttling/
[breakpoints]: https://www.charlesproxy.com/documentation/proxying/breakpoints/
[reverse]: https://www.charlesproxy.com/documentation/proxying/reverse-proxy/
[port-forward]: https://www.charlesproxy.com/documentation/proxying/port-forwarding/
[config]: https://www.charlesproxy.com/documentation/configuration/
[acl]: https://www.charlesproxy.com/documentation/configuration/access-control/
[upstream]: https://www.charlesproxy.com/documentation/configuration/external-proxies/
[web-interface]: https://www.charlesproxy.com/documentation/using-charles/web-interface/
[no-cache]: https://www.charlesproxy.com/documentation/tools/no-caching/
[cookies]: https://www.charlesproxy.com/documentation/tools/block-cookies/
[remote]: https://www.charlesproxy.com/documentation/tools/map-remote/
[local]: https://www.charlesproxy.com/documentation/tools/map-local/
[rewrite]: https://www.charlesproxy.com/documentation/tools/rewrite/
[dns-spoof]: https://www.charlesproxy.com/documentation/tools/dns-spoofing/
[block]: https://www.charlesproxy.com/documentation/tools/block-list/
[mirror]: https://www.charlesproxy.com/documentation/tools/mirror/
[auto-save]: https://www.charlesproxy.com/documentation/tools/auto-save/
[process]: https://www.charlesproxy.com/documentation/tools/client-process/
[edit]: https://www.charlesproxy.com/documentation/tools/edit/
[repeat]: https://www.charlesproxy.com/documentation/tools/repeat/
[repeat-advanced]: https://www.charlesproxy.com/documentation/tools/repeat-advanced/
[validate]: https://www.charlesproxy.com/documentation/tools/validate/

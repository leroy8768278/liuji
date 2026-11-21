# Charles 5.2.3 macOS 菜单核对

2026-11-21 在本机已安装的 Charles 5.2.3 中读取了会话窗口的菜单栏。下表按实际显示顺序记录了应用提供的项目。观察时为 Session 1，工具栏显示正在录制、已启用 SSL Proxying、尚未启用 macOS Proxy。应用内菜单栏提供了菜单文字及快捷键，未逐项提供 enabled 状态。系统「服务」、最近使用文件及窗口名称因用户而异。Charles 应用菜单的系统级项目本轮只确认顶层入口。

| 顶层菜单 | 会话窗口中观察到的项目 |
| --- | --- |
| File | New Session · Open Session… · Clear Session · Close Session · Save Session · Save Session As… · Import… · Export Session… |
| Edit | Undo · Redo · Cut · Copy · Paste · Select All · Find… · Find Next · Find Previous · Find in Session… · Find Next in Session · Find Previous in Session |
| View | Structure · Sequence · Highlight Rules… · Focused Hosts… · Viewer Mappings… · Protobuf Viewer Settings… |
| Proxy | Stop Recording (Session 1) · Stop SSL Proxying · Start Throttling · Enable Breakpoints · Recording Settings… · SSL Proxying Settings… · Throttling Settings… · Breakpoints Settings… · Reverse Proxies… · Port Forwarding… · macOS Proxy · Proxy Settings… · DNS Settings… · Access Control Settings… · External Proxies Settings… · External DNS Resolver Settings… · Web Interface Settings… |
| Tools | No Caching… · Block Cookies… · Map Remote… · Map Local… · Rewrite… · DNS Spoofing… · Block List… · Allow List… · Mirror… · Auto Save… · Client Process… · Compose · Compose New… · Repeat · Repeat Advanced… · Validate · Publish Gist · Import/Export Settings… · Publish Gist Settings… · Profiles… |
| Window | 当前会话 · Error Log · Active Connections · Enter Full Screen |
| Help | Enter Charles License… · Purchase Charles License… · About Java · Local IP Addresses · SSL Proxying ▶ · Check for Updates · Visit Website |

Help → SSL Proxying 下列出 About Charles Root Certificate、Install Charles Root Certificate、Install Charles Root Certificate in iOS Simulators、Install Charles Root Certificate in Java VMs、Install Charles Root Certificate on a Mobile Device or Remote Browser、Save Charles Root Certificate…、Export Charles Root Certificate and Private Key…、Show Generated SSL Certificates Keystore Password、Reset Charles Root Certificate…。本次只读取菜单标题。

## 随上下文变化的命令

- 本次窗口的 Repeat 工具栏按钮呈禁用状态。打开注册对话框后，File、Edit、View、Proxy、Tools、Window、Help 顶层菜单均呈禁用状态。
- 截图中的 CONNECT 会话右键菜单显示 Copy Response 和 Save Response… 禁用；SSL Proxying: Disabled 是状态说明。截图中选中一条请求与本机核对空会话属于不同状态。
- Edit 使用 ⌘F / ⌘G / ⌥⌘G 在当前内容中查找，⇧⌘F / ⇧⌘G / ⌥⇧⌘G 在会话中查找。Structure、Sequence 的快捷键分别为 ⌘9、⌘0。
- 代理菜单的 macOS Proxy 对应 ⇧⌘P，工具栏的同一开关会显示 Start macOS Proxy 或 Stop macOS Proxy。

流迹的行为与已知差异见 [功能对照](charles-5.2.3-roadmap.md) 和 [代理与工具菜单](charles-5.2.3-proxy-tools.md)。

## 流迹文件和查找操作

| 操作 | 流迹行为 |
| --- | --- |
| 新建会话 ⌘N | 在同一窗口开始新的会话分组。先前的记录保留在「窗口 → 录制会话」，已经开始的连接继续更新原来的记录。 |
| 打开、保存、另存为 | 支持流迹的 .flowsession。打开档案后可保存到原位置，也可另存副本。导入 HAR 后首次保存会选择新的流迹会话文件。 |
| 关闭和清空 | 关闭旧录制会话前可另存为；关闭已打开档案返回实时视图。「清空实时会话」影响当前录制分组。 |
| 导入、导出 | 支持 HAR 1.2。导入上限 128 MiB、2,000 条，每段正文最多保留 512 KiB，可读取文本及 Base64 响应。导出覆盖有 HTTP 请求信息的记录。Charles 私有会话文件尚不支持。 |
| Find / Next / Previous | 单请求查找覆盖 URL、标头及已捕获文本正文，前 100 处显示为可导航摘要，支持 ⌘G、⌥⌘G。 |
| Find in Session / Next / Previous | 从当前录制或档案取得快照，后台检索全部记录，选中第一条匹配的请求；⇧⌘G 和 ⌥⇧⌘G 在命中的记录间循环。重新查找会包含新到的请求。 |
| Undo / Redo / Cut / Copy / Paste / Select All | 文本输入由 macOS 文本控件处理。会话操作没有通用撤销栈。 |

# Videoder 可安装扩展

Windows x64 的“设置与扩展 → 扩展中心”提供“发现”和“已安装”两个页面，可搜索、导入 `.vdx`、安装、配置、检测依赖、启停、更新、回滚和卸载。断网时可管理本地扩展并安装发行包附带的两个官方扩展。macOS/Linux 暂保留原编译内置适配器，不承诺外部插件发行验证。

## 使用

1. 首次升级自动安装随应用附带的 yt-dlp 和 TikTokDownloader 包；保留 `enabled_extensions`、原下载参数、工具路径、Cookie 和默认下载目录。
2. 新安装的扩展在确认后启用。更新会等待该扩展的当前任务结束；取消等待会取消更新。停用或卸载会先停止任务。卸载默认保留设置，可选择删除设置和应用保存的 Cookie，已下载媒体始终保留。
3. “配置与依赖”提供设置步骤，可逐项检测或点击“检测全部依赖”。修改输入后清除旧的页面检测结果，点击“保存并检测”保存配置并更新扩展中心的依赖状态；所有任务启动前还会重新检测必需依赖。工具检测支持可执行文件、工具目录及包含 `bin/` 的解压目录，显示超时与启动失败原因。yt-dlp 可从官方 Release 下载带 SHA-256 的便携程序。FFmpeg 等没有配置可信下载信息的依赖提供官方说明和手动选取路径。通用任务页依赖预检失败时提供“修复依赖”入口。
4. TikTokDownloader 包是独立的 Web API 客户端，仍需运行 [TikTokDownloader/DouK-Downloader](https://github.com/JoeanAmier/TikTokDownloader) 的 API 服务（默认 `http://127.0.0.1:5555`）。平台 Cookie 在 API 服务中配置。支持单条及多条作品、视频和普通图集；尚未接入账号采集、直播、评论或实况作品。

## 包和版本

已安装列表分别显示安装、启停、运行及依赖状态。点击“检测依赖”检查已保存的实际配置；必需依赖失败时出现“依赖未就绪”和“修复依赖”入口。未检测时显示“依赖待检测”，不会误报可运行。配置页检测未保存的路径只显示当前页面结果；保存配置或更换插件版本后清除旧的检测状态。

`.vdx` 是 ZIP，根目录包括 `manifest.json`、`signature.json`，以及清单 `entrypoint` 指定的 Windows x64 独立程序和资源。没有运行时 Flutter 页面加载。宿主为第三方插件绘制表单和任务页；两个官方插件使用宿主已有下载/Cookie 页面，以保持配置和使用体验。

清单示例见 `extensions/example/manifest.json`。分别声明 `manifestVersion`、`protocolVersion`、`hostApiVersion`（目前均为 1）；不兼容版本拒绝安装。插件版本格式为 `major.minor.patch`，更新必须版本递增且发布者签名公钥相同。每个插件当前只声明一个 `entrypoint`，提供一个任务页。

支持字段：`text`、`multiline`、`secret`、`bool`、`select`、`file`、`directory`；`required` 用于任务输入，`options` 用于选择框。`settings` 保存配置，`fields` 定义任务输入。依赖包括 `executable` 和 `api`，可设置 `instructionsUrl`、`default`、`required`。便携工具 `download` 指定 HTTPS `url`、`size`、`sha256`、`format`（exe/zip）、`executable`。

通用插件任务页固定显示状态与进度，日志可折叠、复制和清空；每次运行重新记录最近 300 条日志。停止期间禁用重复停止，并在依赖预检结束后阻止启动已取消的任务。配置读取失败时可重新加载。

任务页可选择本次使用的保存目录，或恢复应用默认目录；启动前检查目录是否存在。`execute` 结果中的 `paths` 为本地文件或目录路径列表，相对路径以传给插件的 `outputDirectory` 为基准解析，重复路径合并显示。任务页提供路径复制与打开所在文件夹，打开时检查文件是否仍然存在；不会自动打开文件。可同时返回 `errors` 字符串列表展示失败原因；有结果且有错误显示部分失败，只有错误显示任务失败。非零 `exitCode` 显示任务失败；`cancelled: true` 或用户已请求停止时优先显示已停止，仍保留插件报告的结果入口。宿主只展示插件报告的结果，任务完成状态不代表已验证结果文件的内容。

## 标准输入输出协议

宿主的官方专用页面与第三方通用页面统一调用 `PluginManager.execute(id, PluginTaskRequest(...))`，由管理器读取设置、补全默认字段、解析工具路径、检查必填项及必需依赖，然后发送 `inputs`、`settings`、`dependencies`、`outputDirectory` 四部分。保存目录必须已经存在。依赖预检期间也占用该插件的任务槽，可取消，取消后不会启动插件；配置在预检期间发生改变会要求重新运行。第三方插件不会读取清单 `preference` 指向的宿主设置。

随附插件现为 **1.1.0**，协议版本仍为 1。TikTokDownloader 从 `inputs.links` 读取链接，API 和 Token 从设置读取，实际 API 地址使用解析后的依赖值。yt-dlp 从 `inputs.arguments` 读取参数、从 `dependencies["yt-dlp"]` 读取工具路径，回传标准 `progress`/`log` 事件及 `paths`/`errors`/`exitCode`/`cancelled` 结果；Cookie 选择、命令生成与最终媒体校验仍由宿主管理。管理器兼容已安装的官方 1.0.x 插件；1.1.0 插件也保留旧版宿主的平铺参数与输出事件。扩展中心可使用随应用附带的包离线更新，更新与回滚保留配置。

UTF-8，每行一个 JSON-RPC 2.0 对象，stdout 仅输出协议消息，诊断写 stderr。请求必须按 `id` 返回一个对象结果或错误，不依赖请求完成顺序；任务进行时仍需读取并处理取消。单条消息不得超过 1 MiB。

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"hostApiVersion":1}}
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"hostApiVersion":1}}
{"jsonrpc":"2.0","id":2,"method":"execute","params":{"inputs":{"message":"hello"},"settings":{},"dependencies":{},"outputDirectory":"D:/Downloads"}}
{"jsonrpc":"2.0","method":"progress","params":{"fraction":0.5,"message":"处理中"}}
{"jsonrpc":"2.0","method":"log","params":{"message":"已保存文件"}}
{"jsonrpc":"2.0","id":2,"result":{"paths":["D:/Downloads/result.txt"]}}
{"jsonrpc":"2.0","id":3,"method":"cancel","params":{}}
{"jsonrpc":"2.0","id":3,"result":{"cancelled":true}}
```

失败返回 `error: {"code": -32000, "message": "原因"}`。宿主握手超时 10 秒，取消请求最长等待 2 秒后关闭进程树。Windows Job Object 随宿主/任务关闭杀死插件及子工具进程。插件以当前用户权限执行，独立进程用于故障隔离，不提供操作系统级权限沙箱；清单 permissions 只是供用户审阅的声明。

插件关闭操作可重复调用，所有调用共享同一次清理；发出终止请求后最多等待主进程退出 5 秒，退出后才允许后续安装目录切换或卸载，避免 Windows 上进程仍占用目录时误报安装失败。退出等待超时会返回错误。

## 签名和安装

使用 Ed25519，公钥/签名均为 Base64。签名输入是递归按键名排序、无空白的 JSON UTF-8（`canonicalJson`）。`signature.json` 为 `{publicKey, signature, payload}`，payload 是除 signature.json 外所有文件的相对路径到 SHA-256 小写十六进制值的映射，包括 manifest.json。官方目录采用同样签名信封，payload 为 `{catalogVersion:1, plugins:[{manifest,url,size,sha256,releaseNotes}]}`。

应用仅内置官方公钥。未知签名发布者需确认指纹才保存信任；未签名包仅开发者模式允许。包最大 256 MiB，展开最大 512 MiB，最多 4096 个条目（使用普通 ZIP，拒绝 ZIP64 与分卷）；拒绝路径越界、符号链接、Windows 保留路径、重复路径、签名/哈希不符。安装到临时目录后握手探测，通过后切换版本并保留上一版本；安装失败保持原版，启动时校验发现当前版本损坏则尝试恢复旧版。任务启动前再次验证完整性。

应用支持目录下 `extensions/` 保存 packages、archives、settings、tools 和 registry.json。应用私钥不会放入这些目录或 Flutter 资产。设置保存在本地 JSON；`secret` 隐藏输入显示，不代表加密存储。

## 开发与打包（仓库根目录）

```powershell
flutter pub get
dart run tools/plugin_tool.dart bundle
# 示例第三方插件
New-Item -ItemType Directory -Force build/example/bin
Copy-Item extensions/example/manifest.json build/example/manifest.json
dart compile exe extensions/example/main.dart -o build/example/bin/plugin.exe
dart run tools/plugin_tool.dart keygen build/example.seed
dart run tools/plugin_tool.dart pack build/example build/example.vdx build/example.seed
dart run tools/plugin_tool.dart verify build/example.vdx
```

开发构建自动创建 `build/plugin-signing/local.seed`，只用于本机开发，文件被 git 忽略。Windows CMake 在 Flutter 收集资产之前构建两个随附插件包，离线升级不依赖远程下载。生成包和公钥索引位于 `assets/extensions/generated/`，不提交二进制。

## 正式发布

1. 在受保护的 GitHub Environment `extension-release` 配置 `VIDEODER_PLUGIN_SIGNING_KEY`（32 字节 Ed25519 seed 的 Base64）。每次插件升级递增清单中的 version。长期保留同一密钥；正式应用构建和插件发布必须使用同一密钥。私钥仅保存在受保护发布环境。
2. `dart run tools/plugin_tool.dart bundle --release` 强制要求该密钥。设置 `VIDEODER_PLUGIN_RELEASE_BASE` 后同时输出已签名目录。Windows 应用发布工作流也要求受保护环境密钥，防止正式版本误用开发密钥。
3. 运行 `Extension packages` 工作流，填写独立插件 Release tag；生成草稿 Release 和已签名资产供审阅。发布 Release 后把生成的 `catalog.json` 原样提交到仓库 `extensions/catalog.json`，不要编辑签名后的内容。应用读取当前仓库 main 分支的静态目录；签名错误或离线仍保留缓存。
4. 分发 Windows Release 整个目录或安装包，包括 `data/flutter_assets/assets/extensions/generated/`。插件更新不需要重新编译应用，官方专用界面变化仍需应用更新。

当前仓库未提供正式签名密钥或已发布目录；这些需要发布环境配置完成后上线。开发包不能作为正式更新分发给使用其他公钥的客户端。

## 验证

```powershell
dart run tools/plugin_tool.dart bundle
flutter analyze --no-pub lib test tools
flutter test --no-pub
ctest --test-dir build/native/videoder_core --output-on-failure
flutter build windows --release --no-pub
pwsh -File tools/package_windows.ps1
```

`plugin_system_test.dart` 覆盖签名、损坏、越界、协议、安装、更新、回滚、离线缓存与下载校验；`plugin_runtime_test.dart` 覆盖崩溃、取消、进程树关闭，并用真实签名 TikTok `.vdx` 从本地 API 测试服务器下载文件。该测试不代表真实抖音/TikTok 账号、Cookie 和平台网络验证。

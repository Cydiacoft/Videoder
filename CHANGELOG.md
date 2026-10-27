# Changelog / 更新日志

All notable changes to this project will be documented in this file.  
本项目的重要变更都会记录在这里。

## [26.10.27+8] - 2026-10-27

- 新增签名 VDX 扩展中心、依赖检测、安装、升级、回滚和通用任务页面，随附 yt-dlp 与 TikTokDownloader 1.1.0。
- 图像支持批量处理、BMP/TIFF、即时预览、逐项状态及重试未完成任务。
- 新增静音、镜像、水印、字幕导出、降噪、音量和响度工具，支持自定义编辑预设。
- 改善取消行为、Cookie 导入、中文路径探测、诊断日志及处理结果摘要。
- 发布完整 Windows x64 ZIP 和 SHA-256，插件使用独立正式发布密钥签名。

## [26.9.21+5] - 2026-09-21

- 日志入口统一移至页面右上角，右侧面板显示诊断日志，底部只保留任务状态。
- 宽窗口并排显示日志，窄窗口使用覆盖面板；支持复制、关闭及下载日志清空。
- 包含上一构建的版本更新识别修复。

## [26.9.21+4] - 2026-09-21

- 应用版本改为与仓库一致的日期版本，修复 `1.1.1` 与 `v26.9.21` 混用导致的旧发布误报更新。
- 同日发布支持比较数值构建号；兼容大写 V、首尾空格和历史发布标题中的版本。
- 区分最新版本、本地版本较新、版本解析失败和网络错误；下载按钮打开实际检查到的 Release。

## [1.1.1] - 2026-09-21

- 修复获取最终文件路径时 `--print` 隐式静默造成的下载进度与 ETA 缺失。
- 独立状态栏展示下载当前流进度、速度、ETA，以及合并、后处理、校验和最终结果；支持 Aria2 进度。
- 本地 FFmpeg 工具和专业工作台的任务状态也独立于日志显示。
- 日志不再在开始下载时自动展开，增加复制诊断日志按钮，保留阶段变化与错误，避免进度刷屏。

## [1.1.0] - 2026-09-21

- 网络下载增加视频与音频合并预设、最终流校验及跳过状态。
- 收紧桌面布局，强化侧栏底部分隔，新增绿色就绪点和下载日志折叠。
- 替换默认 Flutter 图标，并改善 Cookie 数据库占用/解密错误提示。

## [1.0.0]

- 转为以 FFmpeg 为核心的桌面工具箱，yt-dlp 作为可选内置扩展。
- 加入视频/音频格式转换、专业参数、视频向导和音频转换/剪切/合并/响度向导。
- 增加浏览器 Cookie 来源、Cookie 文件管理、下载参数及 yt-dlp 更新。
- 重做桌面主题、分组设置与关于/检查更新页面。
- 增加媒体实测、配置与界面回归，修正 Flutter CI 和便携构建脚本。
- 清理过时工作日志、发布文档与旧主题；项目许可证改为 GPL-3.0-only。

## [v15] - 2026-03-26

### Added / 新增
- Added a dedicated download directory configuration card in Settings.  
  在设置页新增了独立的下载目录配置卡片。
- Added clearer environment setup guidance for yt-dlp, ffmpeg, aria2, and the download folder.  
  为 yt-dlp、ffmpeg、aria2 和下载目录补充了更清晰的环境配置提示。
- Added auto-display of ffmpeg and aria2 version info in the environment section.  
  在环境配置区域新增了 ffmpeg 和 aria2 的版本信息展示。
- Added a new cookie management UI flow for platform cookies and custom website cookies.  
  新增了一套更清晰的平台 Cookie 与自定义网站 Cookie 管理交互。
- Added cookie file import support for both platform cookies and custom cookies.  
  为平台 Cookie 和自定义 Cookie 都新增了从文件导入的能力。
- Added validation for custom cookie domain or URL input.  
  新增了自定义 Cookie 的域名或 URL 输入校验。
- Added success feedback after saving, clearing, updating, or deleting cookies.  
  在保存、清除、更新、删除 Cookie 后新增了操作结果提示。
- Added automatic custom cookie matching by domain during downloads.  
  新增了下载时按域名自动匹配自定义 Cookie 的能力。

### Fixed / 修复
- Fixed manual aria2 selection not being saved in Settings.  
  修复了设置页手动选择 aria2 后不会实际保存的问题。
- Fixed desktop configuration flow being blocked because downloadPath was required but not configurable from the UI.  
  修复了桌面端因 `downloadPath` 必填但界面无入口而导致无法完成配置的问题。
- Fixed `isConfigured` so empty strings are no longer treated as valid paths.  
  修复了 `isConfigured` 仅判断 `null`、空字符串仍被视为有效路径的问题。
- Fixed version info rendering so error results are shown as errors instead of normal version entries.  
  修复了版本信息渲染中错误结果被当作普通版本显示的问题。
- Fixed ffmpeg version parsing to support `ffprobe version ...` output.  
  修复了 ffmpeg 版本检测对 `ffprobe version ...` 输出识别失败的问题。
- Fixed cookie parsing so both `document.cookie` style content and Netscape cookie files can be accepted.  
  修复了 Cookie 解析逻辑，使其同时支持 `document.cookie` 风格内容和 Netscape Cookie 文件。
- Fixed cookie status refresh by introducing a state version bump after cookie changes.  
  通过在 Cookie 变更后刷新状态版本，修复了 Cookie 状态更新不及时的问题。

### Changed / 变更
- Changed the active environment settings UI to a cleaner implementation with clearer copy.  
  将当前实际使用的环境配置界面切换为一套更清晰、更易理解的实现。
- Changed download argument building to resolve cookies through a unified cookie path resolver.  
  调整了下载参数构建逻辑，统一通过 Cookie 路径解析器选择可用 Cookie。
- Changed custom cookie storage to normalize domains before saving.  
  调整了自定义 Cookie 的存储逻辑，保存前会先标准化域名。
- Changed cookie file generation to normalize and rewrite entries consistently.  
  调整了 Cookie 文件生成逻辑，统一规范化并重写条目内容。

## [v14] - 2026-03-24

### Added / 新增
- Download/update buttons for yt-dlp, ffmpeg, aria2 (always visible with color-coded styles).  
  新增了 yt-dlp、ffmpeg、aria2 的下载/更新按钮，并始终显示且采用颜色区分。
- Check yt-dlp version button in settings.  
  在设置页新增了 yt-dlp 版本检查按钮。
- SnackBar auto-hide after 5 seconds with copy URL action.  
  新增了 5 秒自动隐藏的 SnackBar，并支持一键复制下载地址。

### Fixed / 修复
- Version check timeout (10 seconds) and error handling.  
  修复了版本检查超时问题，并补充了 10 秒超时和错误处理。
- Version info display crash (fixed Map vs String type issue).  
  修复了版本信息展示崩溃问题，处理了 Map 与 String 类型不匹配的情况。
- Removed ffmpeg version unknown display.  
  修复了 ffmpeg 版本经常显示为 `unknown` 的问题。
- Download buttons now always visible regardless of path configuration.  
  修复了下载按钮受路径配置影响而不显示的问题，现在始终可见。

### Changed / 变更
- Settings page: download buttons use visual color coding.  
  设置页中的下载按钮改为使用颜色区分。
- yt-dlp button uses blue (primary).  
  yt-dlp 按钮使用蓝色（主色）。
- ffmpeg button uses purple.  
  ffmpeg 按钮使用紫色。
- aria2 button uses teal.  
  aria2 按钮使用青色。
- Check version card uses primary container color.  
  版本检查卡片改为使用主色容器背景。
- "检查更新" renamed to "检查 yt-dlp 版本".  
  将“检查更新”重命名为“检查 yt-dlp 版本”。

### Removed / 移除
- Log viewer collapse/expand toggle (simplified to fixed height).  
  移除了日志查看器的折叠/展开开关，改为固定高度。
- Log viewer issues causing gray screen.  
  移除了会导致灰屏问题的旧日志查看器交互。

## [v13] - 2026-03-24

### Added / 新增
- Custom Cookie editing functionality for custom websites.  
  新增了自定义网站 Cookie 的编辑功能。
- Download history management: single delete and clear all/clear completed options.  
  新增了下载历史管理能力，支持单条删除、清空全部和清空已完成。
- Log viewer collapse/expand toggle.  
  新增了日志查看器折叠/展开功能。
- Settings page redesign: two-level menu structure with expand/collapse.  
  重构了设置页，改为支持展开/折叠的二级菜单结构。
- Environment Configuration section (yt-dlp, ffmpeg, aria2 path settings).  
  新增了环境配置区域，包含 yt-dlp、ffmpeg、aria2 路径设置。
- Cookies Configuration section (platform cookies + custom websites).  
  新增了 Cookies 配置区域，包含平台 Cookie 和自定义网站 Cookie。
- Back button in top-left corner.  
  新增了左上角返回按钮。

### Fixed / 修复
- Log viewer now properly collapses and history section adjusts accordingly.  
  修复了日志查看器折叠后布局异常的问题，历史区域会同步自适应。
- Fixed cookiePath/setCookiePath references (removed legacy code).  
  修复了 `cookiePath` / `setCookiePath` 的遗留引用问题，并移除了旧代码。

### Removed / 移除
- Online login feature for Cookie acquisition (focus on Windows development).  
  移除了在线登录获取 Cookie 的功能，当前阶段聚焦 Windows 开发。
- Duplicate format/quality settings (now only in download page).  
  移除了重复的格式/画质设置入口，相关配置现在仅保留在下载页。

## [v12] - 2026-03-19

### Added / 新增
- Copy logs to clipboard button in log viewer.  
  在日志查看器中新增了一键复制日志到剪贴板按钮。

### Fixed / 修复
- Log output encoding issue (GBK to UTF-8).  
  修复了日志输出编码问题，从 GBK 统一到 UTF-8。
- ffmpeg path parameter passing to yt-dlp.  
  修复了 ffmpeg 路径传递给 yt-dlp 时的参数问题。
- Download status detection (exit code 1 without errors now correctly marked as success).  
  修复了下载状态判断问题，现在遇到无错误输出的 exit code 1 会正确标记为成功。

## [v11] - 2026-03-12

### Added / 新增
- Multi-platform Cookie management (YouTube, Bilibili, Twitter/X, TikTok).  
  新增了多平台 Cookie 管理，支持 YouTube、Bilibili、Twitter/X、TikTok。
- Add Cookie dialog: URL, remark, Cookie content.  
  新增了 Cookie 添加弹窗，支持填写 URL、备注和 Cookie 内容。
- Cookie stored in app private directory.  
  Cookie 改为存储在应用私有目录中。
- UI improvements for Cookie management.  
  优化了 Cookie 管理相关界面。

### Fixed / 修复
- Cookie storage issue - now supports multiple platforms.  
  修复了 Cookie 存储只能覆盖单一平台的问题，现在支持多个平台独立存储。
- Cookie path now uses app directory instead of Downloads.  
  修复了 Cookie 路径问题，改为使用应用目录而不是 Downloads。

### Known Issues / 已知问题
- Douyin (TikTok CN): Requires latest yt-dlp nightly + fresh Cookie.  
  抖音（TikTok 中国版）需要最新的 yt-dlp nightly 和新鲜的 Cookie。
- Twitter/X: Only supports tweets with videos.  
  Twitter/X 当前只支持带视频的推文。

## [v10] - 2024-03-11

### Added / 新增
- Initial release.  
  初始版本发布。
- Support for YouTube, Bilibili, Twitter/X, TikTok downloads.  
  新增了对 YouTube、Bilibili、Twitter/X、TikTok 下载的支持。
- Cookie authentication support.  
  新增了 Cookie 认证支持。
- Built-in browser for online login.  
  新增了用于在线登录的内置浏览器。

# Videoder · FFmpeg Studio

一个基于 Flutter 的桌面音视频工具箱。核心负责本地 FFmpeg 处理，网络下载通过可选的 yt-dlp 内置扩展提供。当前主要开发与验证平台为 Windows；Linux、macOS 保留桌面工程，尚未完成发行验证。Android 工程为历史脚手架，本地进程工具不支持 Android。

**Windows 最新版：**[v26.10.3+7 Release](https://github.com/Cydiacoft/Videoder/releases/tag/v26.10.3%2B7)。下载 `Videoder-v26.10.3+7-windows-x64.zip`，完整解压后运行 `videoder_demo.exe`；请保留同目录的 `data/` 和 DLL 文件。FFmpeg、ffprobe、yt-dlp 和 Aria2 按下文配置，不包含在发行包内。

![格式转换](docs/screenshots/toolbox.png)

## 功能

- **格式转换**：视频支持 MP4、MKV、MOV、WebM、AVI、FLV、TS；音频支持 MP3、M4A、FLAC、WAV。按视频/音频分类，更多视频格式按需展开。
- **提取、压缩与剪切**：从视频提取音轨，使用 CRF 压缩视频，按时间截取片段。输出另存新文件。
- **图像处理**：导入本地图像后可裁剪、缩放、旋转并转换为 PNG、JPEG 或 WebP；从视频首帧提取封面，或按指定秒数导出画面。参数生成和 FFmpeg 任务执行由 C++ 核心负责。
- **专业工作台**：向导操作与命令编辑并存。视频支持转码、换封装、缩放、旋转、倍速、字幕、GIF 和拼接；音频支持转换、剪切、拼接、响度统一、采样率与声道设置。
- **专业参数**：编码器、码率、CRF、硬件解码、视频/音频滤镜、命令导入导出，以及媒体信息与本机编码能力检测。
- **设置与关于**：分组设置、FFmpeg 检测、默认输出目录、扩展开关、版本信息与应用更新检查。

![音频工作台](docs/screenshots/expert-audio.png)

## 开始使用

1. 在“设置与扩展 → FFmpeg 引擎”选择已解压的 `ffmpeg` 可执行文件，点击检测版本；媒体信息功能还需要同目录的 `ffprobe`。
2. 设置默认保存位置，添加素材，选择工具和输出格式，再开始处理。
3. 需要下载网络媒体时，在设置中启用 **yt-dlp 网络下载**，配置 yt-dlp 路径。Aria2 为可选下载器。

图像处理在侧栏的“图像处理”中使用。选择图像或视频、输出文件夹及格式；缩放和裁剪留空表示保持原样。封面功能提取视频首帧，网络视频的站点封面可在下载扩展中另行保存。图像输出自动使用新文件名，不覆盖已有文件；处理期间可以取消。

FFmpeg 可从 [官方下载页面](https://ffmpeg.org/download.html) 选择对应系统构建，yt-dlp 可从 [官方发布页](https://github.com/yt-dlp/yt-dlp/releases) 获取。FFmpeg 当前采用下载、解压、选择路径的方式配置，应用不自动安装它；已配置的 yt-dlp 可在扩展设置中更新。

## 下载扩展与 Cookie

网络视频默认请求视频和音频并合并为 MKV，完成后使用同目录的 ffprobe 检查两种流；仅有视频的旧文件不会误报下载完成。独立任务状态栏显示当前流进度、速度、ETA，以及合并、后处理和成品校验阶段；日志可展开/收起或复制用于排错，不影响状态显示。网络下载支持按行输入多个链接、画质上限（至 4K）、音频/封面下载，以及字幕、播放列表范围、限速、重试、代理、命名模板和自定义参数。高级参数需点击“应用参数”后生效。

在“下载与 Cookie → Cookie 管理”选择浏览器、填写可选的配置文件，再点击“应用 Cookie 来源”。先在相应浏览器登录网站，应用会在下载时通过 yt-dlp 读取登录状态。浏览器模式优先于手动 Cookie 文件，不会将浏览器 Cookie 导出到原来的站点文件。Windows 上 Chrome/Edge 的加密或数据库占用可能导致读取失败，可尝试 Firefox 或手动导入 Netscape cookies.txt。也支持粘贴 Cookie 请求头。

登录信息与下载参数保存在本机，请勿将 Cookie 文件提交到仓库或分享。网站访问限制、账号权限和网络风控仍可能使下载失败，配置 Cookie 不保证消除 HTTP 412 等错误。

扩展目前是**随应用编译的模块**，不是可下载安装的第三方插件市场。接口见 [扩展开发说明](docs/extensions.md)。

## 处理规则与限制

- 基础工具默认 WebM 使用 VP9 + Opus，AVI 使用 MPEG-4 + MP3，其余视频格式使用 H.264 + AAC。视频编码可另选：MP4/MKV 支持 H.264、HEVC、AV1，MOV/TS 支持 H.264、HEVC，WebM 支持 VP9、AV1；压缩与剪切也可选择 MP4 的三种编码。
- 基础 MP3/M4A 提供 128–320 kbps；FLAC/WAV 使用 16 位输出。转换无损格式或提高采样率不会恢复源文件已丢失的信息。
- 音频拼接会统一采样率和声道再编码；响度统一使用 `loudnorm` 单遍动态处理，目标 -16 LUFS。视频拼接需要相同分辨率且各段含音轨。
- 压缩后的体积取决于源素材，不保证一定更小；硬件编码是否可用取决于 FFmpeg 构建、显卡与驱动。
- GPU 加速在“设置与扩展 → FFmpeg 引擎”中检测并启用。检测覆盖 H.264、HEVC、AV1、VP9，逐个进行短片段试编码，仅提供本机通过测试的编码器；更换 FFmpeg 后需重新检测。基础工具使用软件解码和滤镜、GPU 编码，未匹配到硬件编码器时保留所选编码并使用 CPU（HEVC/AV1 分别需要 FFmpeg 包含 libx265/libaom-av1，AV1 软件编码可能较慢）。输出设置显示实际编码方式。剪切先定位起点，减少长视频的无用解码。
- 专业工作台的转码和缩放支持“GPU 解码与缩放（NVIDIA）”：在高级参数中选择 H.264/HEVC/AV1 NVENC 编码器后可启用。使用 CUDA 解码、预设缩放与硬件编码；需要 FFmpeg 包含 scale_cuda 且显卡支持源视频解码。自定义其他滤镜需关闭此选项，音频仍由 CPU 处理。相关参数见 [FFmpeg CUDA 滤镜文档](https://ffmpeg.org/ffmpeg-filters.html#scale_005fcuda)。硬件编码质量值也会生效，手动指定视频码率时以码率为准。
- GPU 检测显示逐项进度和失败原因；重新检测保留仍可用的手动编码器、CPU 选择及已关闭的加速开关。检测期间修改设置会停止后续试编码并丢弃过时结果。清空最后一个硬件编码器时自动关闭加速。处理状态显示 FFmpeg 报告的实时速度和帧率，便于观察不同设置的处理表现。
- 专业视频向导按操作和输出容器筛选编码器，例如 WebM 只提供 VP9/AV1 与 Opus/Vorbis；切换格式会自动调整冲突选项并提示。硬件编码器先试编码再开放，GPU 解码与缩放还需当前素材的短片段验证。换封装向导固定为 MKV 并锁定编码参数，GIF 锁定无关设置；滤镜操作不提供流复制。输入数量、容器、质量及码率不合法时禁止生成或执行。手动命令编辑保留自由参数，不应用向导的组合筛选。
- 图像处理依赖本机 FFmpeg；WebP 导出还需 FFmpeg 包含 `libwebp` 编码器。缩放宽高可只填一项以保持原始比例；裁剪须填写 X、Y、宽、高。输入图像或视频损坏、截图时间超出视频长度时不会生成有效输出。
- 自定义命令以参数数组调用本地程序，不经系统 Shell。修改命令时请自行确认输入、输出及覆盖选项。

## 开发与构建

需要支持当前依赖的 Flutter stable、Dart 3.1 或更高版本，以及目标平台的桌面编译工具链。Windows 需要 Visual Studio 的 C++ 桌面开发工具（含 CMake）；Linux / macOS 需要 CMake 3.16 或更高版本。仓库保留 `pubspec.lock` 以固定依赖版本。

```sh
flutter pub get
flutter analyze lib test
flutter test
flutter build windows --release
```

原生核心也可以单独构建和测试（推荐在改动 C++ 后先跑这一步）：

```sh
pwsh -File tools/build_core.ps1      # Windows
tools/build_core.sh                  # Linux / macOS
```

Windows 也可以运行 `./build.ps1`，或 `./build.ps1 -Clean`。构建输出位于 `build/windows/x64/runner/Release/`；分发时应打包整个 Release 目录，不要只复制 exe。构建产物放到 GitHub Releases，不提交到源码仓库。

真实媒体测试需要外部 FFmpeg（同目录应有 ffprobe）：

```powershell
$env:FFMPEG_TEST_PATH = 'D:\tools\ffmpeg\bin\ffmpeg.exe'
flutter test --reporter expanded --timeout 120s
```

不设置该变量时会跳过实际转码测试，其余参数、配置和界面测试仍运行。CI 使用 Linux FFmpeg 运行媒体回归。Windows 下可设置 `CAPTURE_TOOLBOX=1` 并使用 `flutter test test/widget_test.dart --update-goldens` 更新文档截图。

## 原生核心（C++ Core）

Flutter 负责界面，参数验证、图像命令构造及媒体任务执行由 `native/videoder_core` 负责。两者通过稳定 C ABI 通信（不透明句柄、固定宽度整数、明确的字符串与回调所有权、C++ 异常在边界处转换为错误码）。

```
Flutter UI → lib/core_bridge/ → C ABI → C++ Core → FFmpeg / yt-dlp / aria2c（外部可执行文件）
```

约定：

- 只有 `lib/core_bridge/` 允许 `import 'dart:ffi'`；页面、provider、service 一律通过 `VideoderCore` 访问核心（例如 `VideoderCore.probeFile()` 返回结构化的 `MediaInfo`，`VideoderCore.queryHardware()` 返回结构化的 `HardwareCapabilities`，`VideoderCore.buildMediaArguments()`/`buildExpertArguments()`/`buildAudioExpertArguments()`/`buildImageArguments()` 生成 FFmpeg 参数，`VideoderCore.parseArguments()`/`formatArguments()` 负责命令行的解析与展示；Dart 不再解析 ffprobe 的 JSON，也不再自己解析 `ffmpeg -encoders` 输出或拼接处理参数）。
- 动态库：Windows 为 `videoder_core.dll`（与 exe 同目录），Linux 为 `libvideoder_core.so`（bundle `lib/`），macOS 为 `libvideoder_core.dylib`（`Contents/Frameworks`）。加载器按固定顺序探测，也可用环境变量 `VIDEODER_CORE_LIBRARY` 指定绝对路径。
- 事件走有界队列；C++ dispatcher 线程只发送"有事件待取"的唤醒信号，数据由核心的 `poll_event` 交付，避免跨线程回调读到已释放内存。耗时操作（如 ffprobe）在核心的 worker 线程执行，结果先落到结果槽、再由宿主读取，因此事件丢失也不会丢数据。
- 原生核心可以脱离 Flutter 单独构建与测试，这是每个迁移阶段的验收前提（命令见上一节）。

`flutter build windows --release` 会一并构建并安装原生核心，无需单独执行上面的脚本。当前进度与分阶段计划见 [架构重构说明](docs/architecture/native-core-migration.md)：Phase 1–8 已在 Windows 落地，核心负责媒体探测、编码能力检测、FFmpeg 与 yt-dlp/aria2c 参数构造、图像处理命令、转码和下载进程、进度解析，以及统一任务状态和取消。下载设置、界面显示和最终音视频校验仍由 Dart 层管理；普通媒体功能保留仍在使用的 Dart 兼容路径，图像处理需要 C++ 核心。macOS 的核心嵌入与沙箱权限尚未在本机验证，需要在 macOS 上实际构建和试运行。

## 应用更新

“设置与扩展 → 关于 Videoder”检查 [本仓库 Releases](https://github.com/Cydiacoft/Videoder/releases) 的最新公开正式发布并展示更新说明。Windows 上可选择独立的更新包下载目录，直接下载并校验 ZIP，查看进度、取消下载或打开所在文件夹。应用不会自动替换或安装程序。

版本信息读取打包的 `pubspec.yaml`。发布时请同步版本号，使用 `v主版本.次版本.修订版本` 标签并上传完整发行包。没有可访问的公开发布、网络失败、限流或无法识别的版本号时，检查不会误报为“已是最新版”。

## 许可证

本项目采用 **GNU General Public License v3.0（GPL-3.0-only）**，完整条款见 [LICENSE](LICENSE)，历史代码的版权声明保留在 [NOTICE](NOTICE)。

FFmpeg、yt-dlp、Aria2、Flutter 及第三方依赖各自遵循其许可证。外部工具默认不随本项目分发；若制作包含这些工具的发行包，须同时遵守相应许可证及分发要求。

### 发布版本编号

应用与 GitHub Release 使用同一套日期版本，例如 `pubspec.yaml` 中的 `26.10.3+7` 对应标签 `v26.10.3+7`。同日再次发布时递增 `+` 后的构建号；更换日期时更新主版本并继续递增构建号。旧标签 `v26.9.21` 不包含构建号，只比较日期部分。

请先更新 `pubspec.yaml` 再编译，发布标签应与安装包内版本一致。不要把 `1.x.x` 的安装包放在 `v26.x.x` 的标签下，也不要只修改发布标题。更新检查使用 GitHub 最新的公开正式 Release，草稿和预发布不作为正式更新。

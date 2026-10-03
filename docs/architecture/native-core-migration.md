# Videoder 架构重构分析：Dart → C++ Core（渐进式迁移）

> 状态：Phase 1、Phase 2 已完成并验证（见 §13 进度记录）。
> 分析基线：工作区实际内容（`main` 分支 + 未提交的 GPU 检测改动），不以 HEAD 为准。
> 目标：Flutter 只做 UI，C++ 承担与 UI 无关的核心业务，二者之间是稳定 C ABI。

---

## 1. 当前架构图

```
┌──────────────────────────────────────────────────────────────────────┐
│ lib/main.dart  (MaterialApp / 侧边导航 / IndexedStack / 主题模式)      │
│ lib/pages/       toolbox_page(633) expert_page(~1221) settings_page   │
│                  about_page(142)                                       │
│ lib/widgets/     task_status_bar, diagnostic_panel                     │
│ lib/theme/       studio_theme                                          │
│ lib/extensions/  ToolboxExtension 接口 + 编译期注册表                  │
└───────────────┬──────────────────────────────────────────────────────┘
                │ Riverpod（StateNotifier / Provider）
┌───────────────▼──────────────────────────────────────────────────────┐
│ 状态层  lib/providers/                                                │
│   app_provider.dart    AppSettings(SharedPreferences) + GPU 检测编排   │
│   media_provider.dart  MediaNotifier：ffmpeg 进程 + stdout 解析 + 取消 │
│ 插件状态 lib/plugins/yt_dlp/providers/download_provider.dart (989)     │
│   yt-dlp 进程 + 进度模板解析 + 日志环形缓冲 + Cookie/Aria2 配置        │
└───────────────┬──────────────────────────────────────────────────────┘
                │ 直接调用（页面 → provider → service）
┌───────────────▼──────────────────────────────────────────────────────┐
│ 业务服务层  lib/services/ + lib/plugins/*/services/                    │
│   media_command.dart(196+)      FFmpeg 参数构造（转换/音频/压缩/剪切） │
│   expert_command.dart(351+)     预设参数构造 + ArgumentCodec(argv 语法)│
│   audio_expert_command.dart(86) 音频预设参数构造                      │
│   expert_constraints.dart(66)   格式/编码器兼容矩阵                    │
│   gpu_acceleration.dart(133)    硬件编码器族、各厂商质量参数、探测选择  │
│   media_inspector.dart(114+)    ffprobe 调用 + -encoders/-hwaccels 解析│
│   tool_process.dart(27)         Process.start 包装 + 超时             │
│   app_update.dart(123)          GitHub Releases + 版本比较            │
│   yt_dlp/services/             进度解析 / 参数 / Cookie / 成品校验     │
└───────────────┬──────────────────────────────────────────────────────┘
                │ dart:io Process / File / HttpClient
┌───────────────▼──────────────────────────────────────────────────────┐
│ OS：ffmpeg / ffprobe / yt-dlp / aria2c（均为外部可执行文件）           │
│ SharedPreferences / path_provider / file_picker / url_launcher         │
└──────────────────────────────────────────────────────────────────────┘
```

关键事实：**当前 C++ 层没有任何业务逻辑**；全部业务在 Dart 中，通过 `dart:io` 直接驱动外部进程。

## 2. 当前仍由 Dart 实现的核心功能（可迁移候选清单）

| 领域 | 位置 | 内容 | 迁移价值 |
|---|---|---|---|
| FFmpeg 参数构造 | `services/media_command.dart` | 4 种操作的完整参数、容器/编码矩阵、`-progress pipe:1`、VA-API 初始化 | 高 |
| FFmpeg 参数构造（高级） | `services/expert_command.dart` | 8 种预设、滤镜图（GIF/合并/字幕）、码率与 CRF 校验、`ArgumentCodec` | 高 |
| FFmpeg 参数构造（音频） | `services/audio_expert_command.dart` | 4 种音频预设、`concat`/`loudnorm` 滤镜 | 高 |
| 兼容性约束 | `services/expert_constraints.dart` | 容器×编码器×音频编码矩阵、质量区间 | 高 |
| 硬件编码知识 | `services/gpu_acceleration.dart` | NVENC/AMF/QSV/VideoToolbox/VA-API 质量参数、族选择优先级 | 高 |
| 进程执行 + 进度解析 | `providers/media_provider.dart` | `Process.start(ffmpeg)`、`out_time*`/`speed`/`fps`/`progress=` 解析、取消、成品校验（文件存在且非空） | 高 |
| 进程执行（工具探测） | `services/tool_process.dart` | `runTool` + 15s 超时 + `resolveExecutable` | 高 |
| ffprobe / 媒体信息 | `services/media_inspector.dart` | ffprobe JSON 调用、`-encoders`/`-hwaccels` 正则解析、试编码探测 GPU | 高 |
| GPU 探测编排 | `providers/app_provider.dart#detectGpu` | 版本号防陈旧、结果合并、持久化 | 中（状态留在 Dart，探测放 C++） |
| yt-dlp 参数构造 | `plugins/yt_dlp/providers/download_provider.dart#_buildArgs` | 输出模板、画质选择器、aria2 `--downloader-args`、Cookie、选项/开关 | 高 |
| yt-dlp 进度解析 | `plugins/yt_dlp/services/download_progress.dart` | `--progress-template` JSON、Aria2 进度正则、后处理阶段映射 | 高 |
| yt-dlp 选项校验 | `plugins/yt_dlp/services/download_options.dart` | 字段/开关 → 参数、整数校验 | 高 |
| 下载任务与进程 | `download_provider.dart#startDownload` | 任务创建、退出码、错误分类、日志环形缓冲（500）、成品音视频校验 | 高 |
| aria2 能力/自动发现 | `download_provider.dart#_autoDetectAria2` | 平台搜索路径、`--version` 校验、参数生成 | 中 |
| 版本比较 | `services/app_update.dart#compareVersions` | 纯函数 semver 比较（HTTP 请求留在 Dart） | 低（可留 Dart） |

## 3. C++ 当前实际承担的职责

无业务职责。现有 C++ 仅：

- 创建 Flutter 视图并托管引擎（`FlutterViewController`）。
- 窗口/消息循环/DPI/资源（`Win32Window`、`utils.cpp`、Linux 的 GTK `my_application.cc`）。
- 注册插件（`generated_plugin_registrant`）。

补充事实：`windows/CMakeLists.txt` 的 `apply_standard_settings()` 会给 runner 加 `_HAS_EXCEPTIONS=0`（即禁用 C++ 异常）。新的 native core 必须是**独立 target**，显式启用异常（`/EHsc`、`_HAS_EXCEPTIONS=1`），否则 §23「extern "C" 入口必须 catch」无法实现。

## 4. 哪些 C++/原生产物是 Flutter 自动生成的 Runner

全部为 `flutter create` 模板产物，模板注释仍在：

| 路径 | 性质 | 本项目定制 |
|---|---|---|
| `windows/flutter/{CMakeLists.txt,generated_plugin_registrant.cc,generated_plugins.cmake}` | 生成/托管 | 无（勿手改） |
| `windows/runner/{main.cpp,flutter_window.cpp,win32_window.cpp,utils.cpp,*.h,Runner.rc,runner.exe.manifest}` | 模板 | 仅窗口标题 `Videoader - FFmpeg Studio` |
| `windows/CMakeLists.txt` | 模板 | `CMAKE_VS_PLATFORM_TOOLSET v180`（VS 18） |
| `linux/runner/{main.cc,my_application.cc,my_application.h}` | 模板 | `APPLICATION_ID`、窗口标题 |
| `macos/Runner/{AppDelegate.swift,MainFlutterWindow.swift}`、`GeneratedPluginRegistrant.swift` | 模板 | 无 |
| `macos/Runner/Configs/AppInfo.xcconfig` | 模板 | `PRODUCT_NAME`/bundle id 已改 |

结论：这些文件**不迁移、不重写**，只在必要处新增「构建 native core 并把它放到可被 dlopen 的位置」这一步。

**已发现的平台既有风险（与本次重构无关，但必须记录）**：
`macos/Runner/Release.entitlements` 开启了 `com.apple.security.app-sandbox` 且**没有** `network.client` / `files.user-selected.read-write`。因此 macOS 上当前的 Dart 实现（启动外部 ffmpeg/yt-dlp、写入任意目录）在沙箱下本就会失败。无论核心用 Dart 还是 C++，macOS 都需要在发行前确定引擎打包与签名方式，并处理网络和用户选中文件权限；本机没有 macOS 工具链，这项发行验证仍待完成。

## 5. 推荐迁入 C++ 的模块（按风险从低到高排序）

1. **媒体信息解析**：ffprobe 调用 + JSON → `MediaInfo` 结构（`media/`）。
2. **硬件能力检测**：`-encoders`/`-hwaccels`/`-init_hw_device` 探测 + 试编码 + 缓存（`hardware/`）。
3. **FFmpeg 参数构造**：`media_command` / `expert_command` / `audio_expert_command` / `expert_constraints` / `gpu_acceleration` 的质量参数（`ffmpeg/`）。纯函数，最容易与 Dart 逐字节比对。
4. **进程执行 + 进度解析**：`ProcessRunner`（`process/`）+ ffmpeg 进度块解析（`ffmpeg/`）+ 取消/超时/进程树清理。
5. **yt-dlp**：参数构造、进度模板解析、错误分类、任务（`ytdlp/`）。
6. **aria2**：能力探测、配置、参数生成（`ytdlp/aria2` 或独立 `aria2/`）。
7. **统一 TaskManager**：任务注册表、状态机、队列、事件（`tasks/`、`events/`）。

迁移顺序即 Phase 2→7，理由：依赖递减、可测试性递增。

## 6. 不推荐迁移的 Dart 模块（保留在 Dart）

| 模块 | 保留原因 |
|---|---|
| 所有 `pages/`、`widgets/`、`theme/`、`main.dart` | 纯 UI，迁走只会增加 FFI 复杂度 |
| UI 状态（`mediaOperationProvider`、`_selected`、`_engineOpen`、`_logExpanded`、表单 controller、`_crf` 等） | §14 明确要求留在 Dart |
| Riverpod 依赖注入与生命周期 | Flutter 生态强绑定 |
| `file_picker` / `url_launcher` / `path_provider` | 插件为 Flutter 服务，C++ 无对应替代收益 |
| `SharedPreferences` 配置持久化 | 现有格式必须兼容（§20），Dart 侧 API 成熟；C++ 只接收解析后的结构体 |
| `AppUpdate` 的 HTTP 请求与 UI 文案 | 纯 Dart `HttpClient` 已够用；只有 `compareVersions` 是"纯函数"，但它是版本号语义而非媒体核心，留在 Dart 风险最低 |
| `cookie_codec` / `browser_cookies` 的**文件读写与 UI 提示文案** | Cookie 文件位置兼容性由 Dart 的 `path_provider` 决定；核心只接收 `--cookies <path>` |
| `extensions/` 编译期扩展契约 | 宿主 UI 概念 |
| `ArgumentCodec.quote/format`（用于日志展示） | 展示用字符串；C++ 侧只需 `parse`（argv 分割）用于自定义参数 |

判定原则：**只有当逻辑与 UI 无关、且被进程/媒体语义支配时**才迁入 C++。

## 7. FFI 边界设计

### 7.1 依赖方向

```
Page ──► Controller/Notifier ──► lib/core_bridge/videoder_core.dart ──► native_bindings.dart ──► C ABI ──► C++ Core
```
页面**禁止**出现 `DynamicLibrary` / `dart:ffi`（Phase 1 起由 `test/core_bridge_test.dart` 与约定保证）。

### 7.2 事件模型：有界队列 + 可选唤醒回调（**Phase 1 实测修正，重要**）

关键约束分析：

- ffmpeg/yt-dlp 的 stdout 解析发生在 **C++ worker 线程**，不是 Dart 线程。
- `NativeCallable.isolateLocal` 只能从**创建它的 isolate 线程**调用，worker 线程直接调用属于未定义行为 → 禁止。
- `NativeCallable.listener` **允许任意线程调用**（Dart 2.17+，本项目 SDK 已提升到 `>=3.1.0` 以满足 `NativeFinalizer`/`listener` 要求），但**回调是异步的**：native 帧返回后，Dart 回调才在 isolate 事件循环中执行。

**Phase 1 实测结论（这是本次重构最容易踩的坑）**：
最初设计把 `const VDEvent*` 传给 listener，并声明"指针在回调期间有效"。Dart 侧实测得到：数值字段（type/level）正常，**字符串字段为空**——因为 Dart 回调执行时，C++ 那个栈上的 `QueuedEvent` 早已析构，`message.c_str()` 指向已释放内存。也就是说：

> 对 `NativeCallable.listener` 而言，"回调期间有效"这个生命周期约定是**不可用**的，因为 Dart 回调并不在 native 调用期间运行。

最终设计（已在 Phase 1 落地）：

```
[C++ worker] ──enqueue──► 有界事件队列（唯一数据源，容量 4096，丢弃策略+计数）
                                 ├──► vd_core_poll_event()/wait_event()  ← 唯一交付出 payload 的通道
                                 └──► dispatcher thread ──► listener() 仅作"有事件待取"的合并唤醒信号
```

- **payload 只经 poll/wait 交付**，由宿主决定何时读取，字符串生命周期完全可控（Dart 在 FFI 调用内立即 `toDartString()` 拷贝）。
- listener 是**合并的唤醒信号**（可能一次通知对应多个事件），因此 Dart 侧在回调里 `drainEvents()`，而不是直接读指针。
- 安装 listener 时会**异步补发一次通知**（由 dispatcher 线程投递，绝不在 `set_event_listener` 调用内回调），保证"安装前已排队的事件"不会被漏掉。
- 所有 listener 调用都发生在 core 的 dispatcher 线程上；`set_event_listener` 返回后保证没有回调在飞行中（callback mutex 语义），宿主可立即释放 `user_data`。
- 队列有界：溢出时优先丢弃 `LOG`，其次丢弃新到的低价值事件，**终态事件（completed/failed/cancelled）永不丢弃**；丢弃量可通过 `vd_core_dropped_event_count()` 观察。
- `vd_core_wait_event(..., timeout_ms)` 供**独立 isolate** 阻塞消费，不阻塞 UI isolate。

线程安全规则（已写入头文件，属 ABI 契约）：

1. 除 `vd_core_last_error_message` / `vd_string_free` / `vd_core_version` / `vd_core_abi_version` 外，所有函数要求有效句柄。
2. 同一句柄的 `poll_event` / `wait_event` 不得并发调用（内部 scratch 字符串会被覆写）。
3. listener 由 core dispatcher 线程调用，**不携带任何 payload**。
4. 回调内**不得**再调用同一句柄的任何 API（含 `destroy`）。
5. `vd_core_destroy` 之前必须确保没有正在进行的调用。

### 7.3 字符串与内存所有权

- 返回 `const char*` 且指向**静态存储**的（`vd_core_version`）→ 永不释放。
- 返回 `char*` 且由 core `malloc` 的（`vd_core_last_error_message`）→ 必须 `vd_string_free()`，**绝不**用 Dart allocator 释放。
- 事件内嵌字符串由 core 持有，生命周期到下一次 poll；Dart 侧 `toDartString()` 立即拷贝。
- 输入字符串：Dart 传入、C++ 当次调用内读取完即拷贝，不保留指针（除非 API 显式说明，例如后续 `vd_task_create` 会拷贝进 `std::string`）。

### 7.4 ABI 稳定性

- `extern "C"`、固定宽度整数（`uint8_t/uint32_t/int32_t/uint64_t/int64_t/double`）。
- 不透明句柄 `typedef struct VDCoreHandle VDCoreHandle;`。
- 结构体带 `struct_size` 字段（`VDEvent`），未来可扩展字段而不破坏旧调用方。
- 返回枚举 `VDError`；不抛异常、不跨 ABI 传 `std::string`/`std::vector`/`std::function`。
- `vd_core_abi_version()` 供 Dart 启动时校验。

## 8. C ABI 初稿

Phase 1 **只实现已落地的子集**（见 `native/videoder_core/include/videoder_core.h`），下面是完整目标草案，随 Phase 逐步补齐（不提前声明未实现函数，避免伪实现）：

```c
/* ---------- 基础 ---------- */
uint32_t     vd_core_abi_version(void);
const char*  vd_core_version(void);                  /* 静态，勿释放 */

VDCoreHandle* vd_core_create(void);
void          vd_core_destroy(VDCoreHandle* handle);

char*         vd_core_last_error_message(void);      /* 线程局部，需 vd_string_free */
void          vd_string_free(char* value);

/* ---------- 日志 ---------- */
typedef void (*VDLogSinkFn)(int32_t level, const char* message, void* user_data);
void vd_core_set_log_level(VDCoreHandle*, VDLogLevel level);
void vd_core_set_log_sink(VDCoreHandle*, VDLogSinkFn sink, void* user_data);
VDError vd_core_log_message(VDCoreHandle*, VDLogLevel level, const char* message);

/* ---------- 事件 ---------- */
typedef void (*VDEventListenerFn)(void* user_data);   /* 合并唤醒信号，无 payload */
VDError vd_core_poll_event(VDCoreHandle*, VDEvent* out_event, uint8_t* out_has_event);
VDError vd_core_wait_event(VDCoreHandle*, VDEvent* out_event, uint8_t* out_has_event, uint32_t timeout_ms);
VDError vd_core_set_event_listener(VDCoreHandle*, VDEventListenerFn listener, void* user_data);
uint64_t vd_core_dropped_event_count(VDCoreHandle*);

/* ---------- 媒体信息（Phase 2 已落地） ---------- */
VDError vd_media_probe_start(VDCoreHandle*, const VDProbeOptions*, uint64_t* out_request_id);
VDError vd_media_probe_read_result(VDCoreHandle*, uint64_t request_id, VDMediaInfo* out, uint8_t* out_has_result);
VDError vd_media_probe_release_result(VDCoreHandle*, uint64_t request_id, uint8_t* out_released);
VDError vd_media_probe_cancel(VDCoreHandle*, uint64_t request_id, uint8_t* out_cancelled);

/* ---------- 硬件能力（Phase 3 已落地） ---------- */
typedef struct VDStringArray {            /* 调用方分配指针数组，core 写指针 */
    uint32_t struct_size, count, capacity, written;
    const char** items;
} VDStringArray;

typedef struct VDHardwareCapabilities {   /* 四个数组均由调用方分配 */
    uint32_t struct_size, reserved0;
    VDStringArray* video_encoders;
    VDStringArray* audio_encoders;
    VDStringArray* hardware_accels;
    VDStringArray* hardware_encoders;
} VDHardwareCapabilities;

VDError vd_hardware_query_start(VDCoreHandle*, const VDHardwareQueryOptions*, uint64_t* out_request_id);
VDError vd_hardware_query_read_result(VDCoreHandle*, uint64_t id, VDHardwareCapabilities*, uint8_t* out_has_result);
VDError vd_hardware_query_release_result(VDCoreHandle*, uint64_t id, uint8_t* out_released);
VDError vd_hardware_query_cancel(VDCoreHandle*, uint64_t id, uint8_t* out_cancelled);

/* ---------- FFmpeg 参数构造（Phase 4a 已落地；4b 为 expert/audio） ---------- */
typedef enum VDMediaCommandStatus {      /* 返回值即拒绝原因，UI 文案由宿主决定 */
    VD_MEDIA_COMMAND_OK = 0,
    VD_MEDIA_COMMAND_ERROR_PATH = 1,
    VD_MEDIA_COMMAND_ERROR_UNSUPPORTED_CONTAINER = 2,
    VD_MEDIA_COMMAND_ERROR_UNSUPPORTED_VIDEO_FORMAT = 3,
    VD_MEDIA_COMMAND_ERROR_CODEC_NOT_IN_CONTAINER = 4,
    VD_MEDIA_COMMAND_ERROR_INVALID_TIME_SYNTAX = 5,
    VD_MEDIA_COMMAND_ERROR_INVALID_TIME_VALUE = 6,
    VD_MEDIA_COMMAND_ERROR_INVALID_TIME_RANGE = 7,
    VD_MEDIA_COMMAND_ERROR_INVALID_AUDIO_BITRATE = 8,
    VD_MEDIA_COMMAND_ERROR_INVALID_QUALITY = 9,
    VD_MEDIA_COMMAND_ERROR_API = -1
} VDMediaCommandStatus;

typedef struct VDMediaCommandOptions { /* operation/format/video_codec/start/end/... */
    ...
} VDMediaCommandOptions;

int32_t vd_ffmpeg_build_media_args(VDCoreHandle*, const VDMediaCommandOptions*, VDStringArray* out_args);
VDError vd_ffmpeg_video_codecs_for_format(VDCoreHandle*, const char* format, VDStringArray* out_codecs);

/* ---------- 统一任务（ABI 3；各任务由对应 start API 创建） ---------- */
VDError vd_task_snapshot(VDCoreHandle*, uint64_t task_id, const char** out_json);
VDError vd_task_cancel(VDCoreHandle*, uint64_t task_id, uint8_t* out_found);
```

`VDEvent`（Phase 1 已落地固定字段，后续只追加；`struct_size` 由调用方填 `sizeof(VDEvent)`，core 拒绝过小的结构体，因此 ABI 不匹配会报错而不是越界写内存）：

```c
typedef struct VDEvent {
    uint32_t    struct_size;        /* 调用方填 sizeof(VDEvent) */
    uint32_t    type;               /* VDEventType */
    uint64_t    task_id;            /* 0 = 非任务事件 */
    uint32_t    flags;              /* VD_EVENT_FLAG_HAS_FRACTION 等 */
    double      fraction;           /* 0..1 */
    uint64_t    bytes_downloaded;
    uint64_t    bytes_total;
    uint64_t    speed_bps;
    int64_t     eta_seconds;        /* <0 = 未知 */
    int32_t     exit_code;
    int32_t     level;              /* LOG 事件的日志级别 */
    const char* message;            /* 到下次 poll 前有效，可空 */
    const char* detail_json;        /* 结构化扩展载荷，同上 */
} VDEvent;
```

错误码（Phase 1 已落地）：

```c
typedef enum {
    VD_OK = 0, VD_ERROR_INVALID_ARGUMENT, VD_ERROR_INVALID_HANDLE,
    VD_ERROR_NOT_FOUND, VD_ERROR_PROCESS_START, VD_ERROR_TIMEOUT,
    VD_ERROR_CANCELLED, VD_ERROR_UNSUPPORTED, VD_ERROR_IO, VD_ERROR_PARSE,
    VD_ERROR_STATE, VD_ERROR_OUT_OF_MEMORY, VD_ERROR_UNKNOWN
} VDError;
```

## 9. 目录结构建议（尊重现有工程，不做大规模重命名）

```
videoder_demo/
├── lib/
│   ├── core_bridge/            ← 新增：唯一允许 import dart:ffi 的地方（Phase 1 已落地）
│   │   ├── native_library.dart      动态库定位与加载（env / exe 目录 / bundle / 构建输出 / PATH）
│   │   ├── native_bindings.dart     FFI 类型、结构体布局与符号表
│   │   ├── native_error.dart        VDError ↔ 异常（含库不可用异常）
│   │   ├── native_event.dart        NativeEvent 模型 + 事件类型/日志级别枚举
│   │   ├── videoder_core.dart       门面：open/openForPolling、events 流、drainEvents、日志
│   │   ├── task.dart / download_task.dart / transcode_task.dart / media_info.dart  ← Phase 2+
│   ├── ui/                     ← 暂不新建：现有 pages/widgets/theme 即 UI 层，避免搬运
│   ├── pages/ widgets/ theme/ extensions/ providers/ services/ plugins/   （保持原位）
├── native/
│   └── videoder_core/
│       ├── include/videoder_core.h       稳定 C ABI（唯一对外头文件）
│       ├── src/
│       │   ├── api/           C ABI 实现（异常→错误码的唯一入口）+ VDCoreHandle 定义
│       │   ├── core/          句柄/版本/CoreContext
│       │   ├── events/        有界队列 + dispatcher + 事件字段映射
│       │   ├── logging/       日志级别 + 事件 sink + C sink
│       │   ├── process/       ProcessRunner（Phase 5）
│       │   ├── ffmpeg/        Phase 4/5
│       │   ├── media/         Phase 2
│       │   ├── hardware/      Phase 3
│       │   ├── ytdlp/ aria2/  Phase 6
│       │   ├── tasks/         Phase 7
│       │   ├── config/        Phase 6/7
│       │   └── platform/{windows,linux,macos}/   Phase 5 才引入，先仅 common
│       ├── tests/             ctest，独立于 Flutter（自带极简断言框架，无第三方依赖）
│       └── CMakeLists.txt     既可作为独立工程，也可被 windows/linux 工程 add_subdirectory
├── tools/
│   ├── build_core.ps1 | build_core.sh      独立构建 + ctest（不依赖 Flutter）
│   └── validate_pbxproj.py                 校验 macOS 工程文件结构（本机无 Xcode）
├── windows/ linux/ macos/     仅新增"构建 core 并放到 dlopen 可见位置"
└── docs/architecture/native-core-migration.md
```

未新建 `lib/ui/`：现工程 `pages/`、`widgets/`、`theme/` 已经承担 UI 职责，搬目录属于 §26 禁止的"大规模重命名"，收益为零。

## 10. 分阶段迁移计划

| Phase | 内容 | 交付 |
|---|---|---|
| 0 | 本文件 | 分析、ABI 草案、目录规划、验收标准 |
| 1（已完成） | `native/videoder_core` 骨架：CMake、C ABI、句柄、版本、错误、日志、有界事件队列 + dispatcher、`lib/core_bridge/`、三平台构建接线 | Flutter → C ABI → C++ 全链路可验证 |
| 2（已完成） | ffprobe → `MediaInfo`：JSON 解析器、`ProcessRunner`、可执行文件解析、异步 probe + 结果槽、Dart 结构化模型与 `probeFile()` | 媒体信息不再由 Dart 解析 JSON；成品校验已切换 |
| **3（已完成）** | 静态硬件能力：编码器目录/分类、`-encoders`/`-hwaccels` 解析、异步 capability 查询（统一 JobService）、Dart `HardwareCapabilities` 与 `queryHardware()` | `MediaInspector.capabilities` 改由 core 提供 |
| **4a（已完成）** | 基础工具参数构造：容器/编码矩阵、时间解析、各厂商质量参数、`MediaCommand.build` 的四种操作（含 VA-API 初始化） | `MediaCommand.build`/`videoCodecs` 由 core 计算，Dart 保留兼容路径 |
| **4b（已完成）** | 高级向导参数构造：`ExpertCommand.build`（8 预设 + 滤镜图 + GPU 全流程）、`AudioExpertCommand.build`（4 预设）、`ArgumentCodec`（argv 解析/展示引号）、`ExpertConstraints`（兼容矩阵与质量区间） | 高级工作台与命令行编辑器的参数由 core 计算 |
| **5a（已完成）** | FFmpeg 流式执行：`ProcessRunner` 逐行回调、`-progress` 解析、进度/日志事件、成功判定与取消 | `MediaNotifier` 的转码执行改由 core 驱动，Dart 保留 `Process.start` 兼容路径 |
| **5b（已完成）** | GPU **试编码验证**：对每个候选编码器跑一秒钟以内的测试编码（复用 Phase 4 构造器），逐条 `ENCODER_DETECTED` 上报 + 结果表读取 | `MediaInspector.probeGpuEncoders` 的实测部分交给 core，Dart 保留兼容路径 |
| **6（已完成）** | yt-dlp / aria2c 下载参数、进度和进程下沉 | 下载插件保留设置、界面、状态及成品音视频校验 |
| **7（已完成）** | 统一 TaskManager：下载、转码、GPU 验证与短查询共用状态记录、幂等取消和有界日志 | Dart 可读取 core 快照；下载终态取 core 投影 |
| **8（已完成，兼容路径保留）** | 清理 Dart 中已无引用的分类型取消绑定；统一取消走 `vd_task_cancel` | 无引用代码收敛；仍在使用的跨平台回退路径保留 |

> 关于阶段顺序的偏差：Prompt 把"硬件检测"列在"参数构造"之前，但现有 Dart 的 `probeGpuEncoders` 用 `MediaCommand.build` 生成试编码命令。因此 Phase 3 只做**静态**能力检测（`-encoders`/`-hwaccels` 与编码器分类），**动态**可用性验证（试编码）随 Phase 5 一起下沉，避免在 C++ 里提前复制一份参数构造逻辑。

阶段规则（每个 Phase 都必须满足）：`flutter analyze` 0 issue、`flutter test` 全绿、`ctest` 全绿、Windows build 成功。**旧的 Dart 实现保留到对应 C++ 路径通过测试后才切换**，切换顺序为"新增 → 双跑对比 → 切换 → 删除"。

## 11. 每阶段风险

| Phase | 风险 | 缓解 |
|---|---|---|
| 1 | ABI 设计过早固化 | 结构体带 `struct_size`；解析不依赖未实现 API；ABI 版本号可查 |
| 1 | 跨线程回调 Dart 崩溃（use-after-free / 非 Dart 线程） | 只允许 `NativeCallable.listener`；dispatcher 单线程且 destroy 前停线程；Phase 1 就用真实后台线程验证 |
| 1 | 事件队列无界增长（尤其日志） | 有界队列 + 丢弃计数 + 日志上限 |
| 1 | Windows 构建把 `_HAS_EXCEPTIONS=0` 继承给 core | core 为独立 target，显式 `/EHsc` + `_HAS_EXCEPTIONS=1` |
| 1 | dlopen 找不到库（debug/release/test/打包路径不同） | `native_library.dart` 多候选 + `VIDEODER_CORE_LIBRARY` 环境变量覆盖 + 找不到时明确降级 |
| 2 | ffprobe JSON 字段差异（不同版本/容器） | 解析器单测 + 真实 ffprobe 集成测试（`FFMPEG_TEST_PATH`） |
| 3 | 试编码消耗时间/驱动挂死 | 超时 + 逐编码器隔离 + 可取消 + 安全的 CPU 回退 |
| 4 | 参数逐字节兼容（否则用户输出变化） | 与现有 Dart 测试用例一一对应的 C++ 测试，双跑比对 |
| 5 | 进程树清理、取消后残留、stdout 背压 | ProcessRunner 单测 + 真实 ffmpeg 集成测试 + 有界缓冲 |
| 6 | yt-dlp 版本差异、Cookie/代理、错误文案 | 保留现有参数顺序与文案；错误分类表驱动测试 |
| 7 | 任务状态机与 UI 期望不一致 | 先用 Dart 侧影子状态对比，再切换 |
| 全部 | macOS 沙箱（见 §4） | 在 macOS 发行前完成 entitlements/引擎内置决策与实机验证 |

## 12. 每阶段验收标准

**Phase 1（本次）**
1. `native/videoder_core` 可独立 `cmake` 配置 + 构建（Windows/MSVC 与 MinGW、Linux、macOS 同一份 CMake）。
2. `ctest` 全绿：版本、句柄生命周期、错误码、日志 sink、事件队列（FIFO、有界丢弃、dispatcher 回调、销毁安全）。
3. `flutter build windows --debug` 成功，且 `videoder_core.dll` 与 `videoder_demo.exe` 同目录。
4. `test/core_bridge_test.dart`：真实 dlopen → `vd_core_abi_version`/`vd_core_version` → 创建句柄 → 写日志 → **轮询**取到事件 → **listener 从 C++ 后台线程**收到事件 → 销毁。库缺失时明确 skip 并说明。
5. `flutter analyze` 0 issue；`flutter test` 全绿。
6. 页面代码零 `dart:ffi` 引用（`lib/core_bridge/` 之外无 `DynamicLibrary`）。

**Phase 2**：`vd_media_probe` 对同一文件返回与 Dart 版一致的时长/流数量/编码；`MediaInspector.inspect` 走桥接；Dart 侧不再 `jsonDecode` ffprobe 输出。
**Phase 3**：同一 ffmpeg 下，C++ 检测结果与 `MediaInspector.capabilities` 逐项一致；探测可取消；无 GPU 机器安全回退。
**Phase 4**：对现有 Dart 测试覆盖的全部组合，C++ 生成的 argv 与 Dart 逐元素相等。
**Phase 5**：真实 ffmpeg 跑通 4 种操作；进度事件在 10–20 Hz；取消在 2s 内终止进程且无残留子进程。
**Phase 6**：yt-dlp 参数与现网一致；进度/速度/ETA/文件名/播放列表进度解析覆盖现有测试；aria2 模式参数一致。
**Phase 7**：任务状态机覆盖 Created→Queued→Running→Completed/Failed/Cancelled；日志有上限；取消幂等。
**Phase 8**：删除无引用 Dart 后端；`flutter analyze`/`test`/`ctest`/Windows build 仍全绿。

---

## 13. 进度记录

### Phase 1 — 已完成

交付物：

- `native/videoder_core/include/videoder_core.h`：稳定 C ABI（ABI 版本 1、句柄、错误码、日志级别、事件类型与 `VDEvent`、poll/wait、唤醒 listener、字符串与内存所有权、线程规则、日志长度上限）。
- `native/videoder_core/src/`：`api/`（唯一异常边界 + `VDCoreHandle`）、`core/`（CoreContext、版本）、`events/`（有界队列 + dispatcher + 字段映射）、`logging/`（级别 + 事件 sink + C sink）。
- `native/videoder_core/tests/`：`core_api`（8 例）与 `events`（11 例），ctest 驱动，自带极简断言框架，不依赖 Flutter 或第三方库。
- `native/videoder_core/CMakeLists.txt`：现代 CMake，target 级属性；既可作为顶层工程，也可被 Flutter 工程 `add_subdirectory`（embed 时自动关闭测试与 `-Werror`）。
- `lib/core_bridge/`：`native_library.dart`、`native_bindings.dart`、`native_error.dart`、`native_event.dart`、`videoder_core.dart`。
- 平台接线：`windows/CMakeLists.txt`（构建 + 安装 `videoder_core.dll` 到 exe 同目录）、`linux/CMakeLists.txt`（构建 + 安装到 bundle `lib/`）、macOS `Runner.xcodeproj` 新增 “Build Videoder Core” Run Script 阶段（CMake 构建 + 拷入 `Contents/Frameworks` + 条件签名）。
- `tools/build_core.ps1`、`tools/build_core.sh`、`tools/validate_pbxproj.py`。
- `test/core_bridge_test.dart`（9 例，含库定位逻辑与缺失库报错路径）。
- `lib/main.dart`：启动时附加 native core 并打印版本/失败原因（Phase 1 仅诊断，UI 未改动）。

**本机验证结果（Windows 11 + VS 18 + Flutter stable）：**

| 检查项 | 结果 |
|---|---|
| `cmake` + Ninja + MinGW 独立构建 | 通过，`-Wall -Wextra -Wpedantic -Werror` 零警告 |
| `ctest`（19 例） | 全部通过，总耗时 ~1.1s |
| `tools/build_core.ps1` | 通过（配置 → 构建 → ctest 一条命令） |
| `flutter analyze lib test` | 0 issue |
| `flutter test`（含真实 FFmpeg/NVENC 集成） | 58 passed / 1 skipped（跳过的是 golden 截图，需 `CAPTURE_TOOLBOX=1`） |
| `flutter build windows --debug` | 通过，MSVC 编译 core 无警告（`/utf-8` 修复 C4819），`videoder_core.dll` 已安装到 exe 同目录 |
| `flutter build windows --release` | 通过；`dumpbin /exports` 确认 Release DLL 恰好导出 13 个 C ABI 符号，无多余符号（`-fvisibility=hidden` + 显式导出生效） |
| 真实应用启动（`flutter run -d windows`） | 打印 `videoder_core videoder-core 0.1.0 (ABI 1) ready` —— Flutter → C ABI → C++ 全链路在真实进程中成立 |
| 跨线程回调 | Dart 测试用例证明事件经 C++ dispatcher 线程异步投递后在 isolate 内被安全消费 |

**未在本机验证（需对应平台）**：
- Linux：CMake 接线与 `libvideoder_core.so` 安装路径已写好，未在本机编译。
- macOS：Xcode Run Script 阶段已写好，`project.pbxproj` 仅做了结构校验（`tools/validate_pbxproj.py`：括号/引号/注释配平、阶段 ID 引用次数）。**必须在 macOS 上实际构建一次**。已知既有风险见 §4（沙箱 entitlements 缺失）。

**有意未做**（避免越界到后续 Phase）：
- 没有删除或改写任何 Dart 业务代码（`media_command`、`expert_command`、`gpu_acceleration`、`download_provider` 等全部原样保留）。
- 没有在 UI 中消费 core（除启动诊断打印），因此 golden 截图不受影响。
- 没有实现 TaskManager、ProcessRunner、MediaInfo、参数构造（Phase 2–7）。
- 没有引入第三方 C++ 依赖（测试框架自写，避免联网拉取）。

**Phase 1 暴露并已修正的设计问题**（对后续 Phase 有约束意义）：
1. Dart listener 回调是异步的 → payload 不能经 listener 传递（见 §7.2）。后续所有"进度/日志推送"都必须走队列 + 唤醒信号。
2. listener 首次实现持锁等待队列，导致 `set_event_listener` 被饿死数秒 → 改为等待期间释放 callback mutex（`events` 测试用例锁定了这个回归：`dispatcher_notifies_from_its_own_thread_without_consuming`、`removing_the_listener_stops_notifications`）。
3. 队列关闭后 dispatcher 会忙等 → 关闭队列即为停机信号，dispatcher 立即退出，句柄销毁 < 1ms。
4. MSVC + 中文代码页会误读 UTF-8 注释 → 加 `/utf-8`，并保持 native 源码全 ASCII。

### Phase 2 — 已完成

交付物：

- `native/videoder_core/src/util/json.{h,cpp}`：自写严格 JSON 解析/序列化（无第三方依赖），覆盖转义、代理对、非 ASCII 字节透传、深度上限、带字节偏移的错误信息、区域无关的小数点处理。
- `native/videoder_core/src/process/`：`argument_quoting`（Windows CRT argv 规则，纯函数、可跨平台测试）、`process_runner`（捕获 stdout/stderr、超时、协作式取消、捕获上限、退出码）。
- `native/videoder_core/src/platform/{windows,posix}/`：`CreateProcessW` + Job Object（进程树连带终止 + 句柄白名单，避免把宿主管道继承给子进程）与 `posix_spawn` + 进程组（`kill(-pid)`）；Linux 与 macOS 共用 POSIX 实现（避免重复文件）。
- `native/videoder_core/src/ffmpeg/tool_paths.{h,cpp}`：可执行文件解析，与 Dart 版行为一致（目录 → 目录/工具名；否则原样；ffprobe 取 ffmpeg 同级）。
- `native/videoder_core/src/media/`：`media_info`（结构化模型）、`ffprobe_parser`（JSON → MediaInfo，容忍 `"N/A"`、数字/字符串混用、`0/0` 帧率回退、HDR 传输特性）、`probe_job`（调用 + 错误分类）、`probe_result_store`、`probe_service`（单工作线程、可取消）。
- C ABI 新增：`VDStreamInfo`/`VDMediaTag`/`VDMediaInfo`/`VDProbeOptions` 与 `vd_media_probe_{start,read_result,release_result,cancel}`；事件 `VD_EVENT_PROBE_COMPLETED`（高价值事件，不会被队列丢弃）。
- `lib/core_bridge/media_info.dart`（Dart 结构化模型）与 `VideoderCore.probeFile()`（先按容量 0 读计数，再按精确容量读数据，最后释放槽位）。
- 首个消费方切换：`VideoDownload.verify` 走结构化 probe，保留 `inspect` 兼容路径（仅 core 不可用时使用）。
- CI：新增 `native-core` job（cmake + ctest），Flutter job 内构建 core 并通过 `VIDEODER_CORE_LIBRARY` 让桥接测试加载真实库。

**本机验证结果：**

| 检查项 | 结果 |
|---|---|
| `ctest`（5 套件 / 66 例） | 全部通过，约 4.4s |
| `flutter analyze lib test` | 0 issue |
| `flutter test`（含真实 ffmpeg 与真实 ffprobe） | 66 passed / 1 skipped（golden 截图） |
| `flutter build windows` debug + release | 通过，MSVC 零警告 |
| Dart probe 测试 | 结构体布局（88/152/16/96/32 字节）+ 桩 ffprobe 全量字段 + 真实 ffprobe 端到端 |

**Phase 2 暴露并已修正的问题**（都由测试先抓到）：

1. `tag_written` 在容量为 0 的读取里必然是 0，Dart 无法得知元数据条数 → 新增只读总数 `tag_count`（复用原 `reserved0` 位置，结构体尺寸不变，Dart 断言仍为 96 字节）。
2. `take_result` 会消费结果，"先查数量再读数据"这条路走不通 → 改为 `read_result`（可重复、非破坏）+ `release_result`（显式释放），容量上限仍由 core 兜底。
3. `ProbeService` 没有把自己的取消标志交给 `ProbeRequest`，取消**运行中**的 probe 实际无效 → worker 启动进程前回填 `cancel_flag`，并新增端到端断言。
4. 测试脚手架自身的子进程协议写错（多传 `--child`），子进程于是跑起了整个测试套件并递归派生 → 修正为 argv[1] 即模式。这类"测试自身的 bug"会伪装成被测代码的问题，值得记录。
5. JSON 数字解析/格式化依赖 C 区域设置（GTK 在 Linux 上会 `setlocale(LC_ALL, "")`）→ 在小数点上做双向显式转换，避免逗号小数分隔符导致解析失败或输出非法 JSON。

**未在本机验证**：Linux/macOS 的 core 构建（CI 已覆盖 Linux 的 cmake + ctest；macOS 仍只做工程文件结构校验）。

### Phase 6 — 已完成（Windows 验证）

- `src/ytdlp/download_logic.*` 生成完整 yt-dlp argv（视频/音频/封面、格式、Cookie、限速、自定义参数及 aria2c 外部下载器），解析 `--progress-template` JSON、aria2c 文本进度、后处理阶段与 `after_move` 成品路径。参数选项仍从原有设置读取，格式和默认行为保持一致。
- `src/ytdlp/download_task.*` 复用 `ProcessRunner` 和 `TaskService` 的工作线程、进程树取消及有界事件队列。下载进度和日志按 `TASK_PROGRESS`/`TASK_LOG` 上报；结果表记录退出码、成品路径及有界错误摘录。退出码为 0 但未产生视频路径时标记为跳过；Cookie 数据库、解密、HTTP 412、网络、Unsupported URL 由 core 分类，中文帮助文字仍由 Dart 组合。yt-dlp 的重试次数仍由原有 `--retries` 设置控制，未另加应用级重复下载。
- C ABI 升至 **2**，新增 `vd_download_build_args`、`vd_download_parse_progress` 和下载任务的 start/read/release/cancel；请求/结果使用有文档约束的 UTF-8 JSON，数组沿用 `VDStringArray` 两段式读取。`VideoderCore` 接收结构化数据，下载插件在核心可用时走原生任务，核心不可用时保留原 Dart 路径。最终文件仍用既有 ffprobe 校验视频和音轨。
- 本机验证：`ctest` 11 套件全绿（新增下载参数、进度、子进程成功/跳过/失败/取消及 ABI 回归）；`flutter analyze lib test` 0 issue；`flutter test` 含真实 FFmpeg 为 100 passed / 1 skipped；`flutter build windows --release` 成功。下载相关 Dart 测试还将原生 argv 与旧构造器逐项比较。

macOS 的 Release 沙箱目前仍缺少网络及用户选中文件权限，原有 Dart 下载路径也有同样限制。本机没有 macOS 工具链，不能声称 macOS 发行包已验证；在 macOS 上发行前需要完成签名/entitlements 与外部引擎路径的实机验证。

### Phase 7 / 8 — 已完成（Windows 验证）

- `TaskManager` 为五种任务保存统一状态、时间戳、退出码、进度、错误及最近 100 行日志；已完成记录最多保留 256 条。状态在事件入队前更新，因此事件背压不会丢失任务状态。
- `vd_task_snapshot` 提供 JSON 快照，`vd_task_cancel` 按任务类型路由取消。已知终态任务的重复取消返回成功，未知 ID 返回未找到标志。C ABI 提升到 3。
- 短查询继续使用独立工作线程，以免长时间转码阻塞探测；它们与长任务共享状态记录。原有完成事件保持不变。
- Dart 桥接新增 `CoreTaskSnapshot`；下载完成状态优先采用 core 快照。转码取消改用统一入口。移除了无引用的下载与转码专属取消绑定。
- macOS 发行包与沙箱仍需实机验证；当前仍被引用的 Dart 兼容执行路径继续保留，不能当作死代码删除。

### Phase 5b — 已完成

交付物：

- `src/hardware/gpu_probe.{h,cpp}`：试编码命令构造（复用 `BuildMediaCommand`，输入为 `color=size=256x256:rate=30` 的 lavfi 源，输出 `-frames:v 3 -an -f null -`，VP9 用 WebM、其余用 MKV）、判定规则（退出码 0 **且** stdout 出现 `frame>=1`）、首个诊断行提取（error/failed/cannot/not support/no capable/not available/not found，大小写不敏感），以及逐编码器的执行循环（可取消、每个编码器独立超时，默认 15 秒）。
- `TaskService` 泛化为多任务种类：`TaskRequest{kind, media, gpu}` + 两个结果表；GPU 任务逐条发 `ENCODER_DETECTED`（`message`=编码器名、`exit_code`=试编码退出码、`detail_json`={usable, reason, timed_out, start_failed}），终态与媒体任务共用 `TASK_COMPLETED/CANCELLED`。
- ABI：`vd_gpu_probe_start/read_result/release_result/cancel` 与 `VDGpuProbeOptions`(32)/`VDGpuProbeEntry`(32)/`VDGpuProbeResult`(32)；结果表按"先读计数、再分配、再读"的两段式读取，与其它结果表一致。
- Dart：`GpuProbeVerdict`（含从事件构造）、`VideoderCore.probeGpuEncoders()`（进度回调 + `isCancelled` 轮询 + 结果）、`MediaInspector.probeGpuEncoders` 优先走 core 并把判定翻译成原有文案（超时 → `工具执行超时，请检查路径或网络连接`，诊断行截断 240 字符加省略号，否则 `试编码未输出有效帧（退出码 N）`）；注入 `runner` 时仍走 Dart 路径，因此既有探测测试完全不受影响。

**本机验证结果：**

| 检查项 | 结果 |
|---|---|
| `ctest`（10 套件 / 107 例） | 全部通过（新增 `gpu_probe` 7 例：试编码参数、判定规则、可用/被拒/无帧/超时/启动失败/取消、ABI 全流程） |
| `flutter analyze lib test` | 0 issue |
| `flutter test`（含真实 ffmpeg） | 96 passed / 1 skipped（新增 `gpu_probe_test` 5 例：布局、事件解析、真实试编码、服务层过滤、取消保留已有判定） |
| `flutter build windows` debug + release | 通过，MSVC 零警告；Release DLL 导出 42 个符号 |
| 实机启动 | `videoder_core videoder-core 0.1.0 (ABI 1) ready` |

**Phase 5b 发现与注意点：**

1. **`std::vector::insert` 会让迭代器失效**：我按 Dart 的写法先取 `-i` 的迭代器再连续插入两次、输出位置取 `end()-1` 再连续插入五次——第二次插入时就写到了悬垂迭代器上，Windows 直接报 `STATUS_HEAP_CORRUPTION (0xC0000374)`。改为先算下标、再用单个区间 `insert`。**凡是"取迭代器 + 多次插入"的移植都要改成下标。**
2. 测试崩溃时看不到任何输出：C 运行时的 stdout 缓冲会随进程一起丢失。已让测试框架在每个用例后 `fflush`，崩溃时至少能看到崩溃前通过了哪些用例（这次正是靠它把范围缩到第一个用例）。
3. 判定要用**逐行流式**结果而不是捕获后的整段 stdout：`frame>=1` 在读取时就判定，`discard_capture` 因此可以打开，长任务不会为了"事后正则"留住几 MB 文本。
4. 未知的编码器名不会被试编码——`GpuAcceleration.detectedEncoders` 的过滤仍在 Dart 服务层（core 会忠实地测试你给它的任何名字），这样"UI 提供哪些候选"与"候选到底能不能用"两件事保持分离。

### Phase 5a — 已完成

交付物：

- `src/process/line_buffer.{h,cpp}`：跨平台的行切分（跨读取块重组、CRLF、末尾无换行的最后一行），与 Windows/POSIX 的实现共用。
- `ProcessRunner`：新增逐行回调 `on_line` 与 `discard_capture`（长任务不必把几 MB 输出留在内存里）；两个平台实现都改为流式读取。
- `src/ffmpeg/media_progress.{h,cpp}`：`-progress pipe:1` 的字段解析与行分类（沿用 Dart 的字段集合与 `^\d+(\.\d+)?x$` 速度形状规则、"每块一次"的发布时机）。
- `src/tasks/media_task.{h,cpp}`：一次执行的生命周期与**成功判定**（未取消、非超时、ffmpeg 未拒绝覆盖、退出码 0，且当调用方指定了输出文件时必须真的产出媒体且文件非空），拒绝覆盖的两条 stderr 文案识别。
- `src/tasks/task_service.{h,cpp}`：长任务调度器（单调度线程拥有全部工作线程，负责启动、回收、取消与关停；上限 2 并发），把进度/日志/终态变成事件，结果进 `ResultStore`。
- `src/api/task_api.cpp` + ABI：`vd_media_task_start/read_result/release_result/cancel` 与 `VDMediaTaskOptions/VDMediaTaskResult`。
- Dart：`MediaTaskOutcome`/`MediaTaskProgress`/`MediaTaskStatus`、`VideoderCore.runMediaTask()`（进度/日志回调 + 结果）、`cancelMediaTask()`；`MediaNotifier` 改由 core 执行，状态文案与日志行为逐字保持，Dart `Process.start` 路径保留为兼容路径。

**本机验证结果：**

| 检查项 | 结果 |
|---|---|
| `ctest`（9 套件 / 100 例） | 全部通过（新增 `media_task` 6 例：行切分、进度分类、取消/超时、ABI 全流程） |
| `flutter analyze lib test` | 0 issue |
| `flutter test`（含真实 ffmpeg） | 91 passed / 1 skipped（新增 `media_task_test` 6 例：真实转码 + 进度、失败、启动失败、取消） |
| `flutter build windows` debug + release | 通过，MSVC 零警告；Release DLL 导出 38 个符号 |
| **双跑对比** | `media_integration_test` 原本用 Dart `Process.start` 跑真实 ffmpeg，现在同一断言直接验证 core 驱动的执行路径（状态 `处理完成`、输出文件存在、输入未被改动），全部通过 |

**Phase 5a 发现与注意点：**

1. **事件只能有一个消费者**：push 模式下 core 的监听线程会把队列排空并推给 `events` 流；如果 `runMediaTask` 同时用 `drainEvents()` 等终态事件，两者会互相抢，终态事件可能被对方取走导致**永久等待**（我第一版就是这样，集成测试直接挂到超时）。改为：**完成与否只读结果表**（core 在发终态事件之前先落结果），进度/日志按模式从各自的通道取；这样无论谁消费了事件都不会丢终态。
2. **线程对象的归属必须唯一**：长任务最初让工作线程在结束时把自己从 `running_` 里摘除——那会析构一个仍 joinable 的 `std::thread`，直接 `std::terminate()`。改成单调度线程统一启动/回收/join。
3. **不要用 PowerShell 的嵌套数组做批量替换**：`foreach ($pair in @(@('A','B')))` 会被展开成两个字符串，`$pair[0]`/`$pair[1]` 于是变成字符 `'A'`/`'B'`——我把 `V`→`D` 替换进了两个文件。两个文件都是我自己刚写的，已按原意重写。**教训：批量改名用编辑工具或单条 `-replace`，别用嵌套数组。**
4. 速度字段要按 Dart 的正则形状判定（`1.5x` 合法、`N/A` 与 `1.5e2x` 非法），并且要先 trim：ffmpeg 实际输出是 `speed= 1.5x`（带空格）。
5. 进度事件里不放 UI 文案：core 只给 `fraction` 与结构化 `detail_json`（`out_time`/`speed`/`fps`/`frame`），"已处理 … · 速度 … · … fps" 仍由 Dart 拼接。

### Phase 4b — 已完成

交付物：

- `src/ffmpeg/expert_constraints.{h,cpp}`：容器表、容器→视频族/音频编码器矩阵、编码器族名（`libx265`→`hevc`）、质量区间（硬件 1–51、x264/x265 0–51、其余 0–63）、输出扩展名解析（含 `dir.d/file`、`.bashrc`、`clip.` 等边界）。
- `src/ffmpeg/argument_codec.{h,cpp}`：argv 文法（反斜杠在 Windows 路径中原样保留；引号内"反斜杠串后接引号才折半"的规则与 Dart 逐字一致）、展示用引号（仅对含空白/引号/反斜杠的参数加引号）。
- `src/ffmpeg/expert_command.{h,cpp}`：8 种预设（转码/换封装/缩放/旋转/变速/字幕/合并/GIF）、GPU 全流程（`scale_cuda` 改写、拒绝 hwdownload 路径）、合并与字幕的滤镜图、22 个拒绝原因、`executionArguments` 保留选项检查。
- `src/ffmpeg/audio_expert_command.{h,cpp}`：4 种音频预设（转换/剪切/合并/统一响度）、采样率×声道×码率校验、MP3 48 kHz 上限、12 个拒绝原因。
- `src/util/parse_number.{h,cpp}`：Dart 形状的 `int.tryParse`/`double.tryParse`（允许首尾空白、拒绝小数与溢出），供参数构造与时间解析共用。
- `src/api/ffmpeg_api.cpp` + `src/api/api_support.{h,cpp}`：11 个新 ABI 入口（3 个构造器 + 6 个约束查询 + 解析/格式化），线程局部错误消息抽到独立单元，使 `videoder_core_api.cpp` 与 `ffmpeg_api.cpp` 共用一套 `vd_core_last_error_message`。
- Dart：`VideoderCore` 新增对应方法；`ExpertConstraints` 的表格改为**优先取自 core 并做记忆化**（UI 每次 build 都会读，缓存后不再产生 FFI 分配）；`ExpertCommand`/`AudioExpertCommand`/`ArgumentCodec` 改为优先走 core 并把原因码翻译成原有中文提示，Dart 实现保留为兼容路径。

**本机验证结果：**

| 检查项 | 结果 |
|---|---|
| `ctest`（8 套件 / 88 例） | 全部通过（新增 `expert_args` 12 例 + ABI 空串回归 2 例） |
| `flutter analyze lib test` | 0 issue |
| `flutter test`（含真实 ffmpeg） | 85 passed / 1 skipped |
| `flutter build windows` debug + release | 通过，MSVC 零警告；Release DLL 导出 34 个符号 |
| **双跑对比** | 写于 Dart 实现时期的 `expert_command_test`、`audio_expert_test`、`gpu_acceleration_test` 现在直接验证 C++ 实现，全部通过 |

**Phase 4b 发现与注意点：**

1. **空字符串参数是"位置"语义，不能映射成 NULL**：core 的 `KeepString` 一直把空串转成 `nullptr`（对"缺失字段"是合理的），但字符串数组是按位置读取的，命令行里合法的空参数 `""` 会被宿主丢掉并把后面所有下标前移。既有 Dart 测试的 `ArgumentCodec` 往返用例正好抓住了这个 bug——现在数组写入用 `KeepArrayString`（空串保持为空串），并补了 ABI 级回归用例。**这正是双跑对比的价值：C++ 单测在 `std::vector` 层面是通过的，问题只出在 ABI 封送层。**
2. **命名遮蔽（第二次遇到）**：新函数 `EncoderFamily()` 与 `hardware/encoder_catalog.h` 里的 `EncoderFamily` 枚举同名，直接编译失败；改名 `EncoderFamilyName()`。上一次是 `CoreContext::VideoCodecsForFormat` 遮蔽自由函数。**结论：下沉时新增的全局函数名要先和既有头文件对一遍。**
3. **反斜杠折半规则只在引号内且"后接引号"时生效**：`"c:\\\\dir"`（引号内两个反斜杠后跟 `d`）保持两个反斜杠，只有 `"c:\\\\"`（后接引号）才折半成一个。我最初的测试期望反了，是既有 Dart 用例纠正了它。
4. 约束表格在 Dart 侧做了记忆化：`expert_page` 的 `_encoders`/`_audioEncoders` getter 每次 build 都会读，如果每次都走 FFI 会产生可观的每帧分配。
5. `api_support.{h,cpp}` 把线程局部错误消息变成可共享单元，否则第二个 API 翻译单元要么重复实现，要么得反向依赖第一个（我最初的写法引入了一个不存在的 `SetThreadLocalError` 钩子，属于错误设计）。

### Phase 4a — 已完成

交付物：

- `src/ffmpeg/media_formats.{h,cpp}`：容器表（7 视频 / 4 音频）与容器→视频编码器矩阵（`auto` 取首项）。
- `src/ffmpeg/time_utils.{h,cpp}`：`ParseTime`（"90.5" / "01:30" / "00:01:30"），区分"格式错误"与"取值错误"两类失败，与 Dart 规则逐条一致（含允许首尾空白、拒绝负值、分/秒必须为整数且 < 60）。
- `src/ffmpeg/gpu_quality_args.{h,cpp}`：各厂商质量参数（NVENC `-rc vbr -cq`、AMF `-rc cqp`、QSV `-global_quality`、VideoToolbox 反向量程、AMF/VA-API 的 AV1 0–255 量化器）。
- `src/ffmpeg/media_command.{h,cpp}`：四种操作（转换/提取音频/压缩/剪切）的完整参数构造，含 VA-API 设备初始化与帧上传、容器相关音频编码、`hvc1` 标签与 `+faststart`。
- `src/util/number_format.{h,cpp}`：Dart 形状的浮点格式化（`0.0`/`5.0`），复用 JSON 写入器的最短往返数字。
- C ABI：`VDMediaCommandStatus`（拒绝原因）、`VDMediaOperation`、`VDMediaCommandOptions` 与 `vd_ffmpeg_build_media_args`、`vd_ffmpeg_video_codecs_for_format`。
- Dart：`VideoderCore.buildMediaArguments()`/`videoCodecsForFormat()`、`NativeCommandRejected`（携带原因码，不含文案）、`MediaCommand.build`/`videoCodecs` 改为优先走 core，把原因码翻译成**原有中文提示**，并保留 Dart 兼容路径。

**本机验证结果：**

| 检查项 | 结果 |
|---|---|
| `ctest`（7 套件 / 74 例） | 全部通过，约 5.4s（新增 `ffmpeg_args` 11 例） |
| `flutter analyze lib test` | 0 issue |
| `flutter test`（含真实 ffmpeg） | 79 passed / 1 skipped |
| `flutter build windows` debug + release | 通过，MSVC 零警告；Release DLL 导出 23 个符号 |
| **双跑对比** | 现有 Dart 断言（写于 Dart 实现时期）现在直接验证 C++ 实现：`media_integration_test` 用 core 生成的 argv 跑**真实 ffmpeg** 完成转换/提取/压缩/剪切，`gpu_acceleration_test` 校验 VA-API 设备初始化与逐厂商质量参数，全部通过 |

**Phase 4a 发现与注意点：**

1. **数字格式必须与 Dart 一致**：Dart 的 `double.toString()` 对整数值输出 `0.0`/`5.0`，而 `-ss`/`-t` 的值参与 UI 展示与快照断言，因此 core 用了 Dart 形状的格式化器（最短往返 + 必要时补 `.0`），而不是 `std::to_string`。
2. **枚举类状态值让 C++ 断言可读**：`MediaCommandStatus` 是强类型枚举，`VD_CHECK_EQ` 需要 `operator<<`；在测试里按 ADL 补了一个，失败信息直接显示 `codec-not-in-container` 这样的名字。
3. **命名遮蔽**：`CoreContext::VideoCodecsForFormat` 会遮蔽同名的自由函数，调用它等于无限递归；成员改名为 `WriteVideoCodecsForFormat`。
4. 我最初的两条测试期望写错了（`mov` + `auto` 应选 `h264` 而非 `hevc`；VA-API 滤镜后缀长度算错），**builder 是对的**——再次说明既有 Dart 断言才是权威基线。

### Phase 3 — 已完成（要点回顾）

交付物：

- `src/hardware/encoder_catalog.{h,cpp}`：硬件编码器目录（4 个族、16 个编码器）、族判定、厂商标签、目录顺序优选（`DetectedHardwareEncoders`/`BestEncoderForFamily`/`DetectHardwareAcceleration`），与 `lib/services/gpu_acceleration.dart` 的顺序逐项一致。
- `src/hardware/hardware_query.{h,cpp}`：运行 `ffmpeg -hide_banner -encoders` 与 `-hwaccels`，按原有规则解析（6 字符标志列、图例行 `=` 过滤、`-hwaccels` 表头过滤），产出 `HardwareCapabilities`；错误按 启动失败 / 超时 / 取消 / 非零退出 分类。
- `src/tasks/result_store.h`：把 Phase 2 的 `ProbeResultStore` 泛化为 `ResultStore<Result>` 模板（read/release/上限 64），probe 与 hardware 共用一份实现。
- `src/tasks/job_service.{h,cpp}`：把 Phase 2 的 `ProbeService` 泛化为统一的单工作线程 `JobService`（`JobKind::{kProbe,kHardwareQuery}`），取消语义、结果入槽、完成事件共用一套代码；Phase 7 的 TaskManager 将在此之上扩展。
- C ABI：`VDStringArray`、`VDHardwareCapabilities`、`VDHardwareQueryOptions` 与 `vd_hardware_query_{start,read_result,release_result,cancel}`；完成事件 `VD_EVENT_ENCODER_DETECTED`。
- Dart：`lib/core_bridge/hardware_capabilities.dart`、`VideoderCore.queryHardware()`/`cancelHardwareQuery()`、`MediaInspector.hardwareCapabilities()`，`capabilities()` 改为优先走 core（保留原中文错误前缀）并保留 Dart 兼容路径。

**本机验证结果：**

| 检查项 | 结果 |
|---|---|
| `ctest`（6 套件 / 63 例） | 全部通过，约 6.1s |
| `flutter analyze lib test` | 0 issue |
| `flutter test`（含真实 ffmpeg） | 73 passed / 1 skipped（golden 截图） |
| `flutter build windows` debug + release | 通过，MSVC 零警告 |
| Release DLL 导出 | 恰好 21 个 C ABI 符号 |
| 真实硬件交叉验证 | C++ 目录与 Dart 目录在同一份 `-encoders` 输出上选出**完全相同**的编码器列表（本机 NVENC/QSV/VA-API） |

**Phase 3 暴露并已修正的问题**：

1. `VDHardwareCapabilities` 最初把 4 个 `VDStringArray` 内联在结构体里，Dart 侧需要"嵌套结构体按值写入"才生效；改为**调用方分配的指针数组**（与 `VDMediaInfo.streams/tags` 一致），既统一了风格又消除了 FFI 嵌套写语义的不确定性。
2. Dart 轮询循环把"参数错误"当成"仍在运行"：`read_result` 在参数校验失败时返回 `VD_ERROR_INVALID_ARGUMENT` 且不写 `has_result`，Dart 于是每 20ms 重试到超时。现在只有"`VD_OK` 且 `has_result=0`"才算 pending，其余立即失败（`probeFile` 与 `queryHardware` 都修了）。
3. 一次 ABI 变更后未重建 core —— 我自己的构建流程问题。**结构性收获**：`struct_size` 校验把这次不匹配变成了一条明确的 `INVALID_ARGUMENT`（"struct_size is too small for this ABI"），而不是内存越界。这正是该字段存在的意义，已在验证流程中固定为"改 ABI → 先重建 core → 再跑 Dart 测试"。

**未在本机验证**：Linux/macOS 的 core 构建（CI 覆盖 Linux 的 cmake + ctest）。

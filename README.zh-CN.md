# ShengJi（LocalScribe，中文名“声迹”）

[English](README.md) | **简体中文**

[![macOS 15.5+](https://img.shields.io/badge/macOS-15.5%2B-000000?logo=apple)](https://support.apple.com/macos)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-arm64-555555)](https://support.apple.com/guide/mac-help/about-this-mac-mchl3a2c2cb0/mac)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/maddylaneeee/ShengJi/actions/workflows/ci.yml/badge.svg)](https://github.com/maddylaneeee/ShengJi/actions/workflows/ci.yml)
[![下载 macOS 版](https://img.shields.io/badge/下载-macOS%20DMG-0A84FF?logo=github)](https://github.com/maddylaneeee/ShengJi/releases/latest/download/ShengJi-macOS-arm64.dmg)

**把麦克风、音视频文件和 Mac 正在播放的声音，在本机转成可编辑文字与字幕。**

ShengJi 是一款面向 Apple silicon Mac 的免费、开源原生语音转文字与音视频转录应用，无需注册账号。它把本地识别、悬浮实时字幕、字幕编辑与导出、离线翻译、长任务恢复，以及 Gemma 4 文稿优化整合在一个 SwiftUI 界面中。识别音频、导入稿件和 AI 处理内容不会由应用上传。

当前版本：**1.6.4（34）** · [下载 DMG](https://github.com/maddylaneeee/ShengJi/releases/latest/download/ShengJi-macOS-arm64.dmg) · [非开发者下载指南](Documentation/DOWNLOAD.zh-CN.md) · [使用文档](https://lixinchen.ca/docs/localscribe/)

> [!TIP]
> **1.6.4 新增本机 Gemma 4 文稿优化：** 转录完成后可直接纠错、润色或总结，支持自定义提示词、实时结果预览与一键撤销；稿件全程留在 Mac 上。[查看 Gemma 4 功能与真实界面](#用-gemma-4-把转录稿变成可交付文稿164-新增)

## 实际演示

![声迹打开音频文件、选择本地转录设置并生成可编辑文字](Documentation/MediaKit/shengji-demo.gif)

打开 App → 选择音频 → 设置语言与模型 → 得到可编辑的本地转录文字。演示仅使用非私人测试内容。

> [!IMPORTANT]
> **Apple SpeechAnalyzer 本地识别和悬浮实时字幕需要 macOS 26。** App 本身支持 macOS 15.5+；在 macOS 15.5–25 上，请在首页手动选择 Whisper、SenseVoice 或 Parakeet。SenseVoice 和 Parakeet 当前仅支持文件转录。

## 界面预览

![声迹中文首页，包含识别模型、稿件导入、转录后翻译和悬浮实时字幕](Documentation/Screenshots/home-zh-CN.png)

![声迹中文稿件编辑器，包含本地翻译、查找替换、范围编辑、导出与隐私说明](Documentation/Screenshots/transcript-editor-zh-CN.png)

上方首页与稿件编辑器截图来自真实的 1.4.0 macOS App，使用隔离配置和非私人示例稿件制作。

## 用 Gemma 4 把转录稿变成可交付文稿（1.6.4 新增）

**转录不是终点。** 完成转录或导入稿件后，打开右侧检查器的“AI 优化”，即可让 Gemma 4 在 Mac 本机继续整理文字。无需复制到其他 AI 服务，也无需上传稿件。以下画面截取自真实的 1.6.4 App 录屏，使用非私人示例稿件制作。

### 纠错与润色：边生成，边对照

![声迹使用本机 Gemma 4 对转录稿进行纠错与润色，红色显示原文，绿色实时显示优化结果](Documentation/Screenshots/gemma-proofread-zh-CN.png)

原文与建议修改以红绿对照实时显示，处理进度、所用模型和本机隐私状态始终可见。Gemma 会清理口头填充词、重复和明显错误，同时尽量保留原意；未通过校验的片段不会覆盖原文。

### 总结：把长篇转录收束为重点

**总结前：完整的 12 段、501 字转录稿**

![使用 Gemma 4 总结前的声迹界面，显示完整中文转录稿、总结任务、所选模型和中文总结提示词](Documentation/Screenshots/gemma-summary-before-zh-CN.png)

**总结后：重点明确的单段发布计划**

![声迹使用本机 Gemma 4 将同一篇长转录总结为简洁发布计划](Documentation/Screenshots/gemma-summary-after-zh-CN.png)

上方两张图来自同一次总结操作。结果会直接替换文字预览，并保留可撤销的原稿快照。你可以临时指定正确人名、专业术语、表达风格、总结长度、关注重点或输出格式，也可以在设置中保存常用指令。AI 输出仍应由用户复核。

默认的 Gemma 4 E2B IT Q4 模型约 2.8 GB；可在设置中开启约 4.6 GB 的 E4B 选项。模型按需下载并校验，随后通过 llama.cpp 和 Metal 在 Mac 上运行。为避免内存压力，物理内存为 6 GB 或更低的设备会停用该功能；加载 Gemma 前，声迹会释放当前持有的识别和 NLLB 翻译运行环境，任务结束后退出 Gemma helper。

## 适合做什么

- **给 Mac 声音加实时字幕：** 捕获 Mac 正在播放的声音，以悬浮窗显示本地字幕。
- **转录会议与素材：** 导入音频或视频，使用 Apple Speech、Whisper、SenseVoice 或 NVIDIA Parakeet。
- **整理可交付稿件：** 搜索、替换、删除、范围裁剪，并导出 TXT、Markdown、JSON、PDF、SRT 或 WebVTT。
- **用本地 AI 优化文稿：** 通过 Gemma 4 对转录结果纠错、润色或总结，并用提示词指定术语、风格、重点和格式。
- **继续已有内容：** 导入 SRT、WebVTT、TXT、Markdown 或声迹 JSON，也可在原稿后继续麦克风转录。
- **在本机翻译：** 转录后默认使用 Apple Translation，也可下载 NLLB INT8 模型。
- **处理长录音：** 逐步显示结果，保存追加式恢复记录，并支持暂停、恢复和重新开始。

## 下载与安装

1. [下载最新版 DMG](https://github.com/maddylaneeee/ShengJi/releases/latest/download/ShengJi-macOS-arm64.dmg)。
2. 打开 DMG，把“声迹”拖到“应用程序”。
3. 第一次尝试打开时，macOS 会阻止启动。进入“系统设置 → 隐私与安全性”，找到声迹提示并点击“仍要打开”，然后确认“打开”。

完整图文步骤、常见问题和 SHA-256 校验方法见：[下载与安装指南](Documentation/DOWNLOAD.zh-CN.md)。

> [!WARNING]
> 当前公开包只有 ad-hoc 完整性签名，没有 Apple Developer ID 签名，也未经过 Apple 公证。只有在你信任本仓库及对应 Release 时才应绕过系统警告。每个 Release 同时提供 SHA-256 校验文件。

## 系统要求与功能边界

| 项目 | 要求或状态 |
| --- | --- |
| 处理器 | Apple silicon（arm64）；暂不支持 Intel Mac |
| App 最低系统 | macOS 15.5 |
| Apple Speech 文件/麦克风识别 | macOS 26+ |
| 悬浮实时字幕 | macOS 26+，固定使用 Apple 本地识别 |
| macOS 15.5–25 | 手动选择 Whisper、SenseVoice 或 Parakeet |
| SenseVoice / Parakeet | 当前仅支持文件转录 |
| 实时字幕翻译 | 当前关闭；转录完成后的翻译仍可使用 |
| Gemma 4 AI 优化 | 需要超过 6 GB 内存；模型按需下载并在本机运行 |
| 麦克风 | 需要麦克风权限 |
| Mac 声音 | 需要“屏幕与系统音频录制”权限 |

Apple Speech 和 Apple Translation 首次使用某些语言时，可能由 macOS 下载对应语言资源。第三方模型只在用户主动选择后下载和启用。

声迹默认跟随 macOS 的语言和外观，也可在设置中即时切换 English / 简体中文，以及系统 / 浅色 / 深色外观；顶部菜单和实时字幕声音来源会同步热切换。识别语言菜单在顶部提供去重后的“推荐语言”，优先列出英语和设备语言；设备语言为英语时只列一次。权限页会显示麦克风、语音识别与系统音频录制状态，并只在你主动点击时请求权限。

## 识别与翻译引擎

| 引擎 | 用途 | 运行方式 |
| --- | --- | --- |
| Apple Speech | 麦克风、文件、实时字幕 | SpeechAnalyzer / SpeechTranscriber |
| Whisper | 麦克风、文件 | whisper.cpp GGML，Metal → CPU |
| SenseVoice | 文件 | sherpa-onnx，Core ML 可用路径 → CPU |
| NVIDIA Parakeet | 文件 | sherpa-onnx，Core ML 可用路径 → CPU |
| Apple Translation | 默认转录后翻译 | macOS Translation Framework |
| NLLB | 可选转录后翻译 | CTranslate2 CPU/int8 |
| Gemma 4 | 文稿纠错、润色与总结 | llama.cpp，Metal 本机推理 |

Whisper 文件转录使用模型内部滑动窗口；较长素材会在适合时启用内置 Silero VAD v6.2.0。过滤逻辑综合静音、置信度、机械重复和已知幻觉模板，同时尽量保留真实说出的结尾语句。

### 高级转写设置

使用受支持的第三方引擎时，右侧检查器会显示默认收起的“高级”区域。Whisper 可设置模型提示词、Temperature 与回退、Beam 或贪心搜索、上下文长度、静音与置信度过滤、VAD，以及带防误用设计的自动推理线程。SenseVoice 和 Parakeet 只显示其本地运行时真实支持的选项；文件专属和麦克风专属设置只会出现在对应任务中。

带数值的选项既可使用键盘直接输入，也可通过滑块或步进器调节，并带范围校验和简短的鼠标悬停说明。应用会记住上次使用的引擎、模型和高级配置；“恢复模型默认参数”只重置当前所选引擎。

## 隐私与联网行为

声迹不会上传识别音频、导入稿件或 Gemma 处理内容。识别、翻译与 AI 文稿优化均在 Mac 本机执行。网络仅用于按需下载识别、翻译与 Gemma 模型，自动或手动检查和下载更新，以及打开外部文档；自动更新可在设置中关闭。默认会在启动时和每隔六小时检查并下载新版，完成校验后仍会在安装和重新打开前征求确认。所有可选模型都会在使用前明确显示下载状态。

## 从源码构建

需要 Xcode 及 Command Line Tools。仓库已包含 App 所需的本机运行时；大型识别模型、NLLB 和 Gemma 4 模型按需下载，不提交到 Git。

```sh
ruby generate_project.rb

xcodebuild \
  -project LocalScribe.xcodeproj \
  -scheme LocalScribe \
  -destination 'platform=macOS,arch=arm64' \
  build
```

运行测试：

```sh
xcodebuild \
  -project LocalScribe.xcodeproj \
  -scheme LocalScribe \
  -destination 'platform=macOS,arch=arm64' \
  test
```

CI 使用 GitHub 的 macOS 26 Apple silicon runner 执行测试和 Release 静态分析。`./tools/package_local_release.sh` 会创建 ZIP 与 DMG，并检查签名层级、架构、最低系统版本、嵌套 Mach-O、解压启动和 DMG 挂载。

## CLI

```sh
声迹.app/Contents/MacOS/LocalScribe --cli help
声迹.app/Contents/MacOS/LocalScribe --cli models --json
声迹.app/Contents/MacOS/LocalScribe --cli transcribe input.mp4 \
  --engine whisper --language zh_CN --format srt --output output.srt
```

## 文档与反馈

- [非开发者下载与安装指南](Documentation/DOWNLOAD.zh-CN.md)
- [使用说明](https://lixinchen.ca/docs/localscribe/)
- [验收与回归记录](https://lixinchen.ca/docs/localscribe/acceptance.html)
- [SherpaOnnx 构建说明](https://lixinchen.ca/docs/localscribe/sherpa-onnx.html)
- [路线图](ROADMAP.md)
- [参与贡献](CONTRIBUTING.md)
- [提交问题](https://github.com/maddylaneeee/ShengJi/issues)
- [媒体与推荐资料包](Documentation/MediaKit/README.zh-CN.md)

## 许可证

项目源码使用 [MIT License](LICENSE)。第三方组件和模型保留各自许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 `Vendor` 中的许可证文件。可选 NLLB 模型由上游以 CC-BY-NC-4.0 提供。

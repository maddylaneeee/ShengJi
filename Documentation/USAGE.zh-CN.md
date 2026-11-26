# 声迹使用指南

[English](USAGE.md) | **简体中文** · [项目简介](../README.zh-CN.md)

安装和首次启动权限请先看[安装指南](../INSTALL.zh-CN.md)。

## 转录与编辑

选择麦克风、音视频文件或 Mac 声音作为输入。在 macOS 26 或更高版本上，语言支持时可先尝试 Apple Speech；较早系统请先选择并下载第三方模型。SenseVoice 与 Parakeet 仅支持文件；Whisper 支持麦克风和文件转录。悬浮实时字幕需要 macOS 26 或更高版本，可使用麦克风、Mac 声音或两者混合。

结果会逐步显示，转录可暂停和继续；会话日志与恢复快照帮助恢复中断任务。编辑器支持搜索、替换、删除选区和范围裁剪。可导入 SRT、WebVTT、TXT、Markdown 或声迹 JSON 继续编辑，也可在导入稿件后追加麦克风转录。

转录后可用默认的 Apple Translation、Apple 智能或可选 NLLB 翻译。实时字幕翻译当前关闭。纠错、总结、模型选择和回退行为见 [AI 文稿优化与服务](AI-SERVICES.zh-CN.md)。

可导出 TXT、Markdown、JSON、PDF、SRT、WebVTT，或复制到剪贴板。中日韩长字幕会自动换行并拆分。

## 识别与翻译引擎

系统版本与语言支持 Apple Speech 时可先尝试。识别效果取决于语言、录音质量与任务，可用有代表性的音频比较后选择。

| 引擎 | 用途 | 运行方式 |
| --- | --- | --- |
| Apple Speech | 麦克风、文件、实时字幕（macOS 26） | SpeechAnalyzer / SpeechTranscriber |
| Whisper | 麦克风、文件 | whisper.cpp GGML，Metal → CPU |
| SenseVoice | 文件 | sherpa-onnx，Core ML 可用路径 → CPU |
| NVIDIA Parakeet | 文件 | sherpa-onnx，Core ML 可用路径 → CPU |
| Apple Translation | 默认转录后翻译 | macOS Translation Framework |
| NLLB | 可选转录后翻译 | CTranslate2 CPU/int8 |
| Gemma 4 | 纠错、润色、总结 | llama.cpp，Metal 本机推理 |
| Apple 智能 | 翻译、纠错、润色、总结 | Apple Foundation Models 框架，本机推理（macOS 26+） |

Whisper 对较长素材使用内置 Silero VAD 跳过静音，并过滤静音、低置信度、机械重复和已知幻觉输出。

**高级设置：** 使用第三方引擎时，右侧检查器中默认收起的“高级”区域只显示该运行时真实支持的选项。Whisper 可调模型提示词、Temperature 与回退、Beam 或贪心搜索、上下文长度、静音与置信度过滤、VAD 和线程数。应用会记住上次的引擎、模型和设置；“恢复模型默认参数”只重置当前引擎。

## 字幕烧录到视频

在首页点击“烧录字幕”，或选择“文件 → 烧录字幕…”（⇧⌘B）。选择或拖入视频（MP4、MOV、M4V 等 macOS 可播放的格式）和字幕文件：SRT、WebVTT、声迹 JSON、ASS/SSA、SBV、TTML/DFXP。没有有效时间戳的文件会标为不支持；ASS 样式和 TTML 区域会被忽略。

视频转录完成后，点“导出转录”旁的“烧录到视频”，会带着当前显示的原文或译文打开同一页面。

- **输出：** 创建副本（默认），或烧录到原视频（新文件渲染并校验成功后才替换原文件）。
- **样式：** 本机任意字体、字号、顶部或底部位置与边距、可选背景、可调阴影，并带实时预览；样式会被记住。
- 使用 AVFoundation 渲染，保留原分辨率和方向；HEVC 源输出 HEVC，其余输出 H.264。

## 保存麦克风原音

开始新的麦克风转录前，打开“保存原始音频”，并选择“存储优先”“质量优先”或“最高质量”（M4A，AAC 或 ALAC）。完成后可按 0.5×、1×、2× 播放，并与稿件以相同文件名一同导出。编辑或翻译稿件不会改变原音。文件转录、Mac 声音、实时字幕，以及在导入稿件后继续的转录不支持此功能。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| ⌘N | 麦克风转录 |
| ⌘O | 从文件转录 |
| ⇧⌘O | 导入稿件 |
| ⇧⌘B | 烧录字幕 |
| Return | 开始转录 |
| 空格 | 暂停／继续 |
| ⌘E | 导出转录 |

## 命令行

```sh
LS=/Applications/LocalScribe.app/Contents/MacOS/LocalScribe

$LS --cli help
$LS --cli models --json
$LS --cli download whisper.largeV3TurboQ5
$LS --cli transcribe input.mp4 --engine whisper --language zh_CN \
  --translate-to en --format srt --output output.srt
$LS --cli translate "你好" --source zh_CN --target en
$LS --cli translate "你好" --source zh_CN --target en --provider intelligence
$LS --cli prompts edit
$LS --cli burn --video input.mp4 --subtitles input.srt --output subtitled.mp4
```

| 命令 | 作用 |
| --- | --- |
| `models [--json]` | 列出模型及安装状态 |
| `download <model-id>` / `remove <model-id>` | 安装或卸载识别模型 |
| `transcribe <文件>` | 用 Whisper、SenseVoice 或 Parakeet 转录；可用 `--model`、`--compute auto\|coreml\|metal\|cpu`、`--translate-to`、`--translation-provider apple\|nllb\|intelligence`、`--format txt\|md\|json\|pdf\|srt\|vtt` |
| `translate <文字>` | 用 Apple Translation（macOS 26）、NLLB 或 Apple 智能（`--provider intelligence`，macOS 26）翻译文字 |
| `prompts [show\|edit\|reset]` | 查看长期提示词（`--json`）、打开编辑窗口或恢复默认（`proofread\|summary\|all`） |
| `burn` | 烧录字幕；支持 `--in-place`、`--overwrite`、`--font`、`--size`、`--position`、`--margin`、`--background` 及阴影选项 |

## 隐私与更新

识别与翻译在本机运行，识别音频及 Apple 智能或内置 Gemma 处理的文本不会上传。LM Studio 通过同一台 Mac 的回环地址接收文本；只有主动选择 OpenAI 或 DeepSeek 并确认后，才会发送任务文本、上下文和指令。API key 保存在本机不参与同步的 Keychain。

其他联网用途包括按需下载模型、检查与下载更新，以及打开外部文档。Apple Speech、Apple Translation 和 Apple 智能可能需要先准备好由系统管理的资源。

更新器在启动时和每六小时检查一次，从最新 GitHub Release 读取 `update.json`，验证 ZIP 的 SHA-256、Bundle ID 与版本，在替换 App 前询问。可在设置中关闭自动检查更新。

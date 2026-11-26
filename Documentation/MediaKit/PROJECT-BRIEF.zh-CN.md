# 声迹项目事实表

[English](PROJECT-BRIEF.md) | **简体中文**

## 一句话简介

声迹是一款免费开源的 macOS 本地转录应用，支持实时字幕、字幕编辑与烧录，并在受支持的 Mac 上用 Apple 智能完成本机翻译与文稿优化。

## 简短简介

声迹可将麦克风、音视频文件与 Mac 正在播放的声音转成可编辑文字和字幕，支持 Apple 智能本机翻译、纠错与总结，以及字幕烧录、长任务恢复和命令行工作流。

## 完整简介

声迹是一款面向 Apple silicon Mac 的免费开源 SwiftUI 原生应用，将转录、编辑、翻译与字幕交付整合在同一个界面。它提供 Apple Speech、Whisper、SenseVoice 与 NVIDIA Parakeet 识别，并在受支持的 Mac 上使用 Apple 智能翻译、纠错和总结；另有 Gemma 4、可选 NLLB 及自定义 AI 服务。识别不上传原始音视频；只有用户主动选择云端 AI 并确认后，才会发送任务所需的文本、上下文和指令。

## 核心亮点

- 麦克风、音视频文件与 Mac 声音转录；
- 麦克风、Mac 声音或混合输入的悬浮实时字幕；
- Apple Speech、Whisper、SenseVoice、NVIDIA Parakeet 识别；
- 稿件导入、搜索、替换、范围裁剪与多格式导出；
- Apple 智能本机翻译、纠错与总结；
- 默认 Apple Translation 翻译，可选 NLLB 翻译及 Gemma 4 文稿优化；
- 可用本机 LM Studio 或 OpenAI、DeepSeek 进行纠错和总结；
- 字幕烧录支持字体、位置、背景、阴影与实时预览；
- 可选保存麦克风原音，支持恢复、应用内更新与命令行；
- 简体中文、英文与日语界面；
- MIT 许可的应用源码；第三方组件与模型保留各自许可证。

## 系统与限制

- Apple silicon（`arm64`），macOS 15.5 或更高版本；不支持 Intel Mac；
- Apple Speech 识别与悬浮实时字幕需要 macOS 26 或更高版本；
- macOS 15.5–25 需选择并下载第三方识别模型；
- SenseVoice 与 Parakeet 仅支持文件转录，实时字幕翻译当前关闭；
- Apple 智能需要 macOS 26 或更高版本、受支持的 Mac，并已开启且系统模型已就绪；macOS 26 路径尚未经过实机验证；
- 8 GB 及以下内存默认关闭 Gemma，NLLB 需要至少 4 GB 内存；
- OpenAI、DeepSeek 连接器仍为预览功能，可能产生 API 费用；
- 公开包只有 ad-hoc 完整性签名，没有 Developer ID 签名，也未经 Apple 公证。

## 隐私

识别在本机完成，不上传原始音视频；翻译与内置 AI 也在本机运行。LM Studio 通过同一台 Mac 的回环地址接收文本。只有用户主动选择云端 AI 服务并确认后，才会发送任务文本、上下文和指令。API key 保存在本机不参与同步的 Keychain。

## 链接

- [GitHub](https://github.com/maddylaneeee/ShengJi)
- [最新发布与下载](https://github.com/maddylaneeee/ShengJi/releases/latest)
- [安装指南](../../INSTALL.zh-CN.md)
- [使用指南](../USAGE.zh-CN.md) · [AI 文稿优化与服务](../AI-SERVICES.zh-CN.md)
- [官网](https://lixinchen.ca/docs/localscribe/)

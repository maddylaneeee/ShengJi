# 声迹项目事实表

## 一句话简介

声迹是一款原生、开源、本地优先的 macOS 转录工具，可把麦克风、音视频文件和 Mac 正在播放的声音转成可编辑文字与字幕。

## 50 字简介

声迹是一款 Apple silicon Mac 本地转录工具，支持 Mac 声音悬浮字幕、音视频转录、稿件编辑、离线翻译和 SRT 导出，源码开放，音频与稿件不会由应用上传。

## 150 字简介

声迹是一款原生 SwiftUI macOS 开源应用，可转录麦克风、音频、视频以及 Mac 正在播放的声音，并提供悬浮实时字幕、稿件编辑、字幕导入导出、离线翻译和长任务恢复。它整合 Apple Speech、whisper.cpp、SenseVoice 与 NVIDIA Parakeet；识别和可选翻译在本机完成，音频与导入稿件不会由应用上传。当前支持 Apple silicon 和 macOS 15.5+，其中 Apple SpeechAnalyzer 与实时字幕需要 macOS 26。

## 核心亮点

- Mac 系统声音 → 本地悬浮字幕；
- 麦克风、音频和视频文件转录；
- Apple Speech、Whisper、SenseVoice、Parakeet 多引擎；
- 搜索、替换、范围裁剪与多格式导出；
- Apple Translation 与可选 NLLB 本地翻译；
- 恢复记录和应用内更新；
- 简体中文与英文完整界面；
- MIT 许可的应用源码。

## 系统与限制

- Apple silicon（arm64），暂不支持 Intel Mac；
- App 最低 macOS 15.5；
- Apple SpeechAnalyzer 与悬浮实时字幕需要 macOS 26；
- macOS 15.5–25 需手动选择第三方模型；
- SenseVoice 与 Parakeet 当前只支持文件转录；
- 实时字幕翻译当前关闭；
- 公开安装包尚未 Developer ID 签名或公证。

## 链接

- GitHub：<https://github.com/maddylaneeee/ShengJi>
- 下载：<https://github.com/maddylaneeee/ShengJi/releases/latest>
- 中文安装指南：<https://github.com/maddylaneeee/ShengJi/blob/main/Documentation/DOWNLOAD.zh-CN.md>
- 使用说明：<https://lixinchen.ca/docs/localscribe/>
- 问题反馈：<https://github.com/maddylaneeee/ShengJi/issues>

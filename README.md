# 声迹 ShengJi

声迹（ShengJi）是一款面向 Apple Silicon 的原生 macOS 26+ 本地语音转写应用。它使用 SwiftUI 构建界面，以启用 Metal 的 [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) 作为转写引擎，音视频与模型均在本机处理。

## 功能

- 批量导入本地音频和视频
- Metal 加速转写，并提供 CPU 诊断回退
- 下载或导入 GGML Whisper 模型
- 输出 TXT、SRT、VTT、JSON 和 LRC
- 语言、翻译、线程、处理器、温度、时间戳与 VAD 设置
- 实时日志、进度、取消、历史记录和持久化设置

## 系统要求

- Apple Silicon Mac
- macOS 26 或更高版本
- Xcode 26 Command Line Tools
- 发布打包需要本机代码签名身份

## 构建

```bash
./scripts/bootstrap_whisper_cpp.sh
swift build
```

`bootstrap_whisper_cpp.sh` 会将 `whisper.cpp` 下载到被 Git 忽略的 `vendor/` 目录，并构建启用 Metal 的 `whisper-cli`。

创建签名 App 与 DMG：

```bash
./scripts/build_release.sh
```

也可显式指定签名身份：

```bash
SIGN_IDENTITY="Developer ID Application: Example" ./scripts/build_release.sh
```

发布产物位于：

- `dist/声迹.app`
- `dist/ShengJi.dmg`

模型默认保存在 `~/Library/Application Support/ShengJi/models`，输出默认保存到 `~/Documents/声迹输出`。

## 上游与许可证

声迹的 SwiftUI/AppKit 应用代码为独立实现。转写后端使用 MIT 许可的 `whisper.cpp`，其源码和许可证由构建脚本获取并保留在本地 `vendor/` 目录，发布 App 也会包含上游许可证。声迹本身以 MIT License 发布，详见 [LICENSE](LICENSE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

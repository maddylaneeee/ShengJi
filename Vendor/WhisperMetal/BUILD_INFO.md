# WhisperMetal build

- Upstream: `ggml-org/whisper.cpp`
- Version: `v1.9.1`
- Commit: `f049fff95a089aa9969deb009cdd4892b3e74916`
- Architecture: `arm64`
- Deployment target: `macOS 15.5`
- Acceleration: `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON`, `GGML_METAL_USE_BF16=ON`
- CPU fallback kernels: Accelerate/NEON
- Core ML: disabled, so Whisper inference is explicitly configured for the Metal backend.
- ANE: not claimed; this ordinary GGML + Metal build does not automatically execute on ANE.

The combined static archive contains whisper, ggml-base, ggml-cpu, ggml-blas, and ggml-metal.

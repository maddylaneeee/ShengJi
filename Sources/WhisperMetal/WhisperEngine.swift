import Foundation

actor WhisperEngine {
    private(set) var loadedModelPath = ""

    func prepare(modelPath: String, runtime: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw EngineError.modelMissing
        }
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw EngineError.runtimeMissing
        }
        loadedModelPath = modelPath
        return loadedModelPath
    }

    func unload() {
        loadedModelPath = ""
    }
}

enum EngineError: LocalizedError {
    case modelMissing
    case runtimeMissing

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "Selected model file no longer exists."
        case .runtimeMissing:
            return "Bundled whisper runtime is missing."
        }
    }
}

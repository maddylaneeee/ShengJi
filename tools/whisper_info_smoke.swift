import Foundation
import WhisperMetal

@main
struct WhisperInfoSmoke {
    static func main() {
        var parameters = whisper_context_default_params()
        parameters.use_gpu = true
        parameters.flash_attn = true
        let info = String(cString: whisper_print_system_info())
        print("whisper.cpp \(String(cString: whisper_version()))")
        print(info)
        print("use_gpu=\(parameters.use_gpu) flash_attn=\(parameters.flash_attn)")
    }
}

import Foundation

enum LocalScribePaths {
    private static let containerIdentifier = "ca.lixinchen.localscribe"

    static var applicationSupportDirectory: URL {
#if DEBUG
        if let root = ProcessInfo.processInfo.environment["LOCALSCRIBE_TEST_DATA_ROOT"] { return URL(fileURLWithPath: root, isDirectory: true) }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("LocalScribeTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
#endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(containerIdentifier)/Data/Library/Application Support", isDirectory: true)
    }

    static var cachesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(containerIdentifier)/Data/Library/Caches", isDirectory: true)
    }
}

import Foundation

enum LocalScribePaths {
    private static let containerIdentifier = "ca.lixinchen.localscribe"

    static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(containerIdentifier)/Data/Library/Application Support", isDirectory: true)
    }

    static var cachesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(containerIdentifier)/Data/Library/Caches", isDirectory: true)
    }
}

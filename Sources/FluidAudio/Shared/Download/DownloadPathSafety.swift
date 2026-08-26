import Foundation

enum DownloadPathSafety {
    static func validateRemotePath(_ path: String, beneath parent: String = "") throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\u{0000}"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parent.isEmpty || path.hasPrefix(parent + "/") else {
            throw DownloadError.unsafeRemotePath(path)
        }
    }

    static func validateLocalDestination(_ destination: URL, in root: URL) throws {
        let lexicalRoot = root.standardizedFileURL
        let lexicalDestination = destination.standardizedFileURL
        guard lexicalDestination.path.hasPrefix(lexicalRoot.path + "/") else {
            throw DownloadError.unsafeRemotePath(destination.lastPathComponent)
        }

        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
        let resolvedParent = lexicalDestination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent.path == resolvedRoot.path
                || resolvedParent.path.hasPrefix(resolvedRoot.path + "/") else {
            throw DownloadError.unsafeRemotePath(destination.lastPathComponent)
        }
    }
}

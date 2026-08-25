import Darwin
import Foundation

struct ServiceInstallTransaction {
    private struct FileSnapshot {
        let url: URL
        let existed: Bool
        let data: Data?
        let mode: mode_t?
    }

    private struct TreeSnapshot {
        let url: URL
        let existed: Bool
    }

    private let fileSystem: ServiceFileSystem
    private let files: [FileSnapshot]
    private let trees: [TreeSnapshot]

    init(
        fileSystem: ServiceFileSystem,
        files: [URL],
        trees: [URL],
        logFiles: [URL] = []
    ) throws {
        self.fileSystem = fileSystem
        let logFileSet = Set(logFiles)
        self.files = try files.map { url in
            if logFileSet.contains(url) {
                let snapshot = try fileSystem.snapshotPrivateLogFileIfPresent(
                    url,
                    limit: 512 * 1024
                )
                return FileSnapshot(
                    url: url,
                    existed: snapshot != nil,
                    data: snapshot?.data,
                    mode: snapshot?.mode
                )
            }
            let existed = try fileSystem.exists(url)
            let data = existed ? try fileSystem.readExactPrivateData(url, limit: 512 * 1024) : nil
            let mode = existed ? try fileSystem.privateFileMode(url) : nil
            return FileSnapshot(
                url: url,
                existed: existed,
                data: data,
                mode: mode
            )
        }
        self.trees = try trees.map { url in
            TreeSnapshot(url: url, existed: try fileSystem.exists(url))
        }
    }

    func rollback() throws {
        for tree in trees where !tree.existed {
            try ServiceRecoveryContext.consume()
            try fileSystem.removeTreeIfPresent(tree.url)
        }
        for file in files {
            try ServiceRecoveryContext.consume()
            if file.existed, let data = file.data {
                try fileSystem.writePrivateFileAtomically(data, to: file.url)
                if let mode = file.mode {
                    try fileSystem.restorePrivateFileMode(mode, at: file.url)
                }
            } else {
                try fileSystem.removeTreeIfPresent(file.url)
            }
        }
    }
}

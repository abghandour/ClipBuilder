import Foundation

nonisolated enum AssetSyncPlanner {
    static func plan(local: [String: AssetSyncEntry], remote: [String: AssetSyncEntry]) -> AssetSyncPlan {
        let local = local.filter { AssetSyncKind.accepts($0.key, isFolder: $0.value.isFolder) }
        let remote = remote.filter { AssetSyncKind.accepts($0.key, isFolder: $0.value.isFolder) }
        var result = AssetSyncPlan()
        var blocked: [String] = []
        for kind in AssetSyncKind.allCases {
            let root = kind.folderName
            let paths = Set(local.keys).union(remote.keys).union([root])
                .filter { $0 == root || $0.hasPrefix(root + "/") }.sorted()
            for path in paths {
                if blocked.contains(where: { path.hasPrefix($0 + "/") }) { continue }
                let a = local[path]
                let b = remote[path]
                func add(_ op: AssetSyncPlan.Operation) {
                    result.actions.append(.init(operation: op, path: path, local: a, remote: b))
                }
                if let a, let b {
                    if a.isFolder != b.isFolder {
                        add(.conflict)
                        blocked.append(path)
                    } else if a.isFolder {
                        continue
                    } else if (b.md5 != nil && a.md5?.lowercased() == b.md5?.lowercased())
                        || (b.md5 == nil && a.size == b.size)
                    {
                        add(.skip)
                    } else if a.modifiedDate > b.modifiedDate {
                        add(.replaceInDrive)
                    } else if b.modifiedDate > a.modifiedDate {
                        add(.replaceLocal)
                    } else {
                        add(.conflict)
                    }
                } else if let a {
                    add(a.isFolder ? .createDriveFolder : .upload)
                } else if let b {
                    add(b.isFolder ? .createLocalFolder : .download)
                } else {
                    add(.createLocalFolder)
                    add(.createDriveFolder)
                }
            }
        }
        return result
    }
}

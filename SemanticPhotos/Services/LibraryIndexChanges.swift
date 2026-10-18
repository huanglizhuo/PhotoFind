import Foundation

/// Reconciles a complete PhotoKit snapshot, including work not indexed yet.
struct LibraryIndexChanges {
    let added: Set<String>
    let removed: Set<String>

    init(current: Set<String>, indexed: Set<String>, tracked: Set<String>) {
        added = current.subtracting(indexed).subtracting(tracked)
        removed = indexed.union(tracked).subtracting(current)
    }
}

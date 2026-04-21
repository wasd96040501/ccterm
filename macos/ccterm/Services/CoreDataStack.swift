import CoreData

final class CoreDataStack {

    // MARK: - Properties

    static let shared = CoreDataStack()

    let persistentContainer: NSPersistentContainer

    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    // MARK: - Lifecycle

    private init() {
        persistentContainer = NSPersistentContainer(name: "ccterm")
        persistentContainer.loadPersistentStores { _, error in
            if let error {
                appLog(.error, "CoreDataStack", "Failed to load store: \(error)")
            }
        }
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
    }

    /// 测试用：in-memory store，不写磁盘。
    internal init(inMemory: Bool) {
        persistentContainer = NSPersistentContainer(name: "ccterm")
        if inMemory {
            let desc = NSPersistentStoreDescription()
            desc.type = NSInMemoryStoreType
            persistentContainer.persistentStoreDescriptions = [desc]
        }
        persistentContainer.loadPersistentStores { _, error in
            if let error {
                appLog(.error, "CoreDataStack", "Failed to load store: \(error)")
            }
        }
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
    }

    // MARK: - Public Methods

    /// Workaround: macOS 26 SDK 的 `swift_task_deinitOnExecutorImpl` 在 isolated deinit 链中
    /// 命中 libmalloc pointer-freed-but-not-allocated 崩溃。显式 nonisolated deinit 跳过
    /// executor-hop 路径。详见 SessionHandle2.swift 的同类注释。
    nonisolated deinit { }

    func saveContext() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            appLog(.error, "CoreDataStack", "Save failed: \(error)")
        }
    }
}

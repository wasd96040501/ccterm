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
                NSLog("[CoreDataStack] Failed to load store: \(error)")
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
                NSLog("[CoreDataStack] Failed to load store: \(error)")
            }
        }
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
    }

    // MARK: - Public Methods

    func saveContext() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            NSLog("[CoreDataStack] Save failed: \(error)")
        }
    }
}

/// Plans a commit (SPEC §6, §7, §8.2): resolve the anchor against the old
/// geometry, carry it through the map, restore it against the new geometry,
/// then work out every mounted row's start and end, capped by M7.
///
/// A pure function, so the property tests drive it with random batches and
/// compare it against a reference that shares none of its code.
public enum CommitPlanner {

    public static func plan(_ input: CommitInput) -> CommitPlan {
        fatalError("unimplemented: SPEC §6, §8.2")
    }
}

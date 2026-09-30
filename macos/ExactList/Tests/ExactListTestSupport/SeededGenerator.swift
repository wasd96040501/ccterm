/// SplitMix64: a small, fast generator whose sequence depends only on its seed,
/// so a failing property run can be replayed from the seed it prints.
public struct SeededGenerator: RandomNumberGenerator {

    public let seed: UInt64
    private var state: UInt64

    public init(seed: UInt64) {
        self.seed = seed
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

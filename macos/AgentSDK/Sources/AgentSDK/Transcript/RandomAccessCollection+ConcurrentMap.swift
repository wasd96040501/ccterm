import Foundation

extension RandomAccessCollection {
    /// `map` with the elements spread across every core; results keep the
    /// collection's order. For work that dwarfs dispatching it — decoding a
    /// transcript line, not adding two numbers.
    func concurrentMap<Result>(_ transform: (Element) -> Result) -> [Result] {
        let elements = Array(self)
        var results = [Result?](repeating: nil, count: elements.count)
        results.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: elements.count) { index in
                results[index] = transform(elements[index])
            }
        }
        return results.map { $0! }
    }
}

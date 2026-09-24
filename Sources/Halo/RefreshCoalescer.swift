/// Coalesces repeated refresh requests for the same key while one is in flight.
/// The caller starts one follow-up refresh when `finish` returns true.
struct RefreshCoalescer<Key: Hashable> {
    private var inFlight = Set<Key>()
    private var pending = Set<Key>()

    mutating func begin(_ key: Key) -> Bool {
        guard !inFlight.contains(key) else {
            pending.insert(key)
            return false
        }
        inFlight.insert(key)
        return true
    }

    mutating func finish(_ key: Key) -> Bool {
        guard inFlight.remove(key) != nil else { return false }
        return pending.remove(key) != nil
    }

    mutating func reset() {
        inFlight.removeAll()
        pending.removeAll()
    }
}

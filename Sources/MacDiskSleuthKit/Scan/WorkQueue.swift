/// Distributes directory work across scanner tasks. LIFO order keeps the
/// traversal frontier narrow (bounding open parent fds), and termination is
/// detected when no work is pending and none is in flight.
actor WorkQueue {
    private var stack: [DirWork] = []
    private var waiters: [CheckedContinuation<DirWork?, Never>] = []
    private var inFlight = 0
    private var finished = false

    func push(_ items: [DirWork]) {
        guard !finished else {
            for item in items { item.parent?.release() }
            return
        }
        stack.append(contentsOf: items)
        while !waiters.isEmpty && !stack.isEmpty {
            let waiter = waiters.removeFirst()
            inFlight += 1
            waiter.resume(returning: stack.removeLast())
        }
    }

    /// Next work item, or nil when the traversal is complete (or cancelled).
    func next() async -> DirWork? {
        if finished { return nil }
        if !stack.isEmpty {
            inFlight += 1
            return stack.removeLast()
        }
        if inFlight == 0 {
            finishAll()
            return nil
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Must be called exactly once per item obtained from next().
    func complete() {
        inFlight -= 1
        if inFlight == 0 && stack.isEmpty && waiters.count > 0 {
            finishAll()
        } else if inFlight == 0 && stack.isEmpty {
            finished = true
        }
    }

    /// Abort: wake every waiter and drop pending work (releasing parent fds).
    func cancelAll() {
        finishAll()
    }

    private func finishAll() {
        finished = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
        for item in stack { item.parent?.release() }
        stack.removeAll()
    }
}

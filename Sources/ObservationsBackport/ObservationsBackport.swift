import Observation

@inline(__always)
private func eraseIsolation<T, E: Error>(
    _ emit: @escaping @isolated(any) @Sendable () throws(E) -> T
) -> @Sendable () throws(E) -> T {
    // Backport: erase dynamic isolation while relying on callers to stay on the same actor.
    unsafeBitCast(emit, to: (@Sendable () throws(E) -> T).self)
}

/// An asynchronous sequence generated from a closure that tracks changes of `@Observable` types.
public struct ObservationsBackport<Element, Failure>: AsyncSequence, Sendable where Element: Sendable, Failure: Error {
    fileprivate enum Mode: Sendable {
        case element(@Sendable () throws(Failure) -> Element)
        case iteration(@Sendable () throws(Failure) -> Iteration)
    }

    public enum Iteration: Sendable {
        case next(Element)
        case finish
    }

    private let mode: Mode

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public init(@_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element) {
        self.mode = .element(eraseIsolation(emit))
    }

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public static func untilFinished(
        @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Iteration
    ) -> ObservationsBackport<Element, Failure> {
        ObservationsBackport(mode: .iteration(eraseIsolation(emit)))
    }

    private init(mode: Mode) {
        self.mode = mode
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(mode: mode)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let mode: Mode
        private let signal = ChangeSignal()
        private var started = false
        private var finished = false

        fileprivate init(mode: Mode) {
            self.mode = mode
        }

        public mutating func next() async throws(Failure) -> Element? {
            try await next(isolation: #isolation)
        }

        public mutating func next(
            isolation iterationIsolation: isolated (any Actor)? = #isolation
        ) async throws(Failure) -> Element? {
            _ = iterationIsolation
            guard !finished else { return nil }

            if started {
                await signal.wait()
            } else {
                started = true
            }

            guard !finished else { return nil }

            let mode = mode
            let signal = signal
            let result: Result<Iteration, Failure> = withObservationTracking(
                {
                    do {
                        let iteration: Iteration
                        switch mode {
                        case .element(let emit):
                            iteration = .next(try emit())
                        case .iteration(let emit):
                            iteration = try emit()
                        }
                        return Result<Iteration, Failure>.success(iteration)
                    } catch let error as Failure {
                        return Result<Iteration, Failure>.failure(error)
                    } catch {
                        preconditionFailure("Unexpected error type: \(error)")
                    }
                },
                onChange: { [signal] in
                    Task { await signal.signal() }
                }
            )

            switch result {
            case .success(.next(let element)):
                return element
            case .success(.finish):
                finished = true
                Task { await signal.finish() }
                return nil
            case .failure(let error):
                finished = true
                Task { await signal.finish() }
                throw error
            }
        }
    }

    public typealias AsyncIterator = ObservationsBackport<Element, Failure>.Iterator
}

private actor ChangeSignal {
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if pending > 0 {
            pending -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            continuation.resume()
        } else {
            pending += 1
        }
    }

    func finish() {
        let continuations = waiters
        waiters.removeAll()
        pending = 0
        for continuation in continuations {
            continuation.resume()
        }
    }
}

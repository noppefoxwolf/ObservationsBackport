import Observation

@inline(__always)
private func eraseIsolation<T, E: Error>(
    _ emit: @escaping @isolated(any) @Sendable () throws(E) -> T
) -> @Sendable () throws(E) -> T {
    // Backport shim: call only after verifying isolation compatibility.
    unsafeBitCast(emit, to: (@Sendable () throws(E) -> T).self)
}

/// An asynchronous sequence generated from a closure that tracks changes of `@Observable` types.
public struct ObservationsBackport<Element, Failure>: AsyncSequence, Sendable where Element: Sendable, Failure: Error {
    fileprivate enum Mode: Sendable {
        case element(@isolated(any) @Sendable () throws(Failure) -> Element)
        case iteration(@isolated(any) @Sendable () throws(Failure) -> Iteration)
    }

    public enum Iteration: Sendable {
        case next(Element)
        case finish
    }

    private let mode: Mode

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public init(@_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element) {
        self.mode = .element(emit)
    }

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public static func untilFinished(
        @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Iteration
    ) -> ObservationsBackport<Element, Failure> {
        ObservationsBackport(mode: .iteration(emit))
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

        public mutating func next(
            isolation iterationIsolation: isolated (any Actor)? = #isolation
        ) async throws(Failure) -> Element? {
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
                            if let required = emit.isolation {
                                precondition(required === iterationIsolation, "ObservationsBackport.next must be called on the emit isolation.")
                            }
                            let emitSync = eraseIsolation(emit)
                            iteration = .next(try emitSync())
                        case .iteration(let emit):
                            if let required = emit.isolation {
                                precondition(required === iterationIsolation, "ObservationsBackport.next must be called on the emit isolation.")
                            }
                            let emitSync = eraseIsolation(emit)
                            iteration = try emitSync()
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

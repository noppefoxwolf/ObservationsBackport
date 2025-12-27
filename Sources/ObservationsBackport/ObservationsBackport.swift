import Observation

/// An asynchronous sequence generated from a closure that tracks changes of `@Observable` types.
public struct ObservationsBackport<Element, Failure>: AsyncSequence, Sendable where Element: Sendable, Failure: Error {
    fileprivate enum Mode: Sendable {
        case element(emit: @Sendable () throws(Failure) -> Element, isolation: (any Actor)?)
        case iteration(emit: @Sendable () throws(Failure) -> Iteration, isolation: (any Actor)?)
    }

    public enum Iteration: Sendable {
        case next(Element)
        case finish
    }

    private let mode: Mode

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public init(
        isolation: isolated (any Actor)? = #isolation,
        _ emit: @escaping @Sendable () throws(Failure) -> Element
    ) {
        self.mode = .element(emit: emit, isolation: isolation)
    }

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public static func untilFinished(
        isolation: isolated (any Actor)? = #isolation,
        _ emit: @escaping @Sendable () throws(Failure) -> Iteration
    ) -> ObservationsBackport<Element, Failure> {
        ObservationsBackport(mode: .iteration(emit: emit, isolation: isolation))
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
                    switch mode {
                    case let .element(emit, requiredIsolation):
                        if let required = requiredIsolation {
                            precondition(required === iterationIsolation, "ObservationsBackport.next must be called on the emit isolation.")
                        }
                        do {
                            return .success(.next(try emit()))
                        } catch let error as Failure {
                            return .failure(error)
                        } catch {
                            preconditionFailure("Unexpected error type: \(error)")
                        }

                    case let .iteration(emit, requiredIsolation):
                        if let required = requiredIsolation {
                            precondition(required === iterationIsolation, "ObservationsBackport.next must be called on the emit isolation.")
                        }
                        do {
                            return .success(try emit())
                        } catch let error as Failure {
                            return .failure(error)
                        } catch {
                            preconditionFailure("Unexpected error type: \(error)")
                        }
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

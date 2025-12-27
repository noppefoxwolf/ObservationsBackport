import Observation

/// An asynchronous sequence generated from a closure that tracks changes of `@Observable` types.
public struct ObservationsBackport<Element, Failure>: AsyncSequence where Failure: Error {
    fileprivate enum Mode {
        case element(() throws(Failure) -> Element)
        case iteration(() throws(Failure) -> Iteration)
    }

    public enum Iteration {
        case next(Element)
        case finish
    }

    private let mode: Mode

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public init(_ emit: @escaping @Sendable () throws(Failure) -> Element) {
        self.mode = .element(emit)
    }

    /// Constructs an asynchronous sequence for a given closure by tracking changes of `@Observable` types.
    public static func untilFinished(
        _ emit: @escaping () throws(Failure) -> Iteration
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
        private var changeIterator: AsyncStream<Void>.Iterator
        private let changeContinuation: AsyncStream<Void>.Continuation
        private var started = false
        private var finished = false

        fileprivate init(mode: Mode) {
            self.mode = mode
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            self.changeIterator = stream.makeAsyncIterator()
            self.changeContinuation = continuation
        }

        public mutating func next() async throws(Failure) -> Element? {
            guard !finished else { return nil }

            if started {
                _ = await changeIterator.next()
            } else {
                started = true
            }

            guard !finished else { return nil }

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
                        return .success(iteration)
                    } catch let error as Failure {
                        return .failure(error)
                    } catch {
                        preconditionFailure("Unexpected error type: \(error)")
                    }
                },
                onChange: { [continuation = changeContinuation] in
                    continuation.yield(())
                }
            )

            switch result {
            case .success(.next(let element)):
                return element
            case .success(.finish):
                finished = true
                changeContinuation.finish()
                return nil
            case .failure(let error):
                finished = true
                changeContinuation.finish()
                throw error
            }
        }

    }
    
    public typealias AsyncIterator = ObservationsBackport<Element, Failure>.Iterator
}

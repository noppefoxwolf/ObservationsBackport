import Observation

/// An async sequence that yields elements when an observed value changes.
///
/// This type is a backport-style utility similar to `Observation.Observations`,
/// but implemented only with Swift Concurrency primitives. It focuses on
/// correct actor isolation by using `@isolated(any)`.
///
/// - Parameters:
///   - Element: The type of elements produced by the async sequence.
///   - Failure: The type of error that can be thrown during element production.
public struct ObservationsBackport<Element, Failure>: AsyncSequence, Sendable
where Element: Sendable, Failure: Error {
    // The element type of the sequence.
    public typealias Element = Element

    // The error type used by the sequence.
    public typealias Failure = Failure

    /// Represents the iteration state of the async sequence when using
    /// the `untilFinished` initializer.
    public enum Iteration: Sendable {
        case next(Element)
        case finish
    }

    /// Internal storage for how this sequence produces elements.
    fileprivate enum Mode: Sendable {
        case element(@isolated(any) @Sendable () throws(Failure) -> Element)
        case iteration(@isolated(any) @Sendable () throws(Failure) -> Iteration)
    }

    fileprivate let mode: Mode

    /// Creates an observations async sequence that produces elements from the
    /// provided closure.
    ///
    /// The closure is `@isolated(any)`, which means it is isolated to whichever
    /// actor it is created on. Thanks to `@_inheritActorContext`, it can freely
    /// capture `@MainActor` or other actor-isolated state without triggering
    /// Sendable diagnostics.
    ///
    /// - Parameter emit: A closure that synchronously produces an element.
    public init(
        @_inheritActorContext _ emit:
            @escaping @isolated(any) @Sendable () throws(Failure) -> Element
    ) {
        self.mode = .element(emit)
    }

    /// Creates an observations async sequence that continues to produce
    /// elements until it returns `.finish`.
    ///
    /// - Parameter emit: A closure that returns either a next element or a
    ///   finish signal.
    public static func untilFinished(
        @_inheritActorContext _ emit:
            @escaping @isolated(any) @Sendable () throws(Failure) -> Iteration
    ) -> ObservationsBackport<Element, Failure> {
        ObservationsBackport(mode: .iteration(emit))
    }

    /// Private designated initializer from a `Mode`.
    private init(mode: Mode) {
        self.mode = mode
    }

    /// The type of the iterator that produces elements of the async sequence.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private struct ChangeIterator: @unchecked Sendable {
            var iterator: AsyncStream<Void>.AsyncIterator
        }

        fileprivate var mode: Mode
        fileprivate var finished = false
        private var didStart = false
        private var changeIterator: ChangeIterator
        private let changeContinuation: AsyncStream<Void>.Continuation

        fileprivate init(mode: Mode) {
            var continuation: AsyncStream<Void>.Continuation!
            let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) {
                continuation = $0
            }
            self.changeIterator = ChangeIterator(iterator: stream.makeAsyncIterator())
            self.changeContinuation = continuation
            self.mode = mode
        }

        /// Advances to the next element in the sequence.
        ///
        /// This method registers observation tracking and waits for changes
        /// before producing the next value.
        public mutating func next() async throws(Failure) -> Element? {
            try await next(isolation: nil)
        }

        /// Advances to the next element in the sequence with explicit actor isolation.
        public mutating func next(
            isolation iterationIsolation: isolated (any Actor)? = #isolation
        ) async throws(Failure) -> Element? {
            if finished { return nil }

            if didStart {
                _ = await changeIterator.iterator.next(isolation: iterationIsolation)
            }

            let continuation = changeContinuation
            let onChange: @Sendable () -> Void = {
                continuation.yield(())
            }

            func trackedValue<T>(
                from emit: @escaping @isolated(any) @Sendable () throws(Failure) -> T
            ) throws(Failure) -> T {
                // The iterator's isolation parameter guarantees we're on the emit actor.
                if let iterationIsolation {
                    iterationIsolation.preconditionIsolated()
                }
                typealias UnsafeEmit = @Sendable () throws(Failure) -> T
                let unsafeEmit = unsafeBitCast(emit, to: UnsafeEmit.self)
                func apply() -> Result<T, Failure> {
                    do {
                        return .success(try unsafeEmit())
                    } catch {
                        return .failure(error)
                    }
                }
                return try withObservationTracking(apply, onChange: onChange).get()
            }

            switch mode {
            case .element(let emit):
                let value = try trackedValue(from: emit)
                didStart = true
                return value

            case .iteration(let emit):
                let iteration = try trackedValue(from: emit)
                didStart = true
                switch iteration {
                case .next(let element):
                    return element
                case .finish:
                    finished = true
                    changeContinuation.finish()
                    return nil
                }
            }
        }
    }

    /// Returns an iterator over the elements of the async sequence.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(mode: mode)
    }
}

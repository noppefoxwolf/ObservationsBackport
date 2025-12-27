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
public struct ObservationsBackport<Element, Failure>: AsyncSequence, Sendable where Element: Sendable, Failure: Error {
    // The element type of the sequence.
    public typealias Element = Element

    // The error type used by the sequence.
    public typealias Failure = Failure

    /// Represents the iteration state of the async sequence when using
    /// the `untilFinished` initializer.
    public enum Iteration : Sendable{
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
        @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element
    ) {
        self.mode = .element(emit)
    }

    /// Creates an observations async sequence that continues to produce
    /// elements until it returns `.finish`.
    ///
    /// - Parameter emit: A closure that returns either a next element or a
    ///   finish signal.
    public static func untilFinished(
        @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Iteration
    ) -> ObservationsBackport<Element, Failure> {
        ObservationsBackport(mode: .iteration(emit))
    }

    /// Private designated initializer from a `Mode`.
    private init(mode: Mode) {
        self.mode = mode
    }

    /// The type of the iterator that produces elements of the async sequence.
    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var mode: Mode
        fileprivate var finished = false

        /// Advances to the next element in the sequence.
        ///
        /// This method is `async` and simply `await`s the underlying
        /// `@isolated(any)` closure. The runtime will hop to the appropriate
        /// actor as needed.
        public mutating func next() async throws(Failure) -> Element? {
            if finished { return nil }

            switch mode {
            case .element(let emit):
                // Just call the producer and return its result.
                return try await emit()

            case .iteration(let emit):
                let iteration = try await emit()
                switch iteration {
                case .next(let element):
                    return element
                case .finish:
                    finished = true
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

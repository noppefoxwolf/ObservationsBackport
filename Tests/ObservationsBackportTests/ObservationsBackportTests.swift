import Observation
import Testing

@testable import ObservationsBackport

@MainActor
@Observable
final class Counter {
    var value: Int

    init(_ value: Int = 0) {
        self.value = value
    }
}

enum TestError: Error, Equatable {
    case boom
}

@MainActor
@Observable
final class Toggle {
    var value: Int
    var isDone: Bool

    init(value: Int = 0, isDone: Bool = false) {
        self.value = value
        self.isDone = isDone
    }
}

// Minimal API surface shared by Observation.Observations and ObservationsBackport.
protocol ObservationsAPI {
    associatedtype Element: Sendable
    associatedtype Failure: Error
    associatedtype Iteration: Sendable
    associatedtype AsyncIterator: AsyncIteratorProtocol where AsyncIterator.Element == Element, AsyncIterator.Failure == Failure

    init(@_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Element)
    static func untilFinished(
        @_inheritActorContext _ emit: @escaping @isolated(any) @Sendable () throws(Failure) -> Iteration
    ) -> Self

    func makeAsyncIterator() -> AsyncIterator
}

extension ObservationsBackport: ObservationsAPI {
    typealias Iteration = ObservationsBackport<Element, Failure>.Iteration
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension Observation.Observations: ObservationsAPI {
    typealias Iteration = Observation.Observations<Element, Failure>.Iteration
}

@MainActor
private func runYieldsInitialValue<Obs: ObservationsAPI>(_ type: Obs.Type) async
where Obs.Element == Int, Obs.Failure == Never {
    let counter = Counter()
    let observations = Obs { counter.value }
    var iterator = observations.makeAsyncIterator()

    let initial = await iterator.next(isolation: #isolation)
    #expect(initial == 0)
}

@MainActor
private func runYieldsValuesOnMultipleChanges<Obs: ObservationsAPI>(_ type: Obs.Type) async
where Obs.Element == Int, Obs.Failure == Never {
    let counter = Counter()
    let observations = Obs { counter.value }
    var iterator = observations.makeAsyncIterator()

    _ = await iterator.next(isolation: #isolation)

    counter.value = 1
    let first = await iterator.next(isolation: #isolation)

    counter.value = 2
    let second = await iterator.next(isolation: #isolation)

    #expect(first == 1)
    #expect(second == 2)
}

@MainActor
private func runUntilFinishedStopsAfterFinish<Obs: ObservationsAPI>(
    _ type: Obs.Type,
    makeNext: @escaping (Obs.Element) -> Obs.Iteration,
    makeFinish: @escaping () -> Obs.Iteration
) async where Obs.Element == Int, Obs.Failure == Never {
    let toggle = Toggle()
    let observations = Obs.untilFinished {
        if toggle.isDone {
            return makeFinish()
        }
        return makeNext(toggle.value)
    }
    var iterator = observations.makeAsyncIterator()

    let initial = await iterator.next(isolation: #isolation)
    #expect(initial == 0)

    toggle.value = 1
    let updated = await iterator.next(isolation: #isolation)
    #expect(updated == 1)

    toggle.isDone = true
    let finished = await iterator.next(isolation: #isolation)
    #expect(finished == nil)

    let afterFinish = await iterator.next(isolation: #isolation)
    #expect(afterFinish == nil)
}

@MainActor
private func runPropagatesErrors<Obs: ObservationsAPI>(_ type: Obs.Type) async
where Obs.Element == Int, Obs.Failure == TestError {
    let counter = Counter()
    let observations = Obs({ () throws(TestError) -> Int in
        if counter.value < 0 {
            throw TestError.boom
        }
        return counter.value
    })
    var iterator = observations.makeAsyncIterator()

    let initial = try? await iterator.next(isolation: #isolation)
    #expect(initial == 0)

    counter.value = -1
    do {
        _ = try await iterator.next(isolation: #isolation)
        #expect(Bool(false))
    } catch let error {
        #expect(error == .boom)
    }
}

@MainActor
@Suite
struct ObservationsBackportTests {
    @Test func yieldsInitialValue() async {
        await runYieldsInitialValue(ObservationsBackport<Int, Never>.self)
    }

    @Test func yieldsValuesOnMultipleChanges() async {
        await runYieldsValuesOnMultipleChanges(ObservationsBackport<Int, Never>.self)
    }

    @Test func untilFinishedStopsAfterFinish() async {
        await runUntilFinishedStopsAfterFinish(
            ObservationsBackport<Int, Never>.self,
            makeNext: ObservationsBackport<Int, Never>.Iteration.next,
            makeFinish: { ObservationsBackport<Int, Never>.Iteration.finish }
        )
    }

    @Test func propagatesErrors() async {
        await runPropagatesErrors(ObservationsBackport<Int, TestError>.self)
    }
}

@MainActor
@Suite
struct ObservationObservationsTests {
    @Test func yieldsInitialValue() async {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            await runYieldsInitialValue(Observation.Observations<Int, Never>.self)
        }
    }

    @Test func yieldsValuesOnMultipleChanges() async {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            await runYieldsValuesOnMultipleChanges(Observation.Observations<Int, Never>.self)
        }
    }

    @Test func untilFinishedStopsAfterFinish() async {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            await runUntilFinishedStopsAfterFinish(
                Observation.Observations<Int, Never>.self,
                makeNext: Observation.Observations<Int, Never>.Iteration.next,
                makeFinish: { Observation.Observations<Int, Never>.Iteration.finish }
            )
        }
    }

    @Test func propagatesErrors() async {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            await runPropagatesErrors(Observation.Observations<Int, TestError>.self)
        }
    }
}

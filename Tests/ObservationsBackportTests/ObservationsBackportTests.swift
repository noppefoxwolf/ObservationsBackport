import Observation
import Testing

//typealias Observations = Observation.Observations

@testable import ObservationsBackport
typealias Observations = ObservationsBackport

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


@MainActor
@Suite
struct ObservationsTests {
    @Test func yieldsInitialValue() async {
        let counter = Counter()
        let observations = Observations { counter.value }
        var iterator = observations.makeAsyncIterator()

        let initial = await iterator.next(isolation: #isolation)
        #expect(initial == 0)
    }

    @Test func yieldsValuesOnMultipleChanges() async {
        let counter = Counter()
        let observations = Observations { counter.value }
        var iterator = observations.makeAsyncIterator()

        _ = await iterator.next(isolation: #isolation)

        counter.value = 1
        let first = await iterator.next(isolation: #isolation)

        counter.value = 2
        let second = await iterator.next(isolation: #isolation)

        #expect(first == 1)
        #expect(second == 2)
    }

    @Test func untilFinishedStopsAfterFinish() async {
        let toggle = Toggle()
        let observations = Observations<Int, Never>.untilFinished {
            if toggle.isDone {
                return .finish
            }
            return .next(toggle.value)
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

    @Test func propagatesErrors() async {
        let counter = Counter()
        let observations = Observations<Int, TestError>({ () throws(TestError) -> Int in
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
}

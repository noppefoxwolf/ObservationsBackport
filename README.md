# ObservationsBackport

Backport-style async sequence for Observation that mirrors `Observation.Observations`.
This package provides a lightweight implementation using Swift Concurrency primitives
and `withObservationTracking` so values are produced only when observed state changes.

## Requirements

- Swift 6.2
- iOS 18+ / macOS 26+

## Installation (SwiftPM)

```swift
.package(url: "https://github.com/noppefoxwolf/ObservationsBackport", branch: "main"),
```

```swift
.product(name: "ObservationsBackport", package: "ObservationsBackport"),
```

## Usage

```swift
import ObservationsBackport
import Observation

@MainActor
@Observable
final class Counter {
    var value: Int = 0
}

@MainActor
func run() {
    let counter = Counter()

    Task {
        for await value in ObservationsBackport({ counter.value }) {
            print("value:", value)
        }
    }

    counter.value += 1
}
```

### Until finished

```swift
let sequence = ObservationsBackport<Int, Never>.untilFinished {
    if done { return .finish }
    return .next(counter.value)
}

for await value in sequence {
    print(value)
}
```

## Behavior

- The first `next()` yields the current value immediately.
- Subsequent `next()` calls wait until an observed dependency changes.
- Internally uses `withObservationTracking` to avoid per-frame polling.
- Supports `next(isolation:)` to align with the Observation API surface.

## Tests

```sh
swift test
```

## Example

See `Example.swiftpm` for a minimal UIKit sample.

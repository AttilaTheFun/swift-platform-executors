//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// The `wasm32-unknown-wasip1-threads` probe: installs the platform executors
// as the default executors and checks, under a real wasi-threads host, that
//
// 1. a `TaskGroup` fans out across the pool (peak concurrency > 1),
// 2. a `@MainActor` → `nonisolated` hop leaves the main thread and the
//    continuation comes back to it, and
// 3. delayed enqueues (`Task.sleep`) fire on time.
//
// Build and run (the type alias is only honored on WASI with
// `-disable-availability-checking` until `CustomGlobalExecutors` ships):
//
//   swift build --swift-sdk <wasm32-unknown-wasip1-threads SDK> \
//     -Xswiftc -Xfrontend -Xswiftc -disable-availability-checking \
//     --product PlatformExecutorsWASIExample
//   wasmtime run -W threads=y,shared-memory=y -S threads=y \
//     .build/wasm32-unknown-wasip1-threads/debug/PlatformExecutorsWASIExample.wasm
//
// Exits non-zero when a check fails, so it doubles as a CI test.

#if os(WASI)
@_spi(ExperimentalScheduling) @_spi(ConcurrencyExecutors) @_spi(ExperimentalCustomExecutors) import PlatformExecutors
@_spi(ExperimentalScheduling) @_spi(ConcurrencyExecutors) @_spi(ExperimentalCustomExecutors) import _Concurrency
import Synchronization
import WASILibc
import wasi_pthread

typealias DefaultExecutorFactory = PlatformExecutorFactory

/// The thread `main` started on (the main executor takes it over).
nonisolated(unsafe) let mainThread = pthread_self()

func isOnMainThread() -> Bool {
  pthread_self() == mainThread
}

/// Peak number of child tasks running at the same time: each child announces
/// itself, then spins until every sibling has arrived (or a bounded number of
/// spins). Only a multi-threaded executor can ever see all of them at once.
final class Counters: Sendable {
  let active = Atomic<Int>(0)
  let arrived = Atomic<Int>(0)
  let peak = Atomic<Int>(0)
}

func peakConcurrency(tasks: Int) async -> Int {
  let counters = Counters()
  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<tasks {
      group.addTask {
        let now = counters.active.add(1, ordering: .relaxed).newValue
        // Record the high-water mark.
        var current = counters.peak.load(ordering: .relaxed)
        while now > current {
          let (exchanged, original) = counters.peak.compareExchange(
            expected: current,
            desired: now,
            ordering: .relaxed
          )
          if exchanged { break }
          current = original
        }
        counters.arrived.add(1, ordering: .relaxed)
        var spins = 0
        while counters.arrived.load(ordering: .relaxed) < tasks && spins < 20_000_000 {
          spins += 1
        }
        counters.active.subtract(1, ordering: .relaxed)
      }
    }
  }
  return counters.peak.load(ordering: .relaxed)
}

/// An actor isolated to a platform serial executor: every call runs there.
actor OnExecutor {
  let executor: PlatformSerialExecutor
  init(executor: PlatformSerialExecutor) { self.executor = executor }
  nonisolated var unownedExecutor: UnownedSerialExecutor { self.executor.asUnownedSerialExecutor() }
  func check() { self.executor.preconditionIsolated() }
}

@main
struct Probe {
  @MainActor
  static func main() async {
    var failures = 0

    // 1. Parallelism.
    let workers = 4
    let peak = await peakConcurrency(tasks: workers)
    print("peak concurrency: \(peak) of \(workers)")
    if peak < 2 {
      print("FAIL: tasks never ran in parallel")
      failures += 1
    }

    // 2. Isolation: main → nonisolated hops off the main thread; the
    //    continuation returns to it.
    let mainBefore = isOnMainThread()
    let hoppedOff = await Task.detached { !isOnMainThread() }.value
    let mainAfter = isOnMainThread()
    print("main thread: before=\(mainBefore) detached-off-main=\(hoppedOff) after=\(mainAfter)")
    if !mainBefore || !hoppedOff || !mainAfter {
      print("FAIL: main-thread isolation")
      failures += 1
    }
    MainActor.assertIsolated()

    // 3. Delayed scheduling on both clocks.
    let continuousStart = ContinuousClock.now
    try? await Task.sleep(for: .milliseconds(50), clock: .continuous)
    let continuousElapsed = ContinuousClock.now - continuousStart
    let suspendingStart = SuspendingClock.now
    try? await Task.sleep(for: .milliseconds(50), clock: .suspending)
    let suspendingElapsed = SuspendingClock.now - suspendingStart
    print("sleep(50ms): continuous=\(continuousElapsed) suspending=\(suspendingElapsed)")
    if continuousElapsed < .milliseconds(45) || suspendingElapsed < .milliseconds(45) {
      print("FAIL: a sleep returned early")
      failures += 1
    }

    // 4. A pool created on demand, and a serial executor.
    await PlatformExecutorFactory.withTaskExecutor(name: "probe", poolSize: 2) { executor in
      await withTaskExecutorPreference(executor) {
        for _ in 0..<100 { await Task.yield() }
      }
    }
    await PlatformExecutorFactory.withSerialExecutor(name: "serial") { executor in
      let isolated = OnExecutor(executor: executor)
      for _ in 0..<100 { await isolated.check() }
    }
    print("explicit executors: ok")

    print(failures == 0 ? "PASS" : "FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
  }
}
#else
@main
struct Probe {
  static func main() {
    print("This example targets wasm32-unknown-wasip1-threads.")
  }
}
#endif

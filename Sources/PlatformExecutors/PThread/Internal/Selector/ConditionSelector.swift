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

#if os(WASI)
import CPlatformExecutors
import WASILibc
import wasi_pthread

/// The selector for `wasm32-unknown-wasip1-threads`.
///
/// WASI has no `epoll`/`kqueue`, and the executor registers no I/O there, so
/// "wait until woken or until the next clock deadline" is a condition
/// variable: ``wakeup()`` (called from any thread) raises a flag and signals;
/// ``whenReady(strategy:)`` waits for the flag, with a timed wait for the
/// earliest pending deadline. Spurious wakeups just re-check the flag.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
final class ConditionSelector {
  private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
  private let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
  /// Set by `wakeup()`, consumed by `whenReady`. Guarded by `mutex`.
  private var pendingWakeup = false

  init() throws {
    pthread_mutex_init(self.mutex, nil)
    pthread_cond_init(self.condition, nil)
  }

  deinit {
    pthread_cond_destroy(self.condition)
    pthread_mutex_destroy(self.mutex)
    self.condition.deallocate()
    self.mutex.deallocate()
  }

  /// Blocks until `wakeup()` is called or the strategy's earliest deadline passes.
  func whenReady(strategy: SelectorStrategy) throws {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }

    switch strategy {
    case .now:
      // Nothing to wait for; a wakeup that already happened is consumed.
      self.pendingWakeup = false
    case .block:
      while !self.pendingWakeup {
        pthread_cond_wait(self.condition, self.mutex)
      }
      self.pendingWakeup = false
    case .blockUntilTimeout(let continuousClockInstant, let suspendingClockInstant):
      var timeout: Duration? = nil
      if let continuousClockInstant {
        timeout = ContinuousClock.now.duration(to: continuousClockInstant)
      }
      if let suspendingClockInstant {
        let duration = SuspendingClock.now.duration(to: suspendingClockInstant)
        timeout = timeout.map { min($0, duration) } ?? duration
      }
      guard let timeout, timeout > .zero else {
        // A deadline is already due: return so the executor pops it.
        self.pendingWakeup = false
        return
      }
      var deadline = timespec()
      CPlatformExecutors_wasi_deadline(Self.nanoseconds(timeout), &deadline)
      while !self.pendingWakeup {
        if pthread_cond_timedwait(self.condition, self.mutex, &deadline) == ETIMEDOUT {
          break
        }
      }
      self.pendingWakeup = false
    }
  }

  /// Wakes a `whenReady` in progress (or the next one). Callable from any thread.
  func wakeup() throws {
    pthread_mutex_lock(self.mutex)
    self.pendingWakeup = true
    pthread_cond_signal(self.condition)
    pthread_mutex_unlock(self.mutex)
  }

  /// A duration as whole nanoseconds, saturating at `Int64.max`.
  private static func nanoseconds(_ duration: Duration) -> Int64 {
    let (seconds, secondsOverflow) = duration.components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    if secondsOverflow { return .max }
    let nanoseconds = duration.components.attoseconds / 1_000_000_000
    let (total, totalOverflow) = seconds.addingReportingOverflow(nanoseconds)
    return totalOverflow ? .max : total
  }
}
#endif

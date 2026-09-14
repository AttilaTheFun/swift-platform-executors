//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#ifndef C_PLATFORM_EXECUTORS_H
#define C_PLATFORM_EXECUTORS_H

#ifdef __linux__
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <pthread.h>
#include <errno.h>

int CPlatformExecutors_pthread_setname_np(pthread_t thread, const char *name);
int CPlatformExecutors_pthread_getname_np(pthread_t thread, char *name, size_t len);

#endif

#ifndef __wasi__
#include <dlfcn.h>
#endif

#ifdef __wasi__
// wasm32-unknown-wasip1-threads: wasi-libc maps pthread_create onto
// wasi_thread_spawn. The pieces Swift cannot express directly live here.
#include <pthread.h>
#include <stddef.h>
#include <time.h>

// Creates a thread with an explicit stack: wasi-libc's default thread stack
// is small and there is no guard page on wasm, so an executor thread gets a
// 4 MiB stack of its own.
int CPlatformExecutors_wasi_pthread_create(pthread_t *thread, void *(*start)(void *), void *arg);

// An absolute CLOCK_REALTIME deadline `nanoseconds` from now, for
// pthread_cond_timedwait (CLOCK_REALTIME is a pointer macro in wasi-libc,
// which Swift cannot import). Saturates instead of overflowing.
void CPlatformExecutors_wasi_deadline(long long nanoseconds, struct timespec *deadline);

// The thread-name calls, by the same names the Linux shims use (no-ops:
// wasi-libc declares but does not define them).
int CPlatformExecutors_pthread_setname_np(pthread_t thread, const char *name);
int CPlatformExecutors_pthread_getname_np(pthread_t thread, char *name, size_t len);
#endif

#ifdef __APPLE__

// Export RTLD_NEXT constant for Swift
static void* const CPlatformExecutors_RTLD_NEXT = RTLD_NEXT;

// Only essential functions that cannot be implemented in Swift
void CPlatformExecutors_dispatchMain(void) __attribute__((noreturn));

#endif

#endif // C_PLATFORM_EXECUTORS_H

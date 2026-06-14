//
//  GPUThread.swift
//  SwiftLMBackend
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//
//  Pins all MLX GPU work to one dedicated OS thread.
//
//  mlx 0.32 stores Metal command encoders in thread-local storage: an encoder
//  is created only on the OS thread that first runs GPU work for a stream
//  (mlx core backend/metal/eval.cpp try_emplace), and get_command_encoder
//  throws "There is no Stream(gpu, 0) in current thread" when the calling
//  thread has no encoder (backend/metal/device.cpp). eval() and the model
//  forward both run synchronously on the caller's thread, so every forward and
//  eval for one model must run on the SAME pthread. Running the model load and
//  every generation step under this executor makes the encoder be created once
//  on this thread (during model launch) and reused by every later step.
//
//  This is a real `Thread`, not a serial `DispatchQueue`: GCD may rebind a
//  serial queue to different pthreads between submissions, which would silently
//  reintroduce the thread-local-encoder mismatch.
//
//  This is a copy of the embedding host's `GPUThread` (Sources/lmd-model-host).
//  The two live in different modules (`SwiftLMBackend` cannot import the
//  `lmd-model-host` executable target), so the small type is duplicated rather
//  than shared. The MLX video backend owns one of these so that its load,
//  vision/prefill forward, and the whole token-generation loop all run on the
//  one thread; the upstream async-stream generate path spawns its own inner
//  `Task` for the token loop, which does not inherit a task-executor preference,
//  so the backend drives a synchronous loop through `run` instead.
//

import Foundation

/// A `TaskExecutor` backed by a single, fixed OS thread.
///
/// Code run under `withTaskExecutorPreference(gpuThread) { ... }` executes its
/// non-isolated async work, and the synchronous MLX calls inside it, on this
/// one thread, so thread-local GPU state created by the first job is visible to
/// every later job. `run` additionally lets callers drive a fully synchronous
/// closure on the thread, which is required for the generation loop because the
/// upstream `AsyncStream`-based generate spawns an inner `Task` that escapes any
/// task-executor preference.
public final class GPUThread: TaskExecutor, @unchecked Sendable {
  private let condition = NSCondition()
  private var jobs: [UnownedJob] = []

  public init(name: String = "io.goodkind.lmd.gpu") {
    // The worker is owned by its own running execution and the infinite run
    // loop, so it does not need to be stored on the instance.
    let worker = Thread { [weak self] in
      self?.runLoop()
    }
    worker.name = name
    worker.start()
  }

  public func enqueue(_ job: consuming ExecutorJob) {
    let unownedJob = UnownedJob(job)
    condition.lock()
    jobs.append(unownedJob)
    condition.signal()
    condition.unlock()
  }

  private func runLoop() {
    let executor = asUnownedTaskExecutor()
    while true {
      condition.lock()
      while jobs.isEmpty {
        condition.wait()
      }
      let job = jobs.removeFirst()
      condition.unlock()
      job.runSynchronously(on: executor)
    }
  }
}

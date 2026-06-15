//
//  GPUThread.swift
//  lmd-model-host
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
//  forward both run synchronously on the caller's thread, so every embedding
//  forward and eval must run on the SAME pthread. The embedding host otherwise
//  runs GPU work on Swift cooperative-pool threads that differ per request, so
//  the second request faults. Running the backend under this executor makes the
//  encoder be created once on this thread (during model launch) and reused by
//  every later request.
//
//  This is a real `Thread`, not a serial `DispatchQueue`: GCD may rebind a
//  serial queue to different pthreads between submissions, which would silently
//  reintroduce the thread-local-encoder mismatch.
//

import Foundation

/// A `TaskExecutor` backed by a single, fixed OS thread.
///
/// Code run under `withTaskExecutorPreference(gpuThread) { ... }` executes its
/// non-isolated async work, and the synchronous MLX calls inside it, on this
/// one thread, so thread-local GPU state created by the first job is visible to
/// every later job.
final class GPUThread: TaskExecutor, @unchecked Sendable {
  private let condition = NSCondition()
  private var jobs: [UnownedJob] = []

  init(name: String = "io.goodkind.lmd.gpu") {
    // The worker is owned by its own running execution and the infinite run
    // loop, so it does not need to be stored on the instance.
    let worker = Thread { [weak self] in
      self?.runLoop()
    }
    worker.name = name
    worker.start()
  }

  func enqueue(_ job: consuming ExecutorJob) {
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

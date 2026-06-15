//
//  MLXVLMVideoBackend.swift
//  SwiftLMBackend
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-09.
//  Copyright © 2026, all rights reserved.
//

import AppLogger
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

private let videoLog = AppLogger.logger(category: "MLXVLMVideoBackend")

/// In-process VLM video generation backed by mlx-swift-lm.
///
/// The backend intentionally passes video files as ``UserInput.Video.url`` through
/// ``Chat.Message`` so model-specific processors own video decoding, temporal
/// sampling, and prompt preparation. Request-side `fps` and `max_frames` values
/// are validated and preserved for observability, but the current Swift Qwen
/// processors in upstream `mlx-swift-lm` still choose their own sampling policy.
public actor MLXVLMVideoBackend {
  public let model: MLXVLMVideoModelDescriptor
  private var container: ModelContainer?
  // mlx 0.32 keeps Metal command encoders in thread-local storage, so the model
  // load, the vision/prefill forward, and every generation step must run on one
  // fixed OS thread or a later eval faults with "no Stream(gpu, 0) in current
  // thread". A synchronous `TokenIterator` loop driven under this executor keeps
  // every step on the one thread, because a bare `Task` for the token loop would
  // not inherit the task-executor preference. See ``GPUThread``.
  private let gpuThread = GPUThread(name: "io.goodkind.lmd.gpu.video")

  public init(model: MLXVLMVideoModelDescriptor) {
    self.model = model
  }

  /// Load the MLX VLM model into this process. The container load runs on the
  /// GPU thread so the model's first encoder is created there, matching every
  /// later forward and generation step.
  public func load() async throws {
    if container != nil {
      return
    }
    container = try await withTaskExecutorPreference(gpuThread) {
      try await VLMModelFactory.shared.loadContainer(
        from: self.model.directoryURL,
        using: #huggingFaceTokenizerLoader()
      )
    }
    videoLog.notice(
      "vlm_video.model_loaded model=\(self.model.id, privacy: .public) path=\(self.model.path, privacy: .public)"
    )
  }

  /// Release the in-process model container.
  public func shutdown() {
    container = nil
    videoLog.notice("vlm_video.model_unloaded model=\(self.model.id, privacy: .public)")
  }

  /// Generate one non-streaming OpenAI-compatible assistant response.
  public func complete(
    _ request: MLXVLMVideoCompletionRequest
  ) async throws -> MLXVLMVideoChatCompletionResponse {
    var content = ""
    var completionInfo: MLXVLMVideoCompletionInfo?
    for try await event in try await stream(request) {
      switch event {
      case .chunk(let text):
        content += text
      case .info(let info):
        completionInfo = info
      }
    }
    let metadata = MLXVLMVideoMetadata(request: request)
    videoLog.notice(
      "vlm_video.completion_finished model=\(self.model.id, privacy: .public) videos=\(metadata.videoCount, privacy: .public) max_tokens=\(request.maxTokens, privacy: .public)"
    )
    return MLXVLMVideoChatCompletionResponse(
      model: model.id,
      content: content,
      metadata: metadata,
      completionInfo: completionInfo
    )
  }

  /// Generate an OpenAI-compatible assistant response as a stream of events,
  /// one `.chunk` per detokenized step followed by a single `.info`. Each chunk
  /// is yielded from inside the generation loop on the GPU thread, so a caller
  /// iterating this stream receives a token's text the moment that token is
  /// decoded. The yielded values are plain `String`s and a value-type info, so
  /// the consuming task touches no MLX state; only the per-chunk text crosses
  /// from the GPU thread to the consumer through the stream's continuation.
  public func stream(
    _ request: MLXVLMVideoCompletionRequest
  ) async throws -> AsyncThrowingStream<MLXVLMVideoGenerationEvent, Error> {
    try request.validate()
    try await load()
    return AsyncThrowingStream<MLXVLMVideoGenerationEvent, Error> { continuation in
      // This task only awaits the actor-isolated generation; the GPU steps run
      // under `withTaskExecutorPreference(gpuThread)` inside `generate`. The
      // per-chunk `continuation.yield` is a synchronous enqueue onto the
      // stream's buffer, so invoking it from the GPU thread hands the text to
      // the consumer without moving any GPU step off that thread.
      let task = Task {
        do {
          let completionInfo = try await self.generate(request) { chunk in
            continuation.yield(.chunk(chunk))
          }
          videoLog.notice(
            "vlm_video.generation_finished generated=\(completionInfo.generatedCount, privacy: .public) prompt_s=\(String(format: "%.2f", completionInfo.promptTime), privacy: .public) generate_s=\(String(format: "%.2f", completionInfo.generateTime), privacy: .public) finish=\(completionInfo.finishReason, privacy: .public)"
          )
          continuation.yield(.info(completionInfo))
          continuation.finish()
        } catch {
          videoLog.error(
            "vlm_video.generation_failed model=\(self.model.id, privacy: .public) err=\(error, privacy: .public)"
          )
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  /// Run prompt preparation and the whole token generation loop synchronously on
  /// the single GPU thread, invoking `emit` with each detokenized chunk and
  /// returning completion info. The caller validates the request and loads the
  /// model before invoking this.
  ///
  /// Every MLX call happens inside the `withTaskExecutorPreference(gpuThread)`
  /// scope: `container.prepare` (the vision/prefill forward), `container.perform`
  /// (which builds the `TokenIterator`, runs prefill, and steps every token),
  /// and the final readback. The token loop is a plain `for` over a synchronous
  /// `TokenIterator`, so no inner `Task`, `actor` hop, or `AsyncStream`
  /// continuation moves an `eval` off this thread. `emit` runs inline on the GPU
  /// thread for each chunk, so a streaming caller's `continuation.yield` enqueues
  /// the chunk from this thread.
  private func generate(
    _ request: MLXVLMVideoCompletionRequest,
    emit: @escaping @Sendable (String) -> Void
  ) async throws -> MLXVLMVideoCompletionInfo {
    guard let container else {
      throw MLXVLMVideoBackendError.modelNotLoaded(modelID: model.id)
    }

    let parameters = GenerateParameters(
      maxTokens: request.maxTokens,
      temperature: request.temperature
    )

    return try await withTaskExecutorPreference(gpuThread) {
      // Build the non-Sendable `UserInput` inside this isolation region so it is
      // created and consumed on the GPU thread without crossing back to the
      // actor; `request` is value-type and `@unchecked Sendable`.
      let userInput = request.makeUserInput()
      let preparedInput = try await container.prepare(input: userInput)
      // `LMInput` is non-Sendable, so it must cross into the `perform` body via
      // the non-Sendable overload. The `perform` closure runs inside the
      // container's serial lock on this task's executor (the GPU thread), so the
      // whole generation loop stays on the one thread.
      return try await container.perform(nonSendable: preparedInput) { context, input in
        try Self.runGenerationLoop(
          input: input,
          parameters: parameters,
          context: context,
          emit: emit
        )
      }
    }
  }

  /// Drive the synchronous token loop and detokenizer entirely on the calling
  /// thread (the GPU thread), invoking `emit` inline with each detokenized
  /// chunk. The synchronous `TokenIterator` keeps every `eval` on this thread,
  /// and `emit` runs in the loop body on this thread, so the chunk reaches the
  /// caller as soon as the token decodes.
  private static func runGenerationLoop(
    input: LMInput,
    parameters: GenerateParameters,
    context: ModelContext,
    emit: (String) -> Void
  ) throws -> MLXVLMVideoCompletionInfo {
    var iterator = try TokenIterator(
      input: input, model: context.model, parameters: parameters)
    let promptTokenCount = input.text.tokens.size

    let stopTokenIds = buildStopTokenIds(
      modelConfiguration: context.configuration,
      tokenizer: context.tokenizer
    )

    var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
    var generationTokenCount = 0
    var stopReason: GenerateStopReason = .cancelled

    // `TokenIterator.promptPrefillTime` is internal to MLXLMCommon, so prompt
    // time is the wall time of the first `next()`, which returns the
    // prompt-primed first token. Subsequent `next()` calls accrue to generation
    // time.
    var start = Date.timeIntervalSinceReferenceDate
    var promptTime: TimeInterval = 0
    loop: while true {
      if let maxTokens = parameters.maxTokens, generationTokenCount >= maxTokens {
        stopReason = .length
        break loop
      }
      guard let token = iterator.next() else {
        if let maxTokens = parameters.maxTokens, generationTokenCount >= maxTokens {
          stopReason = .length
        }
        break loop
      }
      if promptTime == 0 {
        let now = Date.timeIntervalSinceReferenceDate
        promptTime = now - start
        start = now
      }
      if token == context.tokenizer.unknownTokenId || stopTokenIds.contains(token) {
        stopReason = .stop
        break loop
      }
      generationTokenCount += 1
      detokenizer.append(token: token)
      if let chunk = detokenizer.next() {
        emit(chunk)
      }
    }
    let generationTime = Date.timeIntervalSinceReferenceDate - start

    // TokenIterator uses asyncEval() to keep the pipeline full; drain it on this
    // thread before returning so no eval lands on another thread later.
    Stream().synchronize()

    let finishReason = MLXVLMVideoCompletionInfo.finishReason(stopReason: stopReason)
    return MLXVLMVideoCompletionInfo(
      promptTokenCount: promptTokenCount,
      generationTokenCount: generationTokenCount,
      promptTime: promptTime,
      generateTime: generationTime,
      finishReason: finishReason
    )
  }
}

/// EOS token set assembled from the model configuration and tokenizer. A token
/// in this set ends generation.
private func buildStopTokenIds(
  modelConfiguration: ModelConfiguration,
  tokenizer: MLXLMCommon.Tokenizer
) -> Set<Int> {
  var stopTokenIds = modelConfiguration.eosTokenIds
  if let tokenizerEOS = tokenizer.eosTokenId {
    stopTokenIds.insert(tokenizerEOS)
  }
  for token in modelConfiguration.extraEOSTokens {
    if let id = tokenizer.convertTokenToId(token) {
      stopTokenIds.insert(id)
    }
  }
  return stopTokenIds
}

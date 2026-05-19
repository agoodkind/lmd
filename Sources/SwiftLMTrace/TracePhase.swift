//
//  TracePhase.swift
//  SwiftLMTrace
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-05-18.
//  Copyright © 2026
//
//  Phase string constants for the BackendTrace plane.
//
//  Phases are namespaced by backend kind so naming stays specific
//  without leaking into other kinds. All phases ultimately reduce to a
//  raw String for the `phase=` field on a trace line.
//

import Foundation

public enum TracePhase {
  // Shared lifecycle phases for backends that match the same shape.
  public enum Common: String, Sendable {
    case spawnBegin = "spawn_begin"
    case shutdownPre = "shutdown_pre"
    case tick
  }

  // MLX-resident embedding backend phases.
  public enum Embedding: String, Sendable {
    // Lifecycle
    case spawnBegin = "spawn_begin"
    case spawnConfigParsed = "spawn_config_parsed"
    case spawnModelConstructed = "spawn_model_constructed"
    case spawnWeightsLoaded = "spawn_weights_loaded"
    case spawnTokenizerLoaded = "spawn_tokenizer_loaded"
    case spawnRuntimeReady = "spawn_runtime_ready"
    case shutdownPre = "shutdown_pre"
    case shutdownRuntimeNil = "shutdown_runtime_nil"
    case shutdownPostClearCache = "shutdown_post_clear_cache"
    // Per-request
    case requestPreTokenize = "request_pre_tokenize"
    case requestPostTokenize = "request_post_tokenize"
    case requestPreForward = "request_pre_forward"
    case requestPostForward = "request_post_forward"
    case requestPostPool = "request_post_pool"
    case requestPostEval = "request_post_eval"
    case requestPreReturn = "request_pre_return"
  }

  // Subprocess-based chat backends and any future in-process chat path.
  public enum Chat: String, Sendable {
    // Lifecycle
    case spawnBegin = "spawn_begin"
    case spawnProcessStarted = "spawn_process_started"
    case spawnHealthOk = "spawn_health_ok"
    case spawnReady = "spawn_ready"
    case shutdownPre = "shutdown_pre"
    case shutdownSignaled = "shutdown_signaled"
    case shutdownTerminated = "shutdown_terminated"
    // Per-request
    case requestPrePrompt = "request_pre_prompt"
    case requestPostPrompt = "request_post_prompt"
    case requestPreGenerate = "request_pre_generate"
    case requestPostFirstToken = "request_post_first_token"
    case requestPostGenerate = "request_post_generate"
    case requestPreReturn = "request_pre_return"
  }

  // VLM/video backends with frame ingestion plus generation.
  public enum Video: String, Sendable {
    // Lifecycle
    case spawnBegin = "spawn_begin"
    case spawnContainerLoaded = "spawn_container_loaded"
    case spawnReady = "spawn_ready"
    case shutdownPre = "shutdown_pre"
    case shutdownRuntimeNil = "shutdown_runtime_nil"
    case shutdownPostClearCache = "shutdown_post_clear_cache"
    // Per-request
    case requestPreFrames = "request_pre_frames"
    case requestPostFrames = "request_post_frames"
    case requestPreGenerate = "request_pre_generate"
    case requestPostGenerate = "request_post_generate"
    case requestPreReturn = "request_pre_return"
  }

  // Router-side phases. The router's existing functional logs stay in
  // their current category; these are the BackendTrace mirrors.
  public enum Router: String, Sendable {
    case routeBegin = "router_route_begin"
    case routeEnd = "router_route_end"
    case modelSpawned = "router_model_spawned"
    case modelEvicted = "router_model_evicted"
    case modelUnloaded = "router_model_unloaded"
    case requestDone = "router_request_done"
    case embeddingSpawned = "router_embedding_spawned"
    case embeddingRequestDone = "router_embedding_request_done"
    case embeddingUnloaded = "router_embedding_unloaded"
    case embeddingEvicted = "router_embedding_evicted"
  }

  // Broker request boundaries, kind-agnostic.
  public enum Broker: String, Sendable {
    case requestReceived = "request_received"
    case requestRouted = "request_routed"
    case requestDoneAck = "request_done_ack"
    case requestResponseSent = "request_response_sent"
    case requestStarted = "request_started"
    case requestCompleted = "request_completed"
    case requestFailed = "request_failed"
  }
}

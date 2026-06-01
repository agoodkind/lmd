# Video routing

`lmd` accepts OpenAI-style `video_url` content parts on `POST /v1/chat/completions`, decodes the referenced file into a frame array inside the route, and passes the frame array to the MLX VLM backend through `UserInput.Video.frames([VideoFrame])`. The MLX backend owns model inference; `lmd` owns request acceptance, validation, frame extraction, and routing.

## Request shape

The route accepts the OpenAI multimodal chat shape:

```json
{
  "model": "mlx-community/Qwen2.5-VL-32B-Instruct-4bit",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "Describe the visible motion." },
        {
          "type": "video_url",
          "video_url": {
            "url": "file:///absolute/path/to/clip.mp4"
          }
        }
      ]
    }
  ],
  "stream": false
}
```

`video_url.fps` and `video_url.max_frames` are accepted as request hints. They cap the sampling pass; the canonical sampling rate is the model's declared `videoSamplingFPS`.

## Validation at the route boundary

`lmd` validates every `video_url` request before dispatching. The route checks that `video_url.url` is present, that the URL is a valid absolute `file://` URL, that the host is empty or `localhost`, that the file exists, that the file is readable, that the file is a regular file, and that the file extension is one of the supported video extensions. A failed check produces a structured JSON error response.

## Routing

Text-only requests stay on the text route. A video request routes to the MLX video backend only when the model descriptor advertises `capabilities.video == true`. A video request against a model that does not advertise video capability returns a structured JSON error. A video request against a model that advertises video but has no `videoSamplingFPS` returns a structured JSON error. Streaming video chat is rejected when the active backend cannot support it. Any failure inside the route produces a structured JSON response or JSON error; the route never closes the TCP connection with an empty reply.

## Frame extraction in `lmd`

For each accepted `video_url`, `lmd` reads the file with `AVURLAsset`, computes a frame count from the model's declared `videoSamplingFPS` and the asset duration, and walks `AVAssetImageGenerator` with `requestedTimeToleranceBefore` and `requestedTimeToleranceAfter` set to `.positiveInfinity` so that AVFoundation returns the nearest available frame for each requested time rather than failing on an exact PTS mismatch. Each generated `CGImage` is wrapped in `CIImage` with an sRGB colorspace and packed into `UserInput.VideoFrame(frame:timeStamp:)`. The route hands the resulting array to the backend through `UserInput.Video.frames`.

The relevant upstream surfaces are `UserInput.Video.frames([VideoFrame])` in `MLXLMCommon/UserInput.swift` and `MediaProcessing.asProcessedSequence(_ videoFrames: [VideoFrame], ...)` in `MLXVLM/MediaProcessing.swift`, both shipped by mlx-swift-lm PR #64 (merged 2026-01-26). The local package manifests currently track the `john-rocky/mlx-swift-lm` `feat/gemma4-video` branch while `ml-explore/mlx-swift-lm#256` remains open.

## Per-model sampling rate

Each video-capable model declares the FPS its preprocessor expects through `ModelCapabilities.videoSamplingFPS`. The catalog populates the field during capability inference:

- Qwen2-VL, Qwen2.5-VL, Qwen3-VL: `2.0` (matches the hardcoded value in the upstream MLX Swift processors).
- SmolVLM2: parsed from `preprocessor_config.json`, default `2.0`.
- Gemma 4 video: parsed from `processor_config.json` under `video_fps`, default `2.0`, placeholder until PR #256 lands.

The route uses the declared value as the canonical sampling rate. Request-side `fps` caps the sampling rate downward when present. Request-side `max_frames` caps the resulting frame count.

## Implementation constraints

The video route stays in Swift. No Python, no shell-script driver inside `lmd`, no source changes to `mlx-swift-lm`. The frame extractor uses AVFoundation, which ships with macOS, so no package changes are required. The OpenAI-compatible `video_url` request shape is the only accepted shape. New routing logic uses `localhost` or `[::1]`, never an IPv4 literal.

## Response shape

The route returns a standard OpenAI chat completion envelope. The `metadata` block reports `video_count`, `requested_fps`, `requested_max_frames`, `sampled_fps`, `sampled_frame_count`, and the resolved model id, so a caller can verify which sampling rate was applied.

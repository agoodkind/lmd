# LMD Video Routing Final Decision

Status: planned only, not yet executed as an authoritative implementation plan

## Objective

Add video support to `lmd` by routing OpenAI-style `video_url` requests to an
MLX-backed video-capable model backend.

`lmd` is a router. It is not the video understanding layer. It must not decode,
retime, expand, slow down, or sample video frames itself.

## Final Product Decision

`lmd` remains dumb to video semantics.

The accepted behavior is:

- `lmd` accepts `video_url` request content for models that advertise
  `capabilities.video == true`.
- `lmd` validates that the supplied URL is a local file with a supported video
  extension.
- `lmd` forwards that file reference into the backend runtime unchanged.
- The backend runtime owns video decoding, temporal sampling, frame selection,
  and prompt preparation.
- `lmd` does not implement any workaround for backend temporal limitations.
- `lmd` does not add preprocessing such as frame extraction, optical flow,
  diffing, retiming, or slow-motion expansion.

The user-facing claim is:

- `lmd` supports video routing.

The user-facing non-claim is:

- `lmd` does not currently guarantee high-fidelity subtle-animation analysis.

## Non-Negotiable Constraints

- Swift only.
- No Python.
- No shell-script-based implementation.
- No `mlx-swift-lm` source changes.
- No LMD-side video decoding.
- No LMD-side frame dropping or frame amplification.
- No IPv4 host usage in new logic. Use `localhost` or `[::1]`.
- Keep the OpenAI-compatible `video_url` request shape.

## Backend Semantics

Current backend semantics must be treated as backend-defined, not LMD-defined.

For the current Swift Qwen video path in upstream `mlx-swift-lm`:

- Qwen video processors sample at `2 FPS`.
- This means the backend drops most source frames before the model sees them.
- This is a backend limitation, not an LMD routing policy.

`lmd` may preserve request-side fields such as `fps` and `max_frames` for
observability, but it must not imply that LMD enforces them.

## Required Runtime Behavior

### Request acceptance

Accept this shape:

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

Optional request-side video metadata may be accepted if already supported by the
route parser:

- `video_url.fps`
- `video_url.max_frames`

These are request hints and metadata only unless the backend explicitly honors
them.

### Validation

Validation belongs to `lmd` at the request boundary:

- `video_url.url` must be present.
- `video_url.url` must be a valid absolute file URL.
- Host must be empty or `localhost`.
- File must exist.
- File must be readable.
- File must be a regular file.
- Extension must be one of the supported video extensions.

### Routing

- Text-only requests stay on the normal text route.
- Video requests route only when `descriptor.capabilities.video == true`.
- Streaming video chat is rejected if the current backend cannot support it.
- `lmd` returns structured JSON errors for unsupported model capability or bad
  request shape.

## Required Metadata Contract

Any metadata returned by the LMD video backend must clearly state the boundary:

- `backend_owns_temporal_sampling: true`
- `sampling_parameters_applied: false` unless proven otherwise
- `requested_fps` and `requested_max_frames` may be echoed back as request
  metadata
- `sampling_parameter_note` must state that temporal sampling is backend-owned
  and that the current Swift Qwen processors sample at `2 FPS`

The metadata must not imply:

- full-frame coverage
- native-FPS coverage
- LMD-owned frame control
- subtle-animation suitability

## Acceptance Criteria

The plan is complete only when all of the following are true:

1. `GET /v1/models` exposes correct `capabilities.video` values for video-capable
   models.
2. `POST /v1/chat/completions` with `video_url` routes through the LMD video
   backend path for those models.
3. The route returns a structured JSON response or a structured JSON error.
4. The route does not tear down the HTTP connection with an empty reply.
5. LMD-side metadata and docs describe backend-owned semantics honestly.
6. No LMD-side frame extraction or timing manipulation is introduced.

## Current Stop Point

This is where execution stopped.

The route-level smoke test against the existing broker and the single-frame video
file proves that the current path is not ready yet.

Proven current stop point:

- Broker: launchd-owned `lmd-serve` on `localhost:5400`
- Video-capable model advertised by `/v1/models`:
  `mlx-community/Qwen2.5-VL-32B-Instruct-4bit`
- Test video:
  `/Users/agoodkind/Sites/lmd/red_12x12_1f.mp4`
- Result of `POST /v1/chat/completions` with `video_url`:
  the client receives `curl: (52) Empty reply from server`

Control evidence:

- A text-only request to a normal text model succeeds with `200 OK`.
- A text-only request to the Qwen2.5-VL model returns a structured `503
  launch_failed`.
- The `video_url` path is the one that currently breaks the request flow.

This means the next execution step is not product design. It is runtime
stabilization of the existing video route so that `video_url` requests produce a
JSON response or JSON error instead of an empty connection close.

## Next Execution Work

The next implementation pass must be scoped to these items only:

1. Reproduce the `video_url` failure on the live broker using the single-frame
   test video.
2. Trace the exact failure point in the existing video route:
   request parse, backend request build, model load, MLX backend invocation, or
   response encoding.
3. Make the route fail structurally:
   return a JSON error response instead of an empty reply if backend startup,
   backend invocation, or model load fails.
4. Preserve the final boundary:
   no LMD-side video preprocessing and no `mlx-swift-lm` changes.

## Verification Bundle

Any future implementation against this plan must verify with:

- `make build`
- `make test`
- `make log-audit`
- a live `video_url` smoke request using
  `/Users/agoodkind/Sites/lmd/red_12x12_1f.mp4`

The smoke result must show one of:

- a valid JSON completion response
- a valid JSON error response

An empty TCP reply is a failing result.

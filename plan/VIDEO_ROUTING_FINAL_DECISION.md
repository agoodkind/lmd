# Video routing

`lmd` accepts OpenAI-style `video_url` content parts on `POST /v1/chat/completions` and forwards the referenced file to the MLX video backend without inspection or transformation. The MLX backend owns video understanding; `lmd` owns request acceptance, validation, and routing.

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

`video_url.fps` and `video_url.max_frames` are accepted as request hints. They are echoed back as response metadata and do not constrain backend behavior.

## Validation at the route boundary

`lmd` validates every `video_url` request before dispatching, so backend startup is never wasted on a malformed reference. The route checks that `video_url.url` is present, that the URL is a valid absolute `file://` URL, that the host is empty or `localhost`, that the file exists, that the file is readable, that the file is a regular file, and that the file extension is one of the supported video extensions. A failed check produces a structured JSON error response.

## Routing

Text-only requests stay on the text route. A video request routes to the MLX video backend only when the model descriptor advertises `capabilities.video == true`. A video request against a model that does not advertise video capability returns a structured JSON error. Streaming video chat is rejected when the active backend cannot support it. Any failure inside the route produces a structured JSON response or JSON error; the route never closes the TCP connection with an empty reply.

## Backend ownership

The MLX backend owns video decoding, temporal sampling, frame selection, and prompt preparation. `lmd` does not decode video, sample frames, retime clips, or transform content. The current Swift Qwen video processors in `mlx-swift-lm` sample at 2 FPS and drop most source frames before the model sees them; that is backend behavior reported honestly through the metadata contract below.

## Implementation constraints

The video route stays in Swift. No Python, no shell-script driver inside `lmd`, and no source changes to `mlx-swift-lm`. No frame extraction, optical flow, diffing, retiming, or slow-motion expansion runs inside `lmd`. New routing logic uses `localhost` or `[::1]`, never an IPv4 literal. The OpenAI-compatible `video_url` request shape is the only accepted shape.

## Metadata contract

Responses from the video route declare the ownership boundary explicitly:

- `backend_owns_temporal_sampling: true`
- `sampling_parameters_applied: false` unless the backend explicitly applied them
- `requested_fps` and `requested_max_frames` echo the request values when present
- `sampling_parameter_note` states that temporal sampling is backend-owned and that the current Qwen processors sample at 2 FPS

Response metadata does not imply full-frame coverage, native-FPS coverage, `lmd`-owned frame control, or subtle-animation suitability.

## User-facing claim

`lmd` supports video routing. `lmd` does not claim high-fidelity subtle-animation analysis.

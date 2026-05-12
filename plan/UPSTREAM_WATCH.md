# Upstream watch list

Open upstream items that change `lmd`'s near-term plans when they land.

## Gemma 4 video tower in mlx-swift-lm (PR #256)

`ml-explore/mlx-swift-lm#256` adds Gemma 4 video tower support. It introduces a configurable `Gemma4ProcessorConfiguration.video_fps` field and the first VLM in mlx-swift-lm where video FPS is a first-class processor field rather than a hardcoded constant. The PR is verified on iPhone 17 Pro at 42.53 tok/s decode against `mlx-community/gemma-4-e2b-it-4bit` on an 8-second clip.

When this PR merges and a `mlx-community` Gemma 4 quant is published, swap the default smoke model to Gemma 4 video by updating `ModelCatalog.swift`'s `gemma4VideoSamplingFPS(...)` to parse the real `video_fps` value from the published `processor_config.json`, and add an integration test that runs the smoke against the new model. The current catalog logic already detects `gemma4*` model types and falls back to a 2.0 default, so the catalog entry will work the moment a quant lands.

Check command:

```bash
gh pr view 256 --repo ml-explore/mlx-swift-lm --json state,mergedAt,updatedAt,reviewDecision
```

Hugging Face quant check:

```bash
curl -s 'https://huggingface.co/api/models?search=mlx-community/gemma-4' | jq '.[].modelId'
```

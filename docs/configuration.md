# Broker configuration

`lmd-serve` reads its configuration once at startup through a single typed seam
(`BrokerConfig` in `Sources/LMDServeSupport/BrokerConfig.swift`), backed by the
launchd plist's `EnvironmentVariables`. There are no silent code defaults: every
key below must be defined, and a missing or unparseable value is a named startup
error rather than a guessed fallback. The values ship in
`deploy/io.goodkind.lmd.serve.plist.example`; copy it to
`~/Library/LaunchAgents/` (or run `make install`) and edit the values there.

Swapping the env-backed source for a file-backed one later is a one-line change
at the single construction site in `SwiftLMD.main` (provide a different
`BrokerConfigSource`); no consumer code reads the environment directly.

## Keys

Every key in this table corresponds to a `BrokerConfigKey` case, the canonical
registry the plist and this doc are checked against.

| Key | Type | Validity | Example | Meaning |
| --- | --- | --- | --- | --- |
| `LMD_HOST` | string | `localhost` or `[::1]` | `localhost` | Interface the HTTP broker binds. |
| `LMD_PORT` | int | 1..65535 | `5400` | TCP port for the OpenAI-compatible API. |
| `LMD_RESERVE_GB` | int | >= 0 | `20` | System memory kept free; a model load is admitted only if this much remains. |
| `LMD_SWIFTLM_BINARY` | path | non-empty, executable | `/Users/you/Sites/SwiftLM/.build/arm64-apple-macosx/release/SwiftLM` | The SwiftLM model-runner binary the broker spawns. |
| `LMD_CHAT_MAX_CONCURRENCY` | int | >= 1 | `4` | Max concurrent chat requests per loaded model; excess requests queue for a slot rather than getting a 429. |
| `LMD_EMBEDDING_MAX_CONCURRENCY` | int | >= 1 | `4` | Max concurrent embedding requests per loaded model; excess requests queue for a slot rather than getting a 429. |
| `LMD_BATTERY_THROTTLE_PCT` | int | 0..100 | `20` | Battery charge at or below which the hard stop engages: new chat and embedding requests are refused with HTTP 503 while in-flight requests drain. Held until `LMD_BATTERY_RESUME_PCT`. `0` disables the monitor. |
| `LMD_BATTERY_MILD_PCT` | int | 0..100, and `> LMD_BATTERY_THROTTLE_PCT` and `< LMD_BATTERY_RESUME_PCT` | `35` | Battery charge at or below which the mild embedding slow-down engages. A plain band with no hold: it applies between this value and `LMD_BATTERY_THROTTLE_PCT`, and turns off above it. |
| `LMD_BATTERY_RESUME_PCT` | int | 0..100 | `80` | Battery charge at or above which the hard stop releases (a wide band so the stop does not flap). |
| `LMD_DISABLE_XPC` | bool | `1/0`, `true/false`, `yes/no`, `on/off` | `0` | Disable the XPC control surface used by `lmd` and `lmd-tui`. |
| `LMD_IDLE_MINUTES` | int | >= 0 | `15` | Idle minutes before a chat model is unloaded. |
| `LMD_EMBEDDING_IDLE_MINUTES` | int | >= 0 | `60` | Idle minutes before an embedding model is unloaded. |
| `LMD_DATA_DIR` | path | non-empty | `/Users/you/Library/Application Support/io.goodkind.lmd` | Directory for sensor samples (`memory.jsonl`) and other broker data. |
| `LMD_SAMPLE_INTERVAL` | double | >= 0.1 | `15` | Seconds between sensor samples. |
| `LMD_PROMPT_CACHE_MAX_TOKENS` | int or blank | positive, or blank for auto | (blank) | Prompt-token ceiling for chat requests; blank lets the broker choose. |
| `LMD_PROMPT_CACHE_ENABLED` | bool | as above | `true` | Whether the prompt cache is enabled. |
| `LMD_MLX_CACHE_LIMIT_GB` | double | > 0 | `2` | MLX allocator cache cap for embedding backends (the throttle shrinks this under battery pressure). |

## Diagnostic switches

These are not part of the fail-fast config seam. They are read where they are
used and are normally unset (or `0`) in production.

| Key | Type | Meaning |
| --- | --- | --- |
| `LMD_TRACE_DISABLE_MLX_SNAPSHOT` | bool-ish | Set to `1` to skip live MLX memory snapshots, which avoids Metal initialization in environments (such as unit tests) where it would abort. Read at static initialization in `SwiftLMTrace`. |

## Provided by the system

| Key | Source | Meaning |
| --- | --- | --- |
| `XPC_SERVICE_NAME` | launchd | The Mach service identity; checked at startup, not operator configuration. |

# Phase 5: Grammar-constrained decoding in SwiftLM

**Scope**: this task lives in the [SwiftLM](https://github.com/SharpAI/SwiftLM)
project (a separate repo at `~/Sites/SwiftLM`), not in swiftbench. It is
documented here because swiftbench depends on the behavior via the
`JSONEnforcement` middleware in `SwiftLMRuntime`.

## Problem

Local MLX servers (including SwiftLM's `/v1/chat/completions`) accept
the OpenAI `response_format: {type: "json_object"}` and
`response_format: {type: "json_schema", schema: …}` parameters as
hints but do not enforce them at decode time. Our current workaround,
`injectJSONInstructionIfNeeded` in
`swiftbench/Sources/SwiftLMRuntime/JSONEnforcement.swift`, prompt-injects
a system message instructing the model to emit JSON. That lifts our
measured parse rate from ~50% to ~97% on qwen-coder. The residual
3% still fails in production runs and burns retry tokens.

Grammar-constrained decoding solves this by masking the logits at each
token step so the model **cannot** emit a non-grammar-matching token.
The result is 100% schema-valid output on models that can hit the
schema at all, without prompt injection at all.

## Approach

Adopt [llguidance](https://github.com/microsoft/llguidance) (MIT-licensed,
maintained by Microsoft) via its Rust FFI. llguidance takes a
`grammar` string (Lark-like or JSON schema) and returns an
[`LLGuidanceMatcher`](https://github.com/microsoft/llguidance/blob/main/docs/api.md)
that exposes `validTokensMask(...) -> BitSet` at each decoding step.
The SwiftLM sampler consults the mask before argmax / top-k.

### Step-by-step

1. **Vendor the Rust library.** Add `llguidance` as a git submodule or
   cargo crate in the SwiftLM repo. Build to a static `.a` with
   `cbindgen` generating the C header.

2. **Bridge to Swift.** Add `llguidance` as a
   `.binaryTarget` or `.systemLibrary` target in SwiftLM's
   `Package.swift`. Write a thin Swift wrapper `struct GrammarConstraint`
   that owns the opaque matcher handle and exposes:
       func mask(vocabSize: Int) -> MLXArray   // 0/1 per token id
       mutating func advance(token: Int32)
       var isAccepting: Bool { get }

3. **Intercept in the sampler.** SwiftLM's sampler in
   `Sources/SwiftLM/Generation/Sampler.swift` currently picks the
   next token via `argmax(probs)`. When a grammar is attached to the
   request, apply:
       let m = constraint.mask(vocabSize: vocab)
       logits = logits * m - (1 - m) * 1e9  // mask disallowed tokens
       let token = argmax(logits)
       constraint.advance(token: Int32(token))

4. **Wire the OpenAI parameter.** In SwiftLM's
   `Server.swift:handleChatCompletion`, read `response_format`. For
   `json_object`, build a permissive JSON grammar. For `json_schema`,
   compile `response_format.schema` to an llguidance grammar via
   `llg_json_schema_to_grammar`. Pass the resulting matcher to the
   sampler with each request.

5. **Fall-through for unknown formats.** If the grammar can't compile,
   return HTTP 400 with a clear `type: "grammar_error"` message
   instead of silently dropping the constraint. Otherwise
   `JSONEnforcement` in swiftbench will keep prompt-injecting and
   hide the bug.

### Checklist (for the SwiftLM PR)

- [ ] Add llguidance submodule + build target
- [ ] Swift wrapper (`GrammarConstraint` in `Sources/SwiftLM/Grammar/`)
- [ ] Sampler integration (`Sampler.swift` mask application)
- [ ] `/v1/chat/completions` reads `response_format` and attaches a
      matcher per request
- [ ] `response_format.json_schema.schema` → grammar compilation
- [ ] HTTP 400 on grammar-compile failure with `type: "grammar_error"`
- [ ] End-to-end test: send a request with `response_format:
      {type: "json_schema", schema: {type: "object"...}}`, assert
      100% valid JSON across N samples
- [ ] Perf impact measurement: decode tok/s with vs. without grammar
      (expected 5 to 15% slowdown on M-series; anything > 20% is a bug)

## Follow-up in swiftbench

Once SwiftLM gains grammar support:

- `JSONEnforcement.swift`'s prompt injection becomes a fallback for
  models behind non-SwiftLM endpoints (Anthropic, OpenAI Cloud via
  proxy, etc.). Move its logic into a `struct JSONEnforcement {
  enum Strategy { case grammarConstrained, promptInject } }` so the
  broker can pick per-backend.
- `docs/GRAMMAR.md` in the broker should point users at the supported
  `response_format` shapes.

## Rejected alternatives

- **Our own grammar engine.** llguidance is MIT-licensed, actively
  maintained by Microsoft, and already handles UTF-8 tokenization
  edge cases. Reinventing it is 6+ months of subtle bugs.
- **Regex-based masking at the sampler.** Works for simple grammars
  but does not compose for nested JSON schemas.
- **Retry-until-valid.** What `JSONEnforcement` does today. Wastes
  tokens; not guaranteed to converge.

# NAX accelerator kernels

lmd compiles the M5 GPU matrix-multiply accelerator (NAX) GEMM kernels ahead of time and loads those prebuilt kernels at runtime, because the macOS 26.5 Metal compiler miscompiles the runtime-compiled form. Without the prebuilt kernels, unquantized 16-bit models produce garbage output with no error, while the accelerator stays on the whole time.

## Why the prebuilt kernels exist

The accelerator's 16-bit matrix-multiply kernel is written against Apple's Metal 4 `mpp::tensor_ops`. On macOS 26.5 the Metal compiler miscompiles that kernel when it is compiled at runtime, so the result is NaN and the model emits token-salad. Compiling the same kernel source ahead of time from its `.metal` file is correct.

Quantized models are unaffected in practice: their matrix-multiply accumulates in float32 and their accelerator kernel is covered by the same prebuilt set. Only unquantized 16-bit weights (BF16 or FP16) surface the miscompile, and they do so silently.

## How the fix works

The build compiles the seven NAX kernels ahead of time with the flags that produce correct code: the host deployment target (`-mmacosx-version-min`), no `-std` override, and `-fno-fast-math`. Forcing `-std=metal4.0` or dropping the deployment target reproduces the wrong 16-bit result. `buildNaxAotLibraries` owns this compile and the exact flag set.

At runtime the accelerator loads a prebuilt kernel from a `nax/` directory beside the running binary, resolved from the binary's own location or from `LMD_AOT_LIB` when that is set. It loads a prebuilt kernel only for accelerator GEMM names, and any miss falls through to runtime compilation, so non-accelerator kernels and the float32 accelerator kernels are never perturbed. The loader prints `[nax-aot] kernel directory: <path>` once and `[nax-aot] <kernel> loaded from <file>` for each kernel it loads.

## Where the kernels live

Two processes need the prebuilt kernels, and each gets its own copy staged next to its binary at install.

- The in-process embedding and video hosts load from `<bin>/nax`. `buildNaxAotLibraries` builds these from lmd's `mlx-swift` and stages them through install and the release zip.
- The bundled SwiftLM chat binary loads from `<bin>/swiftlm/nax`. `build-swiftlm` builds these from SwiftLM's own `mlx-swift` submodule, so the chat kernels always match the MLX the chat binary links.

Both directories are additive: if the kernel source or the Metal compiler is absent, the directory stays empty and the runtime compiles the kernel itself, exactly as it did before.

## The accelerator stays enabled

The fix keeps the accelerator on. lmd never disables it, and correctness comes from the prebuilt kernels, not from routing 16-bit matrix-multiply off the accelerator. A per-process escape hatch (`MLX_RUNTIME_NO_NAX=1`) can force the non-accelerator path, but no lmd host sets it, and disabling the accelerator to work around the miscompile is out of scope. This constraint is deliberate: the forks exist to use the accelerator, and unquantized 16-bit embeddings run at float32 parity with it on.

## Verifying and diagnosing

Run an unquantized 16-bit chat model through the broker. A coherent reply, plus a `[nax-aot] ... loaded from steel_gemm_fused_nax.metallib` line in the SwiftLM log, confirms the prebuilt kernel path is active.

A regressed build shows the opposite: an unquantized 16-bit model returns garbage (repeated punctuation or unrelated tokens) with an HTTP 200 and no error, because the host silently compiled the miscompiled kernel at runtime. The usual cause is a missing or stale `nax/` directory beside the affected binary. Rebuild and reinstall so the current kernels stage next to the binary that loads them.

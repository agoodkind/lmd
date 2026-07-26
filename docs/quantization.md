# Embedding weight quantization

lmd loads embedding weights stored at 8 bits, which halves the resident footprint of the NV-EmbedCode model from about 14GB to about 7.4GB. A converter writes a quantized copy of an existing model, and the loader follows whatever precision the checkpoint on disk carries.

Quantizing changes the vectors the model produces, so it is only safe when those vectors still work against an index built from the previous weights. Format choice decides that, and the two 8-bit formats behave very differently.

## Choose affine, not MX FP8

Use `affine` at 8 bits. Measured against a live conversation index of 2.3 million vectors, affine returns essentially the same search results as the 16-bit weights, and MX FP8 does not.

| | agreement with stored vector | top-10 search agreement |
| --- | --- | --- |
| 16-bit re-embed | 0.99991 | 0.9205 |
| affine 8-bit | 0.99949 | 0.9166 |
| MX FP8 | 0.952 | 0.800 |

Read the middle column as how closely a freshly embedded vector matches the vector already stored for the same text. Read the right column as how much of a stored vector's top-10 result list the fresh vector reproduces.

The first row is the control and the reason the second column matters more than it looks. Re-embedding with the *same* 16-bit weights reproduces only 92% of a stored top-10, because results at nearly equal distances reorder on any re-embed. Perfect agreement is therefore unreachable by any format, including the one already in production. A format is acceptable when it matches that floor, and affine does while MX FP8 falls twelve points short.

The difference is structural. MX FP8 stores three mantissa bits per weight with one shared exponent for every 32 weights. Affine stores a scale and an offset for each group, so it reconstructs the original weights far more closely at the same width.

## Convert a model

Run the converter against an unquantized model directory:

```
lmd-dev quantize-nv-embed-mxfp8 --mode affine --bits 8 --group-size 64
```

The destination is named after the mode, so `NV-EmbedCode-7b-v1` produces `NV-EmbedCode-7b-v1-affine`. Pass `--source` and `--destination` to override either path, and `--overwrite` to replace an existing destination. The source is never modified.

The converter assembles the result in a staging directory and moves it into place only once every file is written, so an interrupted run leaves no half-built model where the loader can find it.

Only the linear layers are quantized. They hold 6.98 of the model's 7.11 billion parameters, so they carry nearly all of the size reduction. The token embedding table stays at full precision because it is under 2% of the weights and every later layer reads its output.

### Run the converter from the staged build

The converter needs the Metal library and the accelerator kernels that the build stages under `Products/Build/Debug`. Run it from that directory and point `LMD_AOT_LIB` at the `nax` directory beside it. Without this the first GPU call fails with an MLX error naming `stream.cpp`, which reports a missing GPU stream rather than a missing library. See [NAX accelerator kernels](nax.md) for what those prebuilt kernels do.

## How the loader picks precision

A model directory declares its precision in `config.json`:

```json
"quantization": { "group_size": 64, "bits": 8, "mode": "affine" }
```

When that block is present, the loader quantizes exactly those layers whose stored weights carry a scale entry. The checkpoint decides which layers are quantized, so the loader can never disagree with the file it reads. A directory without the block loads at full precision, unchanged.

MX FP8 is fixed by its format at group size 32 and 8 bits. A model declaring `mxfp8` with any other pairing is rejected at load with a message naming the offending value.

## Put a quantized model into production

The daemon records the embedding model **name** in the index checkpoint. Changing that name discards the checkpoint and re-embeds the entire corpus. Keep the name and change what it points to.

Deploy the binary before swapping the weights. A build without quantization support cannot read a quantized checkpoint, and requests queue without an error until the model is swapped back.

1. Deploy lmd, so the running binary understands quantized checkpoints.
2. Rename the live model directory aside, then rename the quantized directory into its place.
3. Restart the broker so it rescans the model catalog.

Roll back by reversing the two renames and restarting the broker again. Keep the previous weights on disk until you are satisfied, since that is what makes the rollback a rename rather than a rebuild.

Confirm afterwards that the index was preserved: its row count should keep growing normally, and the checkpoint's config digest should be unchanged. A changed digest means the corpus is being re-embedded.

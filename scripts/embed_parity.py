# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx", "numpy"]
# ///
"""Embedding parity gate between two weight sets served by one lmd broker.

The gate embeds the same texts through two model ids and fails unless the
results agree. It exists to prove a converted weight set (bf16) is
interchangeable with the original (fp32) before the converted set takes over
the primary model id.

Checks, in order:

1. Shape canaries. Batch shapes that previously produced non-finite outputs
   (HTTP 500 via a NaN that broke response encoding) run first against both
   models: two long equal-length inputs, a long input mixed with short ones,
   and a full mixed batch. Any HTTP error or non-finite vector fails the gate
   immediately with the offending shape named.
2. Finiteness. Every vector from every request must contain only finite
   values.
3. Pairwise cosine. For every chunk and query, the cosine between the two
   models' vectors must be high (median >= 0.999 by default).
4. Retrieval overlap. For every query, the top-10 chunks by cosine under
   model A and under model B must overlap (mean >= 0.98 by default).

Exit 0 on pass, 1 on fail, with the numbers printed either way.

Run against a broker whose catalog contains both ids, for example:

    uv run scripts/embed_parity.py \
        --chunks-file ~/.local/state/lm-semantic-search/chunks \
        --queries-file scripts/embed_parity_queries.txt
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from dataclasses import dataclass
from pathlib import Path

import httpx
import numpy as np

DEFAULT_BASE_URL = "http://localhost:5400"
DEFAULT_MODEL_A = "nvidia/NV-EmbedCode-7b-v1-bf16"
DEFAULT_MODEL_B = "nvidia/NV-EmbedCode-7b-v1"
DEFAULT_CHUNK_SAMPLE = 1000
DEFAULT_BATCH_ROWS = 32
DEFAULT_SEED = 42
COSINE_MEDIAN_THRESHOLD = 0.999
TOP_K = 10
TOP_K_OVERLAP_THRESHOLD = 0.98
REQUEST_TIMEOUT_SECONDS = 600.0
LONG_CANARY_WORD_REPEATS = 725
SHORT_CANARY_TEXT = "short canary probe"


@dataclass
class GateConfig:
    base_url: str
    model_a: str
    model_b: str
    chunks_path: Path
    queries_path: Path
    chunk_sample: int
    batch_rows: int
    seed: int


class GateFailure(Exception):
    """Raised with a human-readable reason when the gate fails."""


def parse_arguments() -> GateConfig:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--model-a", default=DEFAULT_MODEL_A)
    parser.add_argument("--model-b", default=DEFAULT_MODEL_B)
    parser.add_argument(
        "--chunks-file",
        required=True,
        help=(
            "Text file with one document per line, or a directory of "
            "lm-semantic-search chunk caches (*.json) to sample from."
        ),
    )
    parser.add_argument("--queries-file", required=True)
    parser.add_argument("--chunk-sample", type=int, default=DEFAULT_CHUNK_SAMPLE)
    parser.add_argument("--batch-rows", type=int, default=DEFAULT_BATCH_ROWS)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    args = parser.parse_args()
    return GateConfig(
        base_url=args.base_url,
        model_a=args.model_a,
        model_b=args.model_b,
        chunks_path=Path(args.chunks_file).expanduser(),
        queries_path=Path(args.queries_file).expanduser(),
        chunk_sample=args.chunk_sample,
        batch_rows=args.batch_rows,
        seed=args.seed,
    )


def load_chunks(path: Path, sample_size: int, seed: int) -> list[str]:
    if path.is_dir():
        contents: list[str] = []
        for cache_file in sorted(path.glob("*.json")):
            with cache_file.open() as handle:
                payload = json.load(handle)
            chunk_records = payload if isinstance(payload, list) else payload.get("chunks", [])
            for record in chunk_records:
                if isinstance(record, dict):
                    content = record.get("content") or record.get("Content")
                    if isinstance(content, str) and content.strip():
                        contents.append(content)
        if not contents:
            raise GateFailure(f"no chunk contents found under {path}")
        rng = random.Random(seed)
        if len(contents) > sample_size:
            contents = rng.sample(contents, sample_size)
        return contents
    lines = [line for line in path.read_text().splitlines() if line.strip()]
    if not lines:
        raise GateFailure(f"no lines in {path}")
    return lines[:sample_size]


def load_queries(path: Path) -> list[str]:
    queries = [line for line in path.read_text().splitlines() if line.strip()]
    if not queries:
        raise GateFailure(f"no queries in {path}")
    return queries


def embed_batch(
    client: httpx.Client, base_url: str, model: str, inputs: list[str]
) -> np.ndarray:
    response = client.post(
        f"{base_url}/v1/embeddings",
        json={"model": model, "input": inputs},
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if response.status_code != 200:
        raise GateFailure(
            f"HTTP {response.status_code} from {model} for a {len(inputs)}-row batch: "
            f"{response.text[:200]!r}"
        )
    payload = response.json()
    rows = payload.get("data", [])
    if len(rows) != len(inputs):
        raise GateFailure(
            f"{model} returned {len(rows)} vectors for {len(inputs)} inputs"
        )
    matrix = np.array([row["embedding"] for row in rows], dtype=np.float64)
    if not np.isfinite(matrix).all():
        bad_rows = np.where(~np.isfinite(matrix).all(axis=1))[0].tolist()
        raise GateFailure(
            f"{model} produced non-finite values in rows {bad_rows} of a "
            f"{len(inputs)}-row batch"
        )
    return matrix


def embed_all(
    client: httpx.Client,
    base_url: str,
    model: str,
    texts: list[str],
    batch_rows: int,
) -> np.ndarray:
    blocks: list[np.ndarray] = []
    for start in range(0, len(texts), batch_rows):
        block = embed_batch(client, base_url, model, texts[start : start + batch_rows])
        blocks.append(block)
        print(
            f"  embedded {min(start + batch_rows, len(texts))}/{len(texts)} via {model}",
            flush=True,
        )
    return np.vstack(blocks)


def run_shape_canaries(client: httpx.Client, config: GateConfig) -> None:
    long_text = "func " * LONG_CANARY_WORD_REPEATS
    canaries: list[tuple[str, list[str]]] = [
        ("two equal long rows", [long_text, long_text]),
        ("short row plus long row", [SHORT_CANARY_TEXT, long_text]),
        (
            "mixed four-row batch",
            [SHORT_CANARY_TEXT, long_text, "beta probe", "func " * 80],
        ),
        ("single long row", [long_text]),
    ]
    for model in (config.model_a, config.model_b):
        for name, inputs in canaries:
            embed_batch(client, config.base_url, model, inputs)
            print(f"canary ok: {model}: {name}")


def cosine_rows(matrix_a: np.ndarray, matrix_b: np.ndarray) -> np.ndarray:
    norms_a = np.linalg.norm(matrix_a, axis=1)
    norms_b = np.linalg.norm(matrix_b, axis=1)
    dots = np.einsum("ij,ij->i", matrix_a, matrix_b)
    return dots / (norms_a * norms_b)


def top_k_overlap(
    query_vectors: np.ndarray,
    chunk_vectors: np.ndarray,
    other_query_vectors: np.ndarray,
    other_chunk_vectors: np.ndarray,
) -> float:
    def normalize(matrix: np.ndarray) -> np.ndarray:
        return matrix / np.linalg.norm(matrix, axis=1, keepdims=True)

    scores_a = normalize(query_vectors) @ normalize(chunk_vectors).T
    scores_b = normalize(other_query_vectors) @ normalize(other_chunk_vectors).T
    overlaps: list[float] = []
    for row_a, row_b in zip(scores_a, scores_b):
        top_a = set(np.argsort(row_a)[-TOP_K:].tolist())
        top_b = set(np.argsort(row_b)[-TOP_K:].tolist())
        overlaps.append(len(top_a & top_b) / TOP_K)
    return float(np.mean(overlaps))


def main() -> int:
    config = parse_arguments()
    chunks = load_chunks(config.chunks_path, config.chunk_sample, config.seed)
    queries = load_queries(config.queries_path)
    print(f"chunks: {len(chunks)}, queries: {len(queries)}")
    print(f"model A: {config.model_a}")
    print(f"model B: {config.model_b}")

    with httpx.Client() as client:
        print("running shape canaries...")
        run_shape_canaries(client, config)

        print("embedding chunks with model A...")
        chunks_a = embed_all(client, config.base_url, config.model_a, chunks, config.batch_rows)
        print("embedding chunks with model B...")
        chunks_b = embed_all(client, config.base_url, config.model_b, chunks, config.batch_rows)
        print("embedding queries with model A...")
        queries_a = embed_all(client, config.base_url, config.model_a, queries, config.batch_rows)
        print("embedding queries with model B...")
        queries_b = embed_all(client, config.base_url, config.model_b, queries, config.batch_rows)

    chunk_cosines = cosine_rows(chunks_a, chunks_b)
    query_cosines = cosine_rows(queries_a, queries_b)
    all_cosines = np.concatenate([chunk_cosines, query_cosines])
    median_cosine = float(np.median(all_cosines))
    p1_cosine = float(np.percentile(all_cosines, 1))
    overlap = top_k_overlap(queries_a, chunks_a, queries_b, chunks_b)

    print(f"median pairwise cosine: {median_cosine:.6f} (threshold {COSINE_MEDIAN_THRESHOLD})")
    print(f"p1 pairwise cosine:     {p1_cosine:.6f}")
    print(f"mean top-{TOP_K} overlap:    {overlap:.4f} (threshold {TOP_K_OVERLAP_THRESHOLD})")

    if median_cosine >= COSINE_MEDIAN_THRESHOLD and overlap >= TOP_K_OVERLAP_THRESHOLD:
        print("PARITY GATE: PASS")
        return 0
    print("PARITY GATE: FAIL")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateFailure as failure:
        print(f"PARITY GATE: FAIL: {failure}")
        sys.exit(1)

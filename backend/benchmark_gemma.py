"""Benchmark Gemma 4 E2B and E4B models for speech-to-text on Apple Silicon.

Converts 3 test audio files to 16kHz mono WAV, runs through:
- Gemma 4 E2B (4-bit, ~1 GB)
- Gemma 4 E4B (4-bit, ~5.2 GB)
- Groq Whisper (cloud baseline)

Measures latency, peak memory, and transcription text.
"""

import gc
import os
import resource
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Ensure backend modules are importable
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Load .env for GROQ_API_KEY
env_path = Path(__file__).parent / ".env"
if env_path.exists():
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())

# Test audio files (relative to repo root)
AUDIO_FILES = [
    "tests/audio/test_french.m4a",
    "tests/audio/test_english.m4a",
    "tests/audio/test_chinese.m4a",
]

# Models to benchmark
MODELS = {
    "E2B": "mlx-community/gemma-4-e2b-it-4bit",
    "E4B": "mlx-community/gemma-4-e4b-it-4bit",
}

TRANSCRIPTION_PROMPT = (
    "Transcribe the following speech segment in its original language. "
    "Only output the transcription, with no newlines. "
    "When transcribing numbers, write the digits."
)


def convert_m4a_to_wav(m4a_path: str, wav_path: str) -> None:
    """Convert m4a to 16kHz mono 16-bit PCM WAV via ffmpeg."""
    subprocess.run(
        [
            "ffmpeg", "-y", "-i", m4a_path,
            "-ar", "16000", "-ac", "1", "-sample_fmt", "s16",
            "-f", "wav", wav_path,
        ],
        capture_output=True,
        check=True,
    )


def get_peak_memory_mb() -> float:
    """Get current peak RSS in MB (macOS: ru_maxrss is in bytes)."""
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def run_gemma_benchmark(model_name: str, model_id: str, wav_paths: list[str]) -> dict:
    """Run benchmark for a single Gemma model across all WAV files.

    Returns dict with load_time, peak_memory, and per-file results.
    """
    print(f"\n{'='*60}")
    print(f"  Benchmarking {model_name}: {model_id}")
    print(f"{'='*60}")

    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template

    # Measure model loading
    mem_before = get_peak_memory_mb()
    load_start = time.perf_counter()
    model, processor = load(model_id)
    load_time = time.perf_counter() - load_start
    mem_after_load = get_peak_memory_mb()

    print(f"  Model loaded in {load_time:.1f}s")
    print(f"  Memory: {mem_before:.0f} MB -> {mem_after_load:.0f} MB (delta: {mem_after_load - mem_before:.0f} MB)")

    # Warmup run with first file
    print("  Running warmup inference...")
    prompt = apply_chat_template(
        processor, model.config, TRANSCRIPTION_PROMPT, num_audios=1,
    )
    warmup_result = generate(model, processor, prompt, audio=[wav_paths[0]], max_tokens=500, temperature=0.0)
    # generate() returns GenerationResult with .text attribute
    print(f"  Warmup done. (result type: {type(warmup_result).__name__})")

    # Benchmark each file (2 runs, report second)
    results = []
    for wav_path in wav_paths:
        fname = Path(wav_path).stem
        print(f"\n  File: {fname}")

        prompt = apply_chat_template(
            processor, model.config, TRANSCRIPTION_PROMPT, num_audios=1,
        )

        # Run 1 (discard)
        _ = generate(model, processor, prompt, audio=[wav_path], max_tokens=500, temperature=0.0)

        # Run 2 (measure)
        prompt = apply_chat_template(
            processor, model.config, TRANSCRIPTION_PROMPT, num_audios=1,
        )
        t_start = time.perf_counter()
        gen_result = generate(model, processor, prompt, audio=[wav_path], max_tokens=500, temperature=0.0)
        latency = time.perf_counter() - t_start

        # Extract text from GenerationResult object
        if hasattr(gen_result, "text"):
            text = gen_result.text.strip()
        else:
            text = str(gen_result).strip()

        mem_current = get_peak_memory_mb()
        gen_tokens = getattr(gen_result, "generation_tokens", "?")
        prompt_tps = getattr(gen_result, "prompt_tps", "?")
        gen_tps = getattr(gen_result, "generation_tps", "?")
        peak_mem_gb = getattr(gen_result, "peak_memory", "?")
        print(f"  Latency: {latency:.2f}s | Memory: {mem_current:.0f} MB (MLX peak: {peak_mem_gb} GB)")
        print(f"  Tokens: {gen_tokens} | Prompt TPS: {prompt_tps} | Gen TPS: {gen_tps}")
        print(f"  Text: {text!r}")

        results.append({
            "file": fname,
            "text": text,
            "latency_s": latency,
            "peak_mem_mb": mem_current,
            "gen_tokens": gen_tokens,
            "prompt_tps": prompt_tps if isinstance(prompt_tps, (int, float)) else 0,
            "gen_tps": gen_tps if isinstance(gen_tps, (int, float)) else 0,
            "mlx_peak_gb": peak_mem_gb if isinstance(peak_mem_gb, (int, float)) else 0,
        })

    # Cleanup
    peak_mem = get_peak_memory_mb()
    del model, processor
    gc.collect()

    return {
        "model_name": model_name,
        "model_id": model_id,
        "load_time_s": load_time,
        "mem_delta_mb": mem_after_load - mem_before,
        "peak_mem_mb": peak_mem,
        "files": results,
    }


def run_groq_benchmark(wav_paths: list[str]) -> list[dict]:
    """Run Groq Whisper baseline on all WAV files."""
    print(f"\n{'='*60}")
    print("  Benchmarking Groq Whisper (baseline)")
    print(f"{'='*60}")

    from groq_stt import get_groq_stt

    stt = get_groq_stt()
    results = []

    for wav_path in wav_paths:
        fname = Path(wav_path).stem
        audio_data = Path(wav_path).read_bytes()

        t_start = time.perf_counter()
        result = stt.transcribe(audio_data)
        latency = time.perf_counter() - t_start

        text = result.get("text", "")
        print(f"  {fname}: {latency:.2f}s — {text!r}")

        results.append({
            "file": fname,
            "text": text.strip() if text else "",
            "latency_s": latency,
        })

    return results


def format_results(gemma_results: list[dict], groq_results: list[dict], wav_paths: list[str]) -> str:
    """Format all results as markdown tables."""
    lines = []
    lines.append("# Gemma 4 STT Benchmark Results")
    lines.append("")
    lines.append(f"**Date:** {time.strftime('%Y-%m-%d %H:%M')}")
    lines.append("**Machine:** Apple Silicon Mac")
    lines.append(f"**Test files:** {len(wav_paths)} audio clips (~11s each)")
    lines.append("")

    # Model summary table
    lines.append("## Model Summary")
    lines.append("")
    lines.append("| Model | Load Time | RSS Delta | MLX Peak Memory | Avg Latency | Avg Gen TPS |")
    lines.append("|-------|-----------|-----------|-----------------|-------------|-------------|")
    for gr in gemma_results:
        files = gr["files"]
        avg_lat = sum(f["latency_s"] for f in files) / len(files)
        avg_tps = sum(f.get("gen_tps", 0) for f in files) / len(files)
        max_mlx_gb = max((f.get("mlx_peak_gb", 0) for f in files), default=0)
        lines.append(
            f"| {gr['model_name']} | {gr['load_time_s']:.1f}s | "
            f"{gr['mem_delta_mb']:.0f} MB | {max_mlx_gb:.1f} GB | "
            f"{avg_lat:.2f}s | {avg_tps:.1f} |"
        )
    groq_avg = sum(r["latency_s"] for r in groq_results) / len(groq_results)
    lines.append(f"| Groq (cloud) | N/A | N/A | N/A | {groq_avg:.2f}s | N/A |")
    lines.append("")

    # Per-file transcription comparison
    lines.append("## Transcription Comparison")
    lines.append("")

    file_stems = [Path(p).stem for p in wav_paths]
    for i, stem in enumerate(file_stems):
        lines.append(f"### File: {stem}")
        lines.append("")
        lines.append("| Provider | Latency | Transcription |")
        lines.append("|----------|---------|---------------|")
        for gr in gemma_results:
            f = gr["files"][i]
            lines.append(f"| {gr['model_name']} | {f['latency_s']:.2f}s | {f['text']} |")
        lines.append(f"| Groq | {groq_results[i]['latency_s']:.2f}s | {groq_results[i]['text']} |")
        lines.append("")

    # Cost comparison
    lines.append("## Cost Comparison")
    lines.append("")
    lines.append("| Provider | Cost | Notes |")
    lines.append("|----------|------|-------|")
    lines.append("| E2B (local) | $0 | ~1 GB model, runs on-device |")
    lines.append("| E4B (local) | $0 | ~5.2 GB model, runs on-device |")
    lines.append("| Groq | $0.04-0.111/hr | Cloud API, requires internet |")
    lines.append("")

    return "\n".join(lines)


def main():
    print("Gemma 4 STT Benchmark")
    print("=" * 60)

    # Step 1: Convert audio files to WAV
    tmp_dir = tempfile.mkdtemp(prefix="gemma_bench_")
    wav_paths = []
    for m4a_path in AUDIO_FILES:
        if not Path(m4a_path).exists():
            print(f"ERROR: Audio file not found: {m4a_path}")
            sys.exit(1)
        stem = Path(m4a_path).stem
        wav_path = os.path.join(tmp_dir, f"{stem}.wav")
        print(f"Converting: {stem} -> WAV (16kHz mono)")
        convert_m4a_to_wav(m4a_path, wav_path)
        wav_paths.append(wav_path)

    print(f"\nConverted {len(wav_paths)} files to {tmp_dir}")

    # Step 2: Run Gemma benchmarks
    gemma_results = []
    for model_name, model_id in MODELS.items():
        try:
            result = run_gemma_benchmark(model_name, model_id, wav_paths)
            gemma_results.append(result)
        except Exception as e:
            print(f"\nERROR benchmarking {model_name}: {e}")
            import traceback
            traceback.print_exc()
            gemma_results.append({
                "model_name": model_name,
                "model_id": model_id,
                "load_time_s": 0,
                "mem_delta_mb": 0,
                "peak_mem_mb": 0,
                "files": [{"file": Path(p).stem, "text": f"ERROR: {e}", "latency_s": 0, "peak_mem_mb": 0} for p in wav_paths],
            })

    # Step 3: Run Groq baseline
    try:
        groq_results = run_groq_benchmark(wav_paths)
    except Exception as e:
        print(f"\nERROR running Groq baseline: {e}")
        groq_results = [{"file": Path(p).stem, "text": f"ERROR: {e}", "latency_s": 0} for p in wav_paths]

    # Step 4: Format and save results
    report = format_results(gemma_results, groq_results, wav_paths)
    print("\n\n" + report)

    # Save to reports directory
    report_dir = Path(__file__).parent.parent / "agent-reports" / "agent-team-2026-04-09-gemma4"
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / "benchmark-results.md"
    report_path.write_text(report)
    print(f"\nResults saved to: {report_path}")

    # Cleanup temp files
    for p in wav_paths:
        Path(p).unlink(missing_ok=True)
    Path(tmp_dir).rmdir()

    print("\nBenchmark complete!")


if __name__ == "__main__":
    main()

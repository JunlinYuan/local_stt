#!/usr/bin/env python3
"""Minimal test: Gemini vs Groq for speech-to-text.

Compares:
  1. Groq Whisper large-v3-turbo (current provider)
  2. Gemini 2.5 Flash (with and without vocabulary hints)
  3. Gemini 2.5 Flash-Lite (cheapest)

Usage:
  # Record 5 seconds from mic, then compare:
  python3 tests/test_gemini_stt.py --record 5

  # Use an existing WAV file:
  python3 tests/test_gemini_stt.py path/to/audio.wav

Requires: pip install google-genai groq
"""

import os
import subprocess
import sys
import tempfile
import time

# --- Config ---
GROQ_API_KEY = os.environ.get("GROQ_API_KEY")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")

VOCABULARY = [
    "MCP", "Railway", "TEMPEST", "CLAUDE.md", "Reynolds number",
    "DNS", "STT", "Groq", "Supabase", "LaTeX", "HPCC", "RANS",
    "Navier-Stokes", "Claude Code", "AKCode", "NSF",
]

REPLACEMENTS = {
    "Cloud Code": "Claude Code",
    "Clock code": "Claude Code",
    "cloud.md": "CLAUDE.md",
    "Cloud MD": "CLAUDE.md",
}


def record_audio(duration: int, output_path: str) -> str:
    """Record audio from default mic using ffmpeg."""
    print(f"Recording {duration}s from microphone... (speak now)")
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-f", "avfoundation", "-i", ":0",  # default mic on macOS
            "-t", str(duration),
            "-ar", "16000", "-ac", "1", "-sample_fmt", "s16",
            output_path,
        ],
        check=True,
        capture_output=True,
    )
    print(f"Recorded: {output_path}")
    return output_path


def get_wav_duration(path: str) -> float:
    """Estimate WAV duration from file size (16kHz, 16-bit, mono)."""
    return max(0, (os.path.getsize(path) - 44) / (16000 * 2))


def test_groq(audio_path: str, with_vocab: bool = False) -> dict:
    """Transcribe with Groq Whisper."""
    from groq import Groq

    client = Groq(api_key=GROQ_API_KEY)
    start = time.time()

    prompt = None
    if with_vocab:
        prompt = f"Vocabulary: {', '.join(VOCABULARY)}."

    with open(audio_path, "rb") as f:
        params = {
            "model": "whisper-large-v3-turbo",
            "file": f,
            "response_format": "verbose_json",
        }
        if prompt:
            params["prompt"] = prompt

        response = client.audio.transcriptions.create(**params)

    elapsed = time.time() - start
    text = response.text.strip() if response.text else ""
    duration = getattr(response, "duration", 0) or 0

    label = "Groq Whisper v3-turbo"
    if with_vocab:
        label += " + vocab"

    return {
        "provider": label,
        "text": text,
        "time_s": round(elapsed, 3),
        "audio_duration_s": round(duration, 2),
        "cost_per_min": 0.00067,
        "est_cost": round(duration / 60 * 0.00067, 6),
    }


def test_gemini(audio_path: str, model: str, label: str, with_vocab: bool = False) -> dict:
    """Transcribe with Gemini API."""
    from google import genai

    client = genai.Client(api_key=GEMINI_API_KEY)

    if with_vocab:
        vocab_str = ", ".join(VOCABULARY)
        repl_str = "; ".join(f'"{k}" -> "{v}"' for k, v in REPLACEMENTS.items())
        prompt = (
            "Transcribe the following speech exactly as spoken. "
            "Output ONLY the transcription text, nothing else.\n\n"
            f"Use these specific terms/spellings when you hear them: {vocab_str}\n\n"
            f"Apply these corrections if you hear similar sounds: {repl_str}\n\n"
            "When transcribing numbers, write the digits (e.g., 5000 not five thousand)."
        )
    else:
        prompt = (
            "Transcribe the following speech exactly as spoken. "
            "Output ONLY the transcription text, nothing else. "
            "When transcribing numbers, write the digits."
        )

    start = time.time()

    # Upload audio file to Gemini Files API
    uploaded = client.files.upload(file=audio_path)

    response = client.models.generate_content(
        model=model,
        contents=[uploaded, prompt],
    )
    elapsed = time.time() - start

    text = response.text.strip() if response.text else ""
    duration = get_wav_duration(audio_path)

    usage = response.usage_metadata
    input_tokens = usage.prompt_token_count if usage else 0
    output_tokens = usage.candidates_token_count if usage else 0

    # Audio input pricing per million tokens
    if "flash-lite" in model:
        audio_rate, output_rate = 0.30, 0.40
    elif "flash" in model:
        audio_rate, output_rate = 1.00, 2.50
    else:
        audio_rate, output_rate = 3.75, 10.00

    est_cost = (input_tokens * audio_rate + output_tokens * output_rate) / 1_000_000

    return {
        "provider": label,
        "text": text,
        "time_s": round(elapsed, 3),
        "audio_duration_s": round(duration, 2),
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "est_cost": round(est_cost, 6),
    }


def print_result(result: dict):
    """Pretty-print a test result."""
    print(f"\n{'=' * 60}")
    print(f"  {result['provider']}")
    print(f"{'=' * 60}")
    print(f"  Text: {result['text']}")
    print(f"  Time: {result['time_s']}s | Audio: {result.get('audio_duration_s', '?')}s")
    if "input_tokens" in result:
        print(f"  Tokens: {result['input_tokens']} in / {result['output_tokens']} out")
    print(f"  Est. cost: ${result['est_cost']:.6f}")


def main():
    audio_path = None

    # Parse args
    if len(sys.argv) >= 2:
        if sys.argv[1] == "--record":
            duration = int(sys.argv[2]) if len(sys.argv) > 2 else 5
            audio_path = "/tmp/stt_gemini_test.wav"
            record_audio(duration, audio_path)
        else:
            audio_path = sys.argv[1]
    else:
        print("Usage:")
        print("  python3 tests/test_gemini_stt.py --record [seconds]")
        print("  python3 tests/test_gemini_stt.py path/to/audio.wav")
        sys.exit(1)

    if not os.path.exists(audio_path):
        print(f"File not found: {audio_path}")
        sys.exit(1)

    duration = get_wav_duration(audio_path)
    file_size = os.path.getsize(audio_path)
    print(f"\nAudio: {audio_path}")
    print(f"Size: {file_size:,} bytes | Duration: {duration:.1f}s")

    results = []

    # --- Groq tests ---
    if GROQ_API_KEY:
        print("\n--- Groq Whisper ---")
        for with_vocab in [False, True]:
            try:
                r = test_groq(audio_path, with_vocab=with_vocab)
                results.append(r)
                print_result(r)
            except Exception as e:
                print(f"  Error: {e}")
    else:
        print("\nGROQ_API_KEY not set — skipping Groq")

    # --- Gemini tests ---
    if GEMINI_API_KEY:
        print("\n--- Gemini ---")
        configs = [
            ("gemini-2.5-flash", "Gemini 2.5 Flash", False),
            ("gemini-2.5-flash", "Gemini 2.5 Flash + vocab/replace", True),
            ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite", False),
            ("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite + vocab/replace", True),
        ]
        for model, label, with_vocab in configs:
            try:
                r = test_gemini(audio_path, model, label, with_vocab=with_vocab)
                results.append(r)
                print_result(r)
            except Exception as e:
                print(f"  {label} error: {e}")
    else:
        print("\nGEMINI_API_KEY not set — skipping Gemini")

    # --- Summary ---
    if results:
        print(f"\n{'=' * 70}")
        print("  COMPARISON SUMMARY")
        print(f"{'=' * 70}")
        print(f"  {'Provider':<42} {'Time':>6} {'Cost':>10}")
        print(f"  {'-' * 60}")
        for r in results:
            print(f"  {r['provider']:<42} {r['time_s']:>5.2f}s ${r['est_cost']:.6f}")
        print(f"\n  Note: Groq cost based on audio duration, Gemini on token count.")
        print(f"  Gemini audio = ~32 tokens/sec (~1,920 tokens/min)")


if __name__ == "__main__":
    main()

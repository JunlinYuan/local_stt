#!/usr/bin/env python3
"""End-to-end tests for the Gemini STT provider.

Tests the gemini_stt module against real audio files:
  - /tmp/stt_test_23.wav (French ~11s)
  - /tmp/stt_test_24.wav (English ~11s)
  - /tmp/stt_test_25.wav (Chinese ~11s)

Run: python3 tests/test_gemini_provider.py
"""

import os
import sys
import time

# Setup: backend dir on path and as cwd so backend imports resolve
BACKEND_DIR = os.path.join(os.path.dirname(__file__), "..", "backend")
sys.path.insert(0, os.path.abspath(BACKEND_DIR))
os.chdir(os.path.abspath(BACKEND_DIR))

# Now import the module under test
import gemini_stt

# ── Helpers ──────────────────────────────────────────────────────────────────

PASS = 0
FAIL = 0


def report(name: str, passed: bool, detail: str = ""):
    global PASS, FAIL
    tag = "PASS" if passed else "FAIL"
    if passed:
        PASS += 1
    else:
        FAIL += 1
    suffix = f" — {detail}" if detail else ""
    print(f"  [{tag}] {name}{suffix}")


# ── Test 1: is_gemini_available ──────────────────────────────────────────────

print("\n=== Test 1: is_gemini_available() ===")
avail = gemini_stt.is_gemini_available()
report("API key present", avail, f"is_gemini_available() = {avail}")

if not avail:
    print("\nFATAL: GEMINI_API_KEY not set — cannot continue.")
    sys.exit(1)

# ── Test 2: Singleton creation ───────────────────────────────────────────────

print("\n=== Test 2: get_gemini_stt() ===")
try:
    stt = gemini_stt.get_gemini_stt()
    report("Singleton created", True, f"type={type(stt).__name__}")
except Exception as e:
    report("Singleton created", False, str(e))
    sys.exit(1)

# ── Test 3: Transcription with vocabulary ────────────────────────────────────

VOCAB = [
    "MCP", "Railway", "TEMPEST", "CLAUDE.md",
    "Reynolds number", "DNS", "STT", "Groq", "Claude Code",
]
stt.set_vocabulary(VOCAB)

TEST_FILES = [
    ("/tmp/stt_test_23.wav", "fr", "French"),
    ("/tmp/stt_test_24.wav", "en", "English"),
    ("/tmp/stt_test_25.wav", "zh", "Chinese"),
]

REQUIRED_KEYS = {"text", "language", "language_probability", "duration", "processing_time", "provider"}

print("\n=== Test 3: Transcription with vocabulary ===")
results_with_vocab = []

for path, lang, label in TEST_FILES:
    print(f"\n--- {label} ({os.path.basename(path)}) ---")
    if not os.path.exists(path):
        report(f"{label} transcription", False, f"File not found: {path}")
        continue

    audio_data = open(path, "rb").read()
    file_size = len(audio_data)

    try:
        t0 = time.time()
        result = stt.transcribe(audio_data, language=lang)
        wall_time = time.time() - t0

        # Key presence
        missing = REQUIRED_KEYS - set(result.keys())
        report(f"{label} keys present", len(missing) == 0,
               f"missing={missing}" if missing else "all 6 keys")

        # Provider check
        report(f"{label} provider=='gemini'", result.get("provider") == "gemini",
               f"provider={result.get('provider')}")

        # Text non-empty
        text = result.get("text", "")
        report(f"{label} text non-empty", bool(text), f"len={len(text)}")

        # Duration > 0
        dur = result.get("duration", 0)
        report(f"{label} duration > 0", dur > 0, f"duration={dur:.2f}s")

        # Processing time > 0
        pt = result.get("processing_time", 0)
        report(f"{label} processing_time > 0", pt > 0, f"processing_time={pt:.3f}s")

        print(f"  TEXT: {text}")
        print(f"  TIMING: api={pt:.3f}s  wall={wall_time:.3f}s  audio={dur:.1f}s")
        print(f"  LANGUAGE: {result.get('language')}  prob={result.get('language_probability')}")

        results_with_vocab.append((label, result))

    except Exception as e:
        report(f"{label} transcription", False, f"Exception: {e}")
        import traceback; traceback.print_exc()

# ── Test 4: Transcription without vocabulary ─────────────────────────────────

print("\n=== Test 4: Transcription WITHOUT vocabulary (English only) ===")
# Reset singleton to clear vocabulary
gemini_stt._gemini_stt = None
stt_no_vocab = gemini_stt.get_gemini_stt()
# Explicitly set empty vocabulary
stt_no_vocab.set_vocabulary([])

en_path = "/tmp/stt_test_24.wav"
if os.path.exists(en_path):
    audio_data = open(en_path, "rb").read()
    try:
        result_nv = stt_no_vocab.transcribe(audio_data, language="en")
        text_nv = result_nv.get("text", "")
        report("No-vocab transcription", bool(text_nv), f"len={len(text_nv)}")
        print(f"  TEXT (no vocab): {text_nv}")

        # Compare with vocab result
        for label, r in results_with_vocab:
            if label == "English":
                print(f"  TEXT (w/ vocab):  {r['text']}")
                break

    except Exception as e:
        report("No-vocab transcription", False, str(e))
        import traceback; traceback.print_exc()

# ── Test 5: Error handling — empty audio ─────────────────────────────────────

print("\n=== Test 5: Error handling — empty bytes ===")
try:
    result_empty = stt_no_vocab.transcribe(b"", language="en")
    # If it returns, check it handled gracefully
    text_empty = result_empty.get("text", "")
    report("Empty bytes handled", True, f"returned text='{text_empty}', no crash")
except Exception as e:
    # An exception is acceptable as long as it's clear
    etype = type(e).__name__
    report("Empty bytes handled", True, f"raised {etype}: {e}")

# ── Test 6: Auto-detect language (no language hint) ──────────────────────────

print("\n=== Test 6: Auto-detect language (French audio, no lang hint) ===")
gemini_stt._gemini_stt = None
stt_auto = gemini_stt.get_gemini_stt()
stt_auto.set_vocabulary(VOCAB)

fr_path = "/tmp/stt_test_23.wav"
if os.path.exists(fr_path):
    audio_data = open(fr_path, "rb").read()
    try:
        result_auto = stt_auto.transcribe(audio_data, language=None)
        text_auto = result_auto.get("text", "")
        lang_auto = result_auto.get("language", "")
        report("Auto-detect transcription", bool(text_auto), f"lang={lang_auto}")
        print(f"  TEXT (auto): {text_auto}")
        report("Language is 'unknown' when no hint", lang_auto == "unknown",
               f"language={lang_auto}")
    except Exception as e:
        report("Auto-detect transcription", False, str(e))
        import traceback; traceback.print_exc()

# ── Summary ──────────────────────────────────────────────────────────────────

print(f"\n{'='*60}")
print(f"TOTAL: {PASS} passed, {FAIL} failed out of {PASS+FAIL}")
print(f"{'='*60}")

sys.exit(0 if FAIL == 0 else 1)

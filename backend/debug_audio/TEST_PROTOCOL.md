# STT Diagnostic Test Protocol

## How to Run a Diagnostic Test

Use this protocol whenever transcription accuracy seems off — after changing providers,
microphones, audio settings, or updating the resampling/normalization pipeline.

### Setup

1. Enable debug audio: `curl -X PUT http://localhost:8000/api/settings/save_debug_audio -H 'Content-Type: application/json' -d '{"value": true}'`
2. Note your current settings (provider, language, mic, normalization)
3. Create a subfolder: `mkdir debug_audio/test_run_XX`

### Test Sentences

Pick 8-12 sentences covering these categories:

| Category | Example | Why |
|----------|---------|-----|
| Short common command | "Check my email." | Baseline — should always work |
| Very short (<1s) | "Try again." | Stress-test minimum clip length |
| Proper noun / name | "This is the DAPAR trip." | Tests vocabulary + unusual words |
| Technical phrase | "Set the DM timeout minutes to 30." | Numbers + jargon |
| Similar-sounding words | "Help me fill this in." | fill/feel, in/thing confusion |
| App name + context | "Can you check my Outlook?" | Capitalization + context |
| Git command | "Commit and push." | Short technical phrase |
| Medium natural speech | "I'll be there next week for the meeting." | Conversational baseline |
| Vocab-heavy | "Update the slash command for the mail MCP." | Tests vocabulary biasing |

### Procedure

1. Say each sentence using the hotkey at normal speaking pace
2. Record what the STT returned (pasted text or history API)
3. Check debug metadata: `cat debug_audio/*_meta.txt | tail -15`
4. Rate each result (see scale below)
5. After all tests, move files: `mv debug_audio/2026* debug_audio/test_run_XX/`
6. Disable debug audio: `curl -X PUT http://localhost:8000/api/settings/save_debug_audio -H 'Content-Type: application/json' -d '{"value": false}'`

### Rating Scale

- **A** = Perfect transcription, exact words
- **B** = Minor issue (punctuation, capitalization, dropped prefix) but all words correct
- **C** = 1-2 wrong words but meaning preserved
- **D** = Meaning changed or significant words wrong
- **F** = Gibberish or completely wrong

### What to Check in Debug Metadata

- **RMS (original):** <300 = very quiet mic, check positioning
- **Gain:** >20dB = mic is too quiet, consider a better mic
- **Duration:** <1.5s clips are harder for all providers
- **Padded:** If false on short clips, consider enabling `silence_padding`

---

## Baseline Results (2026-02-04)

### Run 1: PS4 mic, PortAudio 16kHz capture (before resample fix)

Provider: Groq, Language: AUTO, Normalization: On

| # | Expected | Got | Dur | Rating |
|---|----------|-----|-----|--------|
| 1 | Check my email. | Check my email. | 1.1s | A |
| 2 | Try again. | Try again. | 0.9s | A |
| 3 | This is the DAPAR trip. | This is the DabHot Trip. | 1.3s | D |
| 4 | Set the DM timeout minutes to 30. | 7DM timeout miniature city. | 2.2s | F |
| 5 | Help me fill this in. | Help me feel this thing. | 1.4s | D |
| 6 | Can you check my Outlook? I want out. | Can you check my outlook? I went out. | 2.3s | C |
| 7 | Commit and push. | Commit your push. | 1.0s | C |
| 8 | The vocabulary file auto-reloads when changed. | The vocabulary file auto-loads when changed. | 3.1s | B |
| 9 | I'll be there next week for the meeting. | I'll be there next week for the movie. | 2.0s | D |
| 10 | Update the slash command for the mail MCP. | Update the slash command for the mail MCP. | 2.5s | A |

**Score: 3A, 1B, 2C, 3D, 1F** — Short clips with unusual words consistently fail.

### Run 2: PS4 mic, scipy resample 48kHz→16kHz (after fix)

Provider: Groq, Language: AUTO, Normalization: On

| # | Expected | Got | Dur | Rating | Delta |
|---|----------|-----|-----|--------|-------|
| 3 | This is the DAPAR trip. | This is the Dapa trip. | 1.6s | C | D→C |
| 4 | Set the DM timeout minutes to 30. | Set the DM timeout minute to 30. | 3.1s | B | F→B |
| 5 | Help me fill this in. | Help me fill this in. | 2.3s | A | D→A |
| 6 | Can you check my Outlook? I want out. | Can you check my outlook? I went out. | 2.6s | C | C→C |
| 7 | Commit and push. | Commit and push. | 1.3s | A | C→A |
| 9 | I'll be there next week for the meeting. | I'll be there next week for the meeting. | 2.2s | A | D→A |

**Resample fix improved 4 of 6 failed tests.** 3 became perfect (A), 1 went F→B.

### Run 3: Different mic, scipy resample (after fix)

Provider: Groq, Language: AUTO, Normalization: On, Higher RMS (700-1000)

| # | Expected | Got | Rating | Notes |
|---|----------|-----|--------|-------|
| 3 | This is the DAPAR trip. | This is the DARPA trip. | B | Model knows DARPA not DAPAR |
| 4 | Set the DM timeout minutes to 30. | Set the DN timeout minute to 30. | C | DM→DN |
| 5 | Help me fill this in. | Help me feel this ink. | D | Regressed — spoken differently? |
| 6 | Can you check my Outlook? I want out. | Can you check my outlook? I went out. | C | want→went persists |
| 7 | Commit and push. | Commit and push. | A | Consistent |
| 9 | I'll be there next week for the meeting. | I'll be there next week for the meeting. | A | Consistent |

### Key Findings

1. **Resampling fix (48kHz→16kHz with anti-aliasing) was the biggest improvement**
2. **Proper nouns not in vocabulary consistently fail** — add them to vocabulary.txt
3. **"want"→"went" is a persistent Groq issue** across all mics and runs
4. **Clips >2s are significantly more accurate** than clips <1.5s
5. **Vocabulary biasing works** — terms in vocabulary.txt (MCP, slash command) transcribe perfectly

---
description: Add vocabulary words from text, images, or files to vocabulary.txt
---

Extract vocabulary words from the provided input and append them to the project's vocabulary file.

## Input
$ARGUMENTS

## Task

1. **Parse the input** which can be:
   - Plain text with words (comma-separated, newline-separated, or bullet points)
   - File path(s) to images - read the image and extract relevant terms/words
   - File path(s) to text/code files - extract key terms
   - Any combination of the above

2. **Extract words**:
   - If input contains image paths, read each image and identify vocabulary terms
   - If input contains file paths, read the files and extract terms
   - If input is plain text, parse words from commas, newlines, or bullet points
   - Clean each word: trim whitespace, preserve intended casing

3. **Read existing vocabulary** from `backend/vocabulary.txt`

4. **Append new words**:
   - Skip words that already exist (case-insensitive comparison)
   - Add one word per line to `backend/vocabulary.txt`
   - Preserve existing comments and structure

5. **Report results**:
   - List words that were added
   - List words that were skipped (already existed)
   - Show total count

## Vocabulary file location
`backend/vocabulary.txt`

## Examples

Input: `FastAPI, MLX, Whisper`
→ Adds 3 words (if not already present)

Input: `/path/to/screenshot.png`
→ Reads image, extracts visible terms, adds them

Input:
```
FastAPI
WebSocket
MLX
```
→ Adds 3 words from the list

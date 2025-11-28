#!/usr/bin/env python3
"""Global hotkey client for local STT.

Listens for Ctrl+Option system-wide and records audio when held.
Sends audio to the server and copies transcription to clipboard.

Usage:
    uv run --extra client python hotkey_client.py
"""

import io
import subprocess
import sys
import threading
import wave
from typing import Optional

import httpx
import numpy as np
import sounddevice as sd
from pynput import keyboard

# Configuration
SERVER_URL = "http://127.0.0.1:8000"
SAMPLE_RATE = 16000
CHANNELS = 1


class HotkeyClient:
    """Global hotkey listener for speech-to-text."""

    def __init__(self):
        self.ctrl_pressed = False
        self.opt_pressed = False
        self.is_recording = False
        self.is_processing = False
        self.audio_data: list[np.ndarray] = []
        self.stream: Optional[sd.InputStream] = None
        self.lock = threading.Lock()

    def copy_to_clipboard(self, text: str) -> bool:
        """Copy text to clipboard using pbcopy (macOS)."""
        try:
            subprocess.run(
                ["pbcopy"],
                input=text.encode("utf-8"),
                check=True,
            )
            return True
        except subprocess.CalledProcessError:
            print("Failed to copy to clipboard")
            return False

    def audio_callback(
        self,
        indata: np.ndarray,
        frames: int,
        time_info: dict,
        status: sd.CallbackFlags,
    ):
        """Callback for audio stream - stores audio chunks."""
        if status:
            print(f"Audio status: {status}")
        if self.is_recording:
            self.audio_data.append(indata.copy())

    def start_recording(self):
        """Start recording audio."""
        with self.lock:
            if self.is_recording or self.is_processing:
                return

            self.is_recording = True
            self.audio_data = []

            print("🎤 Recording... (release keys to stop)")

            self.stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="int16",
                callback=self.audio_callback,
            )
            self.stream.start()

    def stop_recording(self):
        """Stop recording and send to server."""
        with self.lock:
            if not self.is_recording:
                return

            self.is_recording = False

            if self.stream:
                self.stream.stop()
                self.stream.close()
                self.stream = None

            print("⏹️  Recording stopped, transcribing...")
            self.is_processing = True

        # Process in background thread to not block key listener
        threading.Thread(target=self._process_audio, daemon=True).start()

    def _process_audio(self):
        """Convert audio and send to server."""
        try:
            if not self.audio_data:
                print("No audio recorded")
                self.is_processing = False
                return

            # Combine audio chunks
            audio = np.concatenate(self.audio_data)

            # Convert to WAV bytes
            wav_buffer = io.BytesIO()
            with wave.open(wav_buffer, "wb") as wav_file:
                wav_file.setnchannels(CHANNELS)
                wav_file.setsampwidth(2)  # 16-bit
                wav_file.setframerate(SAMPLE_RATE)
                wav_file.writeframes(audio.tobytes())

            wav_buffer.seek(0)

            # Send to server
            with httpx.Client(timeout=60.0) as client:
                response = client.post(
                    f"{SERVER_URL}/api/transcribe",
                    files={"file": ("audio.wav", wav_buffer, "audio/wav")},
                )
                response.raise_for_status()
                result = response.json()

            text = result.get("text", "").strip()

            if text:
                print(f"📝 Transcription: {text}")
                print(f"   Language: {result.get('language', 'unknown')}")
                print(f"   Duration: {result.get('duration', 0):.1f}s")

                # Copy to clipboard
                if self.copy_to_clipboard(text):
                    print("📋 Copied to clipboard!")
            else:
                print("No speech detected")

        except httpx.ConnectError:
            print("❌ Cannot connect to server. Is it running?")
        except Exception as e:
            print(f"❌ Error: {e}")
        finally:
            self.is_processing = False

    def on_press(self, key):
        """Handle key press events."""
        try:
            if key == keyboard.Key.ctrl_l or key == keyboard.Key.ctrl_r:
                self.ctrl_pressed = True
            elif key == keyboard.Key.alt_l or key == keyboard.Key.alt_r:
                self.opt_pressed = True

            # Start recording when both keys pressed
            if self.ctrl_pressed and self.opt_pressed:
                self.start_recording()
        except Exception:
            pass

    def on_release(self, key):
        """Handle key release events."""
        try:
            if key == keyboard.Key.ctrl_l or key == keyboard.Key.ctrl_r:
                self.ctrl_pressed = False
            elif key == keyboard.Key.alt_l or key == keyboard.Key.alt_r:
                self.opt_pressed = False

            # Stop recording when either key released
            if self.is_recording and (not self.ctrl_pressed or not self.opt_pressed):
                self.stop_recording()
        except Exception:
            pass

    def check_server(self) -> bool:
        """Check if server is running."""
        try:
            with httpx.Client(timeout=5.0) as client:
                response = client.get(f"{SERVER_URL}/")
                return response.status_code == 200
        except Exception:
            return False

    def run(self):
        """Start the hotkey listener."""
        print("=" * 50)
        print("Local STT - Global Hotkey Client")
        print("=" * 50)

        # Check server
        print(f"Checking server at {SERVER_URL}...")
        if not self.check_server():
            print("❌ Server not running. Please start the server first:")
            print("   ./scripts/start.sh")
            sys.exit(1)

        print("✅ Server connected")
        print()
        print("🎯 Ready! Hold Ctrl + Option to record.")
        print("   Release to transcribe and copy to clipboard.")
        print("   Press Ctrl+C to exit.")
        print()

        # Start keyboard listener
        with keyboard.Listener(
            on_press=self.on_press,
            on_release=self.on_release,
        ) as listener:
            try:
                listener.join()
            except KeyboardInterrupt:
                print("\nExiting...")


def main():
    client = HotkeyClient()
    client.run()


if __name__ == "__main__":
    main()

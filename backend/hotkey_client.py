#!/usr/bin/env python3
"""Global hotkey client for local STT.

Reads keybinding from server settings and listens for that hotkey globally.
Sends audio to the server (which uses its language setting), copies
transcription to clipboard, auto-pastes, and restores original clipboard.

Usage:
    uv run --extra client python hotkey_client.py
"""

import io
import subprocess
import sys
import threading
import time
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
        self.modifier_pressed = False  # Ctrl or Shift depending on keybinding
        self.opt_pressed = False
        self.is_recording = False
        self.is_processing = False
        self.audio_data: list[np.ndarray] = []
        self.stream: Optional[sd.InputStream] = None
        self.lock = threading.Lock()

        # Settings from server
        self.keybinding = "ctrl"  # Will be fetched from server
        self.language_display = "AUTO"
        self.paste_delay = 0.5  # Will be fetched from server
        self.clipboard_sync_delay = 0.15  # Will be fetched from server

    def fetch_settings(self) -> bool:
        """Fetch current settings from server."""
        try:
            with httpx.Client(timeout=5.0) as client:
                response = client.get(f"{SERVER_URL}/api/settings")
                response.raise_for_status()
                data = response.json()
                self.keybinding = data.get("keybinding", "ctrl")
                self.language_display = data.get("language_display", "AUTO")
                self.paste_delay = data.get("paste_delay", 0.5)
                self.clipboard_sync_delay = data.get("clipboard_sync_delay", 0.15)
                return True
        except Exception as e:
            print(f"Failed to fetch settings: {e}")
            return False

    def get_keybinding_display(self) -> str:
        """Get human-readable keybinding."""
        return "Ctrl + Option" if self.keybinding == "ctrl" else "Shift + Option"

    def is_modifier_key(self, key) -> bool:
        """Check if key is the configured modifier."""
        if self.keybinding == "ctrl":
            return key == keyboard.Key.ctrl_l or key == keyboard.Key.ctrl_r
        else:
            return key == keyboard.Key.shift_l or key == keyboard.Key.shift_r

    def get_clipboard(self) -> Optional[str]:
        """Get current clipboard content (macOS)."""
        try:
            result = subprocess.run(
                ["pbpaste"],
                capture_output=True,
                check=True,
            )
            return result.stdout.decode("utf-8")
        except subprocess.CalledProcessError:
            return None

    def set_clipboard(self, text: str) -> bool:
        """Set clipboard content (macOS)."""
        try:
            subprocess.run(
                ["pbcopy"],
                input=text.encode("utf-8"),
                check=True,
            )
            return True
        except subprocess.CalledProcessError:
            return False

    def simulate_paste(self) -> bool:
        """Simulate Cmd+V paste using AppleScript (macOS)."""
        try:
            result = subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to keystroke "v" using command down',
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            return True
        except subprocess.CalledProcessError as e:
            # Common cause: Terminal needs Accessibility permissions
            print(f"⚠️  Paste failed: {e.stderr.strip() if e.stderr else 'Unknown error'}")
            print("   → Grant Accessibility access: System Settings → Privacy & Security → Accessibility")
            return False

    def auto_paste_and_restore(self, text: str) -> bool:
        """
        Auto-paste text and restore original clipboard.

        1. Save original clipboard content
        2. Copy transcribed text to clipboard
        3. Simulate Cmd+V paste
        4. Wait for paste_delay
        5. Restore original clipboard
        """
        # Save original clipboard
        original_clipboard = self.get_clipboard()

        # Copy transcribed text
        if not self.set_clipboard(text):
            print("Failed to copy to clipboard")
            return False

        # Delay to ensure clipboard is fully synced before paste
        time.sleep(self.clipboard_sync_delay)

        # Simulate paste
        if not self.simulate_paste():
            # Paste failed (likely permissions), but text IS in clipboard
            print("📋 Text copied to clipboard (paste manually with Cmd+V)")
            return False

        # Wait for configurable delay
        time.sleep(self.paste_delay)

        # Restore original clipboard
        if original_clipboard is not None:
            self.set_clipboard(original_clipboard)
            print("📋 Clipboard restored")

        return True

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

            # Send to server (server uses its language setting)
            with httpx.Client(timeout=60.0) as client:
                response = client.post(
                    f"{SERVER_URL}/api/transcribe",
                    files={"file": ("audio.wav", wav_buffer, "audio/wav")},
                )
                response.raise_for_status()
                result = response.json()

            text = result.get("text", "").strip()

            if text:
                lang = result.get("language", "?").upper()
                duration = result.get("duration", 0)
                proc_time = result.get("processing_time", 0)

                print(f"📝 \"{text}\"")
                print(f"   [{lang}] {duration:.1f}s audio → {proc_time:.2f}s processing")

                # Auto-paste and restore clipboard
                if self.auto_paste_and_restore(text):
                    print("✅ Auto-pasted!")
            else:
                print("No speech detected")

        except httpx.ConnectError:
            print("❌ Cannot connect to server. Is it running?")
        except Exception as e:
            print(f"❌ Error: {e}")
        finally:
            self.is_processing = False
            print()  # Blank line for readability

    def on_press(self, key):
        """Handle key press events."""
        try:
            if self.is_modifier_key(key):
                self.modifier_pressed = True
            elif key == keyboard.Key.alt_l or key == keyboard.Key.alt_r:
                self.opt_pressed = True

            # Start recording when both keys pressed
            if self.modifier_pressed and self.opt_pressed:
                self.start_recording()
        except Exception:
            pass

    def on_release(self, key):
        """Handle key release events."""
        try:
            if self.is_modifier_key(key):
                self.modifier_pressed = False
            elif key == keyboard.Key.alt_l or key == keyboard.Key.alt_r:
                self.opt_pressed = False

            # Stop recording when either key released
            if self.is_recording and (not self.modifier_pressed or not self.opt_pressed):
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
        print("  Local STT - Global Hotkey Client")
        print("=" * 50)

        # Check server
        print(f"Connecting to {SERVER_URL}...")
        if not self.check_server():
            print("❌ Server not running. Please start the server first:")
            print("   ./scripts/start.sh")
            sys.exit(1)

        # Fetch settings from server
        if not self.fetch_settings():
            print("❌ Could not fetch settings from server")
            sys.exit(1)

        print("✅ Connected")
        print()
        print(f"  Keybinding:       {self.get_keybinding_display()}")
        print(f"  Language:         {self.language_display}")
        print(f"  Clipboard sync:   {self.clipboard_sync_delay:.2f}s")
        print(f"  Paste delay:      {self.paste_delay:.1f}s")
        print()
        print(f"🎯 Hold {self.get_keybinding_display()} to record")
        print("   Release to transcribe → auto-paste")
        print()
        print("   (Change settings in web UI: http://127.0.0.1:8000)")
        print("   Press Ctrl+C to exit")
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

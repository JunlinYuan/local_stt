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

from pathlib import Path

# macOS APIs for focus-follows-mouse (imported at module level for speed)
from Quartz import (
    CGWindowListCopyWindowInfo,
    kCGWindowListOptionOnScreenOnly,
    kCGNullWindowID,
    CGEventGetLocation,
    CGEventCreate,
)


class RecordingIndicator:
    """Screen edge overlay that shows recording/processing state.

    Runs as a subprocess because macOS requires tkinter on main thread.

    Colors:
        - Red (#FF3B30): Recording in progress
        - Blue (#007AFF): Processing/transcribing
        - Orange (#FF9500): Error/disconnected state
    """

    COLOR_RECORDING = "#FF3B30"  # Red
    COLOR_PROCESSING = "#007AFF"  # Blue
    COLOR_ERROR = "#FF9500"  # Orange (error/disconnected)

    def __init__(self, border_width: int = 6):
        self.border_width = border_width
        self._process: Optional[subprocess.Popen] = None
        self._script_path = Path(__file__).parent / "scripts" / "recording_indicator.py"

    def _spawn(self, color: str):
        """Spawn indicator subprocess with specified color."""
        if not self._script_path.exists():
            return

        try:
            self._process = subprocess.Popen(
                [
                    sys.executable,
                    str(self._script_path),
                    str(self.border_width),
                    color,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass  # Non-critical, just skip indicator

    def show(self):
        """Show the recording indicator (red border)."""
        if self._process is not None:
            return  # Already showing
        self._spawn(self.COLOR_RECORDING)

    def show_processing(self):
        """Switch to processing indicator (blue border)."""
        self.hide()  # Terminate existing
        self._spawn(self.COLOR_PROCESSING)

    def show_error(self):
        """Switch to error indicator (orange border)."""
        self.hide()  # Terminate existing
        self._spawn(self.COLOR_ERROR)

    def hide(self):
        """Hide the indicator by terminating subprocess."""
        if self._process is None:
            return

        try:
            self._process.terminate()
            self._process.wait(timeout=1.0)
        except Exception:
            try:
                self._process.kill()
            except Exception:
                pass
        finally:
            self._process = None

    def is_available(self) -> bool:
        """Check if indicator script exists."""
        return self._script_path.exists()


# Configuration
SERVER_URL = "http://127.0.0.1:8000"
SAMPLE_RATE = 16000
CHANNELS = 1


class HotkeyClient:
    """Global hotkey listener for speech-to-text.

    Uses LEFT-side modifier keys only to avoid conflict with proactive_companion
    which uses right-side keys.
    """

    def __init__(self):
        self.left_modifier_pressed = False  # Left Ctrl or Left Shift
        self.left_cmd_pressed = False  # Left Command only
        self.is_recording = False
        self.is_processing = False
        self.recording_cancelled = False  # Prevents re-trigger until keys released
        self.recording_start_time: float = 0.0
        self.audio_data: list[np.ndarray] = []
        self.stream: Optional[sd.InputStream] = None
        self.lock = threading.Lock()

        # Settings from server
        self.keybinding = "ctrl"  # Will be fetched from server
        self.language_display = "AUTO"
        self.min_recording_duration = 0.3  # Will be fetched from server
        self.clipboard_sync_delay = 0.025  # Will be fetched from server (25ms)
        self.paste_delay = 0.025  # Will be fetched from server (25ms)
        self.max_recording_duration = 240  # Will be fetched from server (4 min default)

        # Persistent HTTP client for server communication (reused across calls)
        self._http_client: Optional[httpx.Client] = None

        # Visual recording indicator (red screen border)
        self.indicator = RecordingIndicator()

        # Focus-follows-mouse state (fetched from server settings)
        self._ffm_enabled = True  # Will be updated by fetch_settings()
        self._ffm_mode = "track_only"  # "track_only" or "raise_on_hover"
        self._ffm_thread: Optional[threading.Thread] = None
        self._ffm_stop = threading.Event()
        self._ffm_last_app: Optional[str] = None
        self._ffm_last_focus_time: float = 0.0  # When we last focused an app
        self._ffm_cooldown: float = 0.15  # Don't re-check for 150ms after focusing
        self._ffm_dwell_start: float = 0.0  # When mouse started dwelling on current app
        self._ffm_dwell_app: Optional[str] = None  # App mouse is dwelling on
        self._ffm_dwell_threshold: float = 0.05  # Require 50ms dwell before focusing

        # Settings polling state
        self._settings_thread: Optional[threading.Thread] = None
        self._settings_stop = threading.Event()

        # Health check state
        self._server_healthy = True
        self._provider_available = True
        self._last_health_check: float = 0.0
        self._health_check_interval = 20.0  # Check every 20 seconds

    def _get_app_under_mouse_fast(self) -> Optional[str]:
        """Fast version using direct Quartz API (no subprocess)."""
        try:
            # Get mouse position
            event = CGEventCreate(None)
            mouse = CGEventGetLocation(event)
            mouse_x, mouse_y = mouse.x, mouse.y

            # Get all on-screen windows
            windows = CGWindowListCopyWindowInfo(
                kCGWindowListOptionOnScreenOnly, kCGNullWindowID
            )

            for win in windows:
                bounds = win.get("kCGWindowBounds", {})
                x = bounds.get("X", 0)
                y = bounds.get("Y", 0)
                w = bounds.get("Width", 0)
                h = bounds.get("Height", 0)
                owner = win.get("kCGWindowOwnerName", "")
                layer = win.get("kCGWindowLayer", 0)

                # Only consider normal windows (layer 0)
                if layer != 0:
                    continue

                # Check if mouse is in this window
                if x <= mouse_x <= x + w and y <= mouse_y <= y + h:
                    return owner

            return None
        except Exception:
            return None

    def _focus_app_fast(self, app_name: str) -> bool:
        """Focus app using AppleScript (blocking)."""
        try:
            safe_name = app_name.replace("\\", "\\\\").replace('"', '\\"')
            subprocess.run(
                ["osascript", "-e", f'tell application "{safe_name}" to activate'],
                capture_output=True,
                timeout=0.3,  # Short timeout to keep FFM responsive
            )
            return True
        except subprocess.TimeoutExpired:
            return False
        except Exception:
            return False

    def get_http_client(self) -> httpx.Client:
        """Get or create persistent HTTP client for server communication."""
        if self._http_client is None:
            self._http_client = httpx.Client(
                base_url=SERVER_URL,
                timeout=60.0,  # Long timeout for transcription
            )
        return self._http_client

    def close(self):
        """Clean up resources."""
        if self._http_client is not None:
            self._http_client.close()
            self._http_client = None

    def fetch_settings(self, silent: bool = False) -> bool:
        """Fetch current settings from server.

        Args:
            silent: If True, don't print changes (used for initial fetch)
        """
        try:
            client = self.get_http_client()
            response = client.get("/api/settings")
            response.raise_for_status()
            data = response.json()

            # Detect keybinding change
            new_keybinding = data.get("keybinding", "ctrl_only")
            keybinding_changed = new_keybinding != self.keybinding
            self.keybinding = new_keybinding

            if not silent and keybinding_changed:
                print(f"⚙️  Keybinding changed to: {self.get_keybinding_display()}")
            self.language_display = data.get("language_display", "AUTO")
            self.min_recording_duration = data.get("min_recording_duration", 0.3)
            self.clipboard_sync_delay = data.get("clipboard_sync_delay", 0.025)
            self.paste_delay = data.get("paste_delay", 0.025)
            self.max_recording_duration = data.get("max_recording_duration", 240)

            # Detect FFM setting change and start/stop dynamically
            new_ffm_enabled = data.get("ffm_enabled", True)
            ffm_changed = new_ffm_enabled != self._ffm_enabled
            self._ffm_enabled = new_ffm_enabled

            # Update FFM mode
            new_ffm_mode = data.get("ffm_mode", "track_only")
            if new_ffm_mode != self._ffm_mode:
                print(f"⚙️  FFM mode changed to: {new_ffm_mode}")
            self._ffm_mode = new_ffm_mode

            if ffm_changed:
                if self._ffm_enabled:
                    self.start_focus_follows_mouse()
                else:
                    self.stop_focus_follows_mouse()

            return True
        except Exception as e:
            if not silent:
                print(f"Failed to fetch settings: {e}")
            return False

    def _settings_poll_loop(self):
        """Background loop that polls for settings changes and health status."""
        health_check_counter = 0
        while not self._settings_stop.is_set():
            self._settings_stop.wait(2.0)  # Poll every 2 seconds
            if self._settings_stop.is_set():
                break
            self.fetch_settings(silent=False)

            # Health check every ~20 seconds (every 10 settings polls)
            health_check_counter += 1
            if health_check_counter >= 10:
                self.check_health()
                health_check_counter = 0

    def start_settings_polling(self):
        """Start the settings polling background thread."""
        if self._settings_thread is not None:
            return

        self._settings_stop.clear()
        self._settings_thread = threading.Thread(
            target=self._settings_poll_loop,
            daemon=True,
        )
        self._settings_thread.start()

    def stop_settings_polling(self):
        """Stop the settings polling background thread."""
        if self._settings_thread is None:
            return

        self._settings_stop.set()
        self._settings_thread.join(timeout=3.0)
        self._settings_thread = None

    def send_status(self, recording: bool, cancelled: bool = False) -> None:
        """Notify server of recording status (broadcasts to web UI)."""
        try:
            client = self.get_http_client()
            client.post(
                "/api/status",
                json={"recording": recording, "cancelled": cancelled},
            )
        except Exception:
            pass  # Non-critical, don't print errors

    def send_log(self, message: str, level: str = "info") -> None:
        """Send log message to web UI console (broadcasts via server)."""
        try:
            client = self.get_http_client()
            client.post(
                "/api/log",
                json={"level": level, "message": message},
            )
        except Exception:
            pass  # Non-critical

    def get_keybinding_display(self) -> str:
        """Get human-readable keybinding."""
        return {
            "ctrl_only": "Left Ctrl",
            "ctrl": "Left Ctrl + Left Command",
            "shift": "Left Shift + Left Command",
        }.get(self.keybinding, self.keybinding)

    def is_left_modifier_key(self, key) -> bool:
        """Check if key is the configured LEFT-side modifier."""
        if self.keybinding in ("ctrl_only", "ctrl"):
            return key == keyboard.Key.ctrl_l
        else:  # shift
            return key == keyboard.Key.shift_l

    def is_recording_trigger_satisfied(self) -> bool:
        """Check if all required keys for recording are pressed."""
        if self.keybinding == "ctrl_only":
            return self.left_modifier_pressed  # Only need Ctrl
        else:  # ctrl or shift mode requires both keys
            return self.left_modifier_pressed and self.left_cmd_pressed

    def is_trigger_key(self, key) -> bool:
        """Check if key is part of the current recording trigger combination."""
        if self.keybinding == "ctrl_only":
            return key == keyboard.Key.ctrl_l
        else:  # ctrl or shift mode
            return self.is_left_modifier_key(key) or key == keyboard.Key.cmd_l

    def _focus_follows_mouse_loop(self):
        """Background loop that tracks/focuses window under mouse.

        Behavior depends on ffm_mode setting:
        - track_only: Just track which app is under cursor (activate at paste time)
        - raise_on_hover: Activate/raise windows as mouse moves (old behavior)

        Uses debouncing to prevent thrashing.
        """
        mode_desc = (
            "track only (activate at paste)"
            if self._ffm_mode == "track_only"
            else "raise on hover"
        )
        print(f"🖱️  Mouse tracking enabled ({mode_desc})")

        while not self._ffm_stop.is_set():
            try:
                now = time.time()

                # In raise_on_hover mode, skip when left Command is held (pause FFM)
                if self._ffm_mode == "raise_on_hover" and self.left_cmd_pressed:
                    self._ffm_dwell_app = None
                    time.sleep(0.01)
                    continue

                # In raise_on_hover mode, apply cooldown after focusing
                if self._ffm_mode == "raise_on_hover":
                    if now - self._ffm_last_focus_time < self._ffm_cooldown:
                        time.sleep(0.01)
                        continue

                app = self._get_app_under_mouse_fast()

                if app and app not in ("Dock", "Control Center", "Notification Center"):
                    # Track dwell time on this app
                    if app != self._ffm_dwell_app:
                        # Mouse moved to new app, start dwell timer
                        self._ffm_dwell_app = app
                        self._ffm_dwell_start = now
                    elif app != self._ffm_last_app:
                        # Same app, check if dwell threshold met
                        if now - self._ffm_dwell_start >= self._ffm_dwell_threshold:
                            self._ffm_last_app = app
                            # In raise_on_hover mode, also activate the app
                            if self._ffm_mode == "raise_on_hover":
                                self._focus_app_fast(app)
                                self._ffm_last_focus_time = now
                else:
                    # Mouse over excluded app or nothing
                    self._ffm_dwell_app = None

            except Exception:
                pass

            time.sleep(0.01)  # 10ms polling

    def start_focus_follows_mouse(self):
        """Start the focus-follows-mouse background thread."""
        if self._ffm_thread is not None:
            return  # Already running

        self._ffm_stop.clear()
        self._ffm_thread = threading.Thread(
            target=self._focus_follows_mouse_loop,
            daemon=True,
        )
        self._ffm_thread.start()

    def stop_focus_follows_mouse(self):
        """Stop the focus-follows-mouse background thread."""
        if self._ffm_thread is None:
            return

        self._ffm_stop.set()
        self._ffm_thread.join(timeout=1.0)
        self._ffm_thread = None
        print("🖱️  Mouse tracking stopped")

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

    def simulate_paste(self, target_app: Optional[str] = None) -> bool:
        """Simulate Cmd+V paste using AppleScript (macOS).

        Args:
            target_app: If provided, send paste to this specific app/process
                       without activating it. If None, pastes to frontmost app.
        """
        try:
            if target_app:
                # Send keystroke to specific process (doesn't activate/raise)
                safe_name = target_app.replace("\\", "\\\\").replace('"', '\\"')
                script = f'''
                    tell application "System Events"
                        tell process "{safe_name}"
                            keystroke "v" using command down
                        end tell
                    end tell
                '''
            else:
                # Fallback: paste to frontmost app
                script = 'tell application "System Events" to keystroke "v" using command down'

            subprocess.run(
                ["osascript", "-e", script],
                check=True,
                capture_output=True,
                text=True,
            )
            return True
        except subprocess.CalledProcessError as e:
            # Common cause: Terminal needs Accessibility permissions
            print(
                f"⚠️  Paste failed: {e.stderr.strip() if e.stderr else 'Unknown error'}"
            )
            print(
                "   → Grant Accessibility access: System Settings → Privacy & Security → Accessibility"
            )
            return False

    def auto_paste_and_restore(self, text: str) -> bool:
        """
        Auto-paste text and restore original clipboard.

        Uses tracked app under mouse for targeted paste:
        1. In track_only mode: activate the target app (it wasn't raised on hover)
        2. Save original clipboard
        3. Copy text to clipboard
        4. Paste to now-active app
        5. Restore original clipboard
        """
        # Get the app that was under mouse (tracked by FFM loop)
        target_app = self._ffm_last_app if self._ffm_enabled else None

        # In track_only mode, activate the target app so it receives the paste
        # (In raise_on_hover mode, the app is already active from hovering)
        if target_app and self._ffm_mode == "track_only":
            self._focus_app_fast(target_app)

        # Save original clipboard
        original_clipboard = self.get_clipboard()

        # Copy transcribed text
        if not self.set_clipboard(text):
            print("Failed to copy to clipboard")
            return False

        # Brief delay for macOS pasteboard to propagate
        if self.clipboard_sync_delay > 0:
            time.sleep(self.clipboard_sync_delay)

        # Paste to now-active app (we activated target_app above if needed)
        if not self.simulate_paste():
            print("📋 Text copied to clipboard (paste manually with Cmd+V)")
            return False

        if target_app:
            print(f"   Target: {target_app}")

        # Brief delay for app to read clipboard
        if self.paste_delay > 0:
            time.sleep(self.paste_delay)

        # Restore original clipboard
        if original_clipboard is not None:
            self.set_clipboard(original_clipboard)

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

            # Show visual indicator IMMEDIATELY for responsive feedback
            self.indicator.show()

            self.audio_data = []

            # Refresh PortAudio device list to pick up hot-swapped microphones
            # Without this, sounddevice uses a stale cached device list
            try:
                sd._terminate()
                sd._initialize()
            except Exception:
                pass  # Non-critical if refresh fails

            # Query current default input device
            try:
                default_input = sd.query_devices(kind="input")
                device_index = default_input["index"]
                device_name = default_input["name"]
            except Exception:
                device_index = None
                device_name = "default"

            # Try to open audio stream with retry logic
            stream = None
            last_error = None
            for attempt in range(3):
                try:
                    stream = sd.InputStream(
                        device=device_index,
                        samplerate=SAMPLE_RATE,
                        channels=CHANNELS,
                        dtype="int16",
                        callback=self.audio_callback,
                    )
                    stream.start()
                    break  # Success
                except Exception as e:
                    last_error = e
                    if stream:
                        try:
                            stream.close()
                        except Exception:
                            pass
                    stream = None

                    if attempt < 2:
                        # Wait briefly and retry (audio device may need time to release)
                        time.sleep(0.1)
                        # On retry, try default device
                        device_index = None

            if stream is None:
                self.indicator.hide()  # Hide if audio setup failed
                print(f"⚠️  Audio device error: {last_error}")
                print(
                    "   → Try: Close other apps using microphone, or check System Settings → Sound → Input"
                )
                return

            # Only set recording state after stream is successfully opened
            self.is_recording = True
            self.recording_start_time = time.time()
            self.stream = stream

            print("🎤 Recording... (release keys to stop)")
            print(f"   Using: {device_name}")

            # Notify web UI
            self.send_status(recording=True)

            # Start watchdog timer to auto-stop if key release is missed
            threading.Thread(target=self._recording_watchdog, daemon=True).start()

    def stop_recording(self):
        """Stop recording and send to server."""
        with self.lock:
            if not self.is_recording:
                return

            self.is_recording = False
            recording_duration = time.time() - self.recording_start_time

            if self.stream:
                # Use timeout wrapper to prevent freeze if audio device hangs
                def close_stream():
                    try:
                        self.stream.stop()
                        self.stream.close()
                    except Exception:
                        pass

                close_thread = threading.Thread(target=close_stream, daemon=True)
                close_thread.start()
                close_thread.join(timeout=1.0)  # Max 1 second to close
                if close_thread.is_alive():
                    print("⚠️  Audio stream close timed out (continuing anyway)")
                self.stream = None

            # Skip if recording was too short (accidental tap)
            if recording_duration < self.min_recording_duration:
                print(f"⏭️  Recording too short ({recording_duration:.2f}s), skipping")
                self.indicator.hide()
                self.send_status(recording=False, cancelled=True)
                return

            print("⏹️  Recording stopped, transcribing...")
            self.is_processing = True

            # Switch to blue processing indicator
            self.indicator.show_processing()

            # Notify web UI (recording stopped, now processing)
            self.send_status(recording=False)

        # Process in background thread to not block key listener
        threading.Thread(target=self._process_audio, daemon=True).start()

    def cancel_recording(self):
        """Cancel recording and discard audio without transcription.

        Called when user presses any non-trigger key during recording.
        Sets recording_cancelled flag to prevent re-triggering until keys released.
        """
        with self.lock:
            if not self.is_recording:
                return

            self.is_recording = False
            self.recording_cancelled = True  # Prevent re-trigger

            if self.stream:
                # Use timeout wrapper to prevent freeze
                def close_stream():
                    try:
                        self.stream.stop()
                        self.stream.close()
                    except Exception:
                        pass

                close_thread = threading.Thread(target=close_stream, daemon=True)
                close_thread.start()
                close_thread.join(timeout=1.0)
                self.stream = None

            # Discard audio data
            self.audio_data = []

        self.indicator.hide()
        self.send_status(recording=False, cancelled=True)

    def _recording_watchdog(self):
        """Watchdog timer to auto-stop recording if key release is missed.

        This handles cases where macOS/pynput misses the key release event
        (e.g., when switching windows while holding keys).
        """
        start_time = self.recording_start_time
        while self.is_recording:
            elapsed = time.time() - start_time
            if elapsed >= self.max_recording_duration:
                print(
                    f"⚠️  Recording timeout ({self.max_recording_duration}s), auto-stopping..."
                )
                # Reset key state to prevent stuck keys
                self.left_modifier_pressed = False
                self.left_cmd_pressed = False
                self.stop_recording()
                break
            time.sleep(0.5)  # Check every 500ms

    def _process_audio(self):
        """Convert audio and send to server."""
        try:
            if not self.audio_data:
                print("No audio recorded")
                self.indicator.hide()
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

            # Check health before sending (early warning for network issues)
            if not self._server_healthy:
                print("⚠️  Server appears offline - attempting transcription anyway...")

            # Send to server with explicit timeout (server uses its language setting)
            # The 60s timeout is for the transcription itself; network issues should fail faster
            client = self.get_http_client()
            try:
                response = client.post(
                    "/api/transcribe",
                    files={"file": ("audio.wav", wav_buffer, "audio/wav")},
                    timeout=60.0,  # Long timeout for actual transcription
                )
                response.raise_for_status()
                result = response.json()
                # Transcription succeeded - update health state
                self._server_healthy = True
            except httpx.TimeoutException:
                print("❌ Transcription timed out (network issue or server overloaded)")
                self._server_healthy = False
                self.indicator.show_error()
                time.sleep(1.5)  # Show error indicator briefly
                return
            except httpx.ConnectError:
                print("❌ Cannot connect to server - is your network working?")
                self._server_healthy = False
                self.indicator.show_error()
                time.sleep(1.5)  # Show error indicator briefly
                return

            text = result.get("text", "").strip()

            if text:
                lang = result.get("language", "?").upper()
                duration = result.get("duration", 0)
                proc_time = result.get("processing_time", 0)

                print(f'📝 "{text}"')
                print(
                    f"   [{lang}] {duration:.1f}s audio → {proc_time:.2f}s processing"
                )

                # Auto-paste to app under mouse and restore clipboard
                if self.auto_paste_and_restore(text):
                    print("✅ Auto-pasted!")
            else:
                print("No speech detected")

        except httpx.ConnectError:
            print("❌ Cannot connect to server. Is it running?")
        except Exception as e:
            print(f"❌ Error: {e}")
        finally:
            self.indicator.hide()  # Hide processing indicator
            self.is_processing = False
            self.audio_data = []  # Clear audio buffer to free memory
            print()  # Blank line for readability

    def on_press(self, key):
        """Handle key press events.

        Only responds to LEFT-side modifier keys to avoid conflict
        with proactive_companion which uses right-side keys.

        Cancels recording if any non-trigger key is pressed.
        """
        try:
            # Track modifier key states
            if self.is_left_modifier_key(key):
                self.left_modifier_pressed = True
            elif key == keyboard.Key.cmd_l:
                self.left_cmd_pressed = True
            elif key == keyboard.Key.cmd_r:
                pass  # Explicitly ignore right Command
            else:
                # Any other key pressed during recording = cancel
                if self.is_recording:
                    self.cancel_recording()
                return  # Don't start recording on non-trigger keys

            # Start recording when trigger condition is met
            # But not if we cancelled and haven't released keys yet
            if (
                self.is_recording_trigger_satisfied()
                and not self.is_recording
                and not self.is_processing
                and not self.recording_cancelled
            ):
                self.start_recording()
        except Exception as e:
            print(f"⚠️  on_press error: {e}")

    def on_release(self, key):
        """Handle key release events.

        Only responds to LEFT-side modifier keys.
        """
        try:
            if self.is_left_modifier_key(key):
                self.left_modifier_pressed = False
            elif key == keyboard.Key.cmd_l:
                self.left_cmd_pressed = False
            elif key == keyboard.Key.cmd_r:
                pass  # Explicitly ignore right Command

            # Stop recording when trigger condition is no longer met
            if self.is_recording and not self.is_recording_trigger_satisfied():
                self.stop_recording()

            # Clear cancelled flag when trigger keys are fully released
            # This allows starting a new recording after releasing and re-pressing
            if not self.is_recording_trigger_satisfied():
                self.recording_cancelled = False
        except Exception as e:
            print(f"⚠️  on_release error: {e}")

    def check_server(self) -> bool:
        """Check if server is running."""
        try:
            with httpx.Client(timeout=5.0) as client:
                response = client.get(f"{SERVER_URL}/")
                return response.status_code == 200
        except Exception:
            return False

    def check_health(self) -> bool:
        """Check server health and provider availability.

        Returns True if server is healthy and current provider is available.
        Updates internal state for UI feedback.
        """
        try:
            client = self.get_http_client()
            response = client.get("/api/health", timeout=3.0)
            response.raise_for_status()
            data = response.json()

            was_healthy = self._server_healthy
            was_provider_available = self._provider_available

            self._server_healthy = data.get("status") == "ok"

            # Check if current provider is available
            current_provider = data.get("current_provider", "local")
            providers = data.get("providers", {})
            self._provider_available = providers.get(current_provider, False)

            # Log status changes
            if was_healthy and not self._server_healthy:
                print("⚠️  Server health check failed")
            elif not was_healthy and self._server_healthy:
                print("✅ Server connection restored")

            if was_provider_available and not self._provider_available:
                print(f"⚠️  Provider '{current_provider}' is not available")
            elif not was_provider_available and self._provider_available:
                print(f"✅ Provider '{current_provider}' is now available")

            self._last_health_check = time.time()
            return self._server_healthy and self._provider_available

        except httpx.ConnectError:
            if self._server_healthy:
                print("⚠️  Lost connection to server")
            self._server_healthy = False
            self._provider_available = False
            self._last_health_check = time.time()
            return False
        except httpx.TimeoutException:
            if self._server_healthy:
                print("⚠️  Server connection timed out")
            self._server_healthy = False
            self._last_health_check = time.time()
            return False
        except Exception as e:
            if self._server_healthy:
                print(f"⚠️  Health check error: {e}")
            self._server_healthy = False
            self._last_health_check = time.time()
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

        # Check visual recording indicator availability
        indicator_status = (
            "enabled"
            if self.indicator.is_available()
            else "disabled (script not found)"
        )

        print()
        print(f"  Keybinding:       {self.get_keybinding_display()} (left side only)")
        print(f"  Language:         {self.language_display}")
        print(f"  Min duration:     {self.min_recording_duration:.1f}s")
        print(f"  Screen indicator: {indicator_status}")
        if self._ffm_enabled:
            mode_desc = (
                "track only" if self._ffm_mode == "track_only" else "raise on hover"
            )
            tracking_status = f"enabled ({mode_desc})"
        else:
            tracking_status = "disabled"
        print(f"  Mouse tracking:   {tracking_status}")
        print()
        print(f"🎯 Hold {self.get_keybinding_display()} to record")
        print("   Release to transcribe → auto-paste to window under cursor")
        print()
        print("   (Change settings in web UI: http://127.0.0.1:8000)")
        print("   Press Ctrl+C to exit")
        print()

        # Start focus-follows-mouse (replaces Autoraise)
        if self._ffm_enabled:
            self.start_focus_follows_mouse()

        # Start settings polling (picks up changes from web UI)
        self.start_settings_polling()

        # Start keyboard listener
        with keyboard.Listener(
            on_press=self.on_press,
            on_release=self.on_release,
        ) as listener:
            try:
                listener.join()
            except KeyboardInterrupt:
                print("\nExiting...")
            finally:
                self.stop_settings_polling()
                self.stop_focus_follows_mouse()


def main():
    client = HotkeyClient()
    client.run()


if __name__ == "__main__":
    main()

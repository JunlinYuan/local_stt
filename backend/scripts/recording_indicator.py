#!/usr/bin/env python3
"""Recording indicator overlay - shows red border around screen.

This script runs as a separate process because macOS requires
tkinter windows to be created on the main thread.

Usage:
    python recording_indicator.py [border_width] [color]

Exits when parent process dies or receives SIGTERM.
"""

import os
import signal
import sys
import tkinter as tk


def main():
    border_width = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    color = sys.argv[2] if len(sys.argv) > 2 else "#FF3B30"

    root = tk.Tk()

    # Get screen dimensions
    screen_width = root.winfo_screenwidth()
    screen_height = root.winfo_screenheight()

    # Configure window: fullscreen, transparent, no decorations, always on top
    root.overrideredirect(True)
    root.attributes("-topmost", True)
    root.attributes("-transparent", True)
    root.config(bg="systemTransparent")
    root.geometry(f"{screen_width}x{screen_height}+0+0")

    # Create canvas for drawing the border
    canvas = tk.Canvas(
        root,
        width=screen_width,
        height=screen_height,
        highlightthickness=0,
        bg="systemTransparent",
    )
    canvas.pack()

    # Draw border rectangles (top, bottom, left, right)
    bw = border_width
    canvas.create_rectangle(0, 0, screen_width, bw, fill=color, outline="")  # Top
    canvas.create_rectangle(
        0, screen_height - bw, screen_width, screen_height, fill=color, outline=""
    )  # Bottom
    canvas.create_rectangle(0, 0, bw, screen_height, fill=color, outline="")  # Left
    canvas.create_rectangle(
        screen_width - bw, 0, screen_width, screen_height, fill=color, outline=""
    )  # Right

    # Check if parent process is still alive (poll every 200ms)
    parent_pid = os.getppid()

    def check_parent():
        try:
            os.kill(parent_pid, 0)  # Check if parent exists
            root.after(200, check_parent)
        except OSError:
            root.quit()

    # Handle SIGTERM gracefully
    def handle_sigterm(signum, frame):
        root.quit()

    signal.signal(signal.SIGTERM, handle_sigterm)

    root.after(200, check_parent)
    root.mainloop()


if __name__ == "__main__":
    main()

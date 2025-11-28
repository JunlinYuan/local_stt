/**
 * Local STT - Frontend Application
 * Handles key chord detection, audio recording, and WebSocket communication
 */

// =============================================================================
// Console Logging System
// =============================================================================

const consoleLogger = {
    logs: [],
    maxLogs: 100,
    errorCount: 0,

    init() {
        // Store original console methods
        this.originalLog = console.log;
        this.originalWarn = console.warn;
        this.originalError = console.error;

        // Override console methods
        console.log = (...args) => {
            this.addLog('info', args);
            this.originalLog.apply(console, args);
        };

        console.warn = (...args) => {
            this.addLog('warn', args);
            this.originalWarn.apply(console, args);
        };

        console.error = (...args) => {
            this.addLog('error', args);
            this.originalError.apply(console, args);
        };

        // Capture uncaught errors
        window.addEventListener('error', (event) => {
            this.addLog('error', [`Uncaught: ${event.message} at ${event.filename}:${event.lineno}`]);
        });

        window.addEventListener('unhandledrejection', (event) => {
            this.addLog('error', [`Unhandled Promise: ${event.reason}`]);
        });

        // Set up UI handlers after DOM ready
        this.setupUI();
    },

    setupUI() {
        const toggleBtn = document.getElementById('toggleConsole');
        const clearBtn = document.getElementById('clearConsole');
        const consoleHeader = document.getElementById('consoleHeader');
        const consolePanel = document.getElementById('consolePanel');

        if (toggleBtn) {
            toggleBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                consolePanel.classList.toggle('collapsed');
            });
        }

        if (consoleHeader) {
            consoleHeader.addEventListener('click', () => {
                consolePanel.classList.toggle('collapsed');
            });
        }

        if (clearBtn) {
            clearBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.clear();
            });
        }

        this.render();
    },

    addLog(type, args) {
        const message = args.map(arg => {
            if (typeof arg === 'object') {
                try {
                    return JSON.stringify(arg, null, 2);
                } catch {
                    return String(arg);
                }
            }
            return String(arg);
        }).join(' ');

        const entry = {
            type,
            message,
            time: new Date(),
        };

        this.logs.push(entry);

        // Keep logs under limit
        if (this.logs.length > this.maxLogs) {
            this.logs.shift();
        }

        if (type === 'error') {
            this.errorCount++;
        }

        this.render();
    },

    clear() {
        this.logs = [];
        this.errorCount = 0;
        this.render();
    },

    formatTime(date) {
        return date.toLocaleTimeString('en-US', {
            hour12: false,
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit',
        });
    },

    render() {
        const logsContainer = document.getElementById('consoleLogs');
        const countBadge = document.getElementById('consoleCount');
        const consolePanel = document.getElementById('consolePanel');

        if (!logsContainer) return;

        if (this.logs.length === 0) {
            logsContainer.innerHTML = '<div class="console-empty">No logs yet</div>';
        } else {
            logsContainer.innerHTML = this.logs.map(log => `
                <div class="log-entry ${log.type}">
                    <span class="log-time">${this.formatTime(log.time)}</span>
                    <span class="log-type ${log.type}">${log.type.toUpperCase()}</span>
                    <span class="log-message">${this.escapeHtml(log.message)}</span>
                </div>
            `).join('');

            // Auto-scroll to bottom
            logsContainer.scrollTop = logsContainer.scrollHeight;
        }

        if (countBadge) {
            countBadge.textContent = this.logs.length;
        }

        if (consolePanel) {
            if (this.errorCount > 0) {
                consolePanel.classList.add('has-errors');
            } else {
                consolePanel.classList.remove('has-errors');
            }
        }
    },

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    },
};

// Initialize console logger immediately
consoleLogger.init();

// =============================================================================
// State Management
// =============================================================================

const state = {
    // Key states
    ctrlPressed: false,
    optPressed: false,

    // Recording state
    isRecording: false,
    isProcessing: false,

    // Audio
    mediaRecorder: null,
    audioChunks: [],
    audioContext: null,
    analyser: null,
    mediaStream: null,

    // WebSocket
    ws: null,
    wsConnected: false,
};

// =============================================================================
// DOM Elements
// =============================================================================

const elements = {
    ctrlKey: document.getElementById('ctrlKey'),
    optKey: document.getElementById('optKey'),
    recordingPanel: document.getElementById('recordingPanel'),
    recIndicator: document.getElementById('recIndicator'),
    recLabel: document.getElementById('recLabel'),
    recHint: document.getElementById('recHint'),
    waveformContainer: document.getElementById('waveformContainer'),
    waveform: document.getElementById('waveform'),
    transcriptContent: document.getElementById('transcriptContent'),
    transcriptMeta: document.getElementById('transcriptMeta'),
    connectionStatus: document.getElementById('connectionStatus'),
    vocabTerms: document.getElementById('vocabTerms'),
    langBadge: document.getElementById('langBadge'),
};

// =============================================================================
// WebSocket Connection
// =============================================================================

function connectWebSocket() {
    const wsUrl = `ws://${window.location.host}/ws`;
    state.ws = new WebSocket(wsUrl);

    state.ws.onopen = () => {
        console.log('WebSocket connected');
        state.wsConnected = true;
        updateConnectionStatus(true);
    };

    state.ws.onclose = () => {
        console.log('WebSocket disconnected');
        state.wsConnected = false;
        updateConnectionStatus(false);
        // Reconnect after delay
        setTimeout(connectWebSocket, 3000);
    };

    state.ws.onerror = (error) => {
        console.error('WebSocket error:', error);
    };

    state.ws.onmessage = (event) => {
        const result = JSON.parse(event.data);
        handleTranscriptionResult(result);
    };
}

function updateConnectionStatus(connected) {
    if (connected) {
        elements.connectionStatus.classList.add('connected');
        elements.connectionStatus.querySelector('span:last-child').textContent = 'Connected';
    } else {
        elements.connectionStatus.classList.remove('connected');
        elements.connectionStatus.querySelector('span:last-child').textContent = 'Disconnected';
    }
}

// =============================================================================
// Key Detection (Chord: Ctrl + Option)
// =============================================================================

function handleKeyDown(event) {
    // Track Control key (event.ctrlKey on Mac is actually Ctrl, not Cmd)
    if (event.key === 'Control') {
        state.ctrlPressed = true;
        elements.ctrlKey.classList.add('pressed');
        elements.ctrlKey.querySelector('.key-status').textContent = 'HELD';
    }

    // Track Option/Alt key
    if (event.key === 'Alt') {
        state.optPressed = true;
        elements.optKey.classList.add('pressed');
        elements.optKey.querySelector('.key-status').textContent = 'HELD';
    }

    // Check if both keys are pressed → start recording
    if (state.ctrlPressed && state.optPressed && !state.isRecording && !state.isProcessing) {
        startRecording();
    }

    // Prevent default for our key combo
    if (state.ctrlPressed && state.optPressed) {
        event.preventDefault();
    }
}

function handleKeyUp(event) {
    // Track Control key release
    if (event.key === 'Control') {
        state.ctrlPressed = false;
        elements.ctrlKey.classList.remove('pressed');
        elements.ctrlKey.querySelector('.key-status').textContent = '—';
    }

    // Track Option/Alt key release
    if (event.key === 'Alt') {
        state.optPressed = false;
        elements.optKey.classList.remove('pressed');
        elements.optKey.querySelector('.key-status').textContent = '—';
    }

    // If either key is released while recording → stop recording
    if (state.isRecording && (!state.ctrlPressed || !state.optPressed)) {
        stopRecording();
    }
}

// Handle window blur (keys might be released while window not focused)
function handleBlur() {
    state.ctrlPressed = false;
    state.optPressed = false;
    elements.ctrlKey.classList.remove('pressed');
    elements.optKey.classList.remove('pressed');
    elements.ctrlKey.querySelector('.key-status').textContent = '—';
    elements.optKey.querySelector('.key-status').textContent = '—';

    if (state.isRecording) {
        stopRecording();
    }
}

// =============================================================================
// Audio Recording
// =============================================================================

async function initAudio() {
    try {
        state.mediaStream = await navigator.mediaDevices.getUserMedia({
            audio: {
                channelCount: 1,
                sampleRate: 16000,
                echoCancellation: true,
                noiseSuppression: true,
            }
        });

        // Set up audio context for visualization
        state.audioContext = new (window.AudioContext || window.webkitAudioContext)();
        state.analyser = state.audioContext.createAnalyser();
        state.analyser.fftSize = 256;

        const source = state.audioContext.createMediaStreamSource(state.mediaStream);
        source.connect(state.analyser);

        console.log('Audio initialized');
        return true;
    } catch (error) {
        console.error('Failed to initialize audio:', error);
        elements.recHint.textContent = 'Microphone access denied';
        return false;
    }
}

async function startRecording() {
    // Initialize audio on first recording attempt
    if (!state.mediaStream) {
        const success = await initAudio();
        if (!success) return;
    }

    state.isRecording = true;
    state.audioChunks = [];

    // Update UI
    elements.recordingPanel.classList.add('recording');
    elements.recordingPanel.classList.remove('processing');
    elements.recLabel.textContent = 'RECORDING';
    elements.recHint.textContent = 'Release keys to transcribe';
    elements.waveformContainer.classList.add('active');

    // Start media recorder
    state.mediaRecorder = new MediaRecorder(state.mediaStream, {
        mimeType: 'audio/webm;codecs=opus'
    });

    state.mediaRecorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
            state.audioChunks.push(event.data);
        }
    };

    state.mediaRecorder.start(100); // Collect data every 100ms

    // Start waveform visualization
    drawWaveform();

    console.log('Recording started');
}

async function stopRecording() {
    if (!state.mediaRecorder || state.mediaRecorder.state === 'inactive') {
        return;
    }

    state.isRecording = false;

    // Update UI to processing state
    elements.recordingPanel.classList.remove('recording');
    elements.recordingPanel.classList.add('processing');
    elements.recLabel.textContent = 'TRANSCRIBING';
    elements.recHint.textContent = 'Processing audio...';
    elements.waveformContainer.classList.remove('active');
    state.isProcessing = true;

    // Stop recorder and wait for data
    state.mediaRecorder.stop();

    // Wait a moment for final data chunk
    await new Promise(resolve => setTimeout(resolve, 200));

    // Convert to WAV and send
    const audioBlob = new Blob(state.audioChunks, { type: 'audio/webm' });
    await sendAudioForTranscription(audioBlob);
}

async function sendAudioForTranscription(audioBlob) {
    if (!state.wsConnected) {
        console.error('WebSocket not connected');
        resetRecordingState();
        return;
    }

    try {
        // Convert webm to wav using AudioContext
        const arrayBuffer = await audioBlob.arrayBuffer();
        const audioBuffer = await state.audioContext.decodeAudioData(arrayBuffer);
        const wavBlob = audioBufferToWav(audioBuffer);

        // Send via WebSocket
        state.ws.send(wavBlob);
        console.log('Audio sent for transcription');
    } catch (error) {
        console.error('Failed to send audio:', error);
        resetRecordingState();
    }
}

function handleTranscriptionResult(result) {
    state.isProcessing = false;
    resetRecordingState();

    console.log('Transcription result:', result);

    // Update language badge with detected language
    if (result.language && elements.langBadge) {
        const langCode = result.language.toUpperCase();
        const probability = result.language_probability
            ? ` (${(result.language_probability * 100).toFixed(0)}%)`
            : '';
        elements.langBadge.textContent = langCode;
        elements.langBadge.title = `Detected: ${langCode}${probability}`;
    }

    // Display result
    if (result.text) {
        elements.transcriptContent.innerHTML = result.text;
        elements.transcriptMeta.textContent =
            `Duration: ${result.duration?.toFixed(1)}s | Processing: ${result.processing_time?.toFixed(2)}s | Language: ${result.language}`;
    } else {
        elements.transcriptContent.innerHTML = '<span class="placeholder">No speech detected</span>';
        elements.transcriptMeta.textContent = '';
    }
}

function resetRecordingState() {
    elements.recordingPanel.classList.remove('recording', 'processing');
    elements.recLabel.textContent = 'READY';
    elements.recHint.textContent = 'Hold Ctrl + Option to record';
}

// =============================================================================
// Waveform Visualization
// =============================================================================

function drawWaveform() {
    if (!state.isRecording || !state.analyser) return;

    const canvas = elements.waveform;
    const ctx = canvas.getContext('2d');
    const bufferLength = state.analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    state.analyser.getByteTimeDomainData(dataArray);

    // Clear canvas
    ctx.fillStyle = '#141416';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    // Draw waveform
    ctx.lineWidth = 2;
    ctx.strokeStyle = '#ef4444';
    ctx.beginPath();

    const sliceWidth = canvas.width / bufferLength;
    let x = 0;

    for (let i = 0; i < bufferLength; i++) {
        const v = dataArray[i] / 128.0;
        const y = (v * canvas.height) / 2;

        if (i === 0) {
            ctx.moveTo(x, y);
        } else {
            ctx.lineTo(x, y);
        }

        x += sliceWidth;
    }

    ctx.lineTo(canvas.width, canvas.height / 2);
    ctx.stroke();

    // Continue animation
    if (state.isRecording) {
        requestAnimationFrame(drawWaveform);
    }
}

// =============================================================================
// Audio Buffer to WAV Conversion
// =============================================================================

function audioBufferToWav(audioBuffer) {
    const numChannels = 1;
    const sampleRate = audioBuffer.sampleRate;
    const format = 1; // PCM
    const bitDepth = 16;

    // Get audio data (mono)
    const audioData = audioBuffer.getChannelData(0);
    const dataLength = audioData.length * (bitDepth / 8);
    const buffer = new ArrayBuffer(44 + dataLength);
    const view = new DataView(buffer);

    // WAV header
    writeString(view, 0, 'RIFF');
    view.setUint32(4, 36 + dataLength, true);
    writeString(view, 8, 'WAVE');
    writeString(view, 12, 'fmt ');
    view.setUint32(16, 16, true); // fmt chunk size
    view.setUint16(20, format, true);
    view.setUint16(22, numChannels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * numChannels * (bitDepth / 8), true);
    view.setUint16(32, numChannels * (bitDepth / 8), true);
    view.setUint16(34, bitDepth, true);
    writeString(view, 36, 'data');
    view.setUint32(40, dataLength, true);

    // Write audio data
    const offset = 44;
    for (let i = 0; i < audioData.length; i++) {
        const sample = Math.max(-1, Math.min(1, audioData[i]));
        const int16 = sample < 0 ? sample * 0x8000 : sample * 0x7FFF;
        view.setInt16(offset + i * 2, int16, true);
    }

    return new Blob([buffer], { type: 'audio/wav' });
}

function writeString(view, offset, string) {
    for (let i = 0; i < string.length; i++) {
        view.setUint8(offset + i, string.charCodeAt(i));
    }
}

// =============================================================================
// Initialization
// =============================================================================

function init() {
    // Connect WebSocket
    connectWebSocket();

    // Set up key listeners
    document.addEventListener('keydown', handleKeyDown);
    document.addEventListener('keyup', handleKeyUp);
    window.addEventListener('blur', handleBlur);

    // Clear waveform
    const ctx = elements.waveform.getContext('2d');
    ctx.fillStyle = '#141416';
    ctx.fillRect(0, 0, elements.waveform.width, elements.waveform.height);

    console.log('Local STT initialized');
    console.log('Press Ctrl + Option to start recording');
}

// Start when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}

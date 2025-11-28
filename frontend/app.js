/**
 * Local STT - Web UI
 * Display panel for status + settings changes
 * All settings are stored on server and shared with global hotkey client
 */

// =============================================================================
// Console Logging System
// =============================================================================

const consoleLogger = {
    logs: [],
    maxLogs: 100,
    errorCount: 0,

    init() {
        this.originalLog = console.log;
        this.originalWarn = console.warn;
        this.originalError = console.error;

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

        window.addEventListener('error', (event) => {
            this.addLog('error', [`Uncaught: ${event.message}`]);
        });

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
                try { return JSON.stringify(arg, null, 2); }
                catch { return String(arg); }
            }
            return String(arg);
        }).join(' ');

        this.logs.push({ type, message, time: new Date() });

        if (this.logs.length > this.maxLogs) this.logs.shift();
        if (type === 'error') this.errorCount++;

        this.render();
    },

    clear() {
        this.logs = [];
        this.errorCount = 0;
        this.render();
    },

    formatTime(date) {
        return date.toLocaleTimeString('en-US', {
            hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit'
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
            logsContainer.scrollTop = logsContainer.scrollHeight;
        }

        if (countBadge) countBadge.textContent = this.logs.length;
        if (consolePanel) {
            consolePanel.classList.toggle('has-errors', this.errorCount > 0);
        }
    },

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    },
};

consoleLogger.init();

// =============================================================================
// State
// =============================================================================

const state = {
    // Keys
    modifierPressed: false,
    optPressed: false,

    // Recording
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

    // Settings (from server)
    settings: {
        language: '',
        keybinding: 'ctrl',
    },
};

// =============================================================================
// DOM Elements
// =============================================================================

const elements = {
    modifierKey: document.getElementById('modifierKey'),
    modifierLabel: document.getElementById('modifierLabel'),
    optKey: document.getElementById('optKey'),
    recordingPanel: document.getElementById('recordingPanel'),
    recLabel: document.getElementById('recLabel'),
    recHint: document.getElementById('recHint'),
    waveformContainer: document.getElementById('waveformContainer'),
    waveform: document.getElementById('waveform'),
    transcriptContent: document.getElementById('transcriptContent'),
    transcriptMeta: document.getElementById('transcriptMeta'),
    connectionStatus: document.getElementById('connectionStatus'),
    langBadge: document.getElementById('langBadge'),
    languageSelector: document.getElementById('languageSelector'),
    languageStatus: document.getElementById('languageStatus'),
    keybindToggle: document.getElementById('keybindToggle'),
};

// =============================================================================
// Settings API (schema-driven, extendable)
// =============================================================================

async function fetchSettings() {
    try {
        const response = await fetch('/api/settings');
        const data = await response.json();
        // Store all settings dynamically
        for (const key of Object.keys(data)) {
            if (!key.endsWith('_display')) {
                state.settings[key] = data[key];
            }
        }
        updateSettingsUI(data);
        console.log(`Settings loaded: Language=${data.language_display}, Keybinding=${data.keybinding_display}`);
    } catch (error) {
        console.error('Failed to fetch settings:', error);
    }
}

/**
 * Generic setting update function.
 * @param {string} key - Setting key (e.g., 'language', 'keybinding')
 * @param {any} value - New value
 */
async function setSetting(key, value) {
    try {
        const response = await fetch(`/api/settings/${key}`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ value }),
        });
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.detail || 'Failed to update setting');
        }
        const data = await response.json();
        // Update local state
        state.settings[key] = data[key];
        updateSettingsUI(data);
        console.log(`${key} changed to: ${data[`${key}_display`]}`);
    } catch (error) {
        console.error(`Failed to set ${key}:`, error);
    }
}

// Convenience wrappers for existing UI
const setLanguage = (language) => setSetting('language', language);
const setKeybinding = (keybinding) => setSetting('keybinding', keybinding);

function updateSettingsUI(data) {
    // Update language selector
    if (elements.languageSelector) {
        const buttons = elements.languageSelector.querySelectorAll('.lang-btn');
        buttons.forEach(btn => {
            btn.classList.toggle('active', btn.dataset.lang === data.language);
        });
    }

    // Update language status
    if (elements.languageStatus) {
        elements.languageStatus.textContent = data.language
            ? `${data.language_display} mode`
            : 'Auto-detect enabled';
    }

    // Update footer badge
    if (elements.langBadge) {
        elements.langBadge.textContent = data.language_display;
    }

    // Update keybinding toggle
    if (elements.keybindToggle) {
        const buttons = elements.keybindToggle.querySelectorAll('.keybind-btn');
        buttons.forEach(btn => {
            btn.classList.toggle('active', btn.dataset.binding === data.keybinding);
        });
    }

    // Update key indicator label
    if (elements.modifierLabel) {
        elements.modifierLabel.textContent = data.keybinding === 'ctrl' ? 'CTRL' : 'SHIFT';
    }

    // Update hint text
    if (elements.recHint && !state.isRecording) {
        const keyName = data.keybinding === 'ctrl' ? 'Ctrl' : 'Shift';
        elements.recHint.textContent = `Hold ${keyName} + Option to record`;
    }
}

// =============================================================================
// WebSocket Connection
// =============================================================================

function connectWebSocket() {
    const wsUrl = `ws://${window.location.host}/ws`;
    state.ws = new WebSocket(wsUrl);

    state.ws.onopen = () => {
        console.log('Connected to server');
        state.wsConnected = true;
        updateConnectionStatus(true);
    };

    state.ws.onclose = () => {
        state.wsConnected = false;
        updateConnectionStatus(false);
        // Reconnect after delay
        setTimeout(connectWebSocket, 3000);
    };

    state.ws.onerror = (error) => {
        console.error('WebSocket error');
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
// UI Event Handlers
// =============================================================================

function initLanguageSelector() {
    if (!elements.languageSelector) return;

    elements.languageSelector.querySelectorAll('.lang-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            if (state.isRecording || state.isProcessing) return;
            setLanguage(btn.dataset.lang);
        });
    });
}

function initKeybindToggle() {
    if (!elements.keybindToggle) return;

    elements.keybindToggle.querySelectorAll('.keybind-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            if (state.isRecording || state.isProcessing) return;
            setKeybinding(btn.dataset.binding);
        });
    });
}

// =============================================================================
// Key Detection
// =============================================================================

function isModifierKey(event) {
    if (state.settings.keybinding === 'ctrl') {
        return event.key === 'Control';
    } else {
        return event.key === 'Shift';
    }
}

function handleKeyDown(event) {
    if (isModifierKey(event)) {
        state.modifierPressed = true;
        elements.modifierKey?.classList.add('pressed');
        const modStatus = elements.modifierKey?.querySelector('.key-status');
        if (modStatus) modStatus.textContent = 'HELD';
    }

    if (event.key === 'Alt') {
        state.optPressed = true;
        elements.optKey?.classList.add('pressed');
        const optStatus = elements.optKey?.querySelector('.key-status');
        if (optStatus) optStatus.textContent = 'HELD';
    }

    if (state.modifierPressed && state.optPressed && !state.isRecording && !state.isProcessing) {
        startRecording();
    }

    if (state.modifierPressed && state.optPressed) {
        event.preventDefault();
    }
}

function handleKeyUp(event) {
    if (isModifierKey(event)) {
        state.modifierPressed = false;
        elements.modifierKey?.classList.remove('pressed');
        const modStatus = elements.modifierKey?.querySelector('.key-status');
        if (modStatus) modStatus.textContent = '—';
    }

    if (event.key === 'Alt') {
        state.optPressed = false;
        elements.optKey?.classList.remove('pressed');
        const optStatus = elements.optKey?.querySelector('.key-status');
        if (optStatus) optStatus.textContent = '—';
    }

    if (state.isRecording && (!state.modifierPressed || !state.optPressed)) {
        stopRecording();
    }
}

function handleBlur() {
    state.modifierPressed = false;
    state.optPressed = false;
    elements.modifierKey?.classList.remove('pressed');
    elements.optKey?.classList.remove('pressed');
    const modStatus = elements.modifierKey?.querySelector('.key-status');
    const optStatus = elements.optKey?.querySelector('.key-status');
    if (modStatus) modStatus.textContent = '—';
    if (optStatus) optStatus.textContent = '—';

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
            audio: { channelCount: 1, sampleRate: 16000, echoCancellation: true, noiseSuppression: true }
        });

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
    if (!state.mediaStream) {
        const success = await initAudio();
        if (!success) return;
    }

    state.isRecording = true;
    state.audioChunks = [];

    elements.recordingPanel?.classList.add('recording');
    elements.recordingPanel?.classList.remove('processing');
    elements.recLabel.textContent = 'RECORDING';
    elements.recHint.textContent = 'Release keys to transcribe';
    elements.waveformContainer?.classList.add('active');

    state.mediaRecorder = new MediaRecorder(state.mediaStream, {
        mimeType: 'audio/webm;codecs=opus'
    });

    state.mediaRecorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
            state.audioChunks.push(event.data);
        }
    };

    state.mediaRecorder.start(100);
    drawWaveform();
    console.log('Recording started');
}

async function stopRecording() {
    if (!state.mediaRecorder || state.mediaRecorder.state === 'inactive') return;

    state.isRecording = false;

    elements.recordingPanel?.classList.remove('recording');
    elements.recordingPanel?.classList.add('processing');
    elements.recLabel.textContent = 'TRANSCRIBING';
    elements.recHint.textContent = 'Processing audio...';
    elements.waveformContainer?.classList.remove('active');
    state.isProcessing = true;

    state.mediaRecorder.stop();
    await new Promise(resolve => setTimeout(resolve, 200));

    const audioBlob = new Blob(state.audioChunks, { type: 'audio/webm' });
    await sendAudioForTranscription(audioBlob);
}

async function sendAudioForTranscription(audioBlob) {
    if (!state.wsConnected) {
        console.error('Not connected to server');
        resetRecordingState();
        return;
    }

    try {
        const arrayBuffer = await audioBlob.arrayBuffer();
        const audioBuffer = await state.audioContext.decodeAudioData(arrayBuffer);
        const wavBlob = audioBufferToWav(audioBuffer);

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

    if (result.language && elements.langBadge) {
        const langCode = result.language.toUpperCase();
        elements.langBadge.textContent = state.settings.language ? state.settings.language.toUpperCase() : langCode;
    }

    if (result.text) {
        elements.transcriptContent.innerHTML = result.text;
        elements.transcriptMeta.textContent =
            `Duration: ${result.duration?.toFixed(1)}s | Processing: ${result.processing_time?.toFixed(2)}s | Detected: ${result.language?.toUpperCase()}`;
    } else {
        elements.transcriptContent.innerHTML = '<span class="placeholder">No speech detected</span>';
        elements.transcriptMeta.textContent = '';
    }
}

function resetRecordingState() {
    elements.recordingPanel?.classList.remove('recording', 'processing');
    elements.recLabel.textContent = 'READY';

    const keyName = state.settings.keybinding === 'ctrl' ? 'Ctrl' : 'Shift';
    elements.recHint.textContent = `Hold ${keyName} + Option to record`;
}

// =============================================================================
// Waveform
// =============================================================================

function drawWaveform() {
    if (!state.isRecording || !state.analyser) return;

    const canvas = elements.waveform;
    const ctx = canvas.getContext('2d');
    const bufferLength = state.analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    state.analyser.getByteTimeDomainData(dataArray);

    ctx.fillStyle = '#141416';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    ctx.lineWidth = 2;
    ctx.strokeStyle = '#ef4444';
    ctx.beginPath();

    const sliceWidth = canvas.width / bufferLength;
    let x = 0;

    for (let i = 0; i < bufferLength; i++) {
        const v = dataArray[i] / 128.0;
        const y = (v * canvas.height) / 2;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
        x += sliceWidth;
    }

    ctx.lineTo(canvas.width, canvas.height / 2);
    ctx.stroke();

    if (state.isRecording) {
        requestAnimationFrame(drawWaveform);
    }
}

// =============================================================================
// Audio Buffer to WAV
// =============================================================================

function audioBufferToWav(audioBuffer) {
    const numChannels = 1;
    const sampleRate = audioBuffer.sampleRate;
    const format = 1;
    const bitDepth = 16;

    const audioData = audioBuffer.getChannelData(0);
    const dataLength = audioData.length * (bitDepth / 8);
    const buffer = new ArrayBuffer(44 + dataLength);
    const view = new DataView(buffer);

    writeString(view, 0, 'RIFF');
    view.setUint32(4, 36 + dataLength, true);
    writeString(view, 8, 'WAVE');
    writeString(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, format, true);
    view.setUint16(22, numChannels, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * numChannels * (bitDepth / 8), true);
    view.setUint16(32, numChannels * (bitDepth / 8), true);
    view.setUint16(34, bitDepth, true);
    writeString(view, 36, 'data');
    view.setUint32(40, dataLength, true);

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

async function init() {
    // Fetch settings from server first
    await fetchSettings();

    // Initialize UI
    initLanguageSelector();
    initKeybindToggle();

    // Connect WebSocket
    connectWebSocket();

    // Key listeners
    document.addEventListener('keydown', handleKeyDown);
    document.addEventListener('keyup', handleKeyUp);
    window.addEventListener('blur', handleBlur);

    // Clear waveform
    const ctx = elements.waveform?.getContext('2d');
    if (ctx) {
        ctx.fillStyle = '#141416';
        ctx.fillRect(0, 0, elements.waveform.width, elements.waveform.height);
    }

    console.log('Web UI initialized');
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}

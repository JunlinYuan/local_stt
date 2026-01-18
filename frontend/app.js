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

        const copyBtn = document.getElementById('copyConsole');
        if (copyBtn) {
            copyBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.copyLogs();
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

    copyLogs() {
        if (this.logs.length === 0) {
            this.addLog('info', ['No logs to copy']);
            return;
        }
        const text = this.logs.map(log =>
            `[${this.formatTime(log.time)}] ${log.type.toUpperCase()}: ${log.message}`
        ).join('\n');
        navigator.clipboard.writeText(text).then(() => {
            this.addLog('info', ['Logs copied to clipboard']);
        }).catch(err => {
            this.addLog('error', ['Failed to copy logs:', err.message]);
        });
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
    cmdPressed: false,

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

    // Health check state
    serverHealthy: true,
    providerAvailable: true,
    healthCheckInterval: null,

    // Settings (from server)
    settings: {
        language: '',
        keybinding: 'ctrl_only',
        clipboard_sync_delay: 0.05,
        paste_delay: 0.05,
        volume_normalization: true,
        ffm_enabled: true,
        ffm_mode: 'track_only',
        replacements_enabled: true,
    },
};

// =============================================================================
// DOM Elements
// =============================================================================

const elements = {
    modifierKey: document.getElementById('modifierKey'),
    modifierLabel: document.getElementById('modifierLabel'),
    cmdKey: document.getElementById('cmdKey'),
    recordingPanel: document.getElementById('recordingPanel'),
    recLabel: document.getElementById('recLabel'),
    recHint: document.getElementById('recHint'),
    waveformContainer: document.getElementById('waveformContainer'),
    waveform: document.getElementById('waveform'),
    connectionStatus: document.getElementById('connectionStatus'),
    langBadge: document.getElementById('langBadge'),
    languageSelector: document.getElementById('languageSelector'),
    languageStatus: document.getElementById('languageStatus'),
    keybindToggle: document.getElementById('keybindToggle'),
    providerToggle: document.getElementById('providerToggle'),
    clipboardSyncSlider: document.getElementById('clipboardSyncSlider'),
    clipboardSyncValue: document.getElementById('clipboardSyncValue'),
    pasteDelaySlider: document.getElementById('pasteDelaySlider'),
    pasteDelayValue: document.getElementById('pasteDelayValue'),
    normalizeToggle: document.getElementById('normalizeToggle'),
    ffmToggle: document.getElementById('ffmToggle'),
    ffmModeToggle: document.getElementById('ffmModeToggle'),
    maxRecordingSlider: document.getElementById('maxRecordingSlider'),
    maxRecordingValue: document.getElementById('maxRecordingValue'),
    themeToggle: document.getElementById('themeToggle'),
    // Volume indicator elements
    volumeIndicator: document.getElementById('volumeIndicator'),
    volumeOriginalFill: document.getElementById('volumeOriginalFill'),
    volumeOriginalValue: document.getElementById('volumeOriginalValue'),
    volumeNormalizedFill: document.getElementById('volumeNormalizedFill'),
    volumeNormalizedValue: document.getElementById('volumeNormalizedValue'),
    volumeGain: document.getElementById('volumeGain'),
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
const setProvider = (provider) => setSetting('stt_provider', provider);

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

    // Update provider toggle
    if (elements.providerToggle) {
        const buttons = elements.providerToggle.querySelectorAll('.provider-btn');
        buttons.forEach(btn => {
            btn.classList.toggle('active', btn.dataset.provider === data.stt_provider);
        });
    }

    // Update key indicator label
    if (elements.modifierLabel) {
        const labels = { ctrl_only: 'CTRL', ctrl: 'CTRL', shift: 'SHIFT' };
        elements.modifierLabel.textContent = labels[data.keybinding] || 'CTRL';
    }

    // Hint text is now static (observer mode)
    // Key detection disabled in web UI

    // Update clipboard sync delay slider
    if (elements.clipboardSyncSlider && data.clipboard_sync_delay !== undefined) {
        elements.clipboardSyncSlider.value = data.clipboard_sync_delay;
    }
    if (elements.clipboardSyncValue && data.clipboard_sync_delay !== undefined) {
        elements.clipboardSyncValue.textContent = `${data.clipboard_sync_delay.toFixed(2)}s`;
    }

    // Update paste delay slider
    if (elements.pasteDelaySlider && data.paste_delay !== undefined) {
        elements.pasteDelaySlider.value = data.paste_delay;
    }
    if (elements.pasteDelayValue && data.paste_delay !== undefined) {
        elements.pasteDelayValue.textContent = `${data.paste_delay.toFixed(2)}s`;
    }

    // Update volume normalization toggle
    if (elements.normalizeToggle && data.volume_normalization !== undefined) {
        elements.normalizeToggle.classList.toggle('active', data.volume_normalization);
    }

    // Update FFM toggle and mode
    if (elements.ffmToggle && data.ffm_enabled !== undefined) {
        elements.ffmToggle.classList.toggle('active', data.ffm_enabled);
    }
    if (elements.ffmModeToggle && data.ffm_mode !== undefined) {
        const buttons = elements.ffmModeToggle.querySelectorAll('.ffm-mode-btn');
        buttons.forEach(btn => {
            btn.classList.toggle('active', btn.dataset.mode === data.ffm_mode);
        });
    }

    // Update max recording duration slider
    if (elements.maxRecordingSlider && data.max_recording_duration !== undefined) {
        elements.maxRecordingSlider.value = data.max_recording_duration;
    }
    if (elements.maxRecordingValue && data.max_recording_duration_display !== undefined) {
        elements.maxRecordingValue.textContent = data.max_recording_duration_display;
    }

    // Update replacements enabled toggle
    if (data.replacements_enabled !== undefined) {
        state.settings.replacements_enabled = data.replacements_enabled;
        updateReplacementsEnabledUI();
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
        const data = JSON.parse(event.data);

        // Handle status updates from CLI
        if (data.type === 'status') {
            handleStatusUpdate(data);
            return;
        }

        // Handle log messages from CLI
        if (data.type === 'log') {
            const level = data.level || 'info';
            const msg = `[CLI] ${data.message}`;
            if (level === 'error') {
                console.error(msg);
            } else if (level === 'warn') {
                console.warn(msg);
            } else {
                console.log(msg);
            }
            return;
        }

        // Handle transcription results
        handleTranscriptionResult(data);
    };
}

function updateConnectionStatus(connected) {
    const statusText = elements.connectionStatus.querySelector('span:last-child');

    if (!connected) {
        // WebSocket disconnected - worst state
        elements.connectionStatus.classList.remove('connected', 'warning');
        statusText.textContent = 'Disconnected';
    } else if (!state.serverHealthy) {
        // WS connected but server health check failed
        elements.connectionStatus.classList.add('connected');
        elements.connectionStatus.classList.add('warning');
        statusText.textContent = 'Server Error';
    } else if (!state.providerAvailable) {
        // Server OK but provider unavailable (e.g., API key missing)
        elements.connectionStatus.classList.add('connected');
        elements.connectionStatus.classList.add('warning');
        statusText.textContent = 'Provider Unavailable';
    } else {
        // All good
        elements.connectionStatus.classList.add('connected');
        elements.connectionStatus.classList.remove('warning');
        statusText.textContent = 'Connected';
    }
}

// =============================================================================
// Health Check
// =============================================================================

async function checkHealth() {
    try {
        const response = await fetch('/api/health', { signal: AbortSignal.timeout(5000) });
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }

        const data = await response.json();
        const wasHealthy = state.serverHealthy;
        const wasProviderAvailable = state.providerAvailable;

        state.serverHealthy = data.status === 'ok';

        // Check if current provider is available
        const currentProvider = data.current_provider || 'local';
        const providers = data.providers || {};
        state.providerAvailable = providers[currentProvider] !== false;

        // Log status changes
        if (wasHealthy && !state.serverHealthy) {
            console.warn('Server health check failed');
        } else if (!wasHealthy && state.serverHealthy) {
            console.log('Server connection restored');
        }

        if (wasProviderAvailable && !state.providerAvailable) {
            console.warn(`Provider '${currentProvider}' is not available`);
        } else if (!wasProviderAvailable && state.providerAvailable) {
            console.log(`Provider '${currentProvider}' is now available`);
        }

        // Update status display if there was a change
        if (wasHealthy !== state.serverHealthy || wasProviderAvailable !== state.providerAvailable) {
            updateConnectionStatus(state.wsConnected);
        }

        return state.serverHealthy && state.providerAvailable;
    } catch (error) {
        // Network error or timeout
        if (state.serverHealthy) {
            console.warn('Health check failed:', error.message);
        }
        state.serverHealthy = false;
        updateConnectionStatus(state.wsConnected);
        return false;
    }
}

function startHealthChecks() {
    // Initial check
    checkHealth();

    // Periodic checks every 30 seconds
    state.healthCheckInterval = setInterval(checkHealth, 30000);
}

function stopHealthChecks() {
    if (state.healthCheckInterval) {
        clearInterval(state.healthCheckInterval);
        state.healthCheckInterval = null;
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

// Provider icons and display names (fallbacks if not in schema)
const PROVIDER_CONFIG = {
    local: { icon: '🖥️', name: 'Local', title: 'Local (lightning-whisper-mlx)' },
    openai: { icon: '☁️', name: 'OpenAI', title: 'OpenAI Whisper API' },
    groq: { icon: '🚀', name: 'Groq', title: 'Groq Whisper API (Fast)' },
    // Add new providers here - they'll also work if only defined in backend schema
};

async function initProviderToggle() {
    if (!elements.providerToggle) return;

    // Fetch schema to get available providers
    try {
        const response = await fetch('/api/settings/schema');
        const schema = await response.json();
        const providerOptions = schema.stt_provider?.options || ['local', 'openai', 'groq'];

        // Clear existing buttons
        while (elements.providerToggle.firstChild) {
            elements.providerToggle.removeChild(elements.providerToggle.firstChild);
        }

        // Create buttons dynamically using safe DOM methods
        providerOptions.forEach(provider => {
            const config = PROVIDER_CONFIG[provider] || {
                icon: '🔌',
                name: provider.charAt(0).toUpperCase() + provider.slice(1),
                title: `${provider} STT provider`
            };

            const btn = document.createElement('button');
            btn.className = 'provider-btn';
            btn.dataset.provider = provider;
            btn.title = config.title;

            const iconSpan = document.createElement('span');
            iconSpan.className = 'provider-icon';
            iconSpan.textContent = config.icon;

            const nameSpan = document.createElement('span');
            nameSpan.className = 'provider-name';
            nameSpan.textContent = config.name;

            btn.appendChild(iconSpan);
            btn.appendChild(nameSpan);

            // Set active state based on current setting
            if (state.settings.stt_provider === provider) {
                btn.classList.add('active');
            }

            btn.addEventListener('click', () => {
                if (state.isRecording || state.isProcessing) return;
                setProvider(provider);
            });

            elements.providerToggle.appendChild(btn);
        });
    } catch (error) {
        console.error('Failed to load provider options:', error);
    }
}

function initClipboardSyncSlider() {
    if (!elements.clipboardSyncSlider) return;

    // Update display on input (while dragging)
    elements.clipboardSyncSlider.addEventListener('input', () => {
        const value = parseFloat(elements.clipboardSyncSlider.value);
        if (elements.clipboardSyncValue) {
            elements.clipboardSyncValue.textContent = `${value.toFixed(2)}s`;
        }
    });

    // Save setting on change (when released)
    elements.clipboardSyncSlider.addEventListener('change', () => {
        if (state.isRecording || state.isProcessing) return;
        const value = parseFloat(elements.clipboardSyncSlider.value);
        setSetting('clipboard_sync_delay', value);
    });
}

function initPasteDelaySlider() {
    if (!elements.pasteDelaySlider) return;

    // Update display on input (while dragging)
    elements.pasteDelaySlider.addEventListener('input', () => {
        const value = parseFloat(elements.pasteDelaySlider.value);
        if (elements.pasteDelayValue) {
            elements.pasteDelayValue.textContent = `${value.toFixed(2)}s`;
        }
    });

    // Save setting on change (when released)
    elements.pasteDelaySlider.addEventListener('change', () => {
        if (state.isRecording || state.isProcessing) return;
        const value = parseFloat(elements.pasteDelaySlider.value);
        setSetting('paste_delay', value);
    });
}

function initNormalizeToggle() {
    if (!elements.normalizeToggle) return;

    elements.normalizeToggle.addEventListener('click', () => {
        if (state.isRecording || state.isProcessing) return;
        // Toggle the current value
        const newValue = !state.settings.volume_normalization;
        setSetting('volume_normalization', newValue);
    });
}

function initFfmToggle() {
    if (elements.ffmToggle) {
        elements.ffmToggle.addEventListener('click', () => {
            if (state.isRecording || state.isProcessing) return;
            // Toggle the current value
            const newValue = !state.settings.ffm_enabled;
            setSetting('ffm_enabled', newValue);
        });
    }

    if (elements.ffmModeToggle) {
        const buttons = elements.ffmModeToggle.querySelectorAll('.ffm-mode-btn');
        buttons.forEach(btn => {
            btn.addEventListener('click', () => {
                if (state.isRecording || state.isProcessing) return;
                const mode = btn.dataset.mode;
                if (mode && mode !== state.settings.ffm_mode) {
                    setSetting('ffm_mode', mode);
                }
            });
        });
    }
}

function initMaxRecordingSlider() {
    if (!elements.maxRecordingSlider) return;

    // Format duration as "Xm" or "Xs"
    const formatDuration = (seconds) => {
        return seconds >= 60 ? `${Math.floor(seconds / 60)}m` : `${seconds}s`;
    };

    // Update display on input (while dragging)
    elements.maxRecordingSlider.addEventListener('input', () => {
        const value = parseInt(elements.maxRecordingSlider.value);
        if (elements.maxRecordingValue) {
            elements.maxRecordingValue.textContent = formatDuration(value);
        }
    });

    // Save setting on change (when released)
    elements.maxRecordingSlider.addEventListener('change', () => {
        if (state.isRecording || state.isProcessing) return;
        const value = parseInt(elements.maxRecordingSlider.value);
        setSetting('max_recording_duration', value);
    });
}

// =============================================================================
// Theme Toggle (localStorage-based)
// =============================================================================

function initThemeToggle() {
    if (!elements.themeToggle) return;

    const themeIcon = elements.themeToggle.querySelector('.theme-icon');

    // Get initial theme: localStorage > system preference > dark (default)
    const getInitialTheme = () => {
        const stored = localStorage.getItem('theme');
        if (stored) return stored;

        // Check system preference
        if (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
            return 'light';
        }
        return 'dark';
    };

    // Apply theme to document
    const applyTheme = (theme) => {
        if (theme === 'light') {
            document.body.classList.add('theme-light');
            if (themeIcon) themeIcon.textContent = '☀';
        } else {
            document.body.classList.remove('theme-light');
            if (themeIcon) themeIcon.textContent = '☾';
        }
    };

    // Toggle theme
    const toggleTheme = () => {
        const currentTheme = document.body.classList.contains('theme-light') ? 'light' : 'dark';
        const newTheme = currentTheme === 'light' ? 'dark' : 'light';
        localStorage.setItem('theme', newTheme);
        applyTheme(newTheme);
        console.log(`Theme changed to: ${newTheme}`);
    };

    // Apply initial theme
    const initialTheme = getInitialTheme();
    applyTheme(initialTheme);

    // Click handler
    elements.themeToggle.addEventListener('click', toggleTheme);

    // Listen for system preference changes
    if (window.matchMedia) {
        window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', (e) => {
            // Only auto-switch if user hasn't explicitly set a preference
            if (!localStorage.getItem('theme')) {
                applyTheme(e.matches ? 'light' : 'dark');
            }
        });
    }
}

// =============================================================================
// Key Detection (LEFT-side keys only)
// Uses event.code to distinguish left/right modifier keys
// =============================================================================

function isLeftModifierKey(event) {
    if (state.settings.keybinding === 'ctrl_only' || state.settings.keybinding === 'ctrl') {
        return event.code === 'ControlLeft';
    } else {
        return event.code === 'ShiftLeft';
    }
}

function isLeftCommandKey(event) {
    return event.code === 'MetaLeft';
}

function handleKeyDown(event) {
    // Only respond to LEFT-side modifier keys
    if (isLeftModifierKey(event)) {
        state.modifierPressed = true;
        elements.modifierKey?.classList.add('pressed');
        const modStatus = elements.modifierKey?.querySelector('.key-status');
        if (modStatus) modStatus.textContent = 'HELD';
    }

    if (isLeftCommandKey(event)) {
        state.cmdPressed = true;
        elements.cmdKey?.classList.add('pressed');
        const cmdStatus = elements.cmdKey?.querySelector('.key-status');
        if (cmdStatus) cmdStatus.textContent = 'HELD';
    }

    if (state.modifierPressed && state.cmdPressed && !state.isRecording && !state.isProcessing) {
        startRecording();
    }

    if (state.modifierPressed && state.cmdPressed) {
        event.preventDefault();
    }
}

function handleKeyUp(event) {
    // Only respond to LEFT-side modifier keys
    if (isLeftModifierKey(event)) {
        state.modifierPressed = false;
        elements.modifierKey?.classList.remove('pressed');
        const modStatus = elements.modifierKey?.querySelector('.key-status');
        if (modStatus) modStatus.textContent = '—';
    }

    if (isLeftCommandKey(event)) {
        state.cmdPressed = false;
        elements.cmdKey?.classList.remove('pressed');
        const cmdStatus = elements.cmdKey?.querySelector('.key-status');
        if (cmdStatus) cmdStatus.textContent = '—';
    }

    if (state.isRecording && (!state.modifierPressed || !state.cmdPressed)) {
        stopRecording();
    }
}

function handleBlur() {
    state.modifierPressed = false;
    state.cmdPressed = false;
    elements.modifierKey?.classList.remove('pressed');
    elements.cmdKey?.classList.remove('pressed');
    const modStatus = elements.modifierKey?.querySelector('.key-status');
    const cmdStatus = elements.cmdKey?.querySelector('.key-status');
    if (modStatus) modStatus.textContent = '—';
    if (cmdStatus) cmdStatus.textContent = '—';

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

function handleStatusUpdate(data) {
    if (data.cancelled) {
        // Recording was too short, cancelled
        state.isRecording = false;
        state.isProcessing = false;
        resetRecordingState();
        console.log('Recording cancelled (too short)');
    } else if (data.recording) {
        // CLI started recording
        state.isRecording = true;
        elements.recordingPanel?.classList.add('recording');
        elements.recordingPanel?.classList.remove('processing');
        elements.recLabel.textContent = 'RECORDING';
        elements.recHint.textContent = 'CLI is recording...';
        hideVolumeIndicator(); // Hide previous volume display
        console.log('CLI recording started');
    } else {
        // CLI stopped recording, now processing
        state.isRecording = false;
        state.isProcessing = true;
        elements.recordingPanel?.classList.remove('recording');
        elements.recordingPanel?.classList.add('processing');
        elements.recLabel.textContent = 'TRANSCRIBING';
        elements.recHint.textContent = 'Processing audio...';
        console.log('CLI recording stopped, transcribing...');
    }
}

function handleTranscriptionResult(result) {
    state.isProcessing = false;
    resetRecordingState();

    // Handle skipped requests (legacy, kept for compatibility)
    if (result.skipped) {
        console.log('Transcription skipped');
        return;
    }

    console.log('Transcription result:', result);

    // Update language badge if present
    if (result.language && elements.langBadge) {
        const langCode = result.language.toUpperCase();
        elements.langBadge.textContent = state.settings.language ? state.settings.language.toUpperCase() : langCode;
    }

    // Show volume indicator if audio_info present (normalization metrics)
    if (result.audio_info) {
        showVolumeIndicator(result.audio_info);
    }

    // Refresh history to show new entry
    if (result.text) {
        fetchHistory();
    }
}

function resetRecordingState() {
    elements.recordingPanel?.classList.remove('recording', 'processing');
    elements.recLabel.textContent = 'OBSERVING';
    elements.recHint.textContent = 'Waiting for CLI transcription...';
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
// Volume Indicator
// =============================================================================

const VOLUME_MAX_RMS = 5000; // Scale for meter display (target RMS is 3000)

function showVolumeIndicator(audioInfo) {
    if (!audioInfo || !elements.volumeIndicator) return;

    const { original_rms, processed_rms, normalized, gain_db } = audioInfo;

    // Only show if normalization was applied
    if (!normalized) {
        hideVolumeIndicator();
        return;
    }

    // Update meter fill widths
    const originalPercent = Math.min(100, (original_rms / VOLUME_MAX_RMS) * 100);
    const normalizedPercent = Math.min(100, (processed_rms / VOLUME_MAX_RMS) * 100);

    if (elements.volumeOriginalFill) {
        elements.volumeOriginalFill.style.width = `${originalPercent}%`;
    }
    if (elements.volumeNormalizedFill) {
        elements.volumeNormalizedFill.style.width = `${normalizedPercent}%`;
    }

    // Update numeric values
    if (elements.volumeOriginalValue) {
        elements.volumeOriginalValue.textContent = Math.round(original_rms);
    }
    if (elements.volumeNormalizedValue) {
        elements.volumeNormalizedValue.textContent = Math.round(processed_rms);
    }

    // Update gain display
    if (elements.volumeGain) {
        const gainText = gain_db >= 0 ? `+${gain_db.toFixed(1)}` : gain_db.toFixed(1);
        elements.volumeGain.textContent = `Gain: ${gainText}dB`;
    }

    // Show the indicator
    elements.volumeIndicator.classList.add('visible');
}

function hideVolumeIndicator() {
    elements.volumeIndicator?.classList.remove('visible');
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
// Vocabulary Panel
// =============================================================================

const vocabElements = {
    toggle: document.getElementById('vocabToggle'),
    terms: document.getElementById('vocabTerms'),
    count: document.getElementById('vocabCount'),
    panelCount: document.getElementById('vocabPanelCount'),
    overlay: document.getElementById('vocabOverlay'),
    closeBtn: document.getElementById('vocabPanelClose'),
    input: document.getElementById('vocabInput'),
    addBtn: document.getElementById('vocabAddBtn'),
    list: document.getElementById('vocabList'),
};

let vocabularyWords = [];

async function fetchVocabulary() {
    try {
        const response = await fetch('/api/vocabulary');
        const data = await response.json();
        vocabularyWords = data.vocabulary || [];
        updateVocabularyUI();
        console.log(`Vocabulary loaded: ${vocabularyWords.length} words`);
    } catch (error) {
        console.error('Failed to fetch vocabulary:', error);
    }
}

async function addVocabularyWord(word) {
    if (!word.trim()) return;

    try {
        const response = await fetch('/api/vocabulary', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ word: word.trim() }),
        });
        const data = await response.json();

        if (data.added) {
            vocabularyWords = data.vocabulary;
            updateVocabularyUI();
            console.log(`Added vocabulary word: ${word}`);
        } else {
            // Show error message to user
            const errorMsg = data.error || 'Word already exists';
            alert(errorMsg);
            console.log(`Failed to add word: ${errorMsg}`);
        }
    } catch (error) {
        console.error('Failed to add vocabulary word:', error);
    }
}

async function removeVocabularyWord(word) {
    try {
        const response = await fetch('/api/vocabulary', {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ word }),
        });
        const data = await response.json();

        if (data.removed) {
            vocabularyWords = data.vocabulary;
            updateVocabularyUI();
            console.log(`Removed vocabulary word: ${word}`);
        }
    } catch (error) {
        console.error('Failed to remove vocabulary word:', error);
    }
}

function createVocabWordElement(word) {
    const div = document.createElement('div');
    div.className = 'vocab-word';
    div.dataset.word = word;

    const textSpan = document.createElement('span');
    textSpan.className = 'vocab-word-text';
    textSpan.textContent = word;

    const deleteBtn = document.createElement('button');
    deleteBtn.className = 'vocab-word-delete';
    deleteBtn.title = 'Remove';
    deleteBtn.textContent = '✕';

    div.appendChild(textSpan);
    div.appendChild(deleteBtn);
    return div;
}

function updateVocabularyUI() {
    // Update quick-access bar display
    if (vocabElements.terms) {
        if (vocabularyWords.length === 0) {
            vocabElements.terms.textContent = '—';
        } else if (vocabularyWords.length <= 3) {
            vocabElements.terms.textContent = vocabularyWords.join(', ');
        } else {
            vocabElements.terms.textContent = vocabularyWords.slice(0, 2).join(', ') + '...';
        }
    }

    if (vocabElements.count) {
        vocabElements.count.textContent = vocabularyWords.length;
    }

    if (vocabElements.panelCount) {
        vocabElements.panelCount.textContent = vocabularyWords.length;
    }

    // Update panel word list using safe DOM methods
    if (vocabElements.list) {
        vocabElements.list.replaceChildren();

        if (vocabularyWords.length === 0) {
            const emptyDiv = document.createElement('div');
            emptyDiv.className = 'panel-items-empty';
            emptyDiv.textContent = 'No vocabulary words yet. Add words above to improve transcription accuracy.';
            vocabElements.list.appendChild(emptyDiv);
        } else {
            vocabularyWords.forEach(word => {
                vocabElements.list.appendChild(createVocabWordElement(word));
            });
        }
    }
}

function openVocabPanel() {
    vocabElements.overlay?.classList.add('active');
    vocabElements.input?.focus();
}

function closeVocabPanel() {
    vocabElements.overlay?.classList.remove('active');
}

function initVocabularyPanel() {
    // Toggle panel on quick-access click
    vocabElements.toggle?.addEventListener('click', () => {
        openVocabPanel();
    });

    // Close panel
    vocabElements.closeBtn?.addEventListener('click', closeVocabPanel);

    // Close on overlay click (but not panel click)
    vocabElements.overlay?.addEventListener('click', (e) => {
        if (e.target === vocabElements.overlay) {
            closeVocabPanel();
        }
    });

    // Add word on button click
    vocabElements.addBtn?.addEventListener('click', () => {
        const word = vocabElements.input?.value;
        if (word) {
            addVocabularyWord(word);
            vocabElements.input.value = '';
            vocabElements.input.focus();
        }
    });

    // Add word on Enter
    vocabElements.input?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            const word = vocabElements.input.value;
            if (word) {
                addVocabularyWord(word);
                vocabElements.input.value = '';
            }
        }
    });

    // Remove word on delete button click (event delegation)
    vocabElements.list?.addEventListener('click', (e) => {
        const deleteBtn = e.target.closest('.vocab-word-delete');
        if (deleteBtn) {
            const wordEl = deleteBtn.closest('.vocab-word');
            const word = wordEl?.dataset.word;
            if (word) {
                removeVocabularyWord(word);
            }
        }
    });

    // Initial load
    fetchVocabulary();
}

// =============================================================================
// History Panel
// =============================================================================

const historyElements = {
    toggle: document.getElementById('historyToggle'),
    count: document.getElementById('historyCount'),
    panelCount: document.getElementById('historyPanelCount'),
    overlay: document.getElementById('historyOverlay'),
    closeBtn: document.getElementById('historyPanelClose'),
    clearBtn: document.getElementById('historyClearBtn'),
    list: document.getElementById('historyList'),
};

let historyEntries = [];

async function fetchHistory() {
    try {
        const response = await fetch('/api/history');
        const data = await response.json();
        historyEntries = data.history || [];
        updateHistoryUI();
        console.log(`History loaded: ${historyEntries.length} entries`);
    } catch (error) {
        console.error('Failed to fetch history:', error);
    }
}

async function deleteHistoryEntry(index) {
    try {
        const response = await fetch(`/api/history/${index}`, {
            method: 'DELETE',
        });
        const data = await response.json();

        if (data.deleted) {
            historyEntries = data.history;
            updateHistoryUI();
            console.log(`Deleted history entry ${index}`);
        }
    } catch (error) {
        console.error('Failed to delete history entry:', error);
    }
}

async function clearAllHistory() {
    if (!confirm('Clear all history entries? This cannot be undone.')) return;

    try {
        const response = await fetch('/api/history', {
            method: 'DELETE',
        });
        const data = await response.json();

        if (data.cleared) {
            historyEntries = [];
            updateHistoryUI();
            console.log('History cleared');
        }
    } catch (error) {
        console.error('Failed to clear history:', error);
    }
}

async function copyHistoryEntry(index, entryEl) {
    const text = historyEntries[index];
    if (!text) return;

    try {
        await navigator.clipboard.writeText(text);

        // Visual feedback
        entryEl.classList.add('copied');
        setTimeout(() => {
            entryEl.classList.remove('copied');
        }, 1000);

        console.log('Copied to clipboard');
    } catch (error) {
        console.error('Failed to copy:', error);
    }
}

function createHistoryEntryElement(text, index) {
    const entry = document.createElement('div');
    entry.className = 'history-entry';
    entry.dataset.index = index;

    // Index badge
    const indexDiv = document.createElement('div');
    indexDiv.className = 'history-entry-index';
    indexDiv.textContent = index + 1;

    // Content
    const contentDiv = document.createElement('div');
    contentDiv.className = 'history-entry-content';

    const textDiv = document.createElement('div');
    textDiv.className = 'history-entry-text';
    textDiv.textContent = text;

    contentDiv.appendChild(textDiv);

    // Actions (only delete button - clicking entry copies)
    const actionsDiv = document.createElement('div');
    actionsDiv.className = 'history-entry-actions';

    const deleteBtn = document.createElement('button');
    deleteBtn.className = 'history-action-btn delete';
    deleteBtn.title = 'Delete entry';
    deleteBtn.textContent = '✕';

    actionsDiv.appendChild(deleteBtn);

    // Toast
    const toast = document.createElement('div');
    toast.className = 'history-copy-toast';
    toast.textContent = 'COPIED';

    entry.appendChild(indexDiv);
    entry.appendChild(contentDiv);
    entry.appendChild(actionsDiv);
    entry.appendChild(toast);

    return entry;
}

function updateHistoryUI() {
    // Update quick-access bar count
    if (historyElements.count) {
        historyElements.count.textContent = historyEntries.length;
    }

    if (historyElements.panelCount) {
        historyElements.panelCount.textContent = historyEntries.length;
    }

    // Update panel list using safe DOM methods
    if (historyElements.list) {
        historyElements.list.replaceChildren();

        if (historyEntries.length === 0) {
            const emptyDiv = document.createElement('div');
            emptyDiv.className = 'panel-items-empty';
            emptyDiv.textContent = 'No dictation history yet. Transcriptions will appear here.';
            historyElements.list.appendChild(emptyDiv);
        } else {
            historyEntries.forEach((text, index) => {
                historyElements.list.appendChild(createHistoryEntryElement(text, index));
            });
        }
    }
}

function openHistoryPanel() {
    historyElements.overlay?.classList.add('active');
    fetchHistory(); // Refresh on open
}

function closeHistoryPanel() {
    historyElements.overlay?.classList.remove('active');
}

function initHistoryPanel() {
    // Toggle panel on quick-access click
    historyElements.toggle?.addEventListener('click', () => {
        openHistoryPanel();
    });

    // Close panel
    historyElements.closeBtn?.addEventListener('click', closeHistoryPanel);

    // Close on overlay click (but not panel click)
    historyElements.overlay?.addEventListener('click', (e) => {
        if (e.target === historyElements.overlay) {
            closeHistoryPanel();
        }
    });

    // Clear all history
    historyElements.clearBtn?.addEventListener('click', clearAllHistory);

    // Handle clicks on history entries - click anywhere to copy, delete button to delete
    historyElements.list?.addEventListener('click', (e) => {
        const entry = e.target.closest('.history-entry');
        if (!entry) return;

        const index = parseInt(entry.dataset.index, 10);

        // Check if delete button was clicked
        if (e.target.closest('.history-action-btn.delete')) {
            deleteHistoryEntry(index);
            return;
        }

        // Click anywhere else on entry to copy
        copyHistoryEntry(index, entry);
    });

    // Initial load
    fetchHistory();
}

// =============================================================================
// Replacements Panel
// =============================================================================

const replacementsElements = {
    toggle: document.getElementById('replacementsToggle'),
    count: document.getElementById('replacementsCount'),
    panelCount: document.getElementById('replacementsPanelCount'),
    overlay: document.getElementById('replacementsOverlay'),
    closeBtn: document.getElementById('replacementsPanelClose'),
    enabledToggle: document.getElementById('replacementsEnabledToggle'),
    fromInput: document.getElementById('replacementFromInput'),
    toInput: document.getElementById('replacementToInput'),
    addBtn: document.getElementById('replacementAddBtn'),
    list: document.getElementById('replacementsList'),
};

let replacementRules = [];

async function fetchReplacements() {
    try {
        const response = await fetch('/api/replacements');
        const data = await response.json();
        replacementRules = data.replacements || [];
        updateReplacementsUI();
        console.log(`Replacements loaded: ${replacementRules.length} rules`);
    } catch (error) {
        console.error('Failed to fetch replacements:', error);
    }
}

async function addReplacement(fromText, toText) {
    if (!fromText.trim() || !toText.trim()) return;

    try {
        const response = await fetch('/api/replacements', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ from_text: fromText.trim(), to_text: toText.trim() }),
        });
        const data = await response.json();

        if (data.added) {
            replacementRules = data.replacements;
            updateReplacementsUI();
            console.log(`Added replacement: "${fromText}" → "${toText}"`);
        } else {
            // Show error message to user
            const errorMsg = data.error || 'Failed to add replacement';
            alert(errorMsg);
            console.log(`Failed to add replacement: ${errorMsg}`);
        }
    } catch (error) {
        console.error('Failed to add replacement:', error);
    }
}

async function removeReplacement(fromText) {
    try {
        const response = await fetch('/api/replacements', {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ from_text: fromText, to_text: '' }),
        });
        const data = await response.json();

        if (data.removed) {
            replacementRules = data.replacements;
            updateReplacementsUI();
            console.log(`Removed replacement: "${fromText}"`);
        }
    } catch (error) {
        console.error('Failed to remove replacement:', error);
    }
}

function createReplacementElement(rule) {
    const div = document.createElement('div');
    div.className = 'replacement-item';
    div.dataset.from = rule.from;

    const fromSpan = document.createElement('span');
    fromSpan.className = 'replacement-from';
    fromSpan.textContent = rule.from;

    const arrowSpan = document.createElement('span');
    arrowSpan.className = 'replacement-arrow-display';
    arrowSpan.textContent = '→';

    const toSpan = document.createElement('span');
    toSpan.className = 'replacement-to';
    toSpan.textContent = rule.to;

    const deleteBtn = document.createElement('button');
    deleteBtn.className = 'replacement-delete';
    deleteBtn.title = 'Remove';
    deleteBtn.textContent = '✕';

    div.appendChild(fromSpan);
    div.appendChild(arrowSpan);
    div.appendChild(toSpan);
    div.appendChild(deleteBtn);
    return div;
}

async function toggleReplacementsEnabled() {
    const newValue = !state.settings.replacements_enabled;
    try {
        const response = await fetch('/api/settings/replacements_enabled', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ value: newValue }),
        });
        const data = await response.json();
        state.settings.replacements_enabled = data.replacements_enabled;
        updateReplacementsEnabledUI();
        console.log(`Replacements ${newValue ? 'enabled' : 'disabled'}`);
    } catch (error) {
        console.error('Failed to toggle replacements:', error);
    }
}

function updateReplacementsEnabledUI() {
    if (replacementsElements.enabledToggle) {
        const isEnabled = state.settings.replacements_enabled;
        replacementsElements.enabledToggle.classList.toggle('active', isEnabled);
        const label = replacementsElements.enabledToggle.querySelector('.toggle-label');
        if (label) {
            label.textContent = isEnabled ? 'Enabled' : 'Disabled';
        }
    }
}

function updateReplacementsUI() {
    // Update quick-access count
    if (replacementsElements.count) {
        replacementsElements.count.textContent = replacementRules.length;
    }

    if (replacementsElements.panelCount) {
        replacementsElements.panelCount.textContent = replacementRules.length;
    }

    // Update enabled toggle state
    updateReplacementsEnabledUI();

    // Update panel list using safe DOM methods
    if (replacementsElements.list) {
        replacementsElements.list.replaceChildren();

        if (replacementRules.length === 0) {
            const emptyDiv = document.createElement('div');
            emptyDiv.className = 'panel-items-empty';
            emptyDiv.textContent = 'No replacements yet. Add word pairs above to automatically replace text in transcriptions.';
            replacementsElements.list.appendChild(emptyDiv);
        } else {
            replacementRules.forEach(rule => {
                replacementsElements.list.appendChild(createReplacementElement(rule));
            });
        }
    }
}

function openReplacementsPanel() {
    replacementsElements.overlay?.classList.add('active');
    replacementsElements.fromInput?.focus();
}

function closeReplacementsPanel() {
    replacementsElements.overlay?.classList.remove('active');
}

function initReplacementsPanel() {
    // Toggle panel on quick-access click
    replacementsElements.toggle?.addEventListener('click', () => {
        openReplacementsPanel();
    });

    // Close panel
    replacementsElements.closeBtn?.addEventListener('click', closeReplacementsPanel);

    // Enable/disable toggle
    replacementsElements.enabledToggle?.addEventListener('click', toggleReplacementsEnabled);

    // Close on overlay click (but not panel click)
    replacementsElements.overlay?.addEventListener('click', (e) => {
        if (e.target === replacementsElements.overlay) {
            closeReplacementsPanel();
        }
    });

    // Add replacement on button click
    replacementsElements.addBtn?.addEventListener('click', () => {
        const fromText = replacementsElements.fromInput?.value;
        const toText = replacementsElements.toInput?.value;
        if (fromText && toText) {
            addReplacement(fromText, toText);
            replacementsElements.fromInput.value = '';
            replacementsElements.toInput.value = '';
            replacementsElements.fromInput.focus();
        }
    });

    // Handle Enter key in both inputs
    const handleEnter = (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            const fromText = replacementsElements.fromInput?.value;
            const toText = replacementsElements.toInput?.value;
            if (fromText && toText) {
                addReplacement(fromText, toText);
                replacementsElements.fromInput.value = '';
                replacementsElements.toInput.value = '';
                replacementsElements.fromInput.focus();
            }
        }
    };
    replacementsElements.fromInput?.addEventListener('keydown', handleEnter);
    replacementsElements.toInput?.addEventListener('keydown', handleEnter);

    // Tab from 'from' to 'to' input
    replacementsElements.fromInput?.addEventListener('keydown', (e) => {
        if (e.key === 'Tab' && !e.shiftKey) {
            e.preventDefault();
            replacementsElements.toInput?.focus();
        }
    });

    // Remove replacement on delete button click (event delegation)
    replacementsElements.list?.addEventListener('click', (e) => {
        const deleteBtn = e.target.closest('.replacement-delete');
        if (deleteBtn) {
            const itemEl = deleteBtn.closest('.replacement-item');
            const fromText = itemEl?.dataset.from;
            if (fromText) {
                removeReplacement(fromText);
            }
        }
    });

    // Initial load
    fetchReplacements();
}

// Global Escape key handler for all panels
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        if (vocabElements.overlay?.classList.contains('active')) {
            closeVocabPanel();
        }
        if (historyElements.overlay?.classList.contains('active')) {
            closeHistoryPanel();
        }
        if (replacementsElements.overlay?.classList.contains('active')) {
            closeReplacementsPanel();
        }
    }
});

// =============================================================================
// Initialization
// =============================================================================

async function init() {
    // Initialize theme first (before other UI to avoid flash)
    initThemeToggle();

    // Fetch settings from server
    await fetchSettings();

    // Initialize UI
    initLanguageSelector();
    initKeybindToggle();
    await initProviderToggle();
    initClipboardSyncSlider();
    initPasteDelaySlider();
    initNormalizeToggle();
    initFfmToggle();
    initMaxRecordingSlider();
    initVocabularyPanel();
    initHistoryPanel();
    initReplacementsPanel();

    // Connect WebSocket
    connectWebSocket();

    // Start health checks (detect network/API issues)
    startHealthChecks();

    // Key listeners disabled - web UI is observer-only
    // Transcription results are broadcast from CLI
    // document.addEventListener('keydown', handleKeyDown);
    // document.addEventListener('keyup', handleKeyUp);
    // window.addEventListener('blur', handleBlur);

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

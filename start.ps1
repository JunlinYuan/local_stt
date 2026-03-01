# Start Local STT - Server + Global Hotkey Client (Windows)
# Both run in foreground with interleaved output

$ErrorActionPreference = "Stop"

$PROJECT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$BACKEND_DIR = Join-Path $PROJECT_DIR "backend"
$LOG_FILE = Join-Path $env:TEMP "local-stt-server.log"

Write-Host "=========================================="
Write-Host "  Local STT - Full Stack (Windows)"
Write-Host "=========================================="

Set-Location $BACKEND_DIR

# Check if uv is available
if (-not (Get-Command "uv" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: uv is not installed. Please install it first:"
    Write-Host "  powershell -ExecutionPolicy ByPass -c `"irm https://astral.sh/uv/install.ps1 | iex`""
    exit 1
}

# Install all dependencies (Windows uses client-windows extra)
Write-Host "Installing dependencies..."
uv sync --extra client-windows

# Kill any existing server on port 8000
$existingProcess = Get-NetTCPConnection -LocalPort 8000 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique
if ($existingProcess) {
    Write-Host "Stopping existing server..."
    $existingProcess | ForEach-Object {
        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}

Write-Host "Starting server..."
# Clear old log and start server
$ERR_FILE = Join-Path $env:TEMP "local-stt-server-err.log"
"" | Out-File -FilePath $LOG_FILE -Force
"" | Out-File -FilePath $ERR_FILE -Force
$env:PYTHONUNBUFFERED = "1"
$serverProcess = Start-Process -FilePath "uv" -ArgumentList "run", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", "8000" `
    -RedirectStandardOutput $LOG_FILE -RedirectStandardError $ERR_FILE `
    -NoNewWindow -PassThru

# Wait for server to be ready
Write-Host -NoNewline "Waiting for server"
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:8000/" -TimeoutSec 2 -UseBasicParsing -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            Write-Host " ready!"
            $ready = $true
            break
        }
    } catch {}
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 1
}

if (-not $ready) {
    Write-Host " failed!"
    Write-Host "Server log:"
    Get-Content $LOG_FILE
    exit 1
}

# Open browser
Start-Process "http://127.0.0.1:8000"

Write-Host ""
Write-Host "Server: http://127.0.0.1:8000 (opened in browser)"
Write-Host ""
Write-Host "--------------------------------------------"
Write-Host "  Logs from both server and client below"
Write-Host "--------------------------------------------"
Write-Host ""

# Start tailing server log in background
$tailJob = Start-Job -ScriptBlock {
    param($logFile)
    Get-Content -Path $logFile -Wait
} -ArgumentList $LOG_FILE

# Register cleanup
$cleanup = {
    Write-Host ""
    Write-Host "Shutting down..."
    if ($tailJob) { Stop-Job $tailJob -ErrorAction SilentlyContinue; Remove-Job $tailJob -ErrorAction SilentlyContinue }
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

try {
    # Print tail output periodically while client runs
    $clientProcess = Start-Process -FilePath "uv" -ArgumentList "run", "python", "hotkey_client.py" `
        -NoNewWindow -PassThru

    while (-not $clientProcess.HasExited) {
        Receive-Job $tailJob -ErrorAction SilentlyContinue | Write-Host
        Start-Sleep -Milliseconds 500
    }
} finally {
    & $cleanup
}

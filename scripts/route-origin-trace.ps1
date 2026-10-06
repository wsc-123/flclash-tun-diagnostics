[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Status', 'Export')][string]$Action = 'Status',
    [string]$RecordingDirectory = '',
    [switch]$LaunchedFromBatch,
    [switch]$NoPause
)

# Uses a temporary Windows ETW session; does not change network configuration.
# Run the Start and Stop launchers as administrator. No automatic elevation.
$ErrorActionPreference = 'Stop'
$traceSession = 'FlClashRouteOrigin'
$toolRoot = Split-Path -Parent $PSScriptRoot
$traceRoot = Join-Path $toolRoot 'output\route-traces'
$statePath = Join-Path $traceRoot '.active.json'
$logman = Join-Path $env:SystemRoot 'System32\logman.exe'
$routeExe = Join-Path $env:SystemRoot 'System32\route.exe'

function Write-LocalSnapshot([string]$Directory, [string]$Phase) {
    & $routeExe print -4 2>&1 | Out-File (Join-Path $Directory ($Phase + '-routes.txt')) -Encoding utf8
    $items = @(Get-Process | ForEach-Object {
        $started = $null
        try { $started = $_.StartTime.ToString('o') } catch { }
        [ordered]@{ id = $_.Id; name = $_.ProcessName; started = $started }
    })
    ConvertTo-Json -InputObject $items -Depth 4 | Set-Content (Join-Path $Directory ($Phase + '-processes.json')) -Encoding utf8
    try {
        $services = @(Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, ProcessId)
        ConvertTo-Json -InputObject $services -Depth 4 | Set-Content (Join-Path $Directory ($Phase + '-services.json')) -Encoding utf8
    } catch {
        $_.Exception.Message | Set-Content (Join-Path $Directory ($Phase + '-services-error.txt')) -Encoding utf8
    }
}

function Resolve-TraceRecording([string]$Directory) {
    $resolved = [IO.Path]::GetFullPath($Directory)
    $allowed = [IO.Path]::GetFullPath($traceRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw 'The recording directory must exist inside this tool''s output\route-traces folder.'
    }
    return $resolved
}

function Get-TraceStateDirectory($SavedState) {
    if ($SavedState.recording) {
        if ([string]$SavedState.recording -notmatch '^\d{8}_\d{6}_[a-f0-9]{6}$') {
            throw 'Invalid recording name in the trace marker.'
        }
        return (Resolve-TraceRecording (Join-Path $traceRoot ([string]$SavedState.recording)))
    }
    # Accept a legacy absolute marker only if it resolves inside the current output tree.
    return (Resolve-TraceRecording ([string]$SavedState.directory))
}

function Complete-TraceMarker([string]$Directory) {
    if (-not (Test-Path -LiteralPath (Join-Path $Directory 'stopped-at.txt'))) { return }
    if (-not (Test-Path -LiteralPath $statePath)) { return }
    $saved = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($saved.session -eq $traceSession -and
        (Get-TraceStateDirectory $saved) -eq [IO.Path]::GetFullPath($Directory)) {
        Copy-Item -LiteralPath $statePath -Destination (Join-Path $Directory 'trace-info.json')
        Remove-Item -LiteralPath $statePath
    }
}

function Export-TraceRouteEvents([string]$Directory) {
    $eventPath = Join-Path $Directory 'route-events.jsonl'
    $writer = New-Object IO.StreamWriter($eventPath, $false, (New-Object Text.UTF8Encoding($true)))
    $count = 0
    $issues = New-Object 'System.Collections.Generic.List[string]'
    try {
        $etlFiles = @(Get-ChildItem -LiteralPath $Directory -Filter '*.etl' -File)
        if (-not $etlFiles.Count) { throw 'No ETL recording files were found.' }
        foreach ($etl in $etlFiles) {
            try {
                # Filter inside Windows instead of formatting every unrelated event in PowerShell.
                Get-WinEvent -Path $etl.FullName -Oldest -FilterXPath '*[System[(EventID=1145 or EventID=1146 or EventID=1147 or EventID=1452)]]' -ErrorAction Stop |
                    Where-Object { $_.ProviderName -eq 'Microsoft-Windows-TCPIP' } |
                    ForEach-Object {
                        $entry = [ordered]@{
                            time = $_.TimeCreated.ToString('o'); eventId = $_.Id
                            processId = $_.ProcessId; threadId = $_.ThreadId; xml = $_.ToXml()
                        }
                        $writer.WriteLine((ConvertTo-Json -InputObject $entry -Depth 4 -Compress))
                        $count++
                    }
            } catch {
                # A healthy interval can have no route changes. This is a valid empty result.
                if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
            }
        }
    } catch {
        $issues.Add($_.Exception.Message)
        Write-Warning 'Event decoding was incomplete. Keep the original ETL files for analysis.'
    } finally { $writer.Dispose() }
    $summary = [ordered]@{
        completed = ($issues.Count -eq 0); routeEvents = $count
        exportedAt = (Get-Date).ToString('o'); errors = @($issues.ToArray())
        note = 'Counts describe events retained in the circular file, not necessarily the entire recording interval.'
    }
    $summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Directory 'export-status.json') -Encoding utf8
    Write-Host ('Exported route events: ' + $count)
    Write-Host ('Output: ' + $Directory)
    return ($issues.Count -eq 0)
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if ($Action -eq 'Status') {
        if (Test-Path -LiteralPath $statePath) {
            Write-Host 'A saved trace marker exists. Windows session status:'
            & $logman query $traceSession -ets
            Write-Host (Get-Content -Raw -LiteralPath $statePath)
        } else { Write-Host 'No trace marker exists in this folder.' }
        exit 0
    }

    if ($Action -eq 'Export') {
        $runDirectory = Resolve-TraceRecording $RecordingDirectory
        if (-not (Test-Path -LiteralPath (Join-Path $runDirectory 'stopped-at.txt'))) {
            throw 'Run Stop first. Export only processes a recording with a saved stop record.'
        }
        Complete-TraceMarker $runDirectory
        if (Export-TraceRouteEvents $runDirectory) { exit 0 } else { exit 1 }
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $identity.Dispose()
    if (-not $elevated) {
        throw 'Administrator is required for Windows ETW. Right-click the .bat launcher and select Run as administrator.'
    }

    if ($Action -eq 'Start') {
        if (Test-Path -LiteralPath $statePath) {
            throw 'A trace marker already exists. Run the root folder''s 03-*.bat first to preserve that recording.'
        }
        $runName = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
        $runDirectory = Join-Path $traceRoot $runName
        [void][IO.Directory]::CreateDirectory($runDirectory)
        $tracePath = Join-Path $runDirectory 'route-events.etl'
        # Keyword 0x20 = TcpipRoute; level 4 includes route creation/deletion.
        # -ets does not save a scheduled data collector. Circular log: 32 MB.
        & $logman create trace $traceSession -p '{2F07E2EE-15DB-40F1-90EF-9D7BA282188A}' 0x20 4 -o $tracePath -f bincirc -max 32 -ft 1 -ets
        if ($LASTEXITCODE -ne 0) { throw 'Windows could not start the trace. No network settings were changed.' }
        try {
            [ordered]@{ session = $traceSession; recording = $runName; started = (Get-Date).ToString('o') } |
                ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
        } catch {
            & $logman stop $traceSession -ets
            throw
        }
        try { Write-LocalSnapshot $runDirectory 'start' }
        catch { Write-Warning ('Initial snapshot failed; trace is still running: ' + $_.Exception.Message) }
        Write-Host 'STARTED. You may close this window and use TUN normally.'
        Write-Host 'When the fault returns, run the root folder''s 03-*.bat as administrator before deleting the route.'
        Write-Host ('Output: ' + $runDirectory)
        exit 0
    }

    if (-not (Test-Path -LiteralPath $statePath)) {
        throw 'No saved trace marker was found. Run the root folder''s 02-*.bat first.'
    }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    if ($state.session -ne $traceSession) {
        throw 'The saved trace marker is invalid. No session or files were changed.'
    }
    $runDirectory = Get-TraceStateDirectory $state

    # Snapshot before stopping so a route still present at failure is retained.
    try { Write-LocalSnapshot $runDirectory 'stop' }
    catch { Write-Warning ('Final snapshot failed: ' + $_.Exception.Message) }
    & $logman query $traceSession -ets | Out-File (Join-Path $runDirectory 'session-status.txt') -Encoding utf8
    if ($LASTEXITCODE -eq 0) {
        & $logman stop $traceSession -ets
        if ($LASTEXITCODE -ne 0) { throw 'Could not stop the trace. The marker is retained; retry Stop.' }
    } else {
        Write-Warning 'The Windows trace session is unavailable (for example, after a restart). Attempting to preserve existing files.'
    }
    (Get-Date).ToString('o') | Set-Content (Join-Path $runDirectory 'stopped-at.txt') -Encoding utf8
    # Release the stopped marker before export, so closing the window during export cannot block a new Start.
    Complete-TraceMarker $runDirectory
    Write-Host 'Trace STOPPED. Exporting the saved file...'
    $exported = Export-TraceRouteEvents $runDirectory
    Write-Host 'STOPPED. Original ETL recording retained.'
    Write-Host ('Output: ' + $runDirectory)
    Write-Host 'Event PID is execution context; it may be a system worker, not the original requesting application.'
    if (-not $exported) { exit 1 }
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($LaunchedFromBatch -and -not $NoPause) { [void](Read-Host 'Press Enter to close') }
}

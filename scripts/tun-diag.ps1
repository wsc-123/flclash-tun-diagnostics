[CmdletBinding()]
param(
    [string]$Api = 'http://127.0.0.1:9090',
    [string]$Secret = $env:FLCLASH_DIAG_SECRET,
    [string]$Proxy = 'http://127.0.0.1:7890',
    [string]$EntryDomain = '',
    [string]$EntryIP = '',
    [Alias('CampusDns')][string]$DnsServer = '',
    [string]$OutputDirectory = '',
    [ValidateRange(2, 30)][int]$RequestTimeoutSeconds = 8,
    [switch]$SkipNetworkTests,
    [switch]$LaunchedFromBatch,
    [switch]$NoPause
)

# Windows PowerShell 5.1: keep this source as UTF-8 with BOM.
# Dot-sourcing loads helpers without running a collection (used by tests).
$script:DiagVersion = '2.2'
$script:DiagWriter = $null
$script:DiagResults = New-Object 'System.Collections.Generic.List[object]'
$script:DiagCurl = $null
$script:DiagSourceRoot = $PSScriptRoot
if (-not $script:DiagSourceRoot) { $script:DiagSourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DiagToolRoot = Split-Path -Parent $script:DiagSourceRoot
$script:DiagUsesDefaultOutput = -not $PSBoundParameters.ContainsKey('OutputDirectory')
if ($script:DiagUsesDefaultOutput) {
    $OutputDirectory = Join-Path (Join-Path $script:DiagToolRoot 'output\diagnostics') (Get-Date -Format 'yyyy-MM-dd')
}

function Protect-DiagText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    if ($Secret) { $Text = $Text.Replace($Secret, '[REDACTED]') }
    $Text = [regex]::Replace($Text, '(?i)((?:https?|socks[45]h?)://)[^/\s@]+@', '$1[REDACTED]@')
    $Text = [regex]::Replace($Text, '(?i)([?&](?:token|access_token|api[_-]?key|secret|password|auth|key)=)[^&#\s"'']+', '$1[REDACTED]')
    return $Text
}

function Write-DiagLog {
    param([AllowEmptyString()][string]$Text = '')
    $script:DiagWriter.WriteLine((Protect-DiagText $Text))
    $script:DiagWriter.Flush()
}

function Write-DiagSection {
    param([string]$Title)
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Title)
    Write-DiagLog
    Write-DiagLog ('========== {0} | {1} ==========' -f $Title, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'))
}

function Add-DiagResult {
    param([string]$Name, [string]$Status, [string]$Detail, [double]$Seconds = 0)
    $script:DiagResults.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Seconds = [math]::Round($Seconds, 3) })
    Write-DiagLog ('[{0}] {1} | {2:F3}s | {3}' -f $Status, $Name, $Seconds, $Detail)
}

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    # Quote according to the Windows CommandLineToArgvW/CRT convention, including empty arguments.
    $Value = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $Value = [regex]::Replace($Value, '(\\+)$', '$1$1')
    return '"' + $Value + '"'
}

function Invoke-DiagProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 15,
        [string]$InputText = '',
        [switch]$LegacyEncoding
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = New-Object Diagnostics.Process
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process.StartInfo = $info
    $timedOut = $false
    $stdout = ''
    $stderr = ''
    $exitCode = -1
    try {
        # .NET Framework creates the stdin writer using Console.InputEncoding
        # and flushes its preamble during Start. curl --config rejects a BOM.
        # Restore the caller's encoding immediately after creating the process.
        $previousInputEncoding = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
            [void]$process.Start()
        } finally { [Console]::InputEncoding = $previousInputEncoding }
        $outBuffer = New-Object IO.MemoryStream
        $errBuffer = New-Object IO.MemoryStream
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outBuffer)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($errBuffer)
        if ($InputText) { $process.StandardInput.Write($InputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
        }
        if ($outTask.Wait(2000)) { $stdout = ConvertFrom-DiagBytes $outBuffer.ToArray() -LegacyEncoding:$LegacyEncoding }
        if ($errTask.Wait(2000)) { $stderr = ConvertFrom-DiagBytes $errBuffer.ToArray() -LegacyEncoding:$LegacyEncoding }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
    } catch {
        $stderr = $_.Exception.Message
    } finally {
        if ($outBuffer) { $outBuffer.Dispose() }
        if ($errBuffer) { $errBuffer.Dispose() }
        $process.Dispose()
        $timer.Stop()
    }
    [pscustomobject]@{ StdOut = $stdout; StdErr = $stderr; ExitCode = $exitCode; TimedOut = $timedOut; Seconds = $timer.Elapsed.TotalSeconds }
}

function ConvertFrom-DiagBytes {
    param([byte[]]$Bytes, [switch]$LegacyEncoding)
    if ($LegacyEncoding) {
        try { return (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes) }
        catch [Text.DecoderFallbackException] {
            return [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).GetString($Bytes)
        }
    }
    return [Text.Encoding]::UTF8.GetString($Bytes)
}

function Invoke-LocalSnapshot {
    param([string]$Name, [string]$Code, [int]$TimeoutSeconds = 15)
    Write-DiagSection $Name
    # Run collectors in bounded child processes so a stuck CIM/provider query cannot hang the report.
    $prefix = '$ProgressPreference = ''SilentlyContinue''; [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); $OutputEncoding = [Console]::OutputEncoding; $ErrorActionPreference = ''Stop''; '
    $childCode = $prefix + 'try { & { ' + $Code + ' } | ConvertTo-Json -Depth 8 } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))
    $result = Invoke-DiagProcess -FilePath "$PSHOME\powershell.exe" -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $encoded) -TimeoutSeconds $TimeoutSeconds
    $status = 'OK'
    if ($result.TimedOut) { $status = 'TIMEOUT' } elseif ($result.ExitCode -ne 0) { $status = 'ERROR' }
    Add-DiagResult $Name $status ('采集进程退出码={0}' -f $result.ExitCode) $result.Seconds
    if ($result.StdOut) { Write-DiagLog $result.StdOut.TrimEnd() }
    if ($result.StdErr) { Write-DiagLog ('stderr: ' + $result.StdErr.TrimEnd()) }
    $script:DiagLastSnapshotOk = ($status -eq 'OK')
}

function Invoke-NativeSnapshot {
    param([string]$Name, [string]$FilePath, [string[]]$Arguments, [string]$LinePattern = '')
    Write-DiagSection $Name
    $result = Invoke-DiagProcess -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds 10 -LegacyEncoding
    $status = 'OK'
    if ($result.TimedOut) { $status = 'TIMEOUT' } elseif ($result.ExitCode -ne 0) { $status = 'ERROR' }
    Add-DiagResult $Name $status ('备用命令退出码={0}' -f $result.ExitCode) $result.Seconds
    $lines = @($result.StdOut -split '\r?\n')
    if ($LinePattern) { $lines = @($lines | Where-Object { $_ -match $LinePattern }) }
    Write-DiagLog ('筛选后行数={0}；最多记录 300 行。' -f $lines.Count)
    Write-DiagLog (($lines | Select-Object -First 300) -join "`r`n")
    if ($result.StdErr) { Write-DiagLog ('stderr: ' + $result.StdErr.TrimEnd()) }
}

function Get-ApiSnapshot {
    param([string]$Path)
    $arguments = @('-q', '--silent', '--show-error', '--noproxy', '*', '--proxy', '', '--connect-timeout', '2', '--max-time', '3', '--write-out', '\n__TUN_DIAG_HTTP__:%{http_code}')
    $inputConfig = ''
    if ($Secret) {
        # Pass authentication through stdin instead of exposing it in the curl process command line.
        $escaped = $Secret.Replace('\', '\\').Replace('"', '\"')
        $inputConfig = 'header = "Authorization: Bearer ' + $escaped + '"' + "`n"
        $arguments += @('--config', '-')
    }
    $arguments += @('--url', ($Api.TrimEnd('/') + $Path))
    $result = Invoke-DiagProcess $script:DiagCurl $arguments 6 $inputConfig -LegacyEncoding
    $match = [regex]::Match($result.StdOut, '(?s)^(.*)\r?\n__TUN_DIAG_HTTP__:(\d{3})\s*$')
    $httpCode = 0
    if ($match.Success) { $httpCode = [int]$match.Groups[2].Value }
    $ok = $false
    $value = $null
    $status = 'ERROR'
    $detail = 'HTTP={0}, curl退出码={1}' -f $httpCode, $result.ExitCode
    if ($result.TimedOut -or $result.ExitCode -eq 28) { $status = 'TIMEOUT' }
    elseif ($httpCode -in @(401, 403)) { $status = 'AUTH'; $detail += '；请设置 FLCLASH_DIAG_SECRET 后重试' }
    elseif ($result.ExitCode -eq 0 -and $httpCode -eq 200) {
        try {
            $value = $match.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $value) { throw 'Empty JSON' }
            $ok = $true
            $status = 'OK'
        } catch { $detail += '；响应不是有效的非空 JSON（不记录原始响应体）' }
    }
    Add-DiagResult ('API ' + $Path) $status $detail $result.Seconds
    if ($result.StdErr) { Write-DiagLog ('stderr: ' + $result.StdErr.TrimEnd()) }
    [pscustomobject]@{ Ok = $ok; Value = $value; HttpCode = $httpCode }
}

function Write-CoreSnapshots {
    Write-DiagSection '优先保存：FlClash 内核现场'
    Write-DiagLog ('控制器: ' + $Api + '（强制禁用 curl 显式代理）')
    if (-not $script:DiagCurl) { Add-DiagResult '内核快照' 'SKIP' '未找到 curl.exe'; return }
    $versionResult = Get-ApiSnapshot '/version'
    if (-not $versionResult.Ok) {
        Write-DiagLog '控制器不可用或鉴权失败，跳过其余 API；继续采集 Windows 状态。'
        return
    }
    Write-DiagLog ($versionResult.Value | Select-Object version, meta, premium | ConvertTo-Json)
    $configResult = Get-ApiSnapshot '/configs'
    if ($configResult.Ok) {
        $config = $configResult.Value
        $tun = $null
        if ($config.tun) {
            $tun = $config.tun | Select-Object enable, device, stack, 'dns-hijack', 'auto-route', 'strict-route', 'auto-detect-interface', 'inet4-address', 'inet6-address', mtu
        }
        # Explicit allowlist: /configs may contain authentication and other private values.
        Write-DiagLog ([ordered]@{ mode = $config.mode; ipv6 = $config.ipv6; mixedPort = $config.'mixed-port'; httpPort = $config.port; socksPort = $config.'socks-port'; interfaceName = $config.'interface-name'; tun = $tun } | ConvertTo-Json -Depth 5)
        if (-not $script:DiagProxySpecified) {
            if ($config.'mixed-port' -gt 0) { $script:DiagEffectiveProxy = 'http://127.0.0.1:' + $config.'mixed-port' }
            elseif ($config.port -gt 0) { $script:DiagEffectiveProxy = 'http://127.0.0.1:' + $config.port }
            elseif ($config.'socks-port' -gt 0) { $script:DiagEffectiveProxy = 'socks5h://127.0.0.1:' + $config.'socks-port' }
        }
    } elseif ($configResult.HttpCode -in @(401, 403)) { return }

    $connections = Get-ApiSnapshot '/connections'
    if ($connections.Ok) {
        $all = @($connections.Value.connections | Where-Object { $null -ne $_ })
        Write-DiagLog ('活动连接总数={0}；最多显示最近的 60 条。此快照采集于联网探测之前。' -f $all.Count)
        $sample = @($all | Sort-Object start -Descending | Select-Object -First 60 | ForEach-Object {
            [ordered]@{ start = $_.start; network = $_.metadata.network; type = $_.metadata.type; host = $_.metadata.host; destinationIP = $_.metadata.destinationIP; destinationPort = $_.metadata.destinationPort; process = $_.metadata.process; rule = $_.rule; rulePayload = $_.rulePayload; chains = $_.chains }
        })
        Write-DiagLog (ConvertTo-Json -InputObject $sample -Depth 5)
    }
    $proxies = Get-ApiSnapshot '/proxies'
    if ($proxies.Ok) {
        $nodes = @($proxies.Value.proxies.PSObject.Properties | ForEach-Object { $_.Value })
        $groups = @($nodes | Where-Object { $null -ne $_.all } | Select-Object -First 40 | ForEach-Object {
            [ordered]@{ name = $_.name; type = $_.type; selected = $_.now; members = @($_.all).Count }
        })
        Write-DiagLog ('代理项数={0}；以下为组选择，未主动测速；历史 alive 状态不能证明此刻可达。' -f $nodes.Count)
        Write-DiagLog (ConvertTo-Json -InputObject $groups -Depth 4)
    }
    $rules = Get-ApiSnapshot '/rules'
    if ($rules.Ok) {
        Write-DiagLog ('规则总数={0}；按类型统计：' -f @($rules.Value.rules).Count)
        Write-DiagLog (ConvertTo-Json -InputObject @($rules.Value.rules | Group-Object type | Select-Object Name, Count))
    }
}

function Invoke-HttpProbe {
    param([string]$Name, [string]$Url, [string]$ViaProxy = '', [string[]]$ExtraArguments = @())
    Write-DiagSection $Name
    if (-not $script:DiagCurl) { Add-DiagResult $Name 'SKIP' '未找到 curl.exe'; return }
    $route = '系统路由/TUN；已禁用 curl 显式代理及代理环境变量'
    $routeArgs = @('--proxy', '', '--noproxy', '*')
    if ($ViaProxy) { $route = '显式代理 ' + $ViaProxy; $routeArgs = @('--proxy', $ViaProxy, '--noproxy', '') }
    Write-DiagLog ('URL={0} | {1}' -f $Url, $route)
    $format = 'http_code=%{http_code}\ndns=%{time_namelookup}\nconnect=%{time_connect}\ntls=%{time_appconnect}\nfirst_byte=%{time_starttransfer}\ntotal=%{time_total}\nremote_ip=%{remote_ip}\nremote_port=%{remote_port}\nlocal_ip=%{local_ip}\n'
    $arguments = @('-q', '--silent', '--show-error', '--output', 'NUL', '--connect-timeout', '3', '--max-time', [string]$RequestTimeoutSeconds, '--write-out', $format) + $routeArgs + $ExtraArguments + @('--url', $Url)
    $result = Invoke-DiagProcess $script:DiagCurl $arguments ($RequestTimeoutSeconds + 3) -LegacyEncoding
    $match = [regex]::Match($result.StdOut, '(?m)^http_code=(\d{3})')
    $httpCode = 0
    if ($match.Success) { $httpCode = [int]$match.Groups[1].Value }
    $status = 'ERROR'
    $detail = 'curl退出码={0}, HTTP={1}' -f $result.ExitCode, $httpCode
    if ($result.TimedOut -or $result.ExitCode -eq 28) { $status = 'TIMEOUT' }
    elseif ($result.StdErr -match 'SEC_E_NO_CREDENTIALS') {
        $detail += '；本机 TLS 凭据初始化失败，请在正常桌面用户会话中复核，不能据此判断远端或 TUN 故障'
    }
    elseif ($result.ExitCode -eq 0 -and $httpCode -gt 0) {
        $status = 'RESPONSE'
        if ($httpCode -ge 400) { $detail += '；收到 HTTP 错误响应，传输已完成；不能据此判为 TUN 断网' }
        elseif ($httpCode -ge 300) { $detail += '；收到跳转响应，本测试不跟随跳转' }
    }
    Add-DiagResult $Name $status $detail $result.Seconds
    Write-DiagLog $result.StdOut.TrimEnd()
    if ($result.StdErr) { Write-DiagLog ('stderr: ' + $result.StdErr.TrimEnd()) }
}

function Invoke-DnsProbe {
    param([string]$Name, [string]$Server = '')
    $serverArgument = ''
    if ($Server) { $serverArgument = " -Server '" + $Server.Replace("'", "''") + "'" }
    $code = "Resolve-DnsName -Name 'baidu.com' -Type A -DnsOnly -NoHostsFile -QuickTimeout" + $serverArgument + ' | Select-Object Name, Type, IPAddress, NameHost, TTL, Section'
    Invoke-LocalSnapshot $Name $code 8
}

function Write-WindowsSnapshots {
    Invoke-LocalSnapshot '代理进程与服务（限定字段，不采集命令行）' @'
$processFilter = "Name='FlClash.exe' OR Name='FlClashCore.exe' OR Name='FlClashHelperService.exe' OR Name='mihomo.exe' OR Name='clash.exe' OR Name='sing-box.exe' OR Name='xray.exe' OR Name='v2ray.exe'"
[ordered]@{
    processes = @(Get-CimInstance Win32_Process -Filter $processFilter | Select-Object Name, ProcessId, ParentProcessId, CreationDate, WorkingSetSize, HandleCount)
    services = @(Get-CimInstance Win32_Service -Filter "Name LIKE '%clash%' OR Name LIKE '%mihomo%'" | Select-Object Name, State, StartMode, ProcessId, ExitCode)
}
'@
    if (-not $script:DiagLastSnapshotOk) {
        Invoke-LocalSnapshot '备用：代理进程与服务基础状态' @'
$items = @(Get-Process | Where-Object { $_.ProcessName -match '^(FlClash|FlClashCore|FlClashHelperService|mihomo|clash|sing-box|xray|v2ray)$' } | Select-Object ProcessName, Id, WorkingSet64, HandleCount)
$services = @(Get-Service -Name '*clash*', '*mihomo*' -ErrorAction SilentlyContinue | Select-Object Name, @{ Name='Status'; Expression={ [string]$_.Status } }, @{ Name='StartType'; Expression={ [string]$_.StartType } })
[ordered]@{ processes = $items; services = $services }
'@
    }
    Invoke-LocalSnapshot '网卡、IP、DNS 与接口优先级' @'
[ordered]@{
    adapters = @(Get-NetAdapter -IncludeHidden | Select-Object Name, InterfaceDescription, ifIndex, Status, LinkSpeed)
    addresses = @(Get-NetIPAddress | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, IPAddress, PrefixLength, AddressState, PrefixOrigin)
    dns = @(Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses.Count -gt 0 } | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, ServerAddresses)
    interfaces = @(Get-NetIPInterface | Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, ConnectionState, Dhcp, InterfaceMetric, NlMtu, AutomaticMetric)
}
'@
    if (-not $script:DiagLastSnapshotOk) {
        Invoke-LocalSnapshot '备用：网卡、地址、网关、DNS（.NET）' @'
foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    $properties = $adapter.GetIPProperties()
    [ordered]@{
        name = $adapter.Name; description = $adapter.Description; id = $adapter.Id
        status = [string]$adapter.OperationalStatus; type = [string]$adapter.NetworkInterfaceType
        addresses = @($properties.UnicastAddresses | ForEach-Object { $_.Address.ToString() })
        dns = @($properties.DnsAddresses | ForEach-Object { $_.ToString() })
        gateways = @($properties.GatewayAddresses | ForEach-Object { $_.Address.ToString() })
    }
}
'@
    }
    Invoke-LocalSnapshot 'IPv4 / IPv6 路由（最多 300 条）' @'
$routes = @(Get-NetRoute | Sort-Object AddressFamily, DestinationPrefix, RouteMetric)
[ordered]@{ total = $routes.Count; routes = @($routes | Select-Object -First 300 AddressFamily, DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex, RouteMetric, Protocol, State) }
'@
    if (-not $script:DiagLastSnapshotOk) {
        Invoke-NativeSnapshot '备用：IPv4 路由' "$env:SystemRoot\System32\route.exe" @('print', '-4')
        Invoke-NativeSnapshot '备用：IPv6 路由' "$env:SystemRoot\System32\route.exe" @('print', '-6')
    }
    $ports = @(7890, 9090, ([uri]$Api).Port, ([uri]$script:DiagEffectiveProxy).Port) | Where-Object { $_ -gt 0 } | Sort-Object -Unique
    $portCode = '$ports = @(' + ($ports -join ',') + '); '
    Invoke-LocalSnapshot '代理端口监听、连接状态统计' ($portCode + @'
$tcp = @(Get-NetTCPConnection)
$owners = @(Get-CimInstance Win32_Process -Filter "Name='FlClashCore.exe' OR Name='mihomo.exe' OR Name='clash.exe'" | ForEach-Object { $_.ProcessId })
[ordered]@{
    listeners = @($tcp | Where-Object { $_.State -eq 'Listen' -and ($_.LocalPort -in $ports -or $_.OwningProcess -in $owners) } | Select-Object LocalAddress, LocalPort, OwningProcess)
    coreConnectionStates = @($tcp | Where-Object { $_.OwningProcess -in $owners } | Group-Object State | Select-Object Name, Count)
    configuredPortConnections = @($tcp | Where-Object { $_.LocalPort -in $ports -or $_.RemotePort -in $ports } | Select-Object -First 60 LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess)
}
'@)
    if (-not $script:DiagLastSnapshotOk) {
        $portPattern = ':(' + ($ports -join '|') + ')\s'
        Invoke-NativeSnapshot '备用：配置端口的 TCP/UDP 记录' "$env:SystemRoot\System32\netstat.exe" @('-ano') $portPattern
    }
    Invoke-LocalSnapshot '代理设置与接口注册表 DNS（只读取指定字段）' @'
$envItems = @()
foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($name, $scope)
        if ($null -ne $value) { $envItems += [ordered]@{ name = $name; scope = $scope; value = $value } }
    }
}
$proxySettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$dnsRegistry = @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' | ForEach-Object {
    $item = Get-ItemProperty -LiteralPath $_.PSPath
    [ordered]@{ interfaceId = $_.PSChildName; NameServer = $item.NameServer; DhcpNameServer = $item.DhcpNameServer; DhcpIPAddress = $item.DhcpIPAddress }
})
[ordered]@{
    proxyEnvironment = $envItems
    userProxy = $proxySettings | Select-Object ProxyEnable, ProxyServer, ProxyOverride, AutoConfigURL
    interfaceDnsRegistry = $dnsRegistry
    note = '198.18.x 出现在活动 TUN 接口是正常现象；物理接口上是否异常需结合接口状态判断。'
}
'@
    Invoke-LocalSnapshot '最近 30 分钟网络相关警告/错误（最多 30 条）' @'
$events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = @(2, 3); StartTime = (Get-Date).AddMinutes(-30) } -MaxEvents 300 -ErrorAction SilentlyContinue -ErrorVariable eventErrors)
$unexpected = @($eventErrors | Where-Object { $_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*' })
if ($unexpected.Count) { throw $unexpected[0] }
$relevant = @($events | Where-Object { $_.ProviderName -match '(?i)DNS|DHCP|TCPIP|NDIS|WLAN|Network|Netwtw|Schannel' -or ($_.ProviderName -eq 'Service Control Manager' -and $_.Message -match '(?i)clash|mihomo|wintun') } | Select-Object -First 30 TimeCreated, Id, ProviderName, LevelDisplayName, Message)
[ordered]@{ scanned = $events.Count; relevant = $relevant; note = '无匹配事件不代表没有故障；扫描上限为最近 300 条警告/错误。' }
'@
}

function Write-NetworkProbes {
    Write-DiagSection '联网测试说明'
    Write-DiagLog '以下测试会产生少量网络请求，不修改配置。系统路由/TUN 测试不等于绕过 TUN 的物理直连。'
    Write-DiagLog 'HTTP 3xx/4xx/5xx 均单独记录；不将它们等同于连接失败。TLS 证书校验保持开启。'
    Write-DiagLog 'curl 的 dns/connect/tls/first_byte 是从请求开始累计的时间，并非独立阶段耗时；TUN 下 connect/remote_ip 也可能反映虚拟连接。'
    Write-DiagLog '指定 DNS 服务器仍可能被 TUN 劫持；假 IP 与真实 IP 都需结合模式和过滤规则判断。系统解析也可能命中缓存。'
    Invoke-LocalSnapshot 'ICMP：网关与公网 IP（失败不等于断网，流量仍受路由影响）' @'
$gateways = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.OperationalStatus -eq 'Up' } | ForEach-Object {
    $_.GetIPProperties().GatewayAddresses | ForEach-Object { $_.Address }
} | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -ne '0.0.0.0' -and $_.ToString() -notlike '198.18.*' } | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
$targets = @($gateways | Select-Object -First 2) + @('223.5.5.5')
$ping = New-Object Net.NetworkInformation.Ping
try {
    foreach ($target in $targets) {
        try {
            $reply = $ping.Send($target, 1200)
            [ordered]@{ target = $target; status = [string]$reply.Status; milliseconds = $reply.RoundtripTime }
        } catch { [ordered]@{ target = $target; error = $_.Exception.Message } }
    }
} finally { $ping.Dispose() }
'@ 8
    Invoke-DnsProbe 'DNS：系统解析 baidu.com'
    Invoke-DnsProbe 'DNS：指定 223.5.5.5（可能被劫持）' '223.5.5.5'
    if ($DnsServer) { Invoke-DnsProbe ('DNS：自定义服务器 ' + $DnsServer) $DnsServer }

    foreach ($site in @(@{ Name = '百度'; Url = 'https://www.baidu.com' }, @{ Name = '谷歌'; Url = 'https://www.google.com' })) {
        Invoke-HttpProbe ($site.Name + '：系统路由/TUN') $site.Url
        Invoke-HttpProbe ($site.Name + '：显式代理对照') $site.Url $script:DiagEffectiveProxy
    }
    Invoke-HttpProbe 'IPv4：系统路由/TUN 对照' 'https://www.baidu.com' '' @('-4')
    Invoke-HttpProbe 'IPv6：系统路由对照（本机或站点可能不支持 IPv6）' 'https://www.baidu.com' '' @('-6')
    if ($EntryDomain) {
        Invoke-HttpProbe '入口域名：系统路由/TUN' ('https://' + $EntryDomain)
        if ($EntryIP) {
            $resolveIP = $EntryIP
            if ($EntryIP.Contains(':')) { $resolveIP = '[' + $EntryIP + ']' }
            Write-DiagLog '下项用 --resolve 固定目标 IP，保留域名/SNI；只绕过该请求的常规域名解析，流量仍可能经过 TUN。入口网页可达不等于代理节点协议可用。'
            Invoke-HttpProbe '入口固定 IP：保留域名/SNI' ('https://' + $EntryDomain) '' @('--resolve', ($EntryDomain + ':443:' + $resolveIP))
        }
    }
}

function Start-TunDiagnostics {
    $runExit = 0
    $script:DiagResults.Clear()
    $script:DiagProxySpecified = $script:DiagBoundProxy
    $script:DiagEffectiveProxy = $Proxy
    try {
        $apiUri = $null
        if (-not [uri]::TryCreate($Api, [UriKind]::Absolute, [ref]$apiUri) -or $apiUri.Scheme -notin @('http', 'https') -or -not $apiUri.IsLoopback -or $apiUri.UserInfo -or $apiUri.Query -or $apiUri.Fragment) {
            throw 'Api 必须是本机 HTTP(S) 控制器地址，例如 http://127.0.0.1:9090。'
        }
        if ($Secret -match '[\r\n\x00]') { throw 'Secret 不能包含换行或空字符。' }
        $proxyUri = $null
        if (-not [uri]::TryCreate($Proxy, [UriKind]::Absolute, [ref]$proxyUri) -or $proxyUri.Scheme -notin @('http', 'https', 'socks5', 'socks5h') -or $proxyUri.Port -lt 1) { throw 'Proxy 必须包含协议和有效端口。' }
        $ipValue = $null
        if ($EntryIP -and -not $EntryDomain) { throw '指定 EntryIP 时也必须指定 EntryDomain，以保留域名和 SNI。' }
        if ($EntryIP -and -not [Net.IPAddress]::TryParse($EntryIP, [ref]$ipValue)) { throw 'EntryIP 必须是有效 IP 地址。' }
        if ($DnsServer -and -not [Net.IPAddress]::TryParse($DnsServer, [ref]$ipValue)) { throw 'DnsServer 必须是有效 DNS 服务器 IP 地址。' }
        if ($EntryDomain -and ($EntryDomain -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -or $EntryDomain.Contains('..'))) { throw 'EntryDomain 必须是纯域名，不包含协议、端口或路径。' }
        if ($script:DiagUsesDefaultOutput) { [void][IO.Directory]::CreateDirectory($OutputDirectory) }
        if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw '输出文件夹不存在。' }
        $outputName = 'diag_{0}_{1}_{2}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $outputPath = Join-Path (Get-Item -LiteralPath $OutputDirectory).FullName $outputName
        $stream = New-Object IO.FileStream($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $script:DiagWriter = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($true)))
        Write-Host ('报告保存至: ' + $outputPath)
        Write-DiagSection ('FlClash TUN 诊断 v' + $script:DiagVersion)
        Write-DiagLog ('开始时间: ' + (Get-Date -Format o))
        Write-DiagLog ('Windows={0}; PowerShell={1}; PID={2}' -f [Environment]::OSVersion.Version, $PSVersionTable.PSVersion, $PID)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        Write-DiagLog ('运行用户上下文={0}；HKCU 和用户环境变量属于此用户。' -f $identity.Name)
        Write-DiagLog ('管理员运行={0}；无需自动提权，权限不足的项目将单独记录。' -f $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
        $identity.Dispose()
        Write-DiagLog '本脚本只采集，不修改 DNS、路由、注册表或 FlClash 配置，不启动/停止服务。'
        Write-DiagLog '报告使用 UTF-8 BOM。仅采集代理环境变量并遮盖常见凭据；仍含域名、节点组名、IP、进程及网络事件，公开分享前请检查。'
        $curlCommand = @(Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
        $script:DiagCurl = $null
        if ($curlCommand -and (Test-Path -LiteralPath $curlCommand.Source -PathType Leaf)) { $script:DiagCurl = $curlCommand.Source }
        Write-CoreSnapshots
        Write-WindowsSnapshots
        Write-DiagLog ('本次显式代理对照地址: ' + $script:DiagEffectiveProxy)
        if ($SkipNetworkTests) {
            Write-DiagSection '联网测试已跳过'
            Add-DiagResult '联网测试' 'SKIP' '使用了 -SkipNetworkTests；仍采集本机控制器 API'
        } else { Write-NetworkProbes }
    } catch {
        $runExit = 1
        $message = Protect-DiagText $_.Exception.Message
        if ($script:DiagWriter) { Write-DiagLog ('[FATAL] ' + $message) }
        Write-Host ('采集未完整完成: ' + $message) -ForegroundColor Red
    } finally {
        if ($script:DiagWriter) {
            Write-DiagSection '采集汇总'
            Write-DiagLog 'OK 表示该项采集成功；RESPONSE 表示收到 HTTP 响应；ERROR/TIMEOUT/AUTH 需要结合具体项目解读，不能直接当作 TUN 故障结论。'
            Write-DiagLog ($script:DiagResults | Format-Table Name, Status, Seconds, Detail -Wrap | Out-String -Width 180)
            Write-DiagLog ('结束时间: ' + (Get-Date -Format o))
            $script:DiagWriter.Dispose()
            $script:DiagWriter = $null
            Write-Host ('报告已保存: ' + $outputPath)
        }
        if ($LaunchedFromBatch -and -not $NoPause) { [void](Read-Host '按 Enter 关闭窗口') }
    }
    return $runExit
}

$script:DiagBoundProxy = $PSBoundParameters.ContainsKey('Proxy')
if ($MyInvocation.InvocationName -ne '.') {
    exit (Start-TunDiagnostics)
}

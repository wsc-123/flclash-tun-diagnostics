[CmdletBinding()]
param([switch]$LaunchedFromBatch, [switch]$NoPause)

# Save as UTF-8 with BOM for Windows PowerShell 5.1.
# Dot-source to inspect the pure command-generation helper without querying Windows.
function Get-RouteDeletePlan {
    param([object[]]$Routes = @(), [object[]]$Adapters = @())

    foreach ($route in $Routes) {
        if ($route.DestinationPrefix -ne '198.18.0.0/24') { continue }
        $index = 0
        $validIndex = [int]::TryParse([string]$route.InterfaceIndex, [ref]$index) -and $index -gt 0
        $gateway = $null
        $validGateway = [Net.IPAddress]::TryParse([string]$route.NextHop, [ref]$gateway)
        $physical = @($Adapters | Where-Object {
            $_.ifIndex -eq $index -and $_.HardwareInterface -eq $true -and $_.Virtual -ne $true
        })
        $command = ''
        $reason = ''
        if (-not $validIndex) {
            $reason = '接口编号无效，不生成命令。'
        } elseif (-not $validGateway -or $gateway.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            $reason = '下一跳不是有效的 IPv4 网关，不生成命令。'
        } elseif ($gateway.ToString() -eq '0.0.0.0' -or [Net.IPAddress]::IsLoopback($gateway)) {
            $reason = '这是直连或回环下一跳，不符合本次故障模式。'
        } elseif ($physical.Count -eq 0) {
            $reason = '未确认该接口为物理网卡；TUN 等虚拟网卡路由不生成删除命令。'
        } else {
            # Only validated IPv4 and integer values are included in the command.
            $command = 'route.exe delete 198.18.0.0 mask 255.255.255.0 {0} if {1}' -f $gateway.ToString(), $index
        }
        [pscustomobject]@{
            DestinationPrefix = $route.DestinationPrefix
            NextHop = [string]$route.NextHop
            InterfaceAlias = [string]$route.InterfaceAlias
            InterfaceIndex = $index
            Command = $command
            Note = $reason
        }
    }
}

function Start-RouteDeleteCommandGenerator {
    param([string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'output\commands'))
    $reportPath = Join-Path $OutputDirectory 'route-delete-command.txt'
    $encoding = New-Object Text.UTF8Encoding($true)
    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('FlClash 异常路由删除命令生成结果')
    $lines.Add('生成时间：' + $generatedAt)
    $lines.Add('本工具只查询路由和网卡、生成文本，不执行删除。')
    $lines.Add('')
    try {
        [void][IO.Directory]::CreateDirectory($OutputDirectory)
        # Replace old results before querying, so a failed query cannot leave an old command presented as current.
        [IO.File]::WriteAllText($reportPath, (($lines.ToArray() + '本次查询尚未完成，没有可使用的删除命令。') -join "`r`n"), $encoding)
    } catch {
        Write-Host ('无法更新结果文件：' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '如果存在旧的 route-delete-command.txt，请勿将其当作本次结果。'
        return 1
    }

    $exitCode = 0
    try {
        # Query all active IPv4 routes first: an absent /24 must not be confused with a query error.
        $routes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object { $_.DestinationPrefix -eq '198.18.0.0/24' })
        if ($routes.Count -eq 0) {
            $lines.Add('当前没有 198.18.0.0/24 路由，无需针对它生成删除命令。')
            $lines.Add('如果之后再次断网，保持 TUN 开启，再运行本工具。')
        } else {
            $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
            $plans = @(Get-RouteDeletePlan -Routes $routes -Adapters $adapters)
            $lines.Add('当前匹配的路由：')
            $lines.Add(($plans | Format-Table DestinationPrefix, NextHop, InterfaceAlias, InterfaceIndex -AutoSize | Out-String -Width 200).TrimEnd())
            $lines.Add('')
            $commands = @($plans | Where-Object { $_.Command } | Sort-Object Command -Unique)
            if ($commands.Count) {
                $lines.Add('以下命令对应 /24 经物理网卡网关的路由。确认是本次 TUN 故障后，复制到管理员终端执行：')
                $lines.Add('')
                foreach ($plan in $commands) {
                    $lines.Add(('网卡：{0}；接口编号：{1}；网关：{2}' -f $plan.InterfaceAlias, $plan.InterfaceIndex, $plan.NextHop))
                    $lines.Add($plan.Command)
                    $lines.Add('')
                }
                if ($commands.Count -gt 1) {
                    $lines.Add('发现多个匹配条目，已分别列出；请按实际故障接口核对。')
                }
                $lines.Add('换网络或路由发生变化后请重新生成，旧命令可能已经不适用。')
                $lines.Add('若正在记录路由来源，建议先运行 Stop 保存现场，再执行删除命令。')
            } else {
                $lines.Add('未找到符合本次故障模式的物理网卡网关路由，没有生成删除命令。')
            }
            foreach ($plan in @($plans | Where-Object { -not $_.Command })) {
                $lines.Add(('跳过：{0}，下一跳 {1}，接口 {2}。{3}' -f $plan.DestinationPrefix, $plan.NextHop, $plan.InterfaceAlias, $plan.Note))
            }
        }
    } catch {
        $exitCode = 1
        $lines.Add('查询失败：没有生成删除命令。这不等于异常路由不存在。')
        $lines.Add($_.Exception.Message)
        $lines.Add('如果提示拒绝访问，请右键根目录的“04-生成删除命令.bat”，选择“以管理员身份运行”。')
    }

    $report = $lines.ToArray() -join "`r`n"
    try {
        [IO.File]::WriteAllText($reportPath, $report + "`r`n", $encoding)
    } catch {
        Write-Host ('无法保存最终结果：' + $_.Exception.Message) -ForegroundColor Red
        $exitCode = 1
    }
    Write-Host $report
    Write-Host ''
    Write-Host ('结果文件：' + $reportPath)
    return $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    try { exit (Start-RouteDeleteCommandGenerator) }
    finally { if ($LaunchedFromBatch -and -not $NoPause) { [void](Read-Host '按 Enter 关闭窗口') } }
}

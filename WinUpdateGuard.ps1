# WinUpdateGuard - Windows 更新卫士
# 三档可逆的 Windows 更新管理工具（Windows PowerShell 5.1）
# 设计原则：先快照、再改动、能精确回滚；不伪造暂停日期；不动系统自带计划任务。

[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Apply,
    [ValidateSet('Lite', 'Standard', 'Strict')]
    [string]$Mode,
    [switch]$Restore,
    [switch]$Enforce,
    [switch]$Yes,
    [string]$SnapshotPath,
    [int]$PauseDays = 35,
    [int]$DeferDays = 365,
    [switch]$NoAutoReboot,
    [switch]$NoDriverExclude,
    [switch]$Selftest,
    [switch]$UiTest,
    [string]$UiShot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:AppName = 'Windows 更新卫士'
$script:Version = '1.0.1'
$script:Root = Join-Path $env:ProgramData 'WinUpdateGuard'
$script:SnapDir = Join-Path $script:Root 'snapshots'
$script:LogDir = Join-Path $script:Root 'logs'
$script:Latest = Join-Path $script:SnapDir 'latest.ini'
$script:TaskName = 'WinUpdateGuard Keep'
$script:FwPrefix = 'WinUpdateGuard Block '
$script:SvcNames = @('wuauserv', 'UsoSvc')
$script:SelfPath = $MyInvocation.MyCommand.Path
$script:LogSink = $null
$script:Interactive = $true
if ($Status -or $Apply -or $Restore -or $Enforce -or $Selftest -or $UiTest -or $Yes -or $Mode -or $SnapshotPath -or $UiShot) { $script:Interactive = $false }

$script:KAu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:KWu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:KUX = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

# ---------------------------------------------------------------- 受管项目录
$script:ManagedReg = @(
    @{ Group = 'AU'; Path = $script:KAu; Name = 'NoAutoUpdate' }
    @{ Group = 'AU'; Path = $script:KAu; Name = 'NoAutoRebootWithLoggedOnUsers' }
    @{ Group = 'WU'; Path = $script:KWu; Name = 'ExcludeWUDriversInQualityUpdate' }
    @{ Group = 'WU'; Path = $script:KWu; Name = 'DeferFeatureUpdates' }
    @{ Group = 'WU'; Path = $script:KWu; Name = 'DeferFeatureUpdatesPeriodInDays' }
    @{ Group = 'UX'; Path = $script:KUX; Name = 'PauseFeatureUpdatesStartTime' }
    @{ Group = 'UX'; Path = $script:KUX; Name = 'PauseFeatureUpdatesEndTime' }
    @{ Group = 'UX'; Path = $script:KUX; Name = 'PauseQualityUpdatesStartTime' }
    @{ Group = 'UX'; Path = $script:KUX; Name = 'PauseQualityUpdatesEndTime' }
    @{ Group = 'UX'; Path = $script:KUX; Name = 'PauseUpdatesStartTime' }
    @{ Group = 'UX'; Path = $script:KUX; Name = 'PauseUpdatesExpiryTime' }
)

$script:SvcDefault = @{
    'wuauserv' = @{ Start = 3; Delayed = $false }
    'UsoSvc'   = @{ Start = 2; Delayed = $true }
}

# ---------------------------------------------------------------- 基础工具
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($script:LogSink) { & $script:LogSink $line }
    elseif (-not $script:Interactive) { Write-Host $line }
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $file = Join-Path $script:LogDir ('guard-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        Add-Content -LiteralPath $file -Value $line -Encoding UTF8
    }
    catch { }
}

function Invoke-Exe {
    param([string]$File, [string]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; return @{ Code = -1; Out = $out; Err = 'timeout' } }
        return @{ Code = $p.ExitCode; Out = $out; Err = $err }
    }
    catch {
        return @{ Code = -2; Out = ''; Err = $_.Exception.Message }
    }
}

function Ensure-Dirs {
    foreach ($d in @($script:Root, $script:SnapDir, $script:LogDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

# ---------------------------------------------------------------- 注册表
function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($null -eq $k) { return $null }
        return $k.GetValue($Name, $null)
    }
    catch { return $null }
}

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    $kind = switch ($Type) {
        'DWord' { [Microsoft.Win32.RegistryValueKind]::DWord }
        'QWord' { [Microsoft.Win32.RegistryValueKind]::QWord }
        default { [Microsoft.Win32.RegistryValueKind]::String }
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $kind -Force | Out-Null
}

function Remove-RegValue {
    param([string]$Path, [string]$Name)
    try {
        if (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
        }
    }
    catch { }
}

function Get-RegState {
    param([hashtable]$Item)
    $state = [pscustomobject]@{
        Group  = $Item.Group
        Path   = $Item.Path
        Name   = $Item.Name
        Exists = $false
        Kind   = 'MISSING'
        Value  = ''
    }
    try {
        $k = Get-Item -LiteralPath $Item.Path -ErrorAction Stop
        if ($null -ne $k -and ($k.GetValueNames() -contains $Item.Name)) {
            $state.Exists = $true
            $state.Kind = $k.GetValueKind($Item.Name).ToString()
            $v = $k.GetValue($Item.Name, $null)
            if ($null -ne $v) { $state.Value = [string]$v }
        }
    }
    catch { }
    return $state
}

function Restore-RegState {
    param($State)
    if ($State.Exists) {
        $t = 'String'
        if ($State.Kind -eq 'DWord') { $t = 'DWord' }
        elseif ($State.Kind -eq 'QWord') { $t = 'QWord' }
        $v = $State.Value
        if ($t -ne 'String') {
            $n = 0
            if ([int]::TryParse([string]$State.Value, [ref]$n)) { $v = $n }
        }
        Set-RegValue -Path $State.Path -Name $State.Name -Value $v -Type $t
    }
    else {
        Remove-RegValue -Path $State.Path -Name $State.Name
    }
}

# ---------------------------------------------------------------- 服务
function Get-SvcState {
    param([string]$Name, [switch]$WithStatus)
    $start = -1
    $delayed = $false
    try {
        $k = Get-Item -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\$Name") -ErrorAction Stop
        if ($null -ne $k) {
            $s = $k.GetValue('Start', $null)
            if ($null -ne $s) { $start = [int]$s }
            $d = $k.GetValue('DelayedAutostart', $null)
            if ($null -ne $d -and [int]$d -eq 1) { $delayed = $true }
        }
    }
    catch { }
    $result = [pscustomobject]@{
        Name    = $Name
        Start   = $start
        Delayed = $delayed
        Status  = 'Unknown'
    }
    if ($WithStatus) {
        try {
            $svc = Get-Service -Name $Name -ErrorAction Stop
            $result.Status = [string]$svc.Status
        }
        catch { $result.Status = 'NotFound' }
    }
    return $result
}

function Get-StartText {
    param([int]$Start, [bool]$Delayed)
    switch ($Start) {
        0 { return '引导启动' }
        1 { return '系统启动' }
        2 { if ($Delayed) { return '自动(延迟)' } else { return '自动' } }
        3 { return '手动' }
        4 { return '已禁用' }
        default { return '未知' }
    }
}

function Set-SvcStart {
    param([string]$Name, [int]$Start, [bool]$Delayed = $false)
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    switch ($Start) {
        4 { $r = Invoke-Exe $sc ("config {0} start= disabled" -f $Name) }
        3 { $r = Invoke-Exe $sc ("config {0} start= demand" -f $Name) }
        2 {
            if ($Delayed) { $r = Invoke-Exe $sc ("config {0} start= delayed-auto" -f $Name) }
            else { $r = Invoke-Exe $sc ("config {0} start= auto" -f $Name) }
        }
        default { $r = Invoke-Exe $sc ("config {0} start= demand" -f $Name) }
    }
    return ($r.Code -eq 0)
}

function Stop-UpdSvc {
    param([string]$Name)
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            (Get-Service -Name $Name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(8))
        }
        return $true
    }
    catch { return $false }
}

# ---------------------------------------------------------------- 防火墙
function Test-FwRule {
    param([string]$Svc)
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $name = $script:FwPrefix + $Svc
    $r = Invoke-Exe $netsh ('advfirewall firewall show rule name="{0}"' -f $name)
    return ($r.Code -eq 0)
}

function Get-FwCount {
    $n = 0
    foreach ($s in $script:SvcNames) { if (Test-FwRule $s) { $n++ } }
    return $n
}

function Add-FwBlock {
    param([string]$Svc)
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $name = $script:FwPrefix + $Svc
    if (Test-FwRule $Svc) { Remove-FwRule $Svc }
    $args = 'advfirewall firewall add rule name="{0}" dir=out action=block service={1} enable=yes profile=any description="WinUpdateGuard: block outbound for {1}"' -f $name, $Svc
    $r = Invoke-Exe $netsh $args
    return ($r.Code -eq 0)
}

function Remove-FwRule {
    param([string]$Svc)
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $name = $script:FwPrefix + $Svc
    $r = Invoke-Exe $netsh ('advfirewall firewall delete rule name="{0}" dir=out' -f $name)
    return ($r.Code -eq 0)
}

function Remove-AllFw {
    foreach ($s in $script:SvcNames) { Remove-FwRule $s | Out-Null }
}

# ---------------------------------------------------------------- 计划任务
function Test-GuardTask {
    try {
        $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        return ($null -ne $t)
    }
    catch { return $false }
}

function Sync-GuardScript {
    # 始终用当前脚本覆盖 ProgramData 下的副本，保证版本升级后看护任务跑的是新版
    $dst = Join-Path $script:Root 'WinUpdateGuard.ps1'
    try {
        $src = [System.IO.Path]::GetFullPath($script:SelfPath)
        $full = [System.IO.Path]::GetFullPath($dst)
        if ($src -ne $full -and (Test-Path -LiteralPath $src)) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        return $true
    }
    catch {
        Write-Log ('更新看护脚本副本失败: ' + $_.Exception.Message) 'WARN'
        return $false
    }
}

function New-GuardTask {
    $dst = Join-Path $script:Root 'WinUpdateGuard.ps1'
    Sync-GuardScript | Out-Null
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Enforce' -f $dst
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 30))
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    return (Test-GuardTask)
}

function Remove-GuardTask {
    try {
        if (Test-GuardTask) {
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop
        }
        return $true
    }
    catch { return $false }
}

function Protect-RootDir {
    try {
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        Invoke-Exe $icacls ('"{0}" /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F"' -f $script:Root) | Out-Null
    }
    catch { }
}

# ---------------------------------------------------------------- 快照
function New-BaselineSnapshot {
    param([string]$ModeName)
    Ensure-Dirs
    $reg = @()
    foreach ($item in $script:ManagedReg) { $reg += (Get-RegState $item) }
    $svc = @()
    foreach ($s in $script:SvcNames) {
        $st = Get-SvcState $s -WithStatus
        $svc += [pscustomobject]@{ Name = $st.Name; Start = $st.Start; Delayed = $st.Delayed; Status = $st.Status }
    }
    $snap = [pscustomobject]@{
        Created     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Mode        = $ModeName
        Os          = (Get-CimInstance Win32_OperatingSystem).Caption
        TaskExisted = (Test-GuardTask)
        Reg         = $reg
        Svc         = $svc
        Path        = ''
    }
    $name = 'snapshot-{0}.ini' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $file = Join-Path $script:SnapDir $name
    Save-Snapshot $snap $file
    Copy-Item -LiteralPath $file -Destination $script:Latest -Force
    $snap.Path = $file
    return $snap
}

function Save-Snapshot {
    param($Snap, [string]$File)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# WinUpdateGuard snapshot v1 (UTF-8)')
    [void]$sb.AppendLine('[meta]')
    [void]$sb.AppendLine('created=' + $Snap.Created)
    [void]$sb.AppendLine('mode=' + $Snap.Mode)
    [void]$sb.AppendLine('os=' + $Snap.Os)
    [void]$sb.AppendLine('taskexisted=' + [int][bool]$Snap.TaskExisted)
    [void]$sb.AppendLine('[reg]')
    foreach ($r in $Snap.Reg) {
        $kind = $r.Kind
        if (-not $r.Exists) { $kind = 'MISSING' }
        [void]$sb.AppendLine(('{0}|{1}|{2}|{3}' -f $r.Group, $r.Name, $kind, $r.Value))
    }
    [void]$sb.AppendLine('[svc]')
    foreach ($s in $Snap.Svc) {
        [void]$sb.AppendLine(('{0}|{1}|{2}|{3}' -f $s.Name, $s.Start, [int][bool]$s.Delayed, $s.Status))
    }
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($File, $sb.ToString(), $utf8)
}

function Load-Snapshot {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $lines = Get-Content -LiteralPath $File -Encoding UTF8
    $snap = [pscustomobject]@{
        Created     = ''
        Mode        = ''
        Os          = ''
        TaskExisted = $false
        Reg         = @()
        Svc         = @()
        Path        = $File
    }
    $section = ''
    $reg = New-Object System.Collections.ArrayList
    $svc = New-Object System.Collections.ArrayList
    $pathMap = @{ AU = $script:KAu; WU = $script:KWu; UX = $script:KUX }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1].ToLower(); continue }
        if ($section -eq 'meta') {
            $kv = $line -split '=', 2
            if ($kv.Count -lt 2) { continue }
            switch ($kv[0]) {
                'created' { $snap.Created = $kv[1] }
                'mode' { $snap.Mode = $kv[1] }
                'os' { $snap.Os = $kv[1] }
                'taskexisted' { $snap.TaskExisted = ($kv[1] -eq '1') }
            }
            continue
        }
        if ($section -eq 'reg') {
            $p = $line -split '\|', 4
            if ($p.Count -lt 4) { continue }
            $grp = $p[0]
            if (-not $pathMap.ContainsKey($grp)) { continue }
            $exists = ($p[2] -ne 'MISSING')
            [void]$reg.Add([pscustomobject]@{
                    Group  = $grp
                    Path   = $pathMap[$grp]
                    Name   = $p[1]
                    Exists = $exists
                    Kind   = $p[2]
                    Value  = $p[3]
                })
            continue
        }
        if ($section -eq 'svc') {
            $p = $line -split '\|', 4
            if ($p.Count -lt 4) { continue }
            [void]$svc.Add([pscustomobject]@{
                    Name    = $p[0]
                    Start   = [int]$p[1]
                    Delayed = ($p[2] -eq '1')
                    Status  = $p[3]
                })
        }
    }
    $snap.Reg = $reg.ToArray()
    $snap.Svc = $svc.ToArray()
    return $snap
}

function Get-LatestSnapshot {
    if (Test-Path -LiteralPath $script:Latest) { return (Load-Snapshot $script:Latest) }
    $files = @()
    if (Test-Path -LiteralPath $script:SnapDir) {
        $files = Get-ChildItem -LiteralPath $script:SnapDir -Filter 'snapshot-*.ini' | Sort-Object LastWriteTime -Descending
    }
    if ($files.Count -gt 0) { return (Load-Snapshot $files[0].FullName) }
    return $null
}

# ---------------------------------------------------------------- 应用 / 恢复
function Invoke-ApplyMode {
    param(
        [ValidateSet('Lite', 'Standard', 'Strict')][string]$ModeName,
        [bool]$BlockAutoReboot = $true,
        [bool]$ExcludeDrivers = $true,
        [bool]$DeferFeature = $true,
        [int]$Pause = 35,
        [int]$Defer = 365,
        [switch]$Silent
    )
    if (-not (Test-Admin)) { throw '需要管理员权限' }
    Ensure-Dirs
    $applyMode = $ModeName

    $snap = Get-LatestSnapshot
    if ($null -ne $snap -and $snap.Mode -eq 'Selftest') { $snap = $null }
    if ($null -eq $snap) {
        $snap = New-BaselineSnapshot -ModeName $applyMode
        Write-Log ('已创建原状快照: {0}' -f $snap.Path) 'SNAP'
    }
    else {
        Write-Log ('沿用已有原状快照: {0} (创建于 {1})' -f $snap.Path, $snap.Created) 'SNAP'
    }

    # 1) 暂停更新（官方机制，设置页可见）
    $now = (Get-Date).ToUniversalTime()
    $startStr = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $endStr = $now.AddDays($Pause).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Set-RegValue $script:KUX 'PauseFeatureUpdatesStartTime' $startStr 'String'
    Set-RegValue $script:KUX 'PauseFeatureUpdatesEndTime' $endStr 'String'
    Set-RegValue $script:KUX 'PauseQualityUpdatesStartTime' $startStr 'String'
    Set-RegValue $script:KUX 'PauseQualityUpdatesEndTime' $endStr 'String'
    Set-RegValue $script:KUX 'PauseUpdatesStartTime' $startStr 'String'
    Set-RegValue $script:KUX 'PauseUpdatesExpiryTime' $endStr 'String'
    Write-Log ('已设置暂停更新 {0} 天，至 {1}' -f $Pause, $endStr)

    # 2) 附加选项
    if ($BlockAutoReboot) {
        Set-RegValue $script:KAu 'NoAutoRebootWithLoggedOnUsers' 1
        Write-Log '已设置：登录状态下不自动重启'
    }
    if ($ExcludeDrivers) {
        Set-RegValue $script:KWu 'ExcludeWUDriversInQualityUpdate' 1
        Write-Log '已设置：不通过 Windows 更新安装驱动'
    }

    # 3) 标准及以上：停止自动检查
    if ($applyMode -ne 'Lite') {
        Set-RegValue $script:KAu 'NoAutoUpdate' 1
        Write-Log '已设置：停止自动检查更新 (NoAutoUpdate=1)'
        if ($DeferFeature) {
            Set-RegValue $script:KWu 'DeferFeatureUpdates' 1
            Set-RegValue $script:KWu 'DeferFeatureUpdatesPeriodInDays' $Defer
            Write-Log ('已设置：功能更新延迟 {0} 天' -f $Defer)
        }
    }

    # 4) 彻底：服务 + 防火墙 + 看护任务
    if ($applyMode -eq 'Strict') {
        foreach ($s in $script:SvcNames) {
            if ((Get-SvcState $s).Start -eq 4) {
                $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
                if ($null -ne $svc -and $svc.Status -ne 'Stopped') { Stop-UpdSvc $s | Out-Null }
                Write-Log ('服务 {0} 已处于禁用状态' -f $s)
            }
            elseif (Set-SvcStart $s 4) {
                Stop-UpdSvc $s | Out-Null
                Write-Log ('服务 {0} 已设为禁用并尝试停止' -f $s)
            }
            else { Write-Log ('服务 {0} 启动类型修改失败（可能被安全软件拦截）' -f $s) 'WARN' }
        }
        foreach ($s in $script:SvcNames) {
            if (Test-FwRule $s) { Write-Log ('出站阻断规则已存在: ' + $s) }
            elseif (Add-FwBlock $s) { Write-Log ('已添加出站阻断规则: ' + $s) }
            else { Write-Log ('防火墙规则添加失败: ' + $s) 'WARN' }
        }
        Protect-RootDir
        if (Test-GuardTask) {
            Sync-GuardScript | Out-Null
            Write-Log '看护任务已存在，跳过重建（避免重置触发器）'
        }
        else {
            $ok = New-GuardTask
            if ($ok) { Write-Log '已注册 SYSTEM 看护任务（开机/登录/每 30 分钟）' }
            else { Write-Log '看护任务注册失败，其余设置已生效' 'WARN' }
        }
    }
    else {
        # 降级应用：如果之前是 Strict，清掉服务和防火墙层
        $hasTask = Test-GuardTask
        $fw = Get-FwCount
        if ($hasTask -or $fw -gt 0) {
            Remove-GuardTask | Out-Null
            Remove-AllFw
            Write-Log '已移除看护任务与防火墙规则（切换到较低档位）'
        }
        if ($applyMode -eq 'Standard') {
            foreach ($s in $script:SvcNames) {
                if ((Get-SvcState $s).Start -eq 4) {
                    $d = $script:SvcDefault[$s]
                    if (Set-SvcStart $s $d.Start $d.Delayed) {
                        Write-Log ('服务 {0} 已恢复为 {1}' -f $s, (Get-StartText $d.Start $d.Delayed))
                    }
                    else { Write-Log ('服务 {0} 恢复失败，请在 services.msc 手动改为 {1}' -f $s, (Get-StartText $d.Start $d.Delayed)) 'WARN' }
                }
            }
        }
    }
    # 档位变化时同步到快照，保证 -Enforce 用最新档位自愈
    if ($snap.Mode -ne $applyMode) {
        $snap.Mode = $applyMode
        Save-Snapshot $snap $snap.Path
        if ((Split-Path -Leaf $snap.Path) -ne 'latest.ini') {
            Copy-Item -LiteralPath $snap.Path -Destination $script:Latest -Force
        }
        Write-Log ('快照档位已更新为 ' + $applyMode) 'SNAP'
    }
    return $snap
}

function Invoke-RestoreAll {
    param([string]$File, [switch]$Silent)
    if (-not (Test-Admin)) { throw '需要管理员权限' }
    $snap = $null
    if ($File) { $snap = Load-Snapshot $File } else { $snap = Get-LatestSnapshot }

    Remove-GuardTask | Out-Null
    Write-Log '已删除看护任务（若存在）'
    Remove-AllFw
    Write-Log '已删除本工具的防火墙规则'

    if ($null -eq $snap) {
        Write-Log '未找到快照，按 Windows 默认值恢复' 'WARN'
        foreach ($item in $script:ManagedReg) { Remove-RegValue $item.Path $item.Name }
        foreach ($s in $script:SvcNames) {
            $d = $script:SvcDefault[$s]
            if (Set-SvcStart $s $d.Start $d.Delayed) {
                Write-Log ('服务 {0} 恢复为 {1}' -f $s, (Get-StartText $d.Start $d.Delayed))
            }
            else { Write-Log ('服务 {0} 恢复失败，请在 services.msc 手动改为 {1}' -f $s, (Get-StartText $d.Start $d.Delayed)) 'WARN' }
        }
        Write-Log '已清除策略值，服务恢复为系统默认启动类型'
    }
    else {
        Write-Log ('按快照恢复: {0} (创建于 {1})' -f $snap.Path, $snap.Created)
        foreach ($r in $snap.Reg) { Restore-RegState $r }
        Write-Log ('已还原 {0} 个注册表项' -f $snap.Reg.Count)
        foreach ($s in $snap.Svc) {
            if ($s.Start -ge 0) {
                if (Set-SvcStart $s.Name $s.Start $s.Delayed) {
                    Write-Log ('服务 {0} 恢复为 {1}' -f $s.Name, (Get-StartText $s.Start $s.Delayed))
                }
                else { Write-Log ('服务 {0} 恢复失败，请在 services.msc 手动改为 {1}' -f $s.Name, (Get-StartText $s.Start $s.Delayed)) 'WARN' }
            }
        }
    }

    # 把更新服务拉起来
    try {
        $w = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
        if ($null -ne $w -and $w.StartType -ne 'Disabled') { Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue }
    }
    catch { }
    Write-Log '恢复完成'
}

# ---------------------------------------------------------------- 状态检查
function New-Check {
    param([string]$Name, [string]$Detail, [bool]$Ok, [bool]$Warn = $false)
    return [pscustomobject]@{ Name = $Name; Detail = $Detail; Ok = $Ok; Warn = $Warn }
}

function Test-PendingReboot {
    $a = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $b = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    return ($a -or $b)
}

function Get-GuardChecks {
    $out = New-Object System.Collections.ArrayList

    $w = Get-SvcState 'wuauserv' -WithStatus
    $u = Get-SvcState 'UsoSvc' -WithStatus

    [void]$out.Add((New-Check '更新服务 wuauserv' ('{0} / {1}' -f $w.Status, (Get-StartText $w.Start $w.Delayed)) ($w.Start -eq 4) ($w.Start -eq 3)))
    [void]$out.Add((New-Check '更新协调服务 UsoSvc' ('{0} / {1}' -f $u.Status, (Get-StartText $u.Start $u.Delayed)) ($u.Start -eq 4) ($u.Start -eq 2)))

    $nau = Get-RegValue $script:KAu 'NoAutoUpdate'
    [void]$out.Add((New-Check '策略 NoAutoUpdate' ($(if ($null -eq $nau) { '未设置' } else { '= ' + $nau })) ($nau -eq 1) ($null -eq $nau)))

    $exp = Get-RegValue $script:KUX 'PauseUpdatesExpiryTime'
    $expOk = $false
    $expText = '未暂停'
    if ($exp) {
        $expText = [string]$exp + ' (UTC)'
        try { $expOk = ([datetime]::Parse($exp) -gt [datetime]::UtcNow) } catch { }
    }
    [void]$out.Add((New-Check '暂停更新到期时间' $expText $expOk ($null -eq $exp)))

    $def = Get-RegValue $script:KWu 'DeferFeatureUpdatesPeriodInDays'
    [void]$out.Add((New-Check '功能更新延迟' ($(if ($null -eq $def) { '未设置' } else { '' + $def + ' 天' })) ($null -ne $def) ($null -eq $def)))

    $reb = Get-RegValue $script:KAu 'NoAutoRebootWithLoggedOnUsers'
    [void]$out.Add((New-Check '登录时不自动重启' ($(if ($null -eq $reb) { '未设置' } else { '= ' + $reb })) ($reb -eq 1) ($null -eq $reb)))

    $drv = Get-RegValue $script:KWu 'ExcludeWUDriversInQualityUpdate'
    [void]$out.Add((New-Check '不通过更新装驱动' ($(if ($null -eq $drv) { '未设置' } else { '= ' + $drv })) ($drv -eq 1) ($null -eq $drv)))

    $fw = Get-FwCount
    [void]$out.Add((New-Check '出站阻断规则' ('{0} / 2 条' -f $fw) ($fw -ge 2) ($fw -eq 0)))

    $task = Test-GuardTask
    [void]$out.Add((New-Check 'SYSTEM 看护任务' ($(if ($task) { '已注册' } else { '未注册' })) $task (-not $task)))

    $snap = Get-LatestSnapshot
    $snapText = '无'
    if ($null -ne $snap) { $snapText = ('{0} · {1}' -f $snap.Created, $snap.Mode) }
    [void]$out.Add((New-Check '原状快照' $snapText ($null -ne $snap) ($null -eq $snap)))

    $pending = Test-PendingReboot
    [void]$out.Add((New-Check '系统待重启安装' ($(if ($pending) { '有（禁用不会撤销已排队更新）' } else { '无' })) (-not $pending) $pending))

    return $out.ToArray()
}

function Get-GuardState {
    $w = Get-SvcState 'wuauserv'
    $u = Get-SvcState 'UsoSvc'
    $nau = Get-RegValue $script:KAu 'NoAutoUpdate'
    $fw = Get-FwCount
    $task = Test-GuardTask
    $exp = Get-RegValue $script:KUX 'PauseUpdatesExpiryTime'

    if ($w.Start -eq 4 -and $u.Start -eq 4 -and $task -and $fw -ge 2) {
        return [pscustomobject]@{ Level = 'Strict'; Text = '已彻底禁用（服务+网络+看护任务）'; Color = 'Green' }
    }
    if ($nau -eq 1 -or $w.Start -eq 4) {
        return [pscustomobject]@{ Level = 'Standard'; Text = '已停止自动检查更新'; Color = 'Green' }
    }
    if ($exp) {
        $until = ''
        try { $until = ([datetime]::Parse($exp)).ToLocalTime().ToString('yyyy-MM-dd') } catch { $until = [string]$exp }
        return [pscustomobject]@{ Level = 'Lite'; Text = ('已暂停更新至 ' + $until); Color = 'Blue' }
    }
    return [pscustomobject]@{ Level = 'None'; Text = '未启用（系统将按默认策略自动更新）'; Color = 'Orange' }
}

# ---------------------------------------------------------------- 命令行入口
function Show-ConsoleStatus {
    $st = Get-GuardState
    Write-Host ''
    Write-Host ('  {0} v{1}' -f $script:AppName, $script:Version) -ForegroundColor Cyan
    Write-Host ('  当前状态: {0}' -f $st.Text) -ForegroundColor Yellow
    Write-Host ''
    foreach ($c in (Get-GuardChecks)) {
        $mark = '[x]'
        $color = 'Red'
        if ($c.Ok) { $mark = '[v]'; $color = 'Green' }
        elseif ($c.Warn) { $mark = '[-]'; $color = 'DarkYellow' }
        Write-Host ('  {0} {1,-24} {2}' -f $mark, $c.Name, $c.Detail) -ForegroundColor $color
    }
    Write-Host ''
    $snap = Get-LatestSnapshot
    if ($null -ne $snap) { Write-Host ('  快照: ' + $snap.Path) -ForegroundColor DarkGray }
    Write-Host ''
}

function Invoke-Selftest {
    Write-Host '=== 自检 ==='
    Write-Host ('管理员: ' + (Test-Admin))
    Write-Host ('脚本路径: ' + $script:SelfPath)
    Write-Host ('程序目录: ' + $script:Root)
    Write-Host ('PS 版本: ' + $PSVersionTable.PSVersion)
    $snap = New-BaselineSnapshot -ModeName 'Selftest'
    Write-Host ('快照已写入: ' + $snap.Path)
    $back = Load-Snapshot $snap.Path
    Write-Host ('回读注册表项: ' + $back.Reg.Count + ' / 服务: ' + $back.Svc.Count)
    $diff = 0
    for ($i = 0; $i -lt $snap.Reg.Count; $i++) {
        if ($snap.Reg[$i].Name -ne $back.Reg[$i].Name) { $diff++ }
        if ($snap.Reg[$i].Kind -ne $back.Reg[$i].Kind) { $diff++ }
    }
    Write-Host ('快照一致性差异: ' + $diff)
    Write-Host ('状态判断: ' + (Get-GuardState).Text)
    Write-Host ('检查项数量: ' + (Get-GuardChecks).Count)
    Write-Host '=== 自检结束 ==='
}

# ---------------------------------------------------------------- 主流程
if ($Selftest) { Invoke-Selftest; return }

if ($Status) { Show-ConsoleStatus; return }

if ($Apply) {
    if (-not $Mode) { $Mode = 'Standard' }
    if (-not $Yes -and $script:Interactive -eq $false -and -not $PSBoundParameters.ContainsKey('Yes')) {
        Write-Host '应用设置需要加 -Yes 确认，例如: -Apply -Mode Strict -Yes' -ForegroundColor Yellow
        return
    }
    $snap = Invoke-ApplyMode -ModeName $Mode -BlockAutoReboot (-not $NoAutoReboot) -ExcludeDrivers (-not $NoDriverExclude) -Pause $PauseDays -Defer $DeferDays
    Write-Host ''
    Write-Host ('已按 {0} 档应用' -f $Mode) -ForegroundColor Green
    Show-ConsoleStatus
    return
}

if ($Restore) {
    if (-not $Yes) {
        Write-Host '恢复需要加 -Yes 确认，例如: -Restore -Yes' -ForegroundColor Yellow
        return
    }
    Invoke-RestoreAll -File $SnapshotPath
    Write-Host ''
    Write-Host '已恢复' -ForegroundColor Green
    Show-ConsoleStatus
    return
}

if ($Enforce) {
    $snap = Get-LatestSnapshot
    if ($null -eq $snap) { return }
    $m = $snap.Mode
    if ($m -notin @('Lite', 'Standard', 'Strict')) { return }
    Invoke-ApplyMode -ModeName $m -BlockAutoReboot $true -ExcludeDrivers $true -DeferFeature $true -Pause $PauseDays -Defer $DeferDays | Out-Null
    return
}

# ---------------------------------------------------------------- 图形界面
function Set-UiBusy {
    param([bool]$Busy)
    $ui = $script:Ui
    if ($null -eq $ui) { return }
    foreach ($b in @($ui.BtnApply, $ui.BtnRestore, $ui.BtnRefresh, $ui.BtnSnap, $ui.BtnDiag)) {
        if ($null -ne $b) { $b.Enabled = -not $Busy }
    }
    $ui.Form.UseWaitCursor = $Busy
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-UiOption {
    $ui = $script:Ui
    $mode = 'Standard'
    if ($ui.RbLite.Checked) { $mode = 'Lite' }
    elseif ($ui.RbStrict.Checked) { $mode = 'Strict' }
    return @{
        Mode         = $mode
        Pause        = [int]$ui.NumPause.Value
        Defer        = [int]$ui.NumDefer.Value
        Reboot       = [bool]$ui.CbReboot.Checked
        Drivers      = [bool]$ui.CbDrv.Checked
        DeferFeature = [bool]$ui.CbDefer.Checked
    }
}

function Update-UiState {
    $ui = $script:Ui
    if ($null -eq $ui) { return }
    $st = Get-GuardState
    $ui.Badge.Text = '●  ' + $st.Text
    switch ($st.Color) {
        'Green' { $ui.Badge.ForeColor = [System.Drawing.Color]::FromArgb(13, 118, 68) }
        'Blue' { $ui.Badge.ForeColor = [System.Drawing.Color]::FromArgb(28, 100, 220) }
        default { $ui.Badge.ForeColor = [System.Drawing.Color]::FromArgb(196, 108, 8) }
    }
    $ui.List.BeginUpdate()
    try {
        $ui.List.Items.Clear()
        foreach ($c in (Get-GuardChecks)) {
            $it = New-Object System.Windows.Forms.ListViewItem($c.Name)
            [void]$it.SubItems.Add($c.Detail)
            if ($c.Ok) { $it.ForeColor = [System.Drawing.Color]::FromArgb(13, 118, 68) }
            elseif ($c.Warn) { $it.ForeColor = [System.Drawing.Color]::FromArgb(150, 100, 10) }
            else { $it.ForeColor = [System.Drawing.Color]::FromArgb(186, 42, 42) }
            [void]$ui.List.Items.Add($it)
        }
    }
    finally { $ui.List.EndUpdate() }
}

function Invoke-UiApply {
    $opt = Get-UiOption
    $tips = @{
        Lite     = "温和模式会暂停更新 $($opt.Pause) 天，并阻止自动重启 / 驱动更新。`r`n不改服务、不阻断网络，随时可在系统设置里恢复。`r`n`r`n继续？"
        Standard = "标准模式会在温和模式基础上停止自动检查更新（写入策略）。`r`n手动点「检查更新」仍可用。`r`n`r`n继续？"
        Strict   = "彻底模式会禁用更新服务、添加出站阻断规则、注册 SYSTEM 看护任务。`r`n改动前会自动保存原状快照，可一键恢复。`r`n`r`n继续？"
    }
    $r = [System.Windows.Forms.MessageBox]::Show($tips[$opt.Mode], '确认应用', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Set-UiBusy $true
    try {
        $snap = Invoke-ApplyMode -ModeName $opt.Mode -BlockAutoReboot $opt.Reboot -ExcludeDrivers $opt.Drivers -DeferFeature $opt.DeferFeature -Pause $opt.Pause -Defer $opt.Defer
        Update-UiState
        [System.Windows.Forms.MessageBox]::Show(("已按【{0}】档应用。`r`n`r`n原状快照：`r`n{1}`r`n`r`n如需撤销，点「完全恢复」。" -f $opt.Mode, $snap.Path), '完成', 'OK', 'Information') | Out-Null
    }
    catch {
        Write-Log ('应用失败: ' + $_.Exception.Message) 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '操作失败', 'OK', 'Error') | Out-Null
    }
    finally { Set-UiBusy $false }
}

function Invoke-UiRestore {
    $snap = Get-LatestSnapshot
    $msg = '将删除本工具创建的看护任务与防火墙规则，并按快照还原注册表与服务启动类型。'
    if ($null -ne $snap) {
        $msg += "`r`n`r`n将使用快照：`r`n$($snap.Path)`r`n创建于 $($snap.Created)（$($snap.Mode) 档）"
    }
    else {
        $msg += "`r`n`r`n未找到快照，将按 Windows 默认值恢复（策略值清空、服务回默认）。"
    }
    $msg += "`r`n`r`n继续？"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '确认恢复', 'YesNo', 'Warning') -ne 'Yes') { return }
    Set-UiBusy $true
    try {
        Invoke-RestoreAll
        Update-UiState
        [System.Windows.Forms.MessageBox]::Show('已恢复。建议到「设置 - Windows 更新」确认一次服务状态。', '完成', 'OK', 'Information') | Out-Null
    }
    catch {
        Write-Log ('恢复失败: ' + $_.Exception.Message) 'ERROR'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    }
    finally { Set-UiBusy $false }
}

function Invoke-UiNewBaseline {
    $old = Get-LatestSnapshot
    $msg = '把当前系统状态记为新的原状快照（用于重新开始）。'
    if ($null -ne $old) {
        $msg += "`r`n`r`n现有快照：$($old.Created)（$($old.Mode) 档）`r`n新快照不会自动删除旧文件，但「完全恢复」将改用新快照。"
        $msg += "`r`n`r`n如果当前系统仍处于被本工具修改过的状态，新快照会把「已被修改」当成原始状态，回滚就回不到最初了。"
    }
    $msg += "`r`n`r`n确认重建基线？"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '重建基线快照', 'YesNo', 'Warning') -ne 'Yes') { return }
    try {
        $snap = New-BaselineSnapshot -ModeName 'Manual'
        Write-Log ('已重建基线快照: ' + $snap.Path) 'SNAP'
        [System.Windows.Forms.MessageBox]::Show(('新基线已保存：' + $snap.Path), '完成', 'OK', 'Information') | Out-Null
        Update-UiState
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '失败', 'OK', 'Error') | Out-Null
    }
}

function Invoke-UiDiag {
    try {
        $desk = [Environment]::GetFolderPath('Desktop')
        $file = Join-Path $desk ('WinUpdateGuard-诊断-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine(('{0} v{1} 诊断报告' -f $script:AppName, $script:Version))
        [void]$sb.AppendLine(('生成时间: {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
        [void]$sb.AppendLine(('系统: {0} {1} (Build {2})' -f (Get-CimInstance Win32_OperatingSystem).Caption, $env:PROCESSOR_ARCHITECTURE, [Environment]::OSVersion.Version.Build))
        [void]$sb.AppendLine(('PowerShell: {0}' -f $PSVersionTable.PSVersion))
        [void]$sb.AppendLine(('管理员: {0}' -f (Test-Admin)))
        [void]$sb.AppendLine(('当前状态: {0}' -f (Get-GuardState).Text))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- 检查项 ---')
        foreach ($c in (Get-GuardChecks)) {
            $mark = 'FAIL'
            if ($c.Ok) { $mark = 'PASS' } elseif ($c.Warn) { $mark = 'WARN' }
            [void]$sb.AppendLine(('[{0}] {1,-24} {2}' -f $mark, $c.Name, $c.Detail))
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- 快照内容 ---')
        $snap = Get-LatestSnapshot
        if ($null -ne $snap) {
            [void]$sb.AppendLine([System.IO.File]::ReadAllText($snap.Path, [System.Text.Encoding]::UTF8))
        }
        else { [void]$sb.AppendLine('(无)') }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('--- 最近日志 ---')
        $logFile = Join-Path $script:LogDir ('guard-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        if (Test-Path -LiteralPath $logFile) {
            $tail = Get-Content -LiteralPath $logFile -Tail 60
            foreach ($l in $tail) { [void]$sb.AppendLine($l) }
        }
        $utf8 = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($file, $sb.ToString(), $utf8)
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $file + '"')
        Write-Log ('已导出诊断报告: ' + $file)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '导出失败', 'OK', 'Error') | Out-Null
    }
}

function Show-MainGui {
    param([switch]$TestOnly, [string]$ShotPath)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $C = @{
        Bg     = [System.Drawing.Color]::FromArgb(246, 247, 250)
        Card   = [System.Drawing.Color]::White
        Line   = [System.Drawing.Color]::FromArgb(224, 227, 233)
        Text   = [System.Drawing.Color]::FromArgb(30, 34, 42)
        Muted  = [System.Drawing.Color]::FromArgb(108, 116, 130)
        Accent = [System.Drawing.Color]::FromArgb(28, 100, 220)
        Ok     = [System.Drawing.Color]::FromArgb(13, 118, 68)
    }
    $isAdmin = Test-Admin

    $form = New-Object System.Windows.Forms.Form
    $form.Text = ('{0}  v{1}' -f $script:AppName, $script:Version)
    $form.ClientSize = New-Object System.Drawing.Size(748, 744)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.BackColor = $C.Bg
    $form.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 9
    try { $form.Icon = [System.Drawing.SystemIcons]::Shield } catch { }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = $script:AppName
    $title.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 18, ([System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $C.Text
    $title.Location = New-Object System.Drawing.Point(24, 16)
    $title.Size = New-Object System.Drawing.Size(420, 34)
    $form.Controls.Add($title)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = ('三档可逆 · 改动前自动快照 · 一键还原    v{0}' -f $script:Version)
    $sub.ForeColor = $C.Muted
    $sub.Location = New-Object System.Drawing.Point(26, 52)
    $sub.Size = New-Object System.Drawing.Size(560, 20)
    $form.Controls.Add($sub)

    $adminTag = New-Object System.Windows.Forms.Label
    $adminTag.Text = $(if ($isAdmin) { '管理员' } else { '普通权限（只读）' })
    $adminTag.TextAlign = 'MiddleRight'
    $adminTag.ForeColor = $(if ($isAdmin) { $C.Ok } else { [System.Drawing.Color]::FromArgb(186, 42, 42) })
    $adminTag.Location = New-Object System.Drawing.Point(560, 30)
    $adminTag.Size = New-Object System.Drawing.Size(164, 22)
    $form.Controls.Add($adminTag)

    $badge = New-Object System.Windows.Forms.Label
    $badge.Text = '●  正在读取状态…'
    $badge.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 12, ([System.Drawing.FontStyle]::Bold)
    $badge.ForeColor = $C.Muted
    $badge.Location = New-Object System.Drawing.Point(24, 78)
    $badge.Size = New-Object System.Drawing.Size(700, 26)
    $form.Controls.Add($badge)

    # ---- 模式选择
    $gbMode = New-Object System.Windows.Forms.GroupBox
    $gbMode.Text = ' 选择模式 '
    $gbMode.ForeColor = $C.Text
    $gbMode.BackColor = $C.Card
    $gbMode.Location = New-Object System.Drawing.Point(24, 110)
    $gbMode.Size = New-Object System.Drawing.Size(700, 180)
    $form.Controls.Add($gbMode)

    $rbLite = New-Object System.Windows.Forms.RadioButton
    $rbLite.Text = '温和 · 只暂停'
    $rbLite.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
    $rbLite.Location = New-Object System.Drawing.Point(16, 26)
    $rbLite.Size = New-Object System.Drawing.Size(200, 24)
    $rbLite.Checked = $false
    $gbMode.Controls.Add($rbLite)

    $lbLite = New-Object System.Windows.Forms.Label
    $lbLite.Text = '暂停更新指定天数，阻止自动重启与驱动更新。不改服务、不阻断网络，系统设置里随时可见并撤销。'
    $lbLite.ForeColor = $C.Muted
    $lbLite.Location = New-Object System.Drawing.Point(34, 50)
    $lbLite.Size = New-Object System.Drawing.Size(650, 20)
    $gbMode.Controls.Add($lbLite)

    $rbStd = New-Object System.Windows.Forms.RadioButton
    $rbStd.Text = '标准 · 停止检查（推荐）'
    $rbStd.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
    $rbStd.Location = New-Object System.Drawing.Point(16, 74)
    $rbStd.Size = New-Object System.Drawing.Size(240, 24)
    $rbStd.Checked = $true
    $gbMode.Controls.Add($rbStd)

    $lbStd = New-Object System.Windows.Forms.Label
    $lbStd.Text = '在温和基础上停止自动检查更新（策略层），手动「检查更新」仍可用。适合重装后不想被反复打扰。'
    $lbStd.ForeColor = $C.Muted
    $lbStd.Location = New-Object System.Drawing.Point(34, 98)
    $lbStd.Size = New-Object System.Drawing.Size(650, 20)
    $gbMode.Controls.Add($lbStd)

    $rbStrict = New-Object System.Windows.Forms.RadioButton
    $rbStrict.Text = '彻底 · 断开更新通道'
    $rbStrict.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
    $rbStrict.Location = New-Object System.Drawing.Point(16, 122)
    $rbStrict.Size = New-Object System.Drawing.Size(240, 24)
    $gbMode.Controls.Add($rbStrict)

    $lbStrict = New-Object System.Windows.Forms.Label
    $lbStrict.Text = '禁用更新服务 + 出站阻断 + SYSTEM 看护任务（每 30 分钟自愈）。更新页面可能报错，补丁完全停更。'
    $lbStrict.ForeColor = [System.Drawing.Color]::FromArgb(160, 60, 40)
    $lbStrict.Location = New-Object System.Drawing.Point(34, 146)
    $lbStrict.Size = New-Object System.Drawing.Size(650, 20)
    $gbMode.Controls.Add($lbStrict)

    # ---- 附加选项
    $gbOpt = New-Object System.Windows.Forms.GroupBox
    $gbOpt.Text = ' 附加选项 '
    $gbOpt.ForeColor = $C.Text
    $gbOpt.BackColor = $C.Card
    $gbOpt.Location = New-Object System.Drawing.Point(24, 300)
    $gbOpt.Size = New-Object System.Drawing.Size(700, 86)
    $form.Controls.Add($gbOpt)

    $cbReboot = New-Object System.Windows.Forms.CheckBox
    $cbReboot.Text = '登录时不自动重启'
    $cbReboot.Checked = $true
    $cbReboot.Location = New-Object System.Drawing.Point(16, 22)
    $cbReboot.Size = New-Object System.Drawing.Size(180, 22)
    $gbOpt.Controls.Add($cbReboot)

    $cbDrv = New-Object System.Windows.Forms.CheckBox
    $cbDrv.Text = '不通过更新装驱动'
    $cbDrv.Checked = $true
    $cbDrv.Location = New-Object System.Drawing.Point(206, 22)
    $cbDrv.Size = New-Object System.Drawing.Size(180, 22)
    $gbOpt.Controls.Add($cbDrv)

    $cbDefer = New-Object System.Windows.Forms.CheckBox
    $cbDefer.Text = '延迟功能更新'
    $cbDefer.Checked = $true
    $cbDefer.Location = New-Object System.Drawing.Point(396, 22)
    $cbDefer.Size = New-Object System.Drawing.Size(120, 22)
    $gbOpt.Controls.Add($cbDefer)

    $numDefer = New-Object System.Windows.Forms.NumericUpDown
    $numDefer.Minimum = 30
    $numDefer.Maximum = 365
    $numDefer.Value = 365
    $numDefer.Location = New-Object System.Drawing.Point(516, 21)
    $numDefer.Size = New-Object System.Drawing.Size(64, 24)
    $gbOpt.Controls.Add($numDefer)

    $lbDay1 = New-Object System.Windows.Forms.Label
    $lbDay1.Text = '天'
    $lbDay1.ForeColor = $C.Muted
    $lbDay1.Location = New-Object System.Drawing.Point(586, 24)
    $lbDay1.Size = New-Object System.Drawing.Size(24, 20)
    $gbOpt.Controls.Add($lbDay1)

    $lbPause = New-Object System.Windows.Forms.Label
    $lbPause.Text = '暂停天数'
    $lbPause.ForeColor = $C.Muted
    $lbPause.Location = New-Object System.Drawing.Point(16, 56)
    $lbPause.Size = New-Object System.Drawing.Size(70, 20)
    $gbOpt.Controls.Add($lbPause)

    $numPause = New-Object System.Windows.Forms.NumericUpDown
    $numPause.Minimum = 7
    $numPause.Maximum = 3650
    $numPause.Value = 35
    $numPause.Location = New-Object System.Drawing.Point(88, 54)
    $numPause.Size = New-Object System.Drawing.Size(64, 24)
    $gbOpt.Controls.Add($numPause)

    $lbDay2 = New-Object System.Windows.Forms.Label
    $lbDay2.Text = '天（官方机制，系统设置里可见）'
    $lbDay2.ForeColor = $C.Muted
    $lbDay2.Location = New-Object System.Drawing.Point(158, 57)
    $lbDay2.Size = New-Object System.Drawing.Size(280, 20)
    $gbOpt.Controls.Add($lbDay2)

    # ---- 按钮
    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = '应用所选模式'
    $btnApply.Location = New-Object System.Drawing.Point(24, 398)
    $btnApply.Size = New-Object System.Drawing.Size(186, 40)
    $btnApply.FlatStyle = 'Flat'
    $btnApply.FlatAppearance.BorderSize = 0
    $btnApply.BackColor = $C.Accent
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnApply)

    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = '完全恢复'
    $btnRestore.Location = New-Object System.Drawing.Point(220, 398)
    $btnRestore.Size = New-Object System.Drawing.Size(140, 40)
    $btnRestore.FlatStyle = 'Flat'
    $btnRestore.BackColor = $C.Card
    $btnRestore.FlatAppearance.BorderColor = $C.Line
    $form.Controls.Add($btnRestore)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = '刷新状态'
    $btnRefresh.Location = New-Object System.Drawing.Point(370, 398)
    $btnRefresh.Size = New-Object System.Drawing.Size(110, 40)
    $btnRefresh.FlatStyle = 'Flat'
    $btnRefresh.BackColor = $C.Card
    $btnRefresh.FlatAppearance.BorderColor = $C.Line
    $form.Controls.Add($btnRefresh)

    $btnSnap = New-Object System.Windows.Forms.Button
    $btnSnap.Text = '重建基线'
    $btnSnap.Location = New-Object System.Drawing.Point(490, 398)
    $btnSnap.Size = New-Object System.Drawing.Size(110, 40)
    $btnSnap.FlatStyle = 'Flat'
    $btnSnap.BackColor = $C.Card
    $btnSnap.FlatAppearance.BorderColor = $C.Line
    $form.Controls.Add($btnSnap)

    $btnDiag = New-Object System.Windows.Forms.Button
    $btnDiag.Text = '导出诊断'
    $btnDiag.Location = New-Object System.Drawing.Point(610, 398)
    $btnDiag.Size = New-Object System.Drawing.Size(114, 40)
    $btnDiag.FlatStyle = 'Flat'
    $btnDiag.BackColor = $C.Card
    $btnDiag.FlatAppearance.BorderColor = $C.Line
    $form.Controls.Add($btnDiag)

    # ---- 状态清单
    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(24, 450)
    $list.Size = New-Object System.Drawing.Size(700, 200)
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.HeaderStyle = 'Nonclickable'
    $list.MultiSelect = $false
    $list.BorderStyle = 'FixedSingle'
    $list.BackColor = $C.Card
    $list.HideSelection = $true
    [void]$list.Columns.Add('检查项', 250)
    [void]$list.Columns.Add('当前结果', 424)
    $form.Controls.Add($list)

    # ---- 日志
    $log = New-Object System.Windows.Forms.TextBox
    $log.Location = New-Object System.Drawing.Point(24, 658)
    $log.Size = New-Object System.Drawing.Size(700, 62)
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = 'Vertical'
    $log.BackColor = [System.Drawing.Color]::FromArgb(252, 252, 253)
    $log.ForeColor = $C.Muted
    $log.Font = New-Object System.Drawing.Font -ArgumentList 'Consolas', 8.5
    $log.BorderStyle = 'FixedSingle'
    $form.Controls.Add($log)

    $script:Ui = @{
        Form       = $form
        Badge      = $badge
        List       = $list
        Log        = $log
        RbLite     = $rbLite
        RbStd      = $rbStd
        RbStrict   = $rbStrict
        CbReboot   = $cbReboot
        CbDrv      = $cbDrv
        CbDefer    = $cbDefer
        NumDefer   = $numDefer
        NumPause   = $numPause
        BtnApply   = $btnApply
        BtnRestore = $btnRestore
        BtnRefresh = $btnRefresh
        BtnSnap    = $btnSnap
        BtnDiag    = $btnDiag
    }

    if (-not $isAdmin) {
        $btnApply.Enabled = $false
        $btnRestore.Enabled = $false
        $btnSnap.Enabled = $false
        $lbStrict.Text = '需要管理员权限：请双击「启动.vbs」运行本工具。'
    }

    $btnApply.Add_Click({ Invoke-UiApply })
    $btnRestore.Add_Click({ Invoke-UiRestore })
    $btnRefresh.Add_Click({ Update-UiState })
    $btnSnap.Add_Click({ Invoke-UiNewBaseline })
    $btnDiag.Add_Click({ Invoke-UiDiag })

    $script:LogSink = {
        param([string]$Line)
        try {
            $tb = $script:Ui.Log
            $tb.AppendText($Line + "`r`n")
            $tb.SelectionStart = $tb.TextLength
            $tb.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
        catch { }
    }

    $form.Add_Shown({
            $script:Ui.Log.AppendText(('已进入图形界面 · {0}' -f (Get-Date -Format 'HH:mm:ss')) + "`r`n")
            Update-UiState
            $st = Get-GuardState
            $script:Ui.Log.AppendText(('当前状态：{0}' -f $st.Text) + "`r`n")
            if (Test-PendingReboot) { $script:Ui.Log.AppendText('提示：系统有待重启的更新，禁用不会撤销已排队安装。' + "`r`n") }
        })

    if ($TestOnly) {
        try { Update-UiState; Write-Host 'UI 状态刷新成功' }
        catch { Write-Host ('UI 状态刷新失败: ' + $_.Exception.Message) }
        if ($ShotPath) {
            try {
                $form.StartPosition = 'Manual'
                $form.Location = New-Object System.Drawing.Point(-4000, -4000)
                $form.Show()
                for ($i = 0; $i -lt 6; $i++) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 60
                }
                $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                $rect = New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)
                $form.DrawToBitmap($bmp, $rect)
                $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $form.Hide()
                Write-Host ('UI 截图已保存: ' + $ShotPath)
            }
            catch { Write-Host ('UI 截图失败: ' + $_.Exception.Message) }
        }
        $form.Dispose()
        Write-Host 'UI 构造成功'
        $script:LogSink = $null
        $script:Ui = $null
        return
    }

    [void]$form.ShowDialog()
    $script:LogSink = $null
    $script:Ui = $null
}

if ($UiTest) {
    try { Show-MainGui -TestOnly -ShotPath $UiShot }
    catch {
        Write-Host ('UI 构造失败: ' + $_.Exception.Message)
        Write-Host $_.ScriptStackTrace
        exit 1
    }
    return
}

# 无参数 -> 图形界面
Show-MainGui

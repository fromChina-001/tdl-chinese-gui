# tdl Chinese GUI - Windows 中文图形界面
# Copyright (C) 2026 fromChina-001
# License: AGPL-3.0-or-later
param(
    [switch]$SelfTest,
    [switch]$AccountSelfTest,
    [string]$RenderPreview
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TdlGuiNative
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
[System.Windows.Forms.Application]::EnableVisualStyles()
$script:InstanceMutex = $null
if (-not $SelfTest -and -not $AccountSelfTest -and [string]::IsNullOrWhiteSpace($RenderPreview)) {
    $createdNew = $false
    $script:InstanceMutex = [System.Threading.Mutex]::new($true, 'Local\TdlChineseGui_01a03d6f', [ref]$createdNew)
    if (-not $createdNew) {
        [void][Windows.Forms.MessageBox]::Show('中文版下载器已经打开，请不要重复启动。', 'Telegram 下载器', 'OK', 'Information')
        exit 0
    }
}

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TdlPath = Join-Path $script:AppDir 'tdl.exe'
$script:DownloadsDefault = Join-Path $script:AppDir 'downloads'
$script:SettingsPath = Join-Path $script:AppDir 'gui-settings.json'
$script:QueuePath = Join-Path $script:AppDir 'gui-queue.json'
$script:RuntimeDir = Join-Path $script:AppDir 'gui-runtime'
$script:AccountCachePath = Join-Path $script:AppDir 'gui-account.json'
$profileDirectory = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace($profileDirectory)) { $profileDirectory = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($profileDirectory)) { $profileDirectory = $script:AppDir }
$script:SessionPath = Join-Path $profileDirectory '.tdl\data\default'

$script:ActiveRun = $null
$script:CurrentQueueItem = $null
$script:DownloadPaused = $false
$script:LoginRun = $null
$script:LoginForm = $null
$script:AccountRun = $null
$script:AccountProbePath = ''
$script:AccountName = ''
$script:AccountUserId = ''
$script:AccountLastRefresh = ''
$script:StartAfterAccountRefresh = $false
$script:LastLogText = ''
$script:MainForm = $null

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

Ensure-Directory $script:DownloadsDefault
Ensure-Directory $script:RuntimeDir

function Get-DefaultSettings {
    return [ordered]@{
        DownloadDirectory = $script:DownloadsDefault
        ProxyEnabled     = $false
        ProxyAddress     = 'http://127.0.0.1:7890'
        Threads          = 4
        Limit            = 2
        RetryCount       = 2
        GroupMedia       = $true
        SkipSame         = $true
        AutoStart        = $true
    }
}

function Load-Settings {
    $defaults = Get-DefaultSettings
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @($defaults.Keys)) {
                if ($null -ne $saved.PSObject.Properties[$key]) {
                    $defaults[$key] = $saved.$key
                }
            }
        }
        catch {
            # Keep safe defaults when an old settings file is invalid.
        }
    }
    return $defaults
}

$script:Settings = Load-Settings

function Save-Settings {
    $script:Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$builder.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) {
        [void]$builder.Append(('\' * ($slashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-NativeArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string]$_) }) -join ' ')
}

function Start-HiddenProcessCapture {
    param(
        [string[]]$Arguments,
        [string]$Kind
    )

    if (-not (Test-Path -LiteralPath $script:TdlPath)) {
        throw "找不到 tdl.exe：$script:TdlPath"
    }

    $runId = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $script:RuntimeDir "$runId.out.log"
    $stderrPath = Join-Path $script:RuntimeDir "$runId.err.log"

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:TdlPath
    $startInfo.Arguments = Join-NativeArguments $Arguments
    $startInfo.WorkingDirectory = $script:AppDir
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw '无法启动 tdl。'
    }

    $stdoutStream = New-Object System.IO.FileStream(
        $stdoutPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )
    $stderrStream = New-Object System.IO.FileStream(
        $stderrPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )

    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

    return [pscustomobject]@{
        Kind          = $Kind
        Process       = $process
        StdoutPath    = $stdoutPath
        StderrPath    = $stderrPath
        StdoutStream  = $stdoutStream
        StderrStream  = $stderrStream
        StdoutTask    = $stdoutTask
        StderrTask    = $stderrTask
        LastText      = ''
        StopRequested = $false
    }
}

function Read-SharedUtf8File {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)), $true)
            try { return $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch {
        return ''
    }
}

function Get-RunText {
    param($Run)
    if ($null -eq $Run) { return '' }
    $stdout = Read-SharedUtf8File $Run.StdoutPath
    $stderr = Read-SharedUtf8File $Run.StderrPath
    if ([string]::IsNullOrWhiteSpace($stderr)) { return $stdout }
    if ([string]::IsNullOrWhiteSpace($stdout)) { return $stderr }
    return "$stdout`r`n$stderr"
}

function Remove-AnsiCodes {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $clean = [regex]::Replace($Text, "$([char]27)\[[0-?]*[ -/]*[@-~]", '')
    $clean = $clean -replace "`r(?!`n)", "`n"
    return $clean
}

function Complete-CapturedRun {
    param($Run)
    if ($null -eq $Run) { return }
    try { [void]$Run.StdoutTask.Wait(1500) } catch {}
    try { [void]$Run.StderrTask.Wait(1500) } catch {}
    try { $Run.StdoutStream.Dispose() } catch {}
    try { $Run.StderrStream.Dispose() } catch {}
}

function Stop-CapturedRun {
    param($Run)
    if ($null -eq $Run) { return }
    $Run.StopRequested = $true
    try {
        if (-not $Run.Process.HasExited) {
            $killer = New-Object System.Diagnostics.ProcessStartInfo
            $killer.FileName = "$env:SystemRoot\System32\taskkill.exe"
            $killer.Arguments = "/PID $($Run.Process.Id) /T /F"
            $killer.UseShellExecute = $false
            $killer.CreateNoWindow = $true
            $killProcess = [System.Diagnostics.Process]::Start($killer)
            [void]$killProcess.WaitForExit(3000)
            $killProcess.Dispose()
        }
    }
    catch {
        try { $Run.Process.Kill() } catch {}
    }
}

function Get-CommonArguments {
    $arguments = New-Object System.Collections.Generic.List[string]
    if ([bool]$script:Settings.ProxyEnabled -and -not [string]::IsNullOrWhiteSpace([string]$script:Settings.ProxyAddress)) {
        $arguments.Add('--proxy')
        $arguments.Add([string]$script:Settings.ProxyAddress)
    }
    $arguments.Add('--disable-progress-ps')
    return ,$arguments
}

function Get-DownloadArguments {
    param([string]$Url)
    $arguments = Get-CommonArguments
    $arguments.Add('--threads')
    $arguments.Add([string][int]$script:Settings.Threads)
    $arguments.Add('--limit')
    $arguments.Add([string][int]$script:Settings.Limit)
    $arguments.Add('dl')
    $arguments.Add('-u')
    $arguments.Add($Url)
    $arguments.Add('-d')
    $arguments.Add([string]$script:Settings.DownloadDirectory)
    if ([bool]$script:Settings.SkipSame) { $arguments.Add('--skip-same') }
    if ([bool]$script:Settings.GroupMedia) { $arguments.Add('--group') }
    return $arguments.ToArray()
}

function Test-TelegramMessageUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    return ($Url.Trim() -match '^(?i)(https?://)?(t\.me|telegram\.me)/.+/\d+(?:\?.*)?$')
}

function Get-QueueData {
    $rows = @()
    foreach ($listItem in $script:QueueList.Items) {
        $data = $listItem.Tag
        if ($data.Status -in @('等待中', '下载中', '失败', '已停止')) {
            $rows += [ordered]@{
                Url      = $data.Url
                Status   = if ($data.Status -eq '下载中') { '等待中' } else { $data.Status }
                Attempts = [int]$data.Attempts
            }
        }
    }
    $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:QueuePath -Encoding UTF8
}

function Save-Queue {
    if ($null -ne $script:QueueList) {
        try { Get-QueueData } catch {}
    }
}

function Update-QueueRow {
    param(
        [System.Windows.Forms.ListViewItem]$Row,
        [string]$Status,
        [string]$Result
    )
    $Row.Tag.Status = $Status
    $Row.SubItems[0].Text = $Status
    $Row.SubItems[2].Text = $Result
    switch ($Status) {
        '下载中' { $Row.ForeColor = [Drawing.Color]::FromArgb(0, 102, 204) }
        '已完成' { $Row.ForeColor = [Drawing.Color]::FromArgb(16, 124, 16) }
        '失败'   { $Row.ForeColor = [Drawing.Color]::FromArgb(196, 43, 28) }
        '已停止' { $Row.ForeColor = [Drawing.Color]::FromArgb(120, 120, 120) }
        default  { $Row.ForeColor = [Drawing.Color]::FromArgb(45, 45, 48) }
    }
    Save-Queue
}

function Add-QueueUrl {
    param([string]$Url, [string]$InitialStatus = '等待中', [int]$Attempts = 0)
    $normalized = $Url.Trim()
    foreach ($existing in $script:QueueList.Items) {
        if ($existing.Tag.Url -eq $normalized -and $existing.Tag.Status -notin @('已完成', '失败', '已停止')) {
            return $false
        }
    }
    $data = [pscustomobject]@{
        Url      = $normalized
        Status   = $InitialStatus
        Attempts = $Attempts
    }
    $row = New-Object System.Windows.Forms.ListViewItem($InitialStatus)
    [void]$row.SubItems.Add($normalized)
    [void]$row.SubItems.Add('')
    $row.Tag = $data
    [void]$script:QueueList.Items.Add($row)
    Update-QueueRow $row $InitialStatus ''
    return $true
}

function Load-Queue {
    if (-not (Test-Path -LiteralPath $script:QueuePath)) { return }
    try {
        $saved = Get-Content -LiteralPath $script:QueuePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($entry in @($saved)) {
            if ($null -ne $entry.Url -and (Test-TelegramMessageUrl ([string]$entry.Url))) {
                $status = if ([string]$entry.Status -eq '失败') { '失败' } else { '等待中' }
                [void](Add-QueueUrl ([string]$entry.Url) $status ([int]$entry.Attempts))
            }
        }
    }
    catch {
        # Ignore an obsolete queue file.
    }
}

function Append-Log {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:LogBox.AppendText("[$stamp] $Text`r`n")
    if ($script:LogBox.Lines.Count -gt 300) {
        $script:LogBox.Lines = $script:LogBox.Lines | Select-Object -Last 220
    }
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

function Set-AccountDisplay {
    param(
        [string]$Name,
        [string]$UserId,
        [string]$ConnectionText,
        [bool]$IsError = $false
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'Telegram 账号' }
    $script:LoginStateLabel.Text = $Name
    $script:AccountDetailLabel.Text = if ([string]::IsNullOrWhiteSpace($UserId)) {
        '账号 ID：--  ·  tdl 会话：default'
    }
    else {
        "账号 ID：$UserId  ·  tdl 会话：default"
    }
    $script:AccountConnectionLabel.Text = $ConnectionText
    $color = if ($IsError) {
        [Drawing.Color]::FromArgb(196, 43, 28)
    }
    else {
        [Drawing.Color]::FromArgb(16, 124, 16)
    }
    $script:LoginStateLabel.ForeColor = $color
    $script:AccountConnectionLabel.ForeColor = $color
}

function Load-AccountCache {
    if (-not (Test-Path -LiteralPath $script:AccountCachePath)) { return }
    try {
        $saved = Get-Content -LiteralPath $script:AccountCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $saved.PSObject.Properties['Name']) {
            $script:AccountName = [string]$saved.Name
        }
        if ($null -ne $saved.PSObject.Properties['UserId']) {
            $script:AccountUserId = [string]$saved.UserId
        }
        if ($null -ne $saved.PSObject.Properties['LastRefresh']) {
            $script:AccountLastRefresh = [string]$saved.LastRefresh
        }
    }
    catch {
        $script:AccountName = ''
        $script:AccountUserId = ''
        $script:AccountLastRefresh = ''
    }
}

function Save-AccountCache {
    [ordered]@{
        Name        = $script:AccountName
        UserId      = $script:AccountUserId
        LastRefresh = $script:AccountLastRefresh
    } | ConvertTo-Json | Set-Content -LiteralPath $script:AccountCachePath -Encoding UTF8
}

function Update-LoginIndicator {
    if (Test-Path -LiteralPath $script:SessionPath) {
        $name = if ([string]::IsNullOrWhiteSpace($script:AccountName)) { '已登录（资料待刷新）' } else { $script:AccountName }
        $connection = if ([string]::IsNullOrWhiteSpace($script:AccountLastRefresh)) {
            '已检测到登录数据'
        }
        else {
            "上次验证 $($script:AccountLastRefresh)"
        }
        Set-AccountDisplay $name $script:AccountUserId $connection
        $script:AccountRefreshButton.Enabled = $true
    }
    else {
        $script:AccountName = ''
        $script:AccountUserId = ''
        $script:AccountLastRefresh = ''
        Set-AccountDisplay '尚未登录 Telegram' '' '请先登录' $true
        $script:AccountRefreshButton.Enabled = $false
    }
}

function Remove-AccountProbeFiles {
    param($Run)
    foreach ($file in @(
        $script:AccountProbePath,
        $(if ($null -ne $Run) { $Run.StdoutPath } else { '' }),
        $(if ($null -ne $Run) { $Run.StderrPath } else { '' })
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$file) -and (Test-Path -LiteralPath $file)) {
            try { Remove-Item -LiteralPath $file -Force } catch {}
        }
    }
    $script:AccountProbePath = ''
}

function Start-AccountRefresh {
    param([switch]$Quiet)

    if (-not (Test-Path -LiteralPath $script:SessionPath)) {
        Update-LoginIndicator
        if (-not $Quiet) {
            [void][Windows.Forms.MessageBox]::Show($script:MainForm, '尚未检测到 Telegram 登录，请先点右上角登录。', '账号信息', 'OK', 'Information')
        }
        return
    }
    if ($null -ne $script:AccountRun -and -not $script:AccountRun.Process.HasExited) { return }
    if (($null -ne $script:ActiveRun -and -not $script:ActiveRun.Process.HasExited) -or
        ($null -ne $script:LoginRun -and -not $script:LoginRun.Process.HasExited)) {
        if (-not $Quiet) {
            [void][Windows.Forms.MessageBox]::Show($script:MainForm, '当前正在下载或登录，请完成后再刷新账号信息。', '账号信息', 'OK', 'Information')
        }
        return
    }

    try {
        $script:AccountProbePath = Join-Path $script:RuntimeDir ("account-" + [Guid]::NewGuid().ToString('N') + '.json')
        $arguments = New-Object System.Collections.Generic.List[string]
        foreach ($argument in @('chat', 'export', '-T', 'last', '-i', '1', '-o', $script:AccountProbePath)) {
            $arguments.Add([string]$argument)
        }
        foreach ($argument in (Get-CommonArguments)) {
            $arguments.Add([string]$argument)
        }
        $script:AccountRun = Start-HiddenProcessCapture $arguments.ToArray() 'account'
        $script:AccountRefreshButton.Enabled = $false
        $script:AccountConnectionLabel.Text = '正在验证账号…'
        $script:AccountConnectionLabel.ForeColor = [Drawing.Color]::FromArgb(34, 99, 171)
        if (-not $Quiet) { Append-Log '正在刷新当前 Telegram 账号信息。' }
    }
    catch {
        $script:AccountRun = $null
        Remove-AccountProbeFiles $null
        Set-AccountDisplay $script:AccountName $script:AccountUserId '刷新失败，请重试' $true
        $script:AccountRefreshButton.Enabled = $true
        if (-not $Quiet) { Append-Log "刷新账号信息失败：$($_.Exception.Message)" }
    }
}

function Finish-AccountRefresh {
    $run = $script:AccountRun
    if ($null -eq $run) { return }

    $exitCode = -1
    try { $exitCode = $run.Process.ExitCode } catch {}
    Complete-CapturedRun $run
    $clean = Remove-AnsiCodes (Get-RunText $run)
    $success = $false

    try {
        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $script:AccountProbePath)) {
            $probe = Get-Content -LiteralPath $script:AccountProbePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $userId = [string]$probe.id
            if (-not [string]::IsNullOrWhiteSpace($userId)) {
                $name = ''
                $pattern = "(?m)^(?<name>[^\r\n]+)-" + [regex]::Escape($userId) + "\s+\.\.\."
                $nameMatch = [regex]::Match($clean, $pattern)
                if ($nameMatch.Success) {
                    $name = $nameMatch.Groups['name'].Value.Trim()
                }
                if ([string]::IsNullOrWhiteSpace($name)) {
                    $name = if ([string]::IsNullOrWhiteSpace($script:AccountName)) { 'Telegram 账号' } else { $script:AccountName }
                }

                $script:AccountName = $name
                $script:AccountUserId = $userId
                $script:AccountLastRefresh = Get-Date -Format 'MM-dd HH:mm'
                Save-AccountCache
                Set-AccountDisplay $script:AccountName $script:AccountUserId "连接正常 · 更新 $($script:AccountLastRefresh)"
                Append-Log "账号信息已刷新：$($script:AccountName)（ID：$($script:AccountUserId)）。"
                $success = $true
            }
        }
    }
    catch {
        $success = $false
    }

    if (-not $success) {
        $name = if ([string]::IsNullOrWhiteSpace($script:AccountName)) { '已登录 Telegram' } else { $script:AccountName }
        Set-AccountDisplay $name $script:AccountUserId '验证失败，点击刷新重试' $true
        Append-Log '账号信息刷新失败，请确认代理正常后重试。'
    }

    try { $run.Process.Dispose() } catch {}
    Remove-AccountProbeFiles $run
    $script:AccountRun = $null
    $script:AccountRefreshButton.Enabled = (Test-Path -LiteralPath $script:SessionPath)

    if ($script:StartAfterAccountRefresh) {
        $script:StartAfterAccountRefresh = $false
        Start-NextDownload
    }
}

function Stop-AccountRefresh {
    $run = $script:AccountRun
    if ($null -eq $run) { return }
    if (-not $run.Process.HasExited) { Stop-CapturedRun $run }
    Complete-CapturedRun $run
    try { $run.Process.Dispose() } catch {}
    Remove-AccountProbeFiles $run
    $script:AccountRun = $null
}

function Start-NextDownload {
    if ($script:DownloadPaused -or $null -ne $script:ActiveRun) { return }
    if ($null -ne $script:AccountRun -and -not $script:AccountRun.Process.HasExited) {
        $script:StartAfterAccountRefresh = $true
        $script:StatusLabel.Text = '账号信息读取完成后开始下载'
        return
    }

    $nextRow = $null
    foreach ($row in $script:QueueList.Items) {
        if ($row.Tag.Status -eq '等待中') {
            $nextRow = $row
            break
        }
    }

    if ($null -eq $nextRow) {
        $script:ProgressBar.Style = 'Blocks'
        $script:ProgressBar.Value = 0
        $script:StatusLabel.Text = '队列已处理完毕'
        $script:StartButton.Enabled = $true
        $script:StopButton.Enabled = $false
        return
    }

    try {
        Ensure-Directory ([string]$script:Settings.DownloadDirectory)
        $nextRow.Tag.Attempts = [int]$nextRow.Tag.Attempts + 1
        $script:CurrentQueueItem = $nextRow
        Update-QueueRow $nextRow '下载中' "第 $($nextRow.Tag.Attempts) 次尝试"
        $script:ActiveRun = Start-HiddenProcessCapture (Get-DownloadArguments $nextRow.Tag.Url) 'download'
        $script:LastLogText = ''
        $script:ProgressBar.Style = 'Marquee'
        $script:ProgressBar.MarqueeAnimationSpeed = 25
        $script:StatusLabel.Text = '正在下载，请保持代理连接'
        $script:StartButton.Enabled = $false
        $script:StopButton.Enabled = $true
        Append-Log "开始下载：$($nextRow.Tag.Url)"
    }
    catch {
        Update-QueueRow $nextRow '失败' $_.Exception.Message
        Append-Log "启动失败：$($_.Exception.Message)"
        $script:ActiveRun = $null
        $script:CurrentQueueItem = $null
    }
}

function Finish-CurrentDownload {
    $run = $script:ActiveRun
    $row = $script:CurrentQueueItem
    if ($null -eq $run -or $null -eq $row) { return }

    $exitCode = -1
    try { $exitCode = $run.Process.ExitCode } catch {}
    Complete-CapturedRun $run
    $finalText = Remove-AnsiCodes (Get-RunText $run)

    if ($run.StopRequested) {
        Update-QueueRow $row '已停止' '用户停止了任务'
        Append-Log '当前任务已停止。'
    }
    elseif ($exitCode -eq 0) {
        Update-QueueRow $row '已完成' '下载完成'
        Append-Log '下载完成。'
    }
    elseif ([int]$row.Tag.Attempts -le [int]$script:Settings.RetryCount) {
        Update-QueueRow $row '等待中' "失败，准备自动重试（$($row.Tag.Attempts)/$($script:Settings.RetryCount)）"
        Append-Log "下载失败，稍后自动重试。退出代码：$exitCode"
    }
    else {
        $message = "下载失败，退出代码：$exitCode"
        $usefulLines = @(($finalText -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($usefulLines.Count -gt 0) {
            $message = ($usefulLines | Select-Object -Last 1).Trim()
        }
        Update-QueueRow $row '失败' $message
        Append-Log "下载失败：$message"
    }

    try { $run.Process.Dispose() } catch {}
    $script:ActiveRun = $null
    $script:CurrentQueueItem = $null
    $script:ProgressBar.Style = 'Blocks'
    $script:ProgressBar.Value = 0
    $script:StopButton.Enabled = $false

    if (-not $script:DownloadPaused) {
        Start-NextDownload
    }
}

function Show-SettingsDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '下载设置'
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(610, 420)
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

    $downloadLabel = New-Object Windows.Forms.Label
    $downloadLabel.Text = '下载目录'
    $downloadLabel.Location = New-Object Drawing.Point(24, 28)
    $downloadLabel.AutoSize = $true
    $form.Controls.Add($downloadLabel)

    $downloadBox = New-Object Windows.Forms.TextBox
    $downloadBox.Location = New-Object Drawing.Point(24, 52)
    $downloadBox.Size = New-Object Drawing.Size(470, 28)
    $downloadBox.Text = [string]$script:Settings.DownloadDirectory
    $form.Controls.Add($downloadBox)

    $browseButton = New-Object Windows.Forms.Button
    $browseButton.Text = '浏览…'
    $browseButton.Location = New-Object Drawing.Point(505, 50)
    $browseButton.Size = New-Object Drawing.Size(80, 30)
    $form.Controls.Add($browseButton)

    $proxyCheck = New-Object Windows.Forms.CheckBox
    $proxyCheck.Text = '启用代理'
    $proxyCheck.Location = New-Object Drawing.Point(24, 103)
    $proxyCheck.AutoSize = $true
    $proxyCheck.Checked = [bool]$script:Settings.ProxyEnabled
    $form.Controls.Add($proxyCheck)

    $proxyBox = New-Object Windows.Forms.TextBox
    $proxyBox.Location = New-Object Drawing.Point(125, 99)
    $proxyBox.Size = New-Object Drawing.Size(369, 28)
    $proxyBox.Text = [string]$script:Settings.ProxyAddress
    $proxyBox.Enabled = $proxyCheck.Checked
    $form.Controls.Add($proxyBox)

    $proxyHint = New-Object Windows.Forms.Label
    $proxyHint.Text = '当前电脑建议保持：http://127.0.0.1:7890'
    $proxyHint.Location = New-Object Drawing.Point(125, 130)
    $proxyHint.AutoSize = $true
    $proxyHint.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($proxyHint)

    $threadsLabel = New-Object Windows.Forms.Label
    $threadsLabel.Text = '单文件线程数'
    $threadsLabel.Location = New-Object Drawing.Point(24, 174)
    $threadsLabel.AutoSize = $true
    $form.Controls.Add($threadsLabel)

    $threadsBox = New-Object Windows.Forms.NumericUpDown
    $threadsBox.Location = New-Object Drawing.Point(130, 170)
    $threadsBox.Minimum = 1
    $threadsBox.Maximum = 16
    $threadsBox.Value = [decimal][int]$script:Settings.Threads
    $form.Controls.Add($threadsBox)

    $limitLabel = New-Object Windows.Forms.Label
    $limitLabel.Text = '同时下载任务'
    $limitLabel.Location = New-Object Drawing.Point(250, 174)
    $limitLabel.AutoSize = $true
    $form.Controls.Add($limitLabel)

    $limitBox = New-Object Windows.Forms.NumericUpDown
    $limitBox.Location = New-Object Drawing.Point(360, 170)
    $limitBox.Minimum = 1
    $limitBox.Maximum = 8
    $limitBox.Value = [decimal][int]$script:Settings.Limit
    $form.Controls.Add($limitBox)

    $retryLabel = New-Object Windows.Forms.Label
    $retryLabel.Text = '失败重试次数'
    $retryLabel.Location = New-Object Drawing.Point(24, 220)
    $retryLabel.AutoSize = $true
    $form.Controls.Add($retryLabel)

    $retryBox = New-Object Windows.Forms.NumericUpDown
    $retryBox.Location = New-Object Drawing.Point(130, 216)
    $retryBox.Minimum = 0
    $retryBox.Maximum = 5
    $retryBox.Value = [decimal][int]$script:Settings.RetryCount
    $form.Controls.Add($retryBox)

    $groupCheck = New-Object Windows.Forms.CheckBox
    $groupCheck.Text = '自动下载同一组中的全部图片/视频'
    $groupCheck.Location = New-Object Drawing.Point(24, 267)
    $groupCheck.AutoSize = $true
    $groupCheck.Checked = [bool]$script:Settings.GroupMedia
    $form.Controls.Add($groupCheck)

    $skipCheck = New-Object Windows.Forms.CheckBox
    $skipCheck.Text = '跳过名称和大小相同的文件'
    $skipCheck.Location = New-Object Drawing.Point(24, 301)
    $skipCheck.AutoSize = $true
    $skipCheck.Checked = [bool]$script:Settings.SkipSame
    $form.Controls.Add($skipCheck)

    $autoCheck = New-Object Windows.Forms.CheckBox
    $autoCheck.Text = '加入链接后自动开始下载'
    $autoCheck.Location = New-Object Drawing.Point(320, 267)
    $autoCheck.AutoSize = $true
    $autoCheck.Checked = [bool]$script:Settings.AutoStart
    $form.Controls.Add($autoCheck)

    $saveButton = New-Object Windows.Forms.Button
    $saveButton.Text = '保存'
    $saveButton.Location = New-Object Drawing.Point(400, 360)
    $saveButton.Size = New-Object Drawing.Size(88, 34)
    $saveButton.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
    $saveButton.ForeColor = [Drawing.Color]::White
    $saveButton.FlatStyle = 'Flat'
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Location = New-Object Drawing.Point(497, 360)
    $cancelButton.Size = New-Object Drawing.Size(88, 34)
    $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)
    $form.CancelButton = $cancelButton

    $proxyCheck.Add_CheckedChanged({ $proxyBox.Enabled = $proxyCheck.Checked })
    $browseButton.Add_Click({
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        $picker.Description = '选择 Telegram 文件保存位置'
        $picker.SelectedPath = $downloadBox.Text
        if ($picker.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
            $downloadBox.Text = $picker.SelectedPath
        }
        $picker.Dispose()
    })
    $saveButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($downloadBox.Text)) {
            [void][Windows.Forms.MessageBox]::Show($form, '请选择下载目录。', '设置', 'OK', 'Warning')
            return
        }
        if ($proxyCheck.Checked -and [string]::IsNullOrWhiteSpace($proxyBox.Text)) {
            [void][Windows.Forms.MessageBox]::Show($form, '已启用代理，请填写代理地址。', '设置', 'OK', 'Warning')
            return
        }
        $script:Settings.DownloadDirectory = $downloadBox.Text.Trim()
        $script:Settings.ProxyEnabled = $proxyCheck.Checked
        $script:Settings.ProxyAddress = $proxyBox.Text.Trim()
        $script:Settings.Threads = [int]$threadsBox.Value
        $script:Settings.Limit = [int]$limitBox.Value
        $script:Settings.RetryCount = [int]$retryBox.Value
        $script:Settings.GroupMedia = $groupCheck.Checked
        $script:Settings.SkipSame = $skipCheck.Checked
        $script:Settings.AutoStart = $autoCheck.Checked
        Save-Settings
        $script:DownloadPathLabel.Text = [string]$script:Settings.DownloadDirectory
        Append-Log '设置已保存。'
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    [void]$form.ShowDialog($script:MainForm)
    $form.Dispose()
}

function Get-LatestQrBlock {
    param([string]$Text)
    $clean = Remove-AnsiCodes $Text
    $matches = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($clean -split "`n")) {
        $candidate = $line.TrimEnd("`r")
        if ($candidate.Length -ge 25 -and $candidate -match '^[█▄▀ ]+$') {
            $matches.Add($candidate)
        }
    }
    if ($matches.Count -eq 0) { return '' }
    $take = [Math]::Min(24, $matches.Count)
    return (($matches | Select-Object -Last $take) -join "`r`n")
}

function Show-LoginDialog {
    if ($null -ne $script:AccountRun -and -not $script:AccountRun.Process.HasExited) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '正在读取账号信息，请稍候再登录或更换账号。', 'Telegram 登录', 'OK', 'Information')
        return
    }
    if ($null -ne $script:ActiveRun -and -not $script:ActiveRun.Process.HasExited) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '请先停止当前下载任务，再进行登录或更换账号。', 'Telegram 登录', 'OK', 'Information')
        return
    }    if ($null -ne $script:LoginRun -and -not $script:LoginRun.Process.HasExited) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '登录窗口已经在运行。', 'Telegram 登录', 'OK', 'Information')
        return
    }

    if (Test-Path -LiteralPath $script:SessionPath) {
        $answer = [Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            '已经检测到登录数据。只有账号失效或需要更换账号时才应重新登录。是否继续？',
            '重新登录确认',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }

    $form = New-Object Windows.Forms.Form
    $form.Text = '登录 Telegram'
    $form.StartPosition = 'CenterParent'
    $form.ClientSize = New-Object Drawing.Size(620, 650)
    $form.MinimumSize = New-Object Drawing.Size(636, 689)
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $script:LoginForm = $form

    $title = New-Object Windows.Forms.Label
    $title.Text = '请用 Telegram 手机客户端扫描二维码'
    $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
    $title.Location = New-Object Drawing.Point(22, 18)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $hint = New-Object Windows.Forms.Label
    $hint.Text = "Telegram → 设置 → 设备 → 链接桌面设备。二维码可能需要等待几秒钟。"
    $hint.Location = New-Object Drawing.Point(22, 52)
    $hint.Size = New-Object Drawing.Size(570, 40)
    $form.Controls.Add($hint)

    $qrBox = New-Object Windows.Forms.TextBox
    $qrBox.Multiline = $true
    $qrBox.ReadOnly = $true
    $qrBox.WordWrap = $false
    $qrBox.ScrollBars = 'Both'
    $qrBox.BackColor = [Drawing.Color]::White
    $qrBox.ForeColor = [Drawing.Color]::Black
    $qrBox.Font = New-Object Drawing.Font('Consolas', 9, [Drawing.FontStyle]::Regular)
    $qrBox.Location = New-Object Drawing.Point(22, 96)
    $qrBox.Size = New-Object Drawing.Size(575, 465)
    $qrBox.Anchor = 'Top,Bottom,Left,Right'
    $qrBox.Text = "正在连接 Telegram，请稍候……"
    $form.Controls.Add($qrBox)

    $state = New-Object Windows.Forms.Label
    $state.Text = '正在生成二维码'
    $state.Location = New-Object Drawing.Point(22, 579)
    $state.AutoSize = $true
    $state.Anchor = 'Bottom,Left'
    $form.Controls.Add($state)

    $closeButton = New-Object Windows.Forms.Button
    $closeButton.Text = '取消'
    $closeButton.Location = New-Object Drawing.Point(500, 574)
    $closeButton.Size = New-Object Drawing.Size(97, 34)
    $closeButton.Anchor = 'Bottom,Right'
    $form.Controls.Add($closeButton)

    try {
        $args = Get-CommonArguments
        $args.Add('login')
        $args.Add('-T')
        $args.Add('qr')
        $script:LoginRun = Start-HiddenProcessCapture $args.ToArray() 'login'
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '无法登录', 'OK', 'Error')
        $form.Dispose()
        $script:LoginForm = $null
        return
    }

    $loginTimer = New-Object Windows.Forms.Timer
    $loginTimer.Interval = 350
    $loginTimer.Add_Tick({
        if ($null -eq $script:LoginRun) { return }
        $text = Get-RunText $script:LoginRun
        $qr = Get-LatestQrBlock $text
        if (-not [string]::IsNullOrWhiteSpace($qr)) {
            $qrBox.Text = $qr
            $qrBox.SelectionStart = 0
            $qrBox.ScrollToCaret()
            $state.Text = '二维码已生成，等待手机确认'
        }
        if ($script:LoginRun.Process.HasExited) {
            $loginTimer.Stop()
            $exitCode = $script:LoginRun.Process.ExitCode
            $clean = Remove-AnsiCodes (Get-RunText $script:LoginRun)
            Complete-CapturedRun $script:LoginRun
            if (-not $script:LoginRun.StopRequested -and $exitCode -eq 0) {
                $state.Text = '登录成功，可以关闭此窗口'
                $state.ForeColor = [Drawing.Color]::FromArgb(16, 124, 16)
                $closeButton.Text = '完成'
                Append-Log 'Telegram 登录成功。'
                $script:AccountName = ''
                $script:AccountUserId = ''
                $script:AccountLastRefresh = ''
                if (Test-Path -LiteralPath $script:AccountCachePath) {
                    try { Remove-Item -LiteralPath $script:AccountCachePath -Force } catch {}
                }
                Update-LoginIndicator
            }
            elseif (-not $script:LoginRun.StopRequested) {
                $state.Text = '登录未完成，请检查代理后重试'
                $state.ForeColor = [Drawing.Color]::FromArgb(196, 43, 28)
                $details = @(($clean -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 4)
                if ($details.Count -gt 0) { $qrBox.Text = $details -join "`r`n" }
            }
            try { $script:LoginRun.Process.Dispose() } catch {}
            $script:LoginRun = $null
            if ($exitCode -eq 0) { Start-AccountRefresh -Quiet }
        }
    })

    $closeButton.Add_Click({ $form.Close() })
    $form.Add_FormClosing({
        $loginTimer.Stop()
        if ($null -ne $script:LoginRun -and -not $script:LoginRun.Process.HasExited) {
            Stop-CapturedRun $script:LoginRun
            Complete-CapturedRun $script:LoginRun
            try { $script:LoginRun.Process.Dispose() } catch {}
            $script:LoginRun = $null
        }
    })
    $form.Add_FormClosed({
        $loginTimer.Dispose()
        $script:LoginForm = $null
    })

    $loginTimer.Start()
    [void]$form.ShowDialog($script:MainForm)
    $form.Dispose()
}

if ($SelfTest) {
    if (-not (Test-Path -LiteralPath $script:TdlPath)) { throw 'SELFTEST: tdl.exe is missing' }
    $testRun = Start-HiddenProcessCapture @('version') 'selftest'
    [void]$testRun.Process.WaitForExit(10000)
    Start-Sleep -Milliseconds 150
    $testExit = $testRun.Process.ExitCode
    Complete-CapturedRun $testRun
    $testOutput = Remove-AnsiCodes (Get-RunText $testRun)
    $testRun.Process.Dispose()
    if ($testExit -ne 0 -or $testOutput -notmatch 'Version') { throw "SELFTEST: tdl version failed ($testExit)" }
    $commonArgumentTest = Get-CommonArguments
    if ($commonArgumentTest -isnot [System.Collections.Generic.List[string]]) {
        throw 'SELFTEST: common arguments are not mutable'
    }
    $downloadArgumentTest = Get-DownloadArguments 'https://t.me/c/1000000000/1'
    if ($downloadArgumentTest -notcontains 'dl' -or $downloadArgumentTest -notcontains 'https://t.me/c/1000000000/1') {
        throw 'SELFTEST: download arguments are incomplete'
    }
    Write-Output 'SELFTEST_OK'
    Write-Output ($testOutput.Trim())
    exit 0
}

# Main window
$script:MainForm = New-Object Windows.Forms.Form
$script:MainForm.Text = 'Telegram 文件下载器（中文版）'
$script:MainForm.StartPosition = 'CenterScreen'
$script:MainForm.ClientSize = New-Object Drawing.Size(1000, 735)
$script:MainForm.MinimumSize = New-Object Drawing.Size(900, 680)
$script:MainForm.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$script:MainForm.BackColor = [Drawing.Color]::FromArgb(247, 248, 250)

$header = New-Object Windows.Forms.Panel
$header.Location = New-Object Drawing.Point(0, 0)
$header.Size = New-Object Drawing.Size(1000, 76)
$header.Anchor = 'Top,Left,Right'
$header.Height = 76
$header.BackColor = [Drawing.Color]::FromArgb(34, 99, 171)
$script:MainForm.Controls.Add($header)

$titleLabel = New-Object Windows.Forms.Label
$titleLabel.Text = 'Telegram 文件下载器'
$titleLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 17, [Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [Drawing.Color]::White
$titleLabel.Location = New-Object Drawing.Point(24, 13)
$titleLabel.AutoSize = $true
$header.Controls.Add($titleLabel)

$subtitleLabel = New-Object Windows.Forms.Label
$subtitleLabel.Text = '中文窗口 · 多链接队列 · 自动重试 · 无命令框'
$subtitleLabel.ForeColor = [Drawing.Color]::FromArgb(220, 235, 250)
$subtitleLabel.Location = New-Object Drawing.Point(27, 47)
$subtitleLabel.AutoSize = $true
$header.Controls.Add($subtitleLabel)

$loginButton = New-Object Windows.Forms.Button
$loginButton.Text = '登录 / 更换账号'
$loginButton.Location = New-Object Drawing.Point(820, 20)
$loginButton.Size = New-Object Drawing.Size(150, 36)
$loginButton.Anchor = 'Top,Right'
$loginButton.FlatStyle = 'Flat'
$loginButton.BackColor = [Drawing.Color]::White
$loginButton.ForeColor = [Drawing.Color]::FromArgb(34, 99, 171)
$header.Controls.Add($loginButton)

$content = New-Object Windows.Forms.Panel
$content.Location = New-Object Drawing.Point(0, 76)
$content.Size = New-Object Drawing.Size(1000, 659)
$content.Anchor = 'Top,Bottom,Left,Right'
$content.Padding = New-Object Windows.Forms.Padding(20, 14, 20, 12)
$script:MainForm.Controls.Add($content)
$header.BringToFront()

$loginPanel = New-Object Windows.Forms.Panel
$loginPanel.Location = New-Object Drawing.Point(20, 12)
$loginPanel.Size = New-Object Drawing.Size(960, 70)
$loginPanel.Anchor = 'Top,Left,Right'
$loginPanel.BackColor = [Drawing.Color]::White
$loginPanel.BorderStyle = 'FixedSingle'
$content.Controls.Add($loginPanel)

$loginCaption = New-Object Windows.Forms.Label
$loginCaption.Text = '当前账号：'
$loginCaption.Location = New-Object Drawing.Point(12, 10)
$loginCaption.AutoSize = $true
$loginPanel.Controls.Add($loginCaption)

$script:LoginStateLabel = New-Object Windows.Forms.Label
$script:LoginStateLabel.Location = New-Object Drawing.Point(84, 8)
$script:LoginStateLabel.Size = New-Object Drawing.Size(235, 24)
$script:LoginStateLabel.AutoEllipsis = $true
$script:LoginStateLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9.5, [Drawing.FontStyle]::Bold)
$loginPanel.Controls.Add($script:LoginStateLabel)

$script:AccountDetailLabel = New-Object Windows.Forms.Label
$script:AccountDetailLabel.Location = New-Object Drawing.Point(325, 10)
$script:AccountDetailLabel.Size = New-Object Drawing.Size(310, 22)
$script:AccountDetailLabel.ForeColor = [Drawing.Color]::DimGray
$loginPanel.Controls.Add($script:AccountDetailLabel)

$script:AccountConnectionLabel = New-Object Windows.Forms.Label
$script:AccountConnectionLabel.Location = New-Object Drawing.Point(640, 10)
$script:AccountConnectionLabel.Size = New-Object Drawing.Size(180, 22)
$script:AccountConnectionLabel.TextAlign = 'MiddleRight'
$loginPanel.Controls.Add($script:AccountConnectionLabel)

$script:AccountRefreshButton = New-Object Windows.Forms.Button
$script:AccountRefreshButton.Text = '刷新账号'
$script:AccountRefreshButton.Location = New-Object Drawing.Point(835, 5)
$script:AccountRefreshButton.Size = New-Object Drawing.Size(110, 30)
$script:AccountRefreshButton.Anchor = 'Top,Right'
$loginPanel.Controls.Add($script:AccountRefreshButton)

$downloadCaption = New-Object Windows.Forms.Label
$downloadCaption.Text = '保存到：'
$downloadCaption.Location = New-Object Drawing.Point(12, 42)
$downloadCaption.AutoSize = $true
$loginPanel.Controls.Add($downloadCaption)

$script:DownloadPathLabel = New-Object Windows.Forms.Label
$script:DownloadPathLabel.Text = [string]$script:Settings.DownloadDirectory
$script:DownloadPathLabel.Location = New-Object Drawing.Point(72, 41)
$script:DownloadPathLabel.AutoEllipsis = $true
$script:DownloadPathLabel.Size = New-Object Drawing.Size(640, 22)
$script:DownloadPathLabel.Anchor = 'Top,Left,Right'
$script:DownloadPathLabel.ForeColor = [Drawing.Color]::DimGray
$loginPanel.Controls.Add($script:DownloadPathLabel)

$privacyLabel = New-Object Windows.Forms.Label
$privacyLabel.Text = 'tdl 不读取手机号 / @用户名'
$privacyLabel.Location = New-Object Drawing.Point(725, 42)
$privacyLabel.Size = New-Object Drawing.Size(220, 22)
$privacyLabel.Anchor = 'Top,Right'
$privacyLabel.TextAlign = 'MiddleRight'
$privacyLabel.ForeColor = [Drawing.Color]::Gray
$loginPanel.Controls.Add($privacyLabel)

Update-LoginIndicator

$linkGroup = New-Object Windows.Forms.GroupBox
$linkGroup.Text = '粘贴 Telegram 消息链接（每行一个）'
$linkGroup.Location = New-Object Drawing.Point(20, 91)
$linkGroup.Size = New-Object Drawing.Size(960, 132)
$linkGroup.Anchor = 'Top,Left,Right'
$content.Controls.Add($linkGroup)

$script:LinkBox = New-Object Windows.Forms.TextBox
$script:LinkBox.Multiline = $true
$script:LinkBox.ScrollBars = 'Vertical'
$script:LinkBox.Location = New-Object Drawing.Point(14, 26)
$script:LinkBox.Size = New-Object Drawing.Size(700, 88)
$script:LinkBox.Anchor = 'Top,Left,Right'
$script:LinkBox.Font = New-Object Drawing.Font('Segoe UI', 9)
$linkGroup.Controls.Add($script:LinkBox)

$pasteButton = New-Object Windows.Forms.Button
$pasteButton.Text = '从剪贴板粘贴'
$pasteButton.Location = New-Object Drawing.Point(728, 26)
$pasteButton.Size = New-Object Drawing.Size(216, 36)
$pasteButton.Anchor = 'Top,Right'
$linkGroup.Controls.Add($pasteButton)

$addButton = New-Object Windows.Forms.Button
$addButton.Text = '加入下载队列'
$addButton.Location = New-Object Drawing.Point(728, 76)
$addButton.Size = New-Object Drawing.Size(216, 38)
$addButton.Anchor = 'Top,Right'
$addButton.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
$addButton.ForeColor = [Drawing.Color]::White
$addButton.FlatStyle = 'Flat'
$linkGroup.Controls.Add($addButton)

$queueLabel = New-Object Windows.Forms.Label
$queueLabel.Text = '下载队列'
$queueLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$queueLabel.Location = New-Object Drawing.Point(20, 236)
$queueLabel.AutoSize = $true
$content.Controls.Add($queueLabel)

$script:QueueList = New-Object Windows.Forms.ListView
$script:QueueList.Location = New-Object Drawing.Point(20, 262)
$script:QueueList.Size = New-Object Drawing.Size(960, 152)
$script:QueueList.Anchor = 'Top,Bottom,Left,Right'
$script:QueueList.View = 'Details'
$script:QueueList.FullRowSelect = $true
$script:QueueList.GridLines = $true
$script:QueueList.HideSelection = $false
[void]$script:QueueList.Columns.Add('状态', 90)
[void]$script:QueueList.Columns.Add('Telegram 消息链接', 600)
[void]$script:QueueList.Columns.Add('结果', 240)
$content.Controls.Add($script:QueueList)

$buttonPanel = New-Object Windows.Forms.Panel
$buttonPanel.Location = New-Object Drawing.Point(20, 422)
$buttonPanel.Size = New-Object Drawing.Size(960, 44)
$buttonPanel.Anchor = 'Bottom,Left,Right'
$content.Controls.Add($buttonPanel)

$script:StartButton = New-Object Windows.Forms.Button
$script:StartButton.Text = '开始 / 继续'
$script:StartButton.Location = New-Object Drawing.Point(0, 3)
$script:StartButton.Size = New-Object Drawing.Size(120, 36)
$script:StartButton.BackColor = [Drawing.Color]::FromArgb(16, 124, 16)
$script:StartButton.ForeColor = [Drawing.Color]::White
$script:StartButton.FlatStyle = 'Flat'
$buttonPanel.Controls.Add($script:StartButton)

$script:StopButton = New-Object Windows.Forms.Button
$script:StopButton.Text = '停止当前任务'
$script:StopButton.Location = New-Object Drawing.Point(130, 3)
$script:StopButton.Size = New-Object Drawing.Size(125, 36)
$script:StopButton.Enabled = $false
$buttonPanel.Controls.Add($script:StopButton)

$retryButton = New-Object Windows.Forms.Button
$retryButton.Text = '重试选中项'
$retryButton.Location = New-Object Drawing.Point(265, 3)
$retryButton.Size = New-Object Drawing.Size(115, 36)
$buttonPanel.Controls.Add($retryButton)

$clearButton = New-Object Windows.Forms.Button
$clearButton.Text = '清理已完成'
$clearButton.Location = New-Object Drawing.Point(390, 3)
$clearButton.Size = New-Object Drawing.Size(115, 36)
$buttonPanel.Controls.Add($clearButton)

$openButton = New-Object Windows.Forms.Button
$openButton.Text = '打开下载目录'
$openButton.Location = New-Object Drawing.Point(646, 3)
$openButton.Size = New-Object Drawing.Size(130, 36)
$openButton.Anchor = 'Top,Right'
$buttonPanel.Controls.Add($openButton)

$settingsButton = New-Object Windows.Forms.Button
$settingsButton.Text = '设置'
$settingsButton.Location = New-Object Drawing.Point(786, 3)
$settingsButton.Size = New-Object Drawing.Size(80, 36)
$settingsButton.Anchor = 'Top,Right'
$buttonPanel.Controls.Add($settingsButton)

$helpButton = New-Object Windows.Forms.Button
$helpButton.Text = '帮助'
$helpButton.Location = New-Object Drawing.Point(876, 3)
$helpButton.Size = New-Object Drawing.Size(80, 36)
$helpButton.Anchor = 'Top,Right'
$buttonPanel.Controls.Add($helpButton)

$logLabel = New-Object Windows.Forms.Label
$logLabel.Text = '运行记录'
$logLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$logLabel.Location = New-Object Drawing.Point(20, 474)
$logLabel.AutoSize = $true
$logLabel.Anchor = 'Bottom,Left'
$content.Controls.Add($logLabel)

$script:LogBox = New-Object Windows.Forms.RichTextBox
$script:LogBox.Location = New-Object Drawing.Point(20, 500)
$script:LogBox.Size = New-Object Drawing.Size(960, 92)
$script:LogBox.Anchor = 'Bottom,Left,Right'
$script:LogBox.ReadOnly = $true
$script:LogBox.BackColor = [Drawing.Color]::White
$script:LogBox.Font = New-Object Drawing.Font('Microsoft YaHei UI', 8.5)
$content.Controls.Add($script:LogBox)

$script:ProgressBar = New-Object Windows.Forms.ProgressBar
$script:ProgressBar.Location = New-Object Drawing.Point(20, 607)
$script:ProgressBar.Size = New-Object Drawing.Size(690, 20)
$script:ProgressBar.Anchor = 'Bottom,Left,Right'
$content.Controls.Add($script:ProgressBar)

$script:StatusLabel = New-Object Windows.Forms.Label
$script:StatusLabel.Text = '就绪'
$script:StatusLabel.Location = New-Object Drawing.Point(722, 605)
$script:StatusLabel.Size = New-Object Drawing.Size(258, 24)
$script:StatusLabel.Anchor = 'Bottom,Right'
$script:StatusLabel.TextAlign = 'MiddleRight'
$content.Controls.Add($script:StatusLabel)

$pasteButton.Add_Click({
    try {
        if ([Windows.Forms.Clipboard]::ContainsText()) {
            $clip = [Windows.Forms.Clipboard]::GetText().Trim()
            if (-not [string]::IsNullOrWhiteSpace($clip)) {
                if ([string]::IsNullOrWhiteSpace($script:LinkBox.Text)) {
                    $script:LinkBox.Text = $clip
                }
                else {
                    $script:LinkBox.AppendText("`r`n$clip")
                }
            }
        }
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '读取剪贴板失败，请直接按 Ctrl+V。', '剪贴板', 'OK', 'Warning')
    }
})

$addButton.Add_Click({
    $valid = 0
    $invalid = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($script:LinkBox.Text -split "`r?`n")) {
        $url = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        if (Test-TelegramMessageUrl $url) {
            if (Add-QueueUrl $url) { $valid++ }
        }
        else {
            $invalid.Add($url)
        }
    }
    if ($valid -gt 0) {
        $script:LinkBox.Clear()
        Append-Log "已加入 $valid 个链接。"
        if ([bool]$script:Settings.AutoStart) {
            $script:DownloadPaused = $false
            Start-NextDownload
        }
    }
    if ($invalid.Count -gt 0) {
        [void][Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            "以下内容不像 Telegram 消息链接：`r`n$($invalid -join "`r`n")",
            '链接格式不正确',
            'OK',
            'Warning'
        )
    }
})

$script:StartButton.Add_Click({
    foreach ($row in $script:QueueList.SelectedItems) {
        if ($row.Tag.Status -in @('失败', '已停止')) {
            $row.Tag.Attempts = 0
            Update-QueueRow $row '等待中' ''
        }
    }
    $script:DownloadPaused = $false
    Start-NextDownload
})

$script:StopButton.Add_Click({
    if ($null -ne $script:ActiveRun) {
        $script:DownloadPaused = $true
        $script:StatusLabel.Text = '正在停止当前任务…'
        Stop-CapturedRun $script:ActiveRun
    }
})

$retryButton.Add_Click({
    if ($script:QueueList.SelectedItems.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '请先在队列中选择需要重试的项目。', '重试', 'OK', 'Information')
        return
    }
    foreach ($row in $script:QueueList.SelectedItems) {
        if ($row.Tag.Status -in @('失败', '已停止')) {
            $row.Tag.Attempts = 0
            Update-QueueRow $row '等待中' ''
        }
    }
    $script:DownloadPaused = $false
    Start-NextDownload
})

$clearButton.Add_Click({
    $remove = @()
    foreach ($row in $script:QueueList.Items) {
        if ($row.Tag.Status -eq '已完成') { $remove += $row }
    }
    foreach ($row in $remove) { $script:QueueList.Items.Remove($row) }
    Save-Queue
})

$openButton.Add_Click({
    try {
        Ensure-Directory ([string]$script:Settings.DownloadDirectory)
        [void][Diagnostics.Process]::Start('explorer.exe', (ConvertTo-NativeArgument ([string]$script:Settings.DownloadDirectory)))
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, $_.Exception.Message, '无法打开目录', 'OK', 'Error')
    }
})

$settingsButton.Add_Click({ Show-SettingsDialog })
$loginButton.Add_Click({ Show-LoginDialog })
$script:AccountRefreshButton.Add_Click({ Start-AccountRefresh })
$helpButton.Add_Click({
    [void][Windows.Forms.MessageBox]::Show(
        $script:MainForm,
        "使用方法：`r`n`r`n1. 首次使用先点右上角【登录 / 更换账号】并扫码。`r`n2. 顶部会显示当前账号昵称、账号 ID 和连接状态；可点【刷新账号】重新验证。`r`n3. 把 Telegram 消息链接粘贴到输入框，每行一个。`r`n4. 点击【加入下载队列】，程序会连续下载。`r`n5. 下载失败会按照设置自动重试。`r`n`r`n程序关闭时，尚未完成的队列会自动保存。`r`n`r`n原项目：iyear/tdl`r`nhttps://github.com/iyear/tdl`r`n本程序是非官方中文图形界面，核心下载能力及相关权利归原作者与贡献者所有。",
        '使用帮助',
        'OK',
        'Information'
    )
})

$pollTimer = New-Object Windows.Forms.Timer
$pollTimer.Interval = 350
$pollTimer.Add_Tick({
    if ($null -ne $script:AccountRun -and $script:AccountRun.Process.HasExited) {
        Finish-AccountRefresh
    }
    if ($null -eq $script:ActiveRun) { return }
    $raw = Get-RunText $script:ActiveRun
    $clean = Remove-AnsiCodes $raw
    if ($clean.Length -gt $script:LastLogText.Length) {
        $newPart = $clean.Substring($script:LastLogText.Length)
        $script:LastLogText = $clean
        $lines = @(($newPart -split "`n") | ForEach-Object { $_.Trim() } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_ -notmatch '^(CPU|Memory|Goroutines|Progress)'
        })
        foreach ($line in ($lines | Select-Object -Last 8)) {
            Append-Log $line
        }
        $percentMatches = [regex]::Matches($clean, '(?<p>\d{1,3}(?:\.\d+)?)%')
        if ($percentMatches.Count -gt 0) {
            $value = [Math]::Min(100, [Math]::Max(0, [int][double]$percentMatches[$percentMatches.Count - 1].Groups['p'].Value))
            $script:ProgressBar.Style = 'Continuous'
            $script:ProgressBar.Value = $value
            $script:StatusLabel.Text = "正在下载：$value%"
        }
    }
    if ($script:ActiveRun.Process.HasExited) {
        Finish-CurrentDownload
    }
})

$script:MainForm.Add_Shown({
    if (-not [string]::IsNullOrWhiteSpace($RenderPreview)) { return }
    [void][TdlGuiNative]::ShowWindow($script:MainForm.Handle, 5)
    [void][TdlGuiNative]::SetForegroundWindow($script:MainForm.Handle)
    Load-AccountCache
    Update-LoginIndicator
    Load-Queue
    Append-Log '中文版控制窗口已启动。'
    if (Test-Path -LiteralPath $script:SessionPath) {
        Start-AccountRefresh -Quiet
    }
    if ($script:QueueList.Items.Count -gt 0) {
        Append-Log '已恢复上次未完成的下载队列。'
    }
    $pollTimer.Start()
})

$script:MainForm.Add_FormClosing({
    if ($null -ne $script:ActiveRun -and -not $script:ActiveRun.Process.HasExited) {
        $answer = [Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            '当前正在下载。关闭窗口会停止当前任务，未完成链接会保留到下次。确定关闭吗？',
            '确认退出',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        Stop-CapturedRun $script:ActiveRun
        if ($null -ne $script:CurrentQueueItem) {
            Update-QueueRow $script:CurrentQueueItem '等待中' '等待下次继续'
        }
    }
    if ($null -ne $script:AccountRun) {
        Stop-AccountRefresh
    }
    Save-Queue
})

$script:MainForm.Add_FormClosed({
    if ($null -ne $script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch {}
        $script:InstanceMutex.Dispose()
        $script:InstanceMutex = $null
    }    $pollTimer.Stop()
    $pollTimer.Dispose()
    if ($null -ne $script:ActiveRun) {
        Complete-CapturedRun $script:ActiveRun
        try { $script:ActiveRun.Process.Dispose() } catch {}
    }
    if ($null -ne $script:AccountRun) {
        Stop-AccountRefresh
    }
})

if ($AccountSelfTest) {
    Load-AccountCache
    Update-LoginIndicator
    Start-AccountRefresh -Quiet
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($null -ne $script:AccountRun -and -not $script:AccountRun.Process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ($null -ne $script:AccountRun -and $script:AccountRun.Process.HasExited) {
        Finish-AccountRefresh
    }
    elseif ($null -ne $script:AccountRun) {
        Stop-AccountRefresh
        throw 'ACCOUNT_SELFTEST: timed out'
    }
    if ([string]::IsNullOrWhiteSpace($script:AccountUserId) -or [string]::IsNullOrWhiteSpace($script:AccountName)) {
        throw 'ACCOUNT_SELFTEST: account data was not resolved'
    }
    Write-Output 'ACCOUNT_SELFTEST_OK'
    Write-Output ("ID_DIGITS=" + $script:AccountUserId.Length)
    Write-Output ("NAME_CHARS=" + $script:AccountName.Length)
    $pollTimer.Dispose()
    $script:MainForm.Dispose()
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($RenderPreview)) {
    $script:MainForm.Show()
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
    $previewBitmap = New-Object Drawing.Bitmap($script:MainForm.ClientSize.Width, $script:MainForm.ClientSize.Height)
    try {
        $script:MainForm.DrawToBitmap($previewBitmap, $script:MainForm.ClientRectangle)
        $previewBitmap.Save($RenderPreview, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $previewBitmap.Dispose()
        $pollTimer.Dispose()
        $script:MainForm.Dispose()
    }
    exit 0
}
[void][Windows.Forms.Application]::Run($script:MainForm)


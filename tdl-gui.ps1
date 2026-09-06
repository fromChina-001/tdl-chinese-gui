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
$script:AppVersion = '1.3.3'
$script:TdlPath = Join-Path $script:AppDir 'tdl.exe'
$script:InstallerPath = Join-Path $script:AppDir '一键安装或更新.bat'
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
$script:QueueHadWork = $false
$script:LastLogText = ''
$script:MainForm = $null
$script:QueueSummaryLabel = $null
$script:NotifyIcon = $null
$script:NotifyTimer = $null

function Ensure-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '程序内部目录为空，请重新打开软件；如果仍出现，请反馈运行日志。'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

function Assert-DirectoryWritable {
    param([string]$Path)
    Ensure-Directory $Path
    $probePath = Join-Path $Path ('.tdl-write-test-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $stream = New-Object IO.FileStream(
            $probePath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
    }
    catch {
        throw '下载目录无法写入，请使用更改保存目录按钮选择其他位置。'
    }
    finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        if (Test-Path -LiteralPath $probePath) { try { Remove-Item -LiteralPath $probePath -Force } catch {} }
    }
}

Ensure-Directory $script:DownloadsDefault
Ensure-Directory $script:RuntimeDir

function Remove-StaleRuntimeFiles {
    if (-not (Test-Path -LiteralPath $script:RuntimeDir)) { return }
    $staleBefore = (Get-Date).AddDays(-1)
    foreach ($pattern in @('*.out.log', '*.err.log', 'protected-*.json')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:RuntimeDir -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -gt $staleBefore) { continue }
            try { Remove-Item -LiteralPath $file.FullName -Force } catch {}
        }
    }
}
function Get-DefaultSettings {
    return [ordered]@{
        DownloadDirectory = $script:DownloadsDefault
        ProxyEnabled     = $false
        ProxyAddress     = 'http://127.0.0.1:7890'
        Threads          = 4
        Limit            = 2
        RetryCount       = 2
        GroupMedia       = $true
        SkipSame               = $true
        AutoStart              = $true
        CompletionNotification = $true
        WelcomeShown           = $false
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
    if ([string]::IsNullOrWhiteSpace([string]$defaults.DownloadDirectory)) {
        $defaults.DownloadDirectory = $script:DownloadsDefault
    }
    if ([string]::IsNullOrWhiteSpace([string]$defaults.ProxyAddress)) {
        $defaults.ProxyAddress = 'http://127.0.0.1:7890'
    }
    try { $defaults.Threads = [Math]::Min(16, [Math]::Max(1, [int]$defaults.Threads)) } catch { $defaults.Threads = 4 }
    try { $defaults.Limit = [Math]::Min(8, [Math]::Max(1, [int]$defaults.Limit)) } catch { $defaults.Limit = 2 }
    try { $defaults.RetryCount = [Math]::Min(5, [Math]::Max(0, [int]$defaults.RetryCount)) } catch { $defaults.RetryCount = 2 }
    return $defaults
}

$script:Settings = Load-Settings
if (-not [string]::IsNullOrWhiteSpace($RenderPreview)) {
    $script:Settings.DownloadDirectory = 'D:\Telegram Downloads'
    $script:Settings.ProxyEnabled = $false
}

function Save-Settings {
    $script:Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
}

function Set-DownloadDirectorySetting {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $script:Settings.DownloadDirectory = $Path
    Save-Settings
    if ($null -ne $script:DownloadPathLabel) {
        $script:DownloadPathLabel.Text = $Path
    }
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
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
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

function Remove-CapturedRunFiles {
    param($Run)
    if ($null -eq $Run) { return }
    foreach ($file in @($Run.StdoutPath, $Run.StderrPath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$file) -and (Test-Path -LiteralPath $file)) {
            try { Remove-Item -LiteralPath $file -Force } catch {}
        }
    }
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

function Get-LoginArguments {
    $arguments = Get-CommonArguments
    foreach ($argument in @('login', '-T', 'qr')) {
        [void]$arguments.Add([string]$argument)
    }
    return $arguments.ToArray()
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

function Get-ChatListArguments {
    $arguments = Get-CommonArguments
    foreach ($argument in @('chat', 'ls', '-o', 'json')) {
        $arguments.Add([string]$argument)
    }
    return $arguments.ToArray()
}

function Get-ChatExportArguments {
    param(
        [string]$ChatId,
        [int]$MediaCount,
        [string]$OutputPath
    )
    $arguments = Get-CommonArguments
    foreach ($argument in @('chat', 'export', '-c', $ChatId, '-T', 'last', '-i', [string]$MediaCount, '-o', $OutputPath)) {
        $arguments.Add([string]$argument)
    }
    return $arguments.ToArray()
}

function Get-ExportDownloadArguments {
    param(
        [string]$ExportPath,
        [string]$DownloadDirectory = ''
    )
    if ([string]::IsNullOrWhiteSpace($DownloadDirectory)) {
        $DownloadDirectory = [string]$script:Settings.DownloadDirectory
    }
    $arguments = Get-CommonArguments
    $arguments.Add('--threads')
    $arguments.Add([string][int]$script:Settings.Threads)
    $arguments.Add('--limit')
    $arguments.Add([string][int]$script:Settings.Limit)
    $arguments.Add('dl')
    $arguments.Add('-f')
    $arguments.Add($ExportPath)
    $arguments.Add('-d')
    $arguments.Add($DownloadDirectory)
    if ([bool]$script:Settings.SkipSame) { $arguments.Add('--skip-same') }
    if ([bool]$script:Settings.GroupMedia) { $arguments.Add('--group') }
    return $arguments.ToArray()
}

function ConvertFrom-TdlChatListJson {
    param([string]$Text)
    $result = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result.ToArray() }

    $clean = Remove-AnsiCodes $Text
    $start = $clean.IndexOf('[')
    $end = $clean.LastIndexOf(']')
    if ($start -lt 0 -or $end -lt $start) {
        throw '聊天列表返回格式不正确。'
    }

    $data = $clean.Substring($start, ($end - $start) + 1) | ConvertFrom-Json
    foreach ($entry in @($data)) {
        $idProperty = $entry.PSObject.Properties['id']
        $typeProperty = $entry.PSObject.Properties['type']
        $nameProperty = $entry.PSObject.Properties['visible_name']
        $usernameProperty = $entry.PSObject.Properties['username']
        $id = if ($null -eq $idProperty) { '' } else { [string]$idProperty.Value }
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $type = if ($null -eq $typeProperty) { '' } else { [string]$typeProperty.Value }
        $name = if ($null -eq $nameProperty) { '' } else { [string]$nameProperty.Value }
        $username = if ($null -eq $usernameProperty) { '' } else { [string]$usernameProperty.Value }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = if ([string]::IsNullOrWhiteSpace($username)) { "聊天 $id" } else { "@$username" }
        }
        $isBot = ($type -eq 'private' -and $username -match '(?i)bot$')
        $result.Add([pscustomobject]@{
            Id          = $id
            Type        = $type
            VisibleName = $name
            Username    = $username
            IsBot       = $isBot
        })
    }
    return $result.ToArray()
}

function Get-TdlChatTypeLabel {
    param($Chat)
    if ($null -ne $Chat -and [bool]$Chat.IsBot) { return '机器人' }
    switch ([string]$Chat.Type) {
        'private' { return '私聊' }
        'channel' { return '频道' }
        'group'   { return '群组' }
        default   { return '其他' }
    }
}
function Normalize-TelegramMessageUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }

    $candidate = $Url.Trim()
    $candidate = $candidate.TrimEnd([char[]]@('.', ',', '，', '。', ';', '；', '!', '！', ')', '）', ']', '】', '}', '》'))
    if ($candidate -notmatch '^(?i)https?://') {
        $candidate = "https://$candidate"
    }
    return $candidate
}

function Test-TelegramMessageUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $candidate = Normalize-TelegramMessageUrl $Url
    return ($candidate -match '^(?i)https?://(t\.me|telegram\.me)/[^\s]+/\d+(?:\?[^\s]*)?$')
}

function Get-TelegramMessageUrls {
    param([string]$Text)
    $urls = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $urls.ToArray() }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pattern = '(?i)(?:https?://)?(?:t\.me|telegram\.me)/[^\s<>"''，。；！？、]+/\d+(?:\?[^\s<>"''，。；！？、]*)?'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $url = Normalize-TelegramMessageUrl $match.Value
        if ((Test-TelegramMessageUrl $url) -and $seen.Add($url)) {
            $urls.Add($url)
        }
    }
    return $urls.ToArray()
}

function Get-FriendlyTdlError {
    param([string]$Text, [int]$ExitCode)

    $clean = Remove-AnsiCodes $Text
    if ($clean -match '(?is)(open kv storage|open db).*(access is denied|permission denied)') {
        return 'tdl 登录数据正被另一个任务占用，请等待当前下载结束，或关闭其他 tdl 窗口后重试。'
    }
    if ($clean -match '(?i)(timeout|deadline exceeded|i/o timeout|connection refused|network is unreachable|no such host)') {
        return '网络连接失败，请检查网络或在“设置”中配置代理。'
    }
    if ($clean -match '(?i)(flood.?wait|too many requests|rate limit)') {
        return 'Telegram 请求过于频繁，请稍等一段时间后重试。'
    }
    if ($clean -match '(?i)(auth.?key|session.*revoked|unauthorized|not authorized)') {
        return 'Telegram 登录已失效，请点击右上角重新登录。'
    }
    if ($clean -match '(?i)(no downloadable|no media|no messages|nothing to download|empty export)') {
        return '没有找到可下载的媒体，请确认聊天中仍能看到图片、视频或文件。'
    }
    if ($clean -match '(?i)(chat not found|cannot find chat|peer.?id.?invalid)') {
        return '没有找到该聊天，请刷新列表并确认当前登录账号仍能访问。'
    }
    if ($clean -match '(?i)(message.?id.?invalid|message not found|channel private|chat.*forbidden|access denied)') {
        return '消息不存在或当前账号无权访问，请检查链接和账号权限。'
    }
    if ($clean -match '(?i)(no space left|disk full|not enough space)') {
        return '磁盘空间不足，请清理磁盘或更换下载目录。'
    }
    if ($clean -match '(?i)(permission denied|access is denied)') {
        return '无法写入下载目录，请在“设置”中更换保存位置。'
    }

    $usefulLines = @(($clean -split [char]10) | ForEach-Object { $_.Trim() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        $_ -notmatch '^(CPU|Memory|Goroutines|Progress)'
    })
    if ($usefulLines.Count -gt 0) {
        $message = [string]($usefulLines | Select-Object -Last 1)
        $message = [regex]::Replace($message, '(?i)https?://(?:t\.me|telegram\.me)/[^\s]+', '[Telegram 消息链接]')
        foreach ($privatePath in @(
            [string]$script:AppDir,
            [string]$script:RuntimeDir,
            [string]$script:Settings.DownloadDirectory
        )) {
            if (-not [string]::IsNullOrWhiteSpace($privatePath)) {
                $message = $message.Replace($privatePath, '[本地目录]')
            }
        }
        $message = [regex]::Replace($message, '(?i)C:\\Users\\[^\\\s]+', '%USERPROFILE%')
        if ($message.Length -gt 180) { $message = $message.Substring(0, 180) + '…' }
        return $message
    }
    return "下载失败，退出代码：$ExitCode"
}

function Get-QueueItemNumber {
    param([System.Windows.Forms.ListViewItem]$Row)
    if ($null -eq $Row -or $null -eq $script:QueueList) { return 0 }
    return $script:QueueList.Items.IndexOf($Row) + 1
}

function Update-QueueSummary {
    if ($null -eq $script:QueueList -or $null -eq $script:QueueSummaryLabel) { return }
    $counts = @{
        Waiting = 0
        Active  = 0
        Failed  = 0
        Done    = 0
    }
    foreach ($row in $script:QueueList.Items) {
        switch ([string]$row.Tag.Status) {
            '等待中' { $counts.Waiting++ }
            '下载中' { $counts.Active++ }
            '失败'   { $counts.Failed++ }
            '已停止' { $counts.Failed++ }
            '已完成' { $counts.Done++ }
        }
    }
    $script:QueueSummaryLabel.Text = "共 $($script:QueueList.Items.Count) 条 · 等待 $($counts.Waiting) · 下载中 $($counts.Active) · 失败 $($counts.Failed) · 完成 $($counts.Done)"
}

function Show-CompletionNotification {
    param([string]$Message)
    if (-not [bool]$script:Settings.CompletionNotification -or [string]::IsNullOrWhiteSpace($Message)) { return }
    try {
        if ($null -eq $script:NotifyIcon) {
            $script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
            $script:NotifyIcon.Icon = [Drawing.SystemIcons]::Information
            $script:NotifyIcon.Text = 'tdl Chinese GUI'
        }
        $script:NotifyIcon.Visible = $true
        $script:NotifyIcon.ShowBalloonTip(5000, 'Telegram 下载器', $Message, [Windows.Forms.ToolTipIcon]::Info)
        [System.Media.SystemSounds]::Asterisk.Play()

        if ($null -eq $script:NotifyTimer) {
            $script:NotifyTimer = New-Object Windows.Forms.Timer
            $script:NotifyTimer.Interval = 6000
            $script:NotifyTimer.Add_Tick({
                $script:NotifyTimer.Stop()
                if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Visible = $false }
            })
        }
        $script:NotifyTimer.Stop()
        $script:NotifyTimer.Start()
    }
    catch {
        # Notifications are optional and must never affect downloading.
    }
}

function Show-QueueCompletionNotification {
    $failed = 0
    foreach ($row in $script:QueueList.Items) {
        if ($row.Tag.Status -in @('失败', '已停止')) { $failed++ }
    }
    $message = if ($failed -gt 0) {
        "下载队列已处理完毕，其中 $failed 项需要重试。"
    }
    else {
        '下载队列已全部完成。'
    }
    Show-CompletionNotification $message
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
    Update-QueueSummary
}

function Add-QueueUrl {
    param([string]$Url, [string]$InitialStatus = '等待中', [int]$Attempts = 0)
    $normalized = Normalize-TelegramMessageUrl $Url
    if (-not (Test-TelegramMessageUrl $normalized)) { return $false }
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
    Update-QueueSummary
}

function Remove-SelectedQueueItems {
    $selected = @($script:QueueList.SelectedItems)
    if ($selected.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '请先在队列中选择要移除的项目。', '移除队列项', 'OK', 'Information')
        return
    }

    $removed = 0
    $activeSkipped = 0
    foreach ($row in $selected) {
        if ($row.Tag.Status -eq '下载中') {
            $activeSkipped++
            continue
        }
        $script:QueueList.Items.Remove($row)
        $removed++
    }
    Save-Queue
    Update-QueueSummary
    if ($removed -gt 0) { Append-Log "已从队列移除 $removed 项。" }
    if ($activeSkipped -gt 0) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '正在下载的项目不能直接移除，请先停止当前任务。', '移除队列项', 'OK', 'Information')
    }
}

function Open-SelectedTelegramMessage {
    if ($script:QueueList.SelectedItems.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '请先选择一个队列项目。', '打开原消息', 'OK', 'Information')
        return
    }
    try {
        $url = [string]$script:QueueList.SelectedItems[0].Tag.Url
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $url
        $startInfo.UseShellExecute = $true
        [void][Diagnostics.Process]::Start($startInfo)
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '无法打开该消息链接。', '打开原消息', 'OK', 'Error')
    }
}

function Retry-SelectedQueueItems {
    if ($script:QueueList.SelectedItems.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '请先在队列中选择需要重试的项目。', '重试', 'OK', 'Information')
        return
    }
    $changed = 0
    foreach ($row in $script:QueueList.SelectedItems) {
        if ($row.Tag.Status -in @('失败', '已停止')) {
            $row.Tag.Attempts = 0
            Update-QueueRow $row '等待中' ''
            $changed++
        }
    }
    if ($changed -gt 0) {
        $script:DownloadPaused = $false
        Start-NextDownload
    }
}

function Test-TdlReady {
    if (Test-Path -LiteralPath $script:TdlPath) { return $true }

    $message = "未找到核心程序 tdl.exe。"
    if (Test-Path -LiteralPath $script:InstallerPath) {
        $message += [Environment]::NewLine + [Environment]::NewLine + '是否现在运行一键安装器？安装完成后会自动重新打开本程序。'
        $answer = [Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            $message,
            '需要安装 tdl',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Information
        )
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
            try {
                $startInfo = New-Object Diagnostics.ProcessStartInfo
                $startInfo.FileName = $script:InstallerPath
                $startInfo.WorkingDirectory = $script:AppDir
                $startInfo.UseShellExecute = $true
                [void][Diagnostics.Process]::Start($startInfo)
                $script:MainForm.Close()
            }
            catch {
                [void][Windows.Forms.MessageBox]::Show($script:MainForm, "无法启动安装器：$($_.Exception.Message)", '安装失败', 'OK', 'Error')
            }
        }
    }
    else {
        [void][Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            $message + [Environment]::NewLine + [Environment]::NewLine + '请重新下载完整安装包。',
            '缺少核心程序',
            'OK',
            'Error'
        )
    }
    return $false
}

function Show-FirstRunWelcome {
    if ([bool]$script:Settings.WelcomeShown) { return }

    $script:Settings.WelcomeShown = $true
    Save-Settings
    $baseMessage = '欢迎使用 tdl 中文图形界面！' +
        [Environment]::NewLine + [Environment]::NewLine +
        '使用只需三步：' + [Environment]::NewLine +
        '1. 登录 Telegram 账号。' + [Environment]::NewLine +
        '2. 粘贴消息链接或包含链接的文字。' + [Environment]::NewLine +
        '3. 加入队列，等待下载完成。'

    if (Test-Path -LiteralPath $script:SessionPath) {
        [void][Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            $baseMessage + [Environment]::NewLine + [Environment]::NewLine + '已检测到登录数据，可以直接开始使用。',
            '首次使用向导',
            'OK',
            'Information'
        )
        return
    }

    $answer = [Windows.Forms.MessageBox]::Show(
        $script:MainForm,
        $baseMessage + [Environment]::NewLine + [Environment]::NewLine + '是否现在登录 Telegram？',
        '首次使用向导',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Information
    )
    if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
        Show-LoginDialog
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
        $script:StatusLabel.Text = if ($script:QueueList.Items.Count -eq 0) { '队列为空' } else { '队列已处理完毕' }
        $script:StartButton.Enabled = $true
        $script:StopButton.Enabled = $false
        if ($script:QueueHadWork) {
            Show-QueueCompletionNotification
            $script:QueueHadWork = $false
        }
        return
    }

    try {
        Ensure-Directory ([string]$script:Settings.DownloadDirectory)
        $nextRow.Tag.Attempts = [int]$nextRow.Tag.Attempts + 1
        $script:CurrentQueueItem = $nextRow
        Update-QueueRow $nextRow '下载中' "第 $($nextRow.Tag.Attempts) 次尝试"
        $script:ActiveRun = Start-HiddenProcessCapture (Get-DownloadArguments $nextRow.Tag.Url) 'download'
        $script:QueueHadWork = $true
        $script:LastLogText = ''
        $script:ProgressBar.Style = 'Marquee'
        $script:ProgressBar.MarqueeAnimationSpeed = 25
        $script:StatusLabel.Text = '正在下载，请保持网络连接'
        $script:StartButton.Enabled = $false
        $script:StopButton.Enabled = $true
        Append-Log "开始下载队列第 $(Get-QueueItemNumber $nextRow) 项。"
    }
    catch {
        $message = Get-FriendlyTdlError $_.Exception.Message -1
        Update-QueueRow $nextRow '失败' $message
        Append-Log "启动失败：$message"
        $script:ActiveRun = $null
        $script:CurrentQueueItem = $null
        $script:StartButton.Enabled = $true
        $script:StopButton.Enabled = $false
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
    $friendlyError = Get-FriendlyTdlError $finalText $exitCode

    if ($run.StopRequested) {
        Update-QueueRow $row '已停止' '用户停止了任务'
        Append-Log '当前任务已停止。'
    }
    elseif ($exitCode -eq 0) {
        Update-QueueRow $row '已完成' '下载完成'
        Append-Log '下载完成。'
    }
    elseif ([int]$row.Tag.Attempts -le [int]$script:Settings.RetryCount) {
        $remaining = ([int]$script:Settings.RetryCount + 1) - [int]$row.Tag.Attempts
        Update-QueueRow $row '等待中' "下载失败，准备自动重试（剩余 $remaining 次）"
        Append-Log "下载失败：$friendlyError 将自动重试。"
    }
    else {
        Update-QueueRow $row '失败' $friendlyError
        Append-Log "下载失败：$friendlyError"
    }

    try { $run.Process.Dispose() } catch {}
    Remove-CapturedRunFiles $run
    $script:ActiveRun = $null
    $script:CurrentQueueItem = $null
    $script:ProgressBar.Style = 'Blocks'
    $script:ProgressBar.Value = 0
    $script:StopButton.Enabled = $false

    if (-not $script:DownloadPaused) {
        Start-NextDownload
    }
}
function Show-ProtectedChatDialog {
    if (-not (Test-Path -LiteralPath $script:SessionPath)) {
        [void][Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            '请先登录能够看到该机器人视频的 Telegram 账号。',
            '机器人 / 受保护聊天下载',
            'OK',
            'Information'
        )
        return
    }
    if (($null -ne $script:ActiveRun -and -not $script:ActiveRun.Process.HasExited) -or
        ($null -ne $script:AccountRun -and -not $script:AccountRun.Process.HasExited) -or
        ($null -ne $script:LoginRun -and -not $script:LoginRun.Process.HasExited)) {
        [void][Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            '当前有下载、登录或账号刷新任务正在运行，请等待完成后再打开此功能。',
            '机器人 / 受保护聊天下载',
            'OK',
            'Information'
        )
        return
    }

    $form = New-Object Windows.Forms.Form
    $form.Text = '机器人 / 受保护聊天下载'
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(780, 665)
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

    # Event closures share these objects, avoiding dynamic script-scope path loss.
    $pathContext = [pscustomobject]@{
        RuntimeDirectory  = [string]$script:RuntimeDir
        DownloadDirectory = [string]$script:Settings.DownloadDirectory
    }
    if ([string]::IsNullOrWhiteSpace($pathContext.DownloadDirectory)) {
        $pathContext.DownloadDirectory = [string]$script:DownloadsDefault
    }
    $appVersion = [string]$script:AppVersion

    $title = New-Object Windows.Forms.Label
    $title.Text = '无需消息链接，直接从机器人或受保护聊天下载'
    $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 13, [Drawing.FontStyle]::Bold)
    $title.Location = New-Object Drawing.Point(22, 18)
    $title.AutoSize = $true
    $form.Controls.Add($title)

    $hint = New-Object Windows.Forms.Label
    $hint.Text = '程序会读取当前账号的聊天列表。机器人会排在最前；默认只下载所选聊天最近 1 个媒体，普通文字消息会自动忽略。'
    $hint.Location = New-Object Drawing.Point(22, 53)
    $hint.Size = New-Object Drawing.Size(735, 42)
    $hint.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($hint)

    $searchLabel = New-Object Windows.Forms.Label
    $searchLabel.Text = '搜索'
    $searchLabel.Location = New-Object Drawing.Point(22, 107)
    $searchLabel.AutoSize = $true
    $form.Controls.Add($searchLabel)

    $searchBox = New-Object Windows.Forms.TextBox
    $searchBox.Location = New-Object Drawing.Point(72, 103)
    $searchBox.Size = New-Object Drawing.Size(495, 28)
    $form.Controls.Add($searchBox)

    $refreshButton = New-Object Windows.Forms.Button
    $refreshButton.Text = '刷新聊天列表'
    $refreshButton.Location = New-Object Drawing.Point(585, 100)
    $refreshButton.Size = New-Object Drawing.Size(170, 32)
    $form.Controls.Add($refreshButton)

    $chatList = New-Object Windows.Forms.ListView
    $chatList.Location = New-Object Drawing.Point(22, 145)
    $chatList.Size = New-Object Drawing.Size(733, 315)
    $chatList.View = 'Details'
    $chatList.FullRowSelect = $true
    $chatList.GridLines = $true
    $chatList.HideSelection = $false
    $chatList.MultiSelect = $false
    [void]$chatList.Columns.Add('类型', 85)
    [void]$chatList.Columns.Add('聊天名称', 315)
    [void]$chatList.Columns.Add('@用户名', 185)
    [void]$chatList.Columns.Add('聊天 ID', 125)
    $form.Controls.Add($chatList)

    $countLabel = New-Object Windows.Forms.Label
    $countLabel.Text = '下载最近的媒体数量'
    $countLabel.Location = New-Object Drawing.Point(22, 485)
    $countLabel.AutoSize = $true
    $form.Controls.Add($countLabel)

    $countBox = New-Object Windows.Forms.NumericUpDown
    $countBox.Location = New-Object Drawing.Point(175, 481)
    $countBox.Size = New-Object Drawing.Size(75, 28)
    $countBox.Minimum = 1
    $countBox.Maximum = 100
    $countBox.Value = 1
    $form.Controls.Add($countBox)

    $countHint = New-Object Windows.Forms.Label
    $countHint.Text = '建议先保持 1；需要批量下载时再增加。'
    $countHint.Location = New-Object Drawing.Point(270, 485)
    $countHint.AutoSize = $true
    $countHint.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($countHint)

    $destinationLabel = New-Object Windows.Forms.Label
    $destinationLabel.Text = '保存到：' + $pathContext.DownloadDirectory
    $destinationLabel.Location = New-Object Drawing.Point(22, 515)
    $destinationLabel.Size = New-Object Drawing.Size(580, 24)
    $destinationLabel.AutoEllipsis = $true
    $destinationLabel.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($destinationLabel)

    $changeFolderButton = New-Object Windows.Forms.Button
    $changeFolderButton.Text = '更改保存目录'
    $changeFolderButton.Location = New-Object Drawing.Point(620, 508)
    $changeFolderButton.Size = New-Object Drawing.Size(135, 31)
    $form.Controls.Add($changeFolderButton)

    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Location = New-Object Drawing.Point(22, 552)
    $progress.Size = New-Object Drawing.Size(733, 18)
    $form.Controls.Add($progress)

    $status = New-Object Windows.Forms.Label
    $status.Text = '准备读取聊天列表'
    $status.Location = New-Object Drawing.Point(22, 578)
    $status.Size = New-Object Drawing.Size(733, 27)
    $status.ForeColor = [Drawing.Color]::DimGray
    $form.Controls.Add($status)

    $copyErrorButton = New-Object Windows.Forms.Button
    $copyErrorButton.Text = '复制错误信息'
    $copyErrorButton.Location = New-Object Drawing.Point(330, 610)
    $copyErrorButton.Size = New-Object Drawing.Size(105, 36)
    $copyErrorButton.Enabled = $false
    $form.Controls.Add($copyErrorButton)

    $openFolderButton = New-Object Windows.Forms.Button
    $openFolderButton.Text = '打开下载目录'
    $openFolderButton.Location = New-Object Drawing.Point(445, 610)
    $openFolderButton.Size = New-Object Drawing.Size(135, 36)
    $form.Controls.Add($openFolderButton)

    $downloadButton = New-Object Windows.Forms.Button
    $downloadButton.Text = '开始下载'
    $downloadButton.Location = New-Object Drawing.Point(590, 610)
    $downloadButton.Size = New-Object Drawing.Size(100, 36)
    $downloadButton.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
    $downloadButton.ForeColor = [Drawing.Color]::White
    $downloadButton.FlatStyle = 'Flat'
    $downloadButton.Enabled = $false
    $form.Controls.Add($downloadButton)

    $closeButton = New-Object Windows.Forms.Button
    $closeButton.Text = '关闭'
    $closeButton.Location = New-Object Drawing.Point(700, 610)
    $closeButton.Size = New-Object Drawing.Size(55, 36)
    $form.Controls.Add($closeButton)

    $state = [pscustomobject]@{
        Run          = $null
        Phase        = 'idle'
        Chats        = @()
        ExportPath   = ''
        MediaCount   = 1
        LastError    = ''
    }

    $setBusy = {
        param([bool]$Busy, [string]$Message)
        $refreshButton.Enabled = -not $Busy
        $searchBox.Enabled = -not $Busy
        $chatList.Enabled = -not $Busy
        $countBox.Enabled = -not $Busy
        $changeFolderButton.Enabled = -not $Busy
        $downloadButton.Enabled = (-not $Busy -and $chatList.SelectedItems.Count -gt 0)
        $closeButton.Text = if ($Busy) { '停止' } else { '关闭' }
        if (-not [string]::IsNullOrWhiteSpace($Message)) { $status.Text = $Message }
    }.GetNewClosure()

    $removeExport = {
        if (-not [string]::IsNullOrWhiteSpace([string]$state.ExportPath) -and
            (Test-Path -LiteralPath $state.ExportPath)) {
            try { Remove-Item -LiteralPath $state.ExportPath -Force } catch {}
        }
        $state.ExportPath = ''
    }.GetNewClosure()

    $clearError = {
        $state.LastError = ''
        $copyErrorButton.Enabled = $false
    }.GetNewClosure()

    $finishError = {
        param([string]$Message)
        $failedPhase = [string]$state.Phase
        $phaseLabel = switch ($failedPhase) {
            'list'     { '读取聊天列表失败' }
            'prepare'  { '下载前检查失败' }
            'export'   { '查找最近媒体失败' }
            'download' { '下载媒体失败' }
            default    { '操作失败' }
        }
        & $removeExport
        $state.Phase = 'idle'
        $progress.Style = 'Blocks'
        $progress.Value = 0
        if ($Message -eq '操作已停止。') {
            & $clearError
            $status.Text = $Message
            $status.ForeColor = [Drawing.Color]::DimGray
            & $setBusy $false ''
            Append-Log '无链接下载已由用户停止。'
            return
        }
        $status.Text = "$phaseLabel：$Message"
        $status.ForeColor = [Drawing.Color]::FromArgb(196, 43, 28)
        $state.LastError = "tdl Chinese GUI v$appVersion`r`n功能：机器人 / 无链接下载`r`n阶段：$phaseLabel`r`n错误：$Message"
        $copyErrorButton.Enabled = $true
        & $setBusy $false ''
        Append-Log "无链接下载失败：$phaseLabel：$Message"
    }.GetNewClosure()

    $renderChats = {
        $query = $searchBox.Text.Trim()
        $chatList.BeginUpdate()
        try {
            $chatList.Items.Clear()
            $filtered = @($state.Chats | Where-Object {
                if ([string]::IsNullOrWhiteSpace($query)) { return $true }
                return (
                    [string]$_.VisibleName -like "*$query*" -or
                    [string]$_.Username -like "*$query*" -or
                    [string]$_.Id -like "*$query*"
                )
            } | Sort-Object @{ Expression = { if ([bool]$_.IsBot) { 0 } else { 1 } } }, @{ Expression = { [string]$_.VisibleName } })

            foreach ($chat in $filtered) {
                $row = New-Object Windows.Forms.ListViewItem((Get-TdlChatTypeLabel $chat))
                [void]$row.SubItems.Add([string]$chat.VisibleName)
                $username = if ([string]::IsNullOrWhiteSpace([string]$chat.Username)) { '—' } else { '@' + ([string]$chat.Username).TrimStart('@') }
                [void]$row.SubItems.Add($username)
                [void]$row.SubItems.Add([string]$chat.Id)
                $row.Tag = $chat
                [void]$chatList.Items.Add($row)
            }
        }
        finally {
            $chatList.EndUpdate()
        }
        if ($chatList.Items.Count -gt 0) {
            $chatList.Items[0].Selected = $true
            $chatList.Items[0].Focused = $true
            $downloadButton.Enabled = $true
        }
        else {
            $downloadButton.Enabled = $false
        }
    }.GetNewClosure()

    $startChatList = {
        if ($null -ne $state.Run) { return }
        $state.Phase = 'list'
        & $clearError
        try {
            $status.ForeColor = [Drawing.Color]::FromArgb(34, 99, 171)
            $progress.Style = 'Marquee'
            $progress.MarqueeAnimationSpeed = 24
            & $setBusy $true '正在读取当前 Telegram 账号的聊天列表，请稍候……'
            $state.Run = Start-HiddenProcessCapture (Get-ChatListArguments) 'protected-list'
        }
        catch {
            $state.Run = $null
            & $finishError (Get-FriendlyTdlError $_.Exception.Message -1)
        }
    }.GetNewClosure()

    $startDownload = {
        if ($null -ne $state.Run) { return }
        if ($chatList.SelectedItems.Count -eq 0) {
            [void][Windows.Forms.MessageBox]::Show($form, '请先选择视频所在的机器人或聊天。', '无链接下载', 'OK', 'Information')
            return
        }

        $chat = $chatList.SelectedItems[0].Tag
        $count = [int]$countBox.Value
        $answer = [Windows.Forms.MessageBox]::Show(
            $form,
            ('将从“' + [string]$chat.VisibleName + '”下载最近 ' + $count + ' 个媒体。普通文字消息会自动忽略。是否继续？'),
            '确认无链接下载',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }

        $state.Phase = 'prepare'
        & $clearError
        try {
            Assert-DirectoryWritable $pathContext.DownloadDirectory
            Ensure-Directory $pathContext.RuntimeDirectory
            $state.ExportPath = Join-Path $pathContext.RuntimeDirectory ("protected-" + [Guid]::NewGuid().ToString('N') + '.json')
            $state.MediaCount = $count
            $state.Phase = 'export'
            $status.ForeColor = [Drawing.Color]::FromArgb(34, 99, 171)
            $progress.Style = 'Marquee'
            $progress.MarqueeAnimationSpeed = 24
            & $setBusy $true "正在从所选聊天查找最近 $count 个媒体……"
            $state.Run = Start-HiddenProcessCapture (Get-ChatExportArguments ([string]$chat.Id) $count $state.ExportPath) 'protected-export'
        }
        catch {
            $state.Run = $null
            & $finishError (Get-FriendlyTdlError $_.Exception.Message -1)
        }
    }.GetNewClosure()

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 350
    $timer.Add_Tick({
        if ($null -eq $state.Run) { return }

        if ($state.Phase -eq 'download') {
            $downloadText = Remove-AnsiCodes (Get-RunText $state.Run)
            $progressMatches = [regex]::Matches($downloadText, '(?<p>\d{1,3}(?:\.\d+)?)%')
            if ($progressMatches.Count -gt 0) {
                $value = [Math]::Min(100, [Math]::Max(0, [int][double]$progressMatches[$progressMatches.Count - 1].Groups['p'].Value))
                $progress.Style = 'Continuous'
                $progress.Value = $value
                $status.Text = "正在下载：$value%"
            }
        }

        if (-not $state.Run.Process.HasExited) { return }

        $run = $state.Run
        $phase = $state.Phase
        $exitCode = -1
        try { $exitCode = $run.Process.ExitCode } catch {}
        Complete-CapturedRun $run
        $stdout = Remove-AnsiCodes (Read-SharedUtf8File $run.StdoutPath)
        $allText = Remove-AnsiCodes (Get-RunText $run)
        try { $run.Process.Dispose() } catch {}
        Remove-CapturedRunFiles $run
        $state.Run = $null

        if ($run.StopRequested) {
            & $finishError '操作已停止。'
            return
        }

        if ($phase -eq 'list') {
            if ($exitCode -ne 0) {
                & $finishError (Get-FriendlyTdlError $allText $exitCode)
                return
            }
            try {
                $state.Chats = @(ConvertFrom-TdlChatListJson $stdout)
                & $renderChats
                $progress.Style = 'Blocks'
                $progress.Value = 0
                $status.ForeColor = [Drawing.Color]::FromArgb(16, 124, 16)
                $botCount = @($state.Chats | Where-Object { [bool]$_.IsBot }).Count
                $status.Text = "已读取 $($state.Chats.Count) 个聊天，其中识别到 $botCount 个机器人。"
                $state.Phase = 'idle'
                & $setBusy $false ''
            }
            catch {
                & $finishError "聊天列表解析失败：$($_.Exception.Message)"
            }
            return
        }

        if ($phase -eq 'export') {
            $exportReady = (-not [string]::IsNullOrWhiteSpace([string]$state.ExportPath) -and
                (Test-Path -LiteralPath $state.ExportPath))
            if ($exitCode -ne 0) {
                & $finishError (Get-FriendlyTdlError $allText $exitCode)
                return
            }
            if (-not $exportReady) {
                & $finishError '没有生成媒体索引，聊天中可能没有可下载的图片、视频或文件。'
                return
            }
            try {
                Ensure-Directory $pathContext.DownloadDirectory
                $state.Phase = 'download'
                $status.Text = '已找到媒体，正在开始下载……'
                $progress.Style = 'Marquee'
                $progress.MarqueeAnimationSpeed = 24
                $state.Run = Start-HiddenProcessCapture (Get-ExportDownloadArguments $state.ExportPath $pathContext.DownloadDirectory) 'protected-download'
            }
            catch {
                $state.Run = $null
                & $finishError (Get-FriendlyTdlError $_.Exception.Message -1)
            }
            return
        }

        if ($phase -eq 'download') {
            if ($exitCode -ne 0) {
                & $finishError (Get-FriendlyTdlError $allText $exitCode)
                return
            }

            & $removeExport
            $state.Phase = 'idle'
            $progress.Style = 'Continuous'
            $progress.Value = 100
            $status.ForeColor = [Drawing.Color]::FromArgb(16, 124, 16)
            $status.Text = "下载完成：已处理最近 $($state.MediaCount) 个媒体。"
            & $clearError
            & $setBusy $false ''
            $completionMessage = "机器人 / 受保护聊天下载完成，已处理最近 $($state.MediaCount) 个媒体。"
            Append-Log $completionMessage
            Show-CompletionNotification $completionMessage
        }
    }.GetNewClosure())

    $refreshButton.Add_Click($startChatList)
    $downloadButton.Add_Click($startDownload)
    $searchBox.Add_TextChanged($renderChats)
    $chatList.Add_SelectedIndexChanged({
        if ($state.Phase -eq 'idle') {
            $downloadButton.Enabled = ($chatList.SelectedItems.Count -gt 0)
        }
    }.GetNewClosure())
    $chatList.Add_DoubleClick({
        if ($chatList.SelectedItems.Count -gt 0 -and $state.Phase -eq 'idle') {
            & $startDownload
        }
    }.GetNewClosure())

    $changeFolderButton.Add_Click({
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description = '选择机器人媒体保存位置'
            $picker.SelectedPath = [string]$pathContext.DownloadDirectory
            if ($picker.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
                Assert-DirectoryWritable $picker.SelectedPath
                $pathContext.DownloadDirectory = $picker.SelectedPath
                Set-DownloadDirectorySetting $picker.SelectedPath
                $destinationLabel.Text = '保存到：' + $picker.SelectedPath
                & $clearError
                $status.Text = '保存目录已更新。'
                $status.ForeColor = [Drawing.Color]::FromArgb(16, 124, 16)
            }
        }
        catch {
            [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '无法使用该目录', 'OK', 'Error')
        }
        finally {
            $picker.Dispose()
        }
    }.GetNewClosure())

    $copyErrorButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace([string]$state.LastError)) { return }
        try {
            [Windows.Forms.Clipboard]::SetText([string]$state.LastError)
            $status.Text = '错误信息已复制，可以直接粘贴给开发者。'
            $status.ForeColor = [Drawing.Color]::FromArgb(16, 124, 16)
        }
        catch {
            $status.Text = '复制失败，请直接截取当前窗口。'
            $status.ForeColor = [Drawing.Color]::FromArgb(196, 43, 28)
        }
    }.GetNewClosure())

    $openFolderButton.Add_Click({
        try {
            Ensure-Directory $pathContext.DownloadDirectory
            [void][Diagnostics.Process]::Start('explorer.exe', (ConvertTo-NativeArgument $pathContext.DownloadDirectory))
        }
        catch {
            [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '无法打开目录', 'OK', 'Error')
        }
    }.GetNewClosure())

    $closeButton.Add_Click({
        $form.Close()
    }.GetNewClosure())

    $form.Add_Shown({
        $timer.Start()
        & $startChatList
    }.GetNewClosure())

    $form.Add_FormClosing({
        if ($null -eq $state.Run) { return }
        $answer = [Windows.Forms.MessageBox]::Show(
            $form,
            '当前操作尚未完成。关闭窗口会停止读取或下载，确定关闭吗？',
            '确认停止',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        Stop-CapturedRun $state.Run
        Complete-CapturedRun $state.Run
        try { $state.Run.Process.Dispose() } catch {}
        Remove-CapturedRunFiles $state.Run
        $state.Run = $null
        & $removeExport
    }.GetNewClosure())

    $form.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
        & $removeExport
    }.GetNewClosure())

    [void]$form.ShowDialog($script:MainForm)
    $form.Dispose()
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
    $proxyHint.Text = '示例：http://127.0.0.1:7890（请按代理软件填写）'
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

    $notifyCheck = New-Object Windows.Forms.CheckBox
    $notifyCheck.Text = '队列完成后显示系统通知'
    $notifyCheck.Location = New-Object Drawing.Point(320, 301)
    $notifyCheck.AutoSize = $true
    $notifyCheck.Checked = [bool]$script:Settings.CompletionNotification
    $form.Controls.Add($notifyCheck)

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
        $script:Settings.CompletionNotification = $notifyCheck.Checked
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
    # tdl prints one terminal QR row per character column pair. A width of 45 therefore
    # produces 23 rows. Refreshed codes can be appended without a textual separator.
    # Do not use $matches here: PowerShell treats it as the automatic $Matches variable.
    $qrRows = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($clean -split "`n")) {
        $candidate = $line.TrimEnd("`r")
        if ($candidate.Length -ge 25 -and $candidate -match '^[█▄▀ ]+$') {
            [void]$qrRows.Add($candidate)
        }
    }
    if ($qrRows.Count -eq 0) { return '' }

    $widthGroup = $qrRows | Group-Object -Property Length | Sort-Object Count -Descending | Select-Object -First 1
    $qrWidth = [int]$widthGroup.Name
    $rowsAtWidth = @($qrRows | Where-Object { $_.Length -eq $qrWidth })
    $rowsPerCode = [int][Math]::Ceiling($qrWidth / 2.0)
    $completeCodeCount = [int][Math]::Floor($rowsAtWidth.Count / [double]$rowsPerCode)
    if ($completeCodeCount -lt 1) { return '' }

    $startIndex = ($completeCodeCount - 1) * $rowsPerCode
    $latestQrRows = @($rowsAtWidth[$startIndex..($startIndex + $rowsPerCode - 1)])
    return ($latestQrRows -join "`r`n")
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
    # tdl renders terminal QR codes for a dark console: spaces are dark modules and blocks are light modules.
    $qrBox.BackColor = [Drawing.Color]::Black
    $qrBox.ForeColor = [Drawing.Color]::White
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
        $loginArguments = Get-LoginArguments
        $script:LoginRun = Start-HiddenProcessCapture $loginArguments 'login'
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
            Remove-CapturedRunFiles $script:LoginRun
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
            Remove-CapturedRunFiles $script:LoginRun
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
    Remove-CapturedRunFiles $testRun
    if ($testExit -ne 0 -or $testOutput -notmatch 'Version') { throw "SELFTEST: tdl version failed ($testExit)" }
    $commonArgumentTest = Get-CommonArguments
    if ($commonArgumentTest -isnot [System.Collections.Generic.List[string]]) {
        throw 'SELFTEST: common arguments are not mutable'
    }
    $loginArgumentTest = Get-LoginArguments
    if ($loginArgumentTest -notcontains 'login' -or $loginArgumentTest -notcontains 'qr') {
        throw 'SELFTEST: login arguments are incomplete'
    }
    $qrWidthTest = 45
    $qrRowsPerCodeTest = [int][Math]::Ceiling($qrWidthTest / 2.0)
    $oldQrLineTest = '█' * $qrWidthTest
    $newQrLineTest = '▄' * $qrWidthTest
    $partialQrLineTest = '▀' * $qrWidthTest
    $oldQrBlockTest = ((1..$qrRowsPerCodeTest | ForEach-Object { $oldQrLineTest }) -join "`r`n")
    $newQrBlockTest = ((1..$qrRowsPerCodeTest | ForEach-Object { $newQrLineTest }) -join "`r`n")
    $partialQrBlockTest = ((1..4 | ForEach-Object { $partialQrLineTest }) -join "`r`n")
    $parsedQrBlockTest = Get-LatestQrBlock ("noise`r`n$oldQrBlockTest`r`n$newQrBlockTest`r`n$partialQrBlockTest")
    if ($parsedQrBlockTest -ne $newQrBlockTest -or ($parsedQrBlockTest -split "`r`n").Count -ne $qrRowsPerCodeTest) {
        throw 'SELFTEST: latest complete QR-code frame was not selected'
    }
    $downloadArgumentTest = Get-DownloadArguments 'https://t.me/c/1000000000/1'
    if ($downloadArgumentTest -notcontains 'dl' -or $downloadArgumentTest -notcontains 'https://t.me/c/1000000000/1') {
        throw 'SELFTEST: download arguments are incomplete'
    }
    $linkExtractionTest = @(Get-TelegramMessageUrls '请下载 t.me/demo_channel/123，另一个是 https://t.me/c/1000000000/456?single。')
    if ($linkExtractionTest.Count -ne 2 -or $linkExtractionTest[0] -ne 'https://t.me/demo_channel/123') {
        throw 'SELFTEST: Telegram link extraction failed'
    }
    $chatJsonTest = '[{"id":123,"type":"private","visible_name":"示例机器人","username":"sample_helper_bot"},{"id":456,"type":"group","visible_name":"示例群"}]'
    $chatListTest = @(ConvertFrom-TdlChatListJson $chatJsonTest)
    if ($chatListTest.Count -ne 2 -or -not $chatListTest[0].IsBot -or $chatListTest[1].IsBot -or $chatListTest[1].Username -ne '') {
        throw 'SELFTEST: chat list parsing or bot detection failed'
    }
    $chatExportTest = Get-ChatExportArguments '123' 1 'D:\temp\protected.json'
    if ($chatExportTest -notcontains 'export' -or $chatExportTest -notcontains 'last' -or $chatExportTest -notcontains '123') {
        throw 'SELFTEST: protected chat export arguments are incomplete'
    }
    $customDownloadDirectoryTest = 'D:\temp\custom downloads'
    $fileDownloadTest = Get-ExportDownloadArguments 'D:\temp\protected.json' $customDownloadDirectoryTest
    if ($fileDownloadTest -notcontains '-f' -or
        $fileDownloadTest -notcontains 'D:\temp\protected.json' -or
        $fileDownloadTest -notcontains $customDownloadDirectoryTest) {
        throw 'SELFTEST: exported file download arguments are incomplete'
    }
    Assert-DirectoryWritable $script:RuntimeDir
    $protectedPathContextTest = [pscustomobject]@{
        RuntimeDirectory  = [string]$script:RuntimeDir
        DownloadDirectory = [string]$script:Settings.DownloadDirectory
    }
    $protectedPathClosureTest = { return $protectedPathContextTest }.GetNewClosure()
    $protectedPathValues = & $protectedPathClosureTest
    if ([string]::IsNullOrWhiteSpace([string]$protectedPathValues.RuntimeDirectory) -or
        [string]::IsNullOrWhiteSpace([string]$protectedPathValues.DownloadDirectory)) {
        throw 'SELFTEST: protected dialog paths were lost inside closure'
    }
    if ((Get-FriendlyTdlError 'no downloadable messages' 1) -notmatch '没有找到') {
        throw 'SELFTEST: no-media error was not translated'
    }
    $redactedErrorTest = Get-FriendlyTdlError ('failure in ' + $script:AppDir) 1
    if ($redactedErrorTest -match [regex]::Escape($script:AppDir)) {
        throw 'SELFTEST: local path was not removed from diagnostic text'
    }
    if ([int]$script:Settings.Threads -lt 1 -or [int]$script:Settings.Threads -gt 16 -or
        [int]$script:Settings.Limit -lt 1 -or [int]$script:Settings.Limit -gt 8 -or
        [int]$script:Settings.RetryCount -lt 0 -or [int]$script:Settings.RetryCount -gt 5) {
        throw 'SELFTEST: settings were not normalized'
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
$script:MainForm.MinimumSize = New-Object Drawing.Size(1016, 774)
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
$subtitleLabel.Text = "v$script:AppVersion · 中文窗口 · 多链接队列 · 自动重试 · 无命令框"
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
$privacyLabel.Text = '聊天资料仅在本机使用'
$privacyLabel.Location = New-Object Drawing.Point(725, 42)
$privacyLabel.Size = New-Object Drawing.Size(220, 22)
$privacyLabel.Anchor = 'Top,Right'
$privacyLabel.TextAlign = 'MiddleRight'
$privacyLabel.ForeColor = [Drawing.Color]::Gray
$loginPanel.Controls.Add($privacyLabel)

Update-LoginIndicator

$linkGroup = New-Object Windows.Forms.GroupBox
$linkGroup.Text = '有消息链接时粘贴到这里；无链接请使用右侧机器人下载'
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
$pasteButton.Location = New-Object Drawing.Point(728, 25)
$pasteButton.Size = New-Object Drawing.Size(216, 27)
$pasteButton.Anchor = 'Top,Right'
$linkGroup.Controls.Add($pasteButton)

$addButton = New-Object Windows.Forms.Button
$addButton.Text = '加入链接队列'
$addButton.Location = New-Object Drawing.Point(728, 57)
$addButton.Size = New-Object Drawing.Size(216, 27)
$addButton.Anchor = 'Top,Right'
$addButton.BackColor = [Drawing.Color]::FromArgb(0, 120, 212)
$addButton.ForeColor = [Drawing.Color]::White
$addButton.FlatStyle = 'Flat'
$linkGroup.Controls.Add($addButton)

$protectedButton = New-Object Windows.Forms.Button
$protectedButton.Text = '机器人 / 无链接下载'
$protectedButton.Location = New-Object Drawing.Point(728, 89)
$protectedButton.Size = New-Object Drawing.Size(216, 27)
$protectedButton.Anchor = 'Top,Right'
$protectedButton.BackColor = [Drawing.Color]::FromArgb(111, 66, 193)
$protectedButton.ForeColor = [Drawing.Color]::White
$protectedButton.FlatStyle = 'Flat'
$linkGroup.Controls.Add($protectedButton)

$queueLabel = New-Object Windows.Forms.Label
$queueLabel.Text = '下载队列'
$queueLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI', 10, [Drawing.FontStyle]::Bold)
$queueLabel.Location = New-Object Drawing.Point(20, 236)
$queueLabel.AutoSize = $true
$content.Controls.Add($queueLabel)

$script:QueueSummaryLabel = New-Object Windows.Forms.Label
$script:QueueSummaryLabel.Text = '共 0 条 · 等待 0 · 下载中 0 · 失败 0 · 完成 0'
$script:QueueSummaryLabel.Location = New-Object Drawing.Point(120, 235)
$script:QueueSummaryLabel.Size = New-Object Drawing.Size(860, 24)
$script:QueueSummaryLabel.Anchor = 'Top,Left,Right'
$script:QueueSummaryLabel.TextAlign = 'MiddleRight'
$script:QueueSummaryLabel.ForeColor = [Drawing.Color]::DimGray
$content.Controls.Add($script:QueueSummaryLabel)

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

$queueMenu = New-Object Windows.Forms.ContextMenuStrip
$openMessageMenu = New-Object Windows.Forms.ToolStripMenuItem('打开 Telegram 原消息')
$retryMessageMenu = New-Object Windows.Forms.ToolStripMenuItem('重试选中项')
$removeMessageMenu = New-Object Windows.Forms.ToolStripMenuItem('移除选中项')
[void]$queueMenu.Items.Add($openMessageMenu)
[void]$queueMenu.Items.Add($retryMessageMenu)
[void]$queueMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$queueMenu.Items.Add($removeMessageMenu)
$script:QueueList.ContextMenuStrip = $queueMenu

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

$removeButton = New-Object Windows.Forms.Button
$removeButton.Text = '移除选中项'
$removeButton.Location = New-Object Drawing.Point(515, 3)
$removeButton.Size = New-Object Drawing.Size(120, 36)
$buttonPanel.Controls.Add($removeButton)

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
                    $script:LinkBox.AppendText([Environment]::NewLine + $clip)
                }
                $script:LinkBox.Focus()
                $script:LinkBox.SelectionStart = $script:LinkBox.TextLength
            }
        }
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($script:MainForm, '读取剪贴板失败，请直接按 Ctrl+V。', '剪贴板', 'OK', 'Warning')
    }
})

$addButton.Add_Click({
    $urls = @(Get-TelegramMessageUrls $script:LinkBox.Text)
    if ($urls.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show(
            $script:MainForm,
            '没有识别到 Telegram 消息链接。请粘贴形如 https://t.me/频道名/123 的单条消息链接。',
            '未找到消息链接',
            'OK',
            'Information'
        )
        return
    }

    $added = 0
    foreach ($url in $urls) {
        if (Add-QueueUrl $url) { $added++ }
    }
    $skipped = $urls.Count - $added
    $script:LinkBox.Clear()
    $summary = "已加入 $added 个链接"
    if ($skipped -gt 0) { $summary += "，跳过 $skipped 个重复项" }
    Append-Log ($summary + '。')
    Update-QueueSummary

    if ($added -gt 0 -and [bool]$script:Settings.AutoStart) {
        $script:DownloadPaused = $false
        Start-NextDownload
    }
})

$script:LinkBox.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        $addButton.PerformClick()
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

$retryButton.Add_Click({ Retry-SelectedQueueItems })
$removeButton.Add_Click({ Remove-SelectedQueueItems })

$clearButton.Add_Click({
    $remove = @()
    foreach ($row in $script:QueueList.Items) {
        if ($row.Tag.Status -eq '已完成') { $remove += $row }
    }
    foreach ($row in $remove) { $script:QueueList.Items.Remove($row) }
    Save-Queue
    Update-QueueSummary
    if ($remove.Count -gt 0) { Append-Log "已清理 $($remove.Count) 个已完成项目。" }
})

$openMessageMenu.Add_Click({ Open-SelectedTelegramMessage })
$retryMessageMenu.Add_Click({ Retry-SelectedQueueItems })
$removeMessageMenu.Add_Click({ Remove-SelectedQueueItems })
$script:QueueList.Add_DoubleClick({ Open-SelectedTelegramMessage })
$script:QueueList.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::Delete) {
        $_.SuppressKeyPress = $true
        Remove-SelectedQueueItems
    }
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
$protectedButton.Add_Click({ Show-ProtectedChatDialog })
$loginButton.Add_Click({ Show-LoginDialog })
$script:AccountRefreshButton.Add_Click({ Start-AccountRefresh })
$helpButton.Add_Click({
    $helpText = "tdl Chinese GUI v$script:AppVersion" +
        [Environment]::NewLine + [Environment]::NewLine +
        '1. 首次使用先点右上角【登录 / 更换账号】扫码。' + [Environment]::NewLine +
        '2. 有消息链接时可粘贴链接或整段聊天文字，程序会自动识别。' + [Environment]::NewLine +
        '3. 机器人不提供消息链接时，点击【机器人 / 无链接下载】。' + [Environment]::NewLine +
        '4. 选择机器人，默认下载最近 1 个媒体；普通文字会自动忽略。' + [Environment]::NewLine +
        '5. 链接队列支持重试、移除和打开原消息。' + [Environment]::NewLine +
        '6. 下载失败会按设置自动重试，完成后可显示系统通知。' +
        [Environment]::NewLine + [Environment]::NewLine +
        '提示：账号必须能访问原消息；已经被删除或无权限的文件无法下载。' +
        [Environment]::NewLine + [Environment]::NewLine +
        '原项目：iyear/tdl' + [Environment]::NewLine +
        'https://github.com/iyear/tdl' + [Environment]::NewLine +
        '本程序是非官方中文图形界面，核心下载能力及相关权利归原作者与贡献者所有。'
    [void][Windows.Forms.MessageBox]::Show(
        $script:MainForm,
        $helpText,
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
            $safeLine = [regex]::Replace($line, '(?i)https?://(?:t\.me|telegram\.me)/[^\s]+', '[Telegram 消息链接]')
            Append-Log $safeLine
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
    Remove-StaleRuntimeFiles
    Load-AccountCache
    Update-LoginIndicator
    Load-Queue
    Append-Log "tdl Chinese GUI v$script:AppVersion 已启动。"

    if (-not (Test-TdlReady)) {
        if (-not $script:MainForm.IsDisposed) {
            $script:StatusLabel.Text = '缺少 tdl.exe，请运行一键安装器'
        }
        return
    }

    Show-FirstRunWelcome
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
    }
    $pollTimer.Stop()
    $pollTimer.Dispose()
    if ($null -ne $script:ActiveRun) {
        Complete-CapturedRun $script:ActiveRun
        try { $script:ActiveRun.Process.Dispose() } catch {}
        Remove-CapturedRunFiles $script:ActiveRun
    }
    if ($null -ne $script:AccountRun) {
        Stop-AccountRefresh
    }
    if ($null -ne $script:NotifyTimer) {
        $script:NotifyTimer.Stop()
        $script:NotifyTimer.Dispose()
    }
    if ($null -ne $script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
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


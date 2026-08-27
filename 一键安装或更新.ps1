# Upstream: https://github.com/iyear/tdl
# Downloads the official tdl release; tdl is licensed under GNU AGPL v3.0.
param(
    [switch]$Launch,
    [string]$Proxy = '',
    [switch]$NoDesktopShortcut,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$TdlVersion = 'v0.20.4'
$TdlVersionNumber = '0.20.4'
$ArchiveName = 'tdl_Windows_64bit.zip'
$ExpectedSha256 = '3f219779c07a4be628c34491b9910c18a3b0a0ca0b0aa4f283bb83ab33b007c8'
$DownloadUrl = "https://github.com/iyear/tdl/releases/download/$TdlVersion/$ArchiveName"
$TdlExecutablePath = Join-Path $AppDirectory 'tdl.exe'
$TemporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('tdl-chinese-gui-' + [Guid]::NewGuid().ToString('N'))
$ArchivePath = Join-Path $TemporaryDirectory $ArchiveName
$ExtractDirectory = Join-Path $TemporaryDirectory 'extract'
$NewLine = [Environment]::NewLine

Add-Type -AssemblyName System.Windows.Forms

function Show-Result {
    param(
        [string]$Message,
        [string]$Title,
        [System.Windows.Forms.MessageBoxIcon]$Icon
    )
    [void][System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', $Icon)
}

function New-LauncherShortcut {
    param([string]$ShortcutPath)
    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $Shortcut.Arguments = '"' + (Join-Path $AppDirectory '启动中文版下载器.vbs') + '"'
    $Shortcut.WorkingDirectory = $AppDirectory
    $Shortcut.Description = 'Telegram 文件下载器（中文版）'
    $Shortcut.Save()
}

function Test-InstalledTdlVersion {
    if (-not (Test-Path -LiteralPath $TdlExecutablePath)) { return $false }
    try {
        $versionOutput = (& $TdlExecutablePath version 2>&1 | Out-String)
        return ($LASTEXITCODE -eq 0 -and $versionOutput -match [regex]::Escape($TdlVersionNumber))
    }
    catch {
        return $false
    }
}

function Invoke-TdlDownload {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "正在从 tdl 官方仓库下载 $TdlVersion（第 $attempt/3 次）……"
            $request = @{
                Uri             = $DownloadUrl
                OutFile         = $ArchivePath
                UseBasicParsing = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
                $request.Proxy = $Proxy
            }
            Invoke-WebRequest @request
            return
        }
        catch {
            if ($attempt -eq 3) { throw }
            Write-Host '下载失败，稍后自动重试……'
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

try {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw '当前安装器仅支持 64 位 Windows。'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [void](New-Item -ItemType Directory -Path (Join-Path $AppDirectory 'downloads') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $AppDirectory 'gui-runtime') -Force)

    $Downloaded = $false
    if (-not $Force -and (Test-InstalledTdlVersion)) {
        Write-Host "已安装 tdl $TdlVersion，无需重复下载。"
    }
    else {
        [void](New-Item -ItemType Directory -Path $TemporaryDirectory -Force)
        [void](New-Item -ItemType Directory -Path $ExtractDirectory -Force)
        Invoke-TdlDownload

        $ActualSha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualSha256 -ne $ExpectedSha256) {
            throw "下载文件校验失败。期望：$ExpectedSha256，实际：$ActualSha256"
        }

        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDirectory -Force
        $TdlExecutable = Get-ChildItem -LiteralPath $ExtractDirectory -Filter 'tdl.exe' -Recurse | Select-Object -First 1
        if ($null -eq $TdlExecutable) {
            throw '压缩包中没有找到 tdl.exe。'
        }

        Copy-Item -LiteralPath $TdlExecutable.FullName -Destination $TdlExecutablePath -Force
        if (-not (Test-InstalledTdlVersion)) {
            throw 'tdl.exe 已复制，但版本检查未通过。'
        }
        $Downloaded = $true
    }

    foreach ($fileName in @('tdl.exe', 'tdl-gui.ps1', '启动中文版下载器.vbs', '一键安装或更新.ps1', '一键安装或更新.bat')) {
        $filePath = Join-Path $AppDirectory $fileName
        if (Test-Path -LiteralPath $filePath) {
            try { Unblock-File -LiteralPath $filePath } catch {}
        }
    }

    $LocalShortcut = Join-Path $AppDirectory 'Telegram下载器（中文版）.lnk'
    New-LauncherShortcut $LocalShortcut

    $DesktopShortcutCreated = $false
    if (-not $NoDesktopShortcut) {
        $DesktopDirectory = [Environment]::GetFolderPath('Desktop')
        if (-not [string]::IsNullOrWhiteSpace($DesktopDirectory)) {
            try {
                New-LauncherShortcut (Join-Path $DesktopDirectory 'Telegram下载器（中文版）.lnk')
                $DesktopShortcutCreated = $true
            }
            catch {
                Write-Host '桌面快捷方式创建失败，但不影响软件使用。'
            }
        }
    }

    $ActionText = if ($Downloaded) { '安装完成。' } else { '检查完成，当前已经是所需版本。' }
    $SuccessMessage = $ActionText + $NewLine + $NewLine +
        'tdl 版本：' + $TdlVersion + $NewLine +
        '安装目录：' + $AppDirectory + $NewLine +
        '本地快捷方式：已创建'
    if ($DesktopShortcutCreated) {
        $SuccessMessage += $NewLine + '桌面快捷方式：已创建'
    }
    elseif (-not $NoDesktopShortcut) {
        $SuccessMessage += $NewLine + '桌面快捷方式：未创建，可使用安装目录中的快捷方式'
    }
    Show-Result $SuccessMessage 'tdl Chinese GUI' ([System.Windows.Forms.MessageBoxIcon]::Information)

    if ($Launch) {
        $launcher = Join-Path $AppDirectory '启动中文版下载器.vbs'
        [void][Diagnostics.Process]::Start('wscript.exe', ('"' + $launcher + '"'))
    }
}
catch {
    $FailureMessage = '安装失败：' + $NewLine + $NewLine + $_.Exception.Message +
        $NewLine + $NewLine +
        '如果 GitHub 无法访问，可在 PowerShell 中指定代理后重试：' + $NewLine +
        "powershell -ExecutionPolicy Bypass -File .\一键安装或更新.ps1 -Proxy 'http://127.0.0.1:7890' -Launch" +
        $NewLine + $NewLine +
        '更多排查方法请查看 docs\FAQ.md。'
    Show-Result $FailureMessage 'tdl Chinese GUI' ([System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
finally {
    if (Test-Path -LiteralPath $TemporaryDirectory) {
        Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force
    }
}
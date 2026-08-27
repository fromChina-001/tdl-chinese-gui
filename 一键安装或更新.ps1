# Upstream: https://github.com/iyear/tdl
# Downloads the official tdl release; tdl is licensed under GNU AGPL v3.0.
param(
    [switch]$Launch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$TdlVersion = 'v0.20.4'
$ArchiveName = 'tdl_Windows_64bit.zip'
$ExpectedSha256 = '3f219779c07a4be628c34491b9910c18a3b0a0ca0b0aa4f283bb83ab33b007c8'
$DownloadUrl = "https://github.com/iyear/tdl/releases/download/$TdlVersion/$ArchiveName"
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

try {
    [void](New-Item -ItemType Directory -Path $TemporaryDirectory -Force)
    [void](New-Item -ItemType Directory -Path $ExtractDirectory -Force)

    Write-Host "正在从 tdl 官方仓库下载 $TdlVersion，请稍候……"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchivePath -UseBasicParsing

    $ActualSha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "下载文件校验失败。期望：$ExpectedSha256，实际：$ActualSha256"
    }

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDirectory -Force
    $TdlExecutable = Get-ChildItem -LiteralPath $ExtractDirectory -Filter 'tdl.exe' -Recurse | Select-Object -First 1
    if ($null -eq $TdlExecutable) {
        throw '压缩包中没有找到 tdl.exe。'
    }

    Copy-Item -LiteralPath $TdlExecutable.FullName -Destination (Join-Path $AppDirectory 'tdl.exe') -Force
    [void](New-Item -ItemType Directory -Path (Join-Path $AppDirectory 'downloads') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $AppDirectory 'gui-runtime') -Force)

    $LocalShortcut = Join-Path $AppDirectory 'Telegram下载器（中文版）.lnk'
    New-LauncherShortcut $LocalShortcut

    $DesktopDirectory = [Environment]::GetFolderPath('Desktop')
    if (-not [string]::IsNullOrWhiteSpace($DesktopDirectory)) {
        New-LauncherShortcut (Join-Path $DesktopDirectory 'Telegram下载器（中文版）.lnk')
    }

    $SuccessMessage = '安装完成。' + $NewLine + $NewLine + 'tdl 版本：' + $TdlVersion + $NewLine + '目录：' + $AppDirectory
    Show-Result $SuccessMessage 'tdl Chinese GUI' ([System.Windows.Forms.MessageBoxIcon]::Information)

    if ($Launch) {
        [void][Diagnostics.Process]::Start('wscript.exe', ('"' + (Join-Path $AppDirectory '启动中文版下载器.vbs') + '"'))
    }
}
catch {
    $FailureMessage = '安装失败：' + $NewLine + $NewLine + $_.Exception.Message
    Show-Result $FailureMessage 'tdl Chinese GUI' ([System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}
finally {
    if (Test-Path -LiteralPath $TemporaryDirectory) {
        Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force
    }
}
# tdl Chinese GUI

[简体中文](README.md) · [FAQ (Chinese)](docs/FAQ.md) · [Issues](https://github.com/fromChina-001/tdl-chinese-gui/issues) · [Upstream tdl](https://github.com/iyear/tdl)

A Windows GUI wrapper for [iyear/tdl](https://github.com/iyear/tdl), designed for users who prefer a Chinese graphical interface over the command line.

![Application screenshot](assets/screenshot.png)

## Upstream project and attribution

Telegram login, message resolution, and file transfer are provided by **[iyear/tdl](https://github.com/iyear/tdl)**.

- Upstream project: [iyear/tdl](https://github.com/iyear/tdl)
- Original author: [iyear](https://github.com/iyear) and tdl contributors
- Tested upstream version: [tdl v0.20.4](https://github.com/iyear/tdl/releases/tag/v0.20.4)
- Upstream license: [GNU AGPL v3.0](https://github.com/iyear/tdl/blob/master/LICENSE)
- This repository: an unofficial Windows Chinese GUI for tdl

This repository contains the independent GUI and installer only. The installer downloads tdl.exe from the official upstream GitHub Release and verifies its SHA-256 checksum. See [UPSTREAM.md](UPSTREAM.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Highlights in v1.3.3

- Chinese Windows GUI with no visible console
- First-run guide and missing-core recovery
- Telegram QR-code login and account status
- Extracts multiple Telegram message URLs from pasted text
- Downloads recent media from bots and protected chats without requiring a message URL
- Handles chats that do not expose a public username
- Shows and changes the no-link download destination with a write preflight
- Provides stage-specific errors, copyable diagnostics, and completion notifications
- Persistent queue with retry, remove, open-original, and status counts
- Friendly error summaries and optional completion notifications
- Configurable download directory, proxy, threads, and concurrency
- Media-group downloading and duplicate-file skipping

## Install

Download and extract this repository, then double-click **一键安装或更新.bat**. Keep the extracted folder after installation. The installer downloads the tested tdl v0.20.4 Windows x64 release and creates shortcuts.

For a network that requires an HTTP proxy:

~~~powershell
powershell -ExecutionPolicy Bypass -File .\一键安装或更新.ps1 -Proxy 'http://127.0.0.1:7890' -Launch
~~~

## Usage

1. Click **登录 / 更换账号** and scan the QR code from Telegram.
2. Paste message URLs or text containing several message URLs.
3. Click **加入链接队列**, or press **Ctrl+Enter**.
4. For a bot or protected chat without message links, click **机器人 / 无链接下载**, select the chat, and download its most recent media.
5. Double-click a linked queue item to open the original message; press **Delete** to remove selected items.

## Privacy and limitations

Telegram sessions, account cache, message URLs, settings, temporary logs, downloaded media, and tdl.exe are excluded from Git. Never upload your **.tdl** session directory.

This project does not bypass Telegram access controls and cannot restore media that is no longer accessible to the signed-in account. Use it only for content you are authorized to save.

## License

AGPL-3.0. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
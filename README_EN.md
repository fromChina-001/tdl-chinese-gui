# tdl Chinese GUI

[简体中文](README.md) · [Issues](https://github.com/fromChina-001/tdl-chinese-gui/issues) · [Upstream tdl](https://github.com/iyear/tdl)

A Windows GUI wrapper for [iyear/tdl](https://github.com/iyear/tdl), designed for users who prefer a Chinese graphical interface over the command line.

![Application screenshot](assets/screenshot.png)

## Upstream project and attribution

The Telegram login, message resolution, and file-transfer capabilities are provided by the upstream open-source project **[iyear/tdl](https://github.com/iyear/tdl)**.

- Upstream project: [iyear/tdl](https://github.com/iyear/tdl)
- Original author: [iyear](https://github.com/iyear) and tdl contributors
- Tested upstream version: [tdl v0.20.4](https://github.com/iyear/tdl/releases/tag/v0.20.4)
- Upstream license: [GNU AGPL v3.0](https://github.com/iyear/tdl/blob/master/LICENSE)
- This repository: an unofficial Windows Chinese GUI for tdl

This project does not claim ownership of the tdl core or brand. It contains the independent GUI and installer only; tdl.exe is downloaded from the official upstream GitHub Release. See [UPSTREAM.md](UPSTREAM.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Highlights

- Chinese Windows GUI with no visible console window
- Telegram QR-code login inside the application
- Account name, Telegram user ID, and connection status
- Multi-link queue with continuous sequential downloads
- Automatic retry and persistent unfinished queue
- Configurable download directory, proxy, threads, and concurrency
- Media-group downloading and duplicate-file skipping
- Works with chats and media the signed-in account is authorized to access

## Install

Download and extract the repository, then double-click **一键安装或更新.bat**. The installer downloads the tested tdl v0.20.4 Windows x64 release from the official GitHub repository and verifies its SHA-256 checksum.

## Privacy

Telegram sessions, account cache, message URLs, settings, logs, downloaded media, and tdl.exe are excluded from Git. Never upload your **.tdl** session directory.

## Limitations

This project does not bypass Telegram access controls and cannot restore media that is no longer accessible to the signed-in account. Use it only for content you are authorized to save.

## License

AGPL-3.0. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
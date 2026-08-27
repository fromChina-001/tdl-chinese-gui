# 原项目出处与分工说明

## 上游项目

本项目使用 [iyear/tdl](https://github.com/iyear/tdl) 作为 Telegram 登录、消息解析和文件下载引擎。

- 项目名称：tdl
- 上游仓库：https://github.com/iyear/tdl
- 原作者：https://github.com/iyear
- 贡献者：https://github.com/iyear/tdl/graphs/contributors
- 本项目已测试版本：https://github.com/iyear/tdl/releases/tag/v0.20.4
- 上游许可证：https://github.com/iyear/tdl/blob/master/LICENSE
- 许可证名称：GNU Affero General Public License v3.0

所有与 tdl 原始代码、可执行程序和品牌有关的权利，归 tdl 原作者及贡献者所有。

## 本项目提供的内容

tdl Chinese GUI 是一个独立的非官方 Windows 界面层，主要提供：

- 中文 Windows 图形界面
- 二维码登录窗口
- 多消息链接下载队列
- 自动重试与队列保存
- 下载设置与账号状态展示
- 从上游官方 Release 下载并校验 tdl 的安装脚本

本仓库不直接提交或重新打包 tdl.exe。安装器从上游官方 GitHub Release 获取指定版本，以便用户可以明确识别下载来源。

## 无隶属关系声明

本项目不是 Telegram 官方客户端，不隶属于 Telegram，也不是 iyear/tdl 的官方图形界面。项目名称中使用 tdl 仅用于说明兼容关系和技术依赖。

## 许可证

本项目采用 AGPL-3.0，以保持与上游 tdl 的许可证方向一致。使用、修改和再发布前，请同时阅读本仓库的 LICENSE 与上游许可证。
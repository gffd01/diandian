# S-UI 纯净源码版

本仓库基于 [Teminuosi/s-ui](https://github.com/Teminuosi/s-ui) 和
[Teminuosi/s-ui-frontend](https://github.com/Teminuosi/s-ui-frontend) 构建。

保留 Teminuosi 版本的面板、节点、中转、服务器管理、多节点、API、安装、升级和
`SUI_AUTO=1` 自动配置逻辑，仅从前端源码删除以下推广入口：

- 官网/博客链接
- YouTube 频道链接
- VPS/机器推荐链接
- 作者推广入口及对应文案

具体上游提交记录在 [`.upstream-versions`](.upstream-versions) 中。前端已作为普通源码放在
`frontend/`，不再依赖单独的 Git 子模块。

## 一键安装

支持 Debian、Ubuntu 等采用 systemd 的 Linux 系统。请使用 root 用户执行：

```bash
SUI_AUTO=1 bash <(curl -fsSL https://raw.githubusercontent.com/gffd01/diandian/main/install.sh)
```

命令会自动识别服务器架构、下载本仓库最新稳定 Release、安装或升级 S-UI，并沿用上游的
自动生成账号、面板路径、端口、API Token、开放防火墙和启动服务逻辑。

如需恢复上游交互式安装方式：

```bash
SUI_AUTO=0 bash <(curl -fsSL https://raw.githubusercontent.com/gffd01/diandian/main/install.sh)
```

## 源码构建

每次源码更新后，GitHub Actions 会构建前端和 Linux 静态后端，并发布可供 `install.sh`
下载的稳定 Release。当前构建目标与上游安装脚本一致：`amd64`、`arm64`、`armv7`、
`armv6`、`armv5`、`386` 和 `s390x`。

## 同步上游

在 GitHub Actions 中手动运行 **Import and clean upstream source**，即可重新拉取两个
Teminuosi 上游仓库、再次应用纯净补丁、写入完整源码并启动发布构建。如果上游前端结构发生
变化，脚本会停止而不是静默遗漏推广内容，便于先检查再适配。

## 许可

后端沿用仓库中的 GPL-3.0 `LICENSE`。各依赖及前端源码遵循其各自上游许可。本仓库仅维护
上述纯净化修改和自动构建安装流程。

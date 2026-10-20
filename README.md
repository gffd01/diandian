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

支持 Debian、Ubuntu 等采用 systemd 的 Linux 系统。请使用 root 用户复制整行执行：

```bash
curl --fail --location --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/gffd01/diandian/secure-installer-v1/install.sh -o /tmp/s-ui-secure-install.sh && echo 'a0bd39f561097a950b9b312a1344a016f6892a45e2b5985608fc25013ca2f645  /tmp/s-ui-secure-install.sh' | sha256sum --check - && chmod 700 /tmp/s-ui-secure-install.sh && SUI_AUTO=1 /tmp/s-ui-secure-install.sh clean-15
```

命令会先验证安装脚本；只有显示 `/tmp/s-ui-secure-install.sh: OK` 才会继续。随后自动识别服务器
架构，下载并校验 `clean-15` Release，然后安装或升级 S-UI。
新装时会生成随机账号、密码、面板路径和空闲端口。默认采用 `direct` 模式，可直接通过
`http://服务器IP:面板端口/随机路径/` 登录；如果主机启用了 UFW 或 firewalld，安装器只开放
面板端口、订阅端口及 `SUI_NODE_PORTS` 明确指定的节点端口。集中管理 API Token 默认有效 30 天。

如需先查看源码再执行：

```bash
git clone --depth=1 --branch secure-installer-v1 --single-branch https://github.com/gffd01/diandian.git
cd diandian
less install.sh
SUI_AUTO=1 ./install.sh clean-15
```

公网直连、SSH 隧道、集中管理、限时 API Token、防火墙和网络优化说明见
[部署说明](SECURE_INSTALL.md)。安装器不包含地区、服务商或固定服务器 IP，适用于采用 systemd
的常见 Debian、Ubuntu 等 Linux VPS。

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

# BBR 直连/落地优化脚本

## 用法

```bash
sudo bash bbr-direct-tune.sh
sudo bash bbr-direct-tune.sh apply
sudo bash bbr-direct-tune.sh restore
bash bbr-direct-tune.sh status
bash bbr-direct-tune.sh --help
```

## 运行环境

建议在 Debian/Ubuntu 系 Linux VPS 上运行。

基本要求：

- `root` 权限，应用优化和恢复都需要 `sudo` 或 root。
- `bash`，脚本使用 Bash 语法。
- `systemd`，用于开机恢复 `tc fq`、MSS clamp 等配置。
- 常见系统命令：`sysctl`、`ip`、`awk`、`sed`、`grep`、`tar`、`mktemp`、`du`、`free`。
- 可选命令：`tc`、`iptables`、`curl` 或 `wget`、`modinfo`、`speedtest`。

内核要求：

- 当前内核需要支持 `bbr`，否则 `net.ipv4.tcp_congestion_control=bbr` 不会真正生效。
- 如果需要 BBR v3，需要先自行安装并切换到支持 BBR v3 的内核。本脚本不安装内核。

不太适合的环境：

- OpenVZ、LXC、Docker 等权限受限容器，部分 `sysctl`、`tc`、`iptables`、RPS 参数可能无法写入。
- 没有 `systemd` 的精简系统。
- 非 root 用户直接运行。

## 主要行为

脚本会交互式检测/选择上传带宽，根据地区计算 TCP 缓冲区，然后写入并应用 BBR/FQ 直连优化参数。

会涉及这些系统位置：

- `/etc/sysctl.d/99-bbr-ultimate.conf`
- `/etc/sysctl.conf`，仅注释冲突 TCP 参数并生成备份
- `/etc/systemd/system/bbr-optimize-persist.service`
- `/usr/local/bin/bbr-optimize-apply.sh`
- `/etc/security/limits.conf`
- `/swapfile` 和 `/etc/fstab`，仅当你确认配置 SWAP 时

`restore` 会清理由本脚本创建的 sysctl 配置、systemd 持久化服务、恢复脚本、iptables MSS clamp 规则，以及 `limits.conf` 中带有本脚本标记的文件描述符配置块。若发现 `/etc/sysctl.conf.bak.original`，会询问是否恢复。

## 验证

```bash
bash bbr-direct-tune.sh status
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
systemctl status bbr-optimize-persist.service --no-pager
```

预期结果：拥塞控制为 `bbr`，队列算法为 `fq`，缓冲区最大值与脚本计算的 MB 数对应。

## 注意

该脚本不安装内核。若当前内核不支持 BBR 或 BBR v3，需要先自行安装/切换支持的内核并重启。

# Padavan 平台层（MI-R3G）

小米路由器 3G（MI-R3G，Padavan 固件）上的部署脚本与开机钩子。
**它们属于 `ap-relay` 的一部分**：配置模板、渲染/校验/应用/刷新脚本都在仓库
根目录共用，这里只保留 Padavan 特有的运行时层。

> 原 `mihomo-padavan` 仓库已并入这里，只保留 git 历史作存档。

## 目标环境

| 项 | 值 |
|---|---|
| 设备 | 小米路由器 3G（MI-R3G） |
| 固件 | Padavan（不刷 OpenWrt） |
| 持久分区 | `/media/mtd_rwfs`（UBIFS，RWFS） |
| 部署目录 | `/media/mtd_rwfs/mihomo`，另建软链 `/etc/mihomo` |
| 模式 | `redirect`（iptables REDIRECT），可切 `tun` |
| 端口 | 1008 mixed / 1009 redir / 1053 DNS / 7070 面板 |

## 目录与设备路径

| 仓库路径 | 设备路径 | 说明 |
|---|---|---|
| `scripts/mihomo-*.sh`（仓库根） | `/etc/storage/` | 两台设备共用的渲染/校验/应用/刷新/热重载 |
| `platforms/padavan/scripts/*.sh` | `/etc/storage/` | Padavan 特有的启动/守护/防火墙/路由 |
| `platforms/padavan/mihomo.conf` | `/etc/storage/mihomo.conf` | 平台变量（无凭据） |
| （本机创建） | `/etc/storage/mihomo.local.conf` | `SECRET` + `SUB_URL`，权限 600 |
| `platforms/padavan/hooks/started_script.sh` | `/etc/storage/started_script.sh` | 开机后拉 mihomo |
| `platforms/padavan/hooks/post_iptables_script.sh` | `/etc/storage/post_iptables_script.sh` | 防火墙重载后补规则 |
| `templates/mihomo.config.yaml` | `/media/mtd_rwfs/mihomo/mihomo.config.yaml.tpl` | 与手机共用同一份模板（路由器没有 `/usr/local`） |

运行时文件（不入库）：

```
/media/mtd_rwfs/mihomo/
├── mihomo              二进制
├── geoip.metadb        GeoIP 库（geo-auto-update 依赖它）
├── config.yaml         由模板渲染，含 secret → 权限 600
├── cache.db
├── enabled             存在才自启
├── mode                redirect / tun
├── providers/
│   └── juzi.yaml       订阅节点（type: http 自动更新）
└── ui/                 zashboard 构建产物
```

## 日志

mihomo 本身只按 `log-level` 往 stdout 打日志，本项目没有配日志文件，
由 `mihomo-run.sh` 用 `>>` 重定向到：

```
/tmp/mihomo.log      当前写入
/tmp/mihomo.log.1    上一轮快照
```

`/tmp` 是 tmpfs，两个文件占的是内存。轮转规则：

| 项目 | 值 |
|---|---|
| 检查间隔 | **30 秒**（`mihomo-run.sh` 里的后台循环） |
| 单文件上限 | **3 MB**（`MIHOMO_LOG_MAX`，默认 3145728 字节） |
| 保留代数 | **1 代**（只覆盖 `.1`，不累积 `.2` / `.3`） |
| 合计上限 | ≈ **6 MB** + 最多 30 秒的新增量 |

- 轮转是 **copytruncate**：先 `cp` 出副本，再原地 `: >` 截断。**不能用 `mv`** ——
  stdout 是 `O_APPEND` 打开的，`mv` 之后内核会继续往旧 inode 追加，新文件永远是空的。
  实现见 `mihomo-env.sh` 的 `padavan_rotate_log()`。
- `mihomo-start.sh` 启动时也调同一个函数归档，所以跨重启同样是 2 个文件、不累积。
- 阈值可以用环境变量临时覆盖，做验证不必改代码：

  ```sh
  MIHOMO_LOG_MAX=4096 /etc/storage/mihomo-start.sh   # 4 KB 触发，几十秒内就能看到轮转
  ```

- 告警量的大头是 `direct` 模式下失败拨号的 `dial ... i/o timeout`。真要减量，
  把 `mihomo.conf` 里的 `LOG_LEVEL` 从 `warning` 降到 `error`，然后
  `mihomo-reload.sh`（`log-level` 是运行时项，不用重启）。

## 脚本职责

### Padavan 特有（本目录）

| 脚本 | 作用 |
|---|---|
| `mihomo-env.sh` | 平台环境层（被 source）。持久分区/PID/日志路径、端口（读 `mihomo.conf`）、链名、`padavan_*` 小工具、日志轮转 `padavan_rotate_log()` |
| `mihomo-start.sh` | 启动入口。加锁防并发、等 RWFS 挂载、检查 `enabled`、建 `/etc/mihomo` 软链、调 `mihomo-run.sh` |
| `mihomo-run.sh` | 守护外壳。退出最多重试 3 次，失败保持直连；旁边跑一个 30 秒周期的日志轮转循环 |
| `mihomo-stop.sh` | 停进程，等端口释放，清 nat 链和 TUN 路由 |
| `mihomo-fw.sh` | 防火墙 `up`/`down`。`redirect` 走 nat REDIRECT，`tun` 只劫持 DNS |
| `mihomo-tun-route.sh` | TUN 模式策略路由，只把 `iif br0` 的转发流量导进 `meta` |
| `mihomo-mode.sh` | `show` / `tun` / `redirect`；同时改 `config.yaml` 与 `mihomo.conf` 的 `TUN_ENABLE`，避免下次渲染覆盖 |
| `mihomo-edit.sh` | 编辑 `/etc/storage` 下脚本，退出后语法检查，失败自动回滚 |
| `mihomo-save.sh` | 检查 `mihomo-*.sh`、`mihomo.conf`、`.local.conf`、两个钩子的语法，全部通过才写 flash |
| `mihomo-sysctl.sh` | 设置临时端口范围（幂等，开机和每次启动都补） |

### 两台设备共用（仓库根 `scripts/`）

| 脚本 | 作用 |
|---|---|
| `mihomo-vars.sh` | 配置层：载入平台配置 + `.local.conf`，补默认值；不含任何凭据 |
| `mihomo-lib.sh` | 能力层：定位配置/二进制、读 secret、重启、等端口、调用 REST API |
| `mihomo-render.sh` | 把模板里的 `${VAR}` 渲染成 `config.yaml`（无常量猜替换、原子替换、权限 600） |
| `mihomo-verify.sh` | 结构自检 + `mihomo -t` + provider 必须是 `type: http` |
| `mihomo-apply.sh` | 渲染 → 校验 → 备份 → 替换 → 重启 → 等端口；失败自动回滚 |
| `mihomo-refresh.sh` | 立刻刷新 provider（`PUT /providers/proxies/<name>`），不用等 `interval` |
| `mihomo-reload.sh` | 校验后 `PUT /configs?force=true` 热重载；`-f` 失败时回退完整重启 |

> `mihomo-update.sh` / `mihomo-provider.sh` 已删除：`type: http` 由内核自己按
> `interval` 下载，外部脚本再写 `providers/*.yaml` 会被立刻覆盖。

## 部署（修改路由器前先读）

```sh
# 1. 变量与凭据
cp platforms/padavan/mihomo.conf /etc/storage/mihomo.conf
cat > /etc/storage/mihomo.local.conf <<'EOF'
SECRET='CHANGE_ME'
SUB_URL='https://example.com/link/CHANGE_ME?clash=1'
EOF
chmod 600 /etc/storage/mihomo.local.conf

# 2. 共用脚本 + Padavan 脚本
cp scripts/mihomo-*.sh /etc/storage/
cp platforms/padavan/scripts/*.sh /etc/storage/
chmod 755 /etc/storage/mihomo-*.sh

# 3. 模板（路由器没有 /usr/local，放 RWFS）
cp templates/mihomo.config.yaml /media/mtd_rwfs/mihomo/mihomo.config.yaml.tpl

# 4. 先看会改什么（不会动线上配置）
/etc/storage/mihomo-apply.sh --dry-run

# 5. 真正生效（渲染 + 校验 + 备份 + 重启 + 等端口）
/etc/storage/mihomo-apply.sh

# 6. 刷新订阅、确认是 HTTP provider
/etc/storage/mihomo-refresh.sh
```

钩子只需在 `started_script.sh` / `post_iptables_script.sh` 末尾保留这几行：

```sh
/etc/storage/mihomo-sysctl.sh
/etc/storage/mihomo-start.sh &

[ -f /tmp/mihomo.pid ] && /etc/storage/mihomo-fw.sh up >/dev/null 2>&1
```

最后写 flash（先做语法检查）：

```sh
/etc/storage/mihomo-save.sh
```

## 日常操作

```sh
pidof mihomo
netstat -lnt | grep -E ':(1008|1009|1053|7070)'

/etc/storage/mihomo-mode.sh show
/etc/storage/mihomo-refresh.sh          # 立刻拉一次订阅
/etc/storage/mihomo-reload.sh           # 只改了规则/分组时热重载
/etc/storage/mihomo-apply.sh           # 改了 mihomo.conf 后重新渲染并重启
/etc/storage/mihomo-stop.sh
```

## 为什么配置能两台共用

模板只有 25 个 `${VAR}`，平台的差异全部落在变量文件里：

| 变量 | 手机（TUN） | 路由器（redirect） |
|---|---|---|
| `REDIR_LINE` | 注释掉 | `redir-port: 1009` |
| `DNS_LISTEN` | `127.0.0.1:1053` | `0.0.0.0:1053` |
| `SNIFFER_OVERRIDE_DESTINATION` | `false` | `true` |
| `SNIFFER_HTTP_PORTS` | `[80, 8080-8880]` | `[80, 8080]` |
| `TUN_ENABLE` | `true` | `false` |
| `TUN_STACK` | `mixed` | `gvisor` |
| `TUN_AUTO_DETECT_INTERFACE` | `true` | `false` |

其余（`proxy-groups` 与 5384 条 `rules`）两台逐字节一致。

## 安全约定

- 本目录与模板**不含**真实 `secret`、订阅地址、Wi-Fi 密码或 SSH 私钥。
- 凭据只写 `/etc/storage/mihomo.local.conf`（600）；`config.yaml` 由渲染脚本强制 600。
- `config.yaml`、`providers/`、`ui/`、二进制、GeoIP 都不入库。
- 提交前自查：

  ```sh
  grep -rniE 'secret|password|passwd|psk|token|api[-_]?key|BEGIN .*PRIVATE KEY' --exclude-dir=.git .
  ```

## 坑与经验

Padavan 侧的踩坑记录已移到 [`docs/pitfalls_padavan_zh.md`](../../docs/pitfalls_padavan_zh.md)。

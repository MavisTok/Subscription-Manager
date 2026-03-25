# 订阅管理工具 (Subscription Manager)

> 服务器端订阅拉取 & GitHub 自动推送工具，支持定时调度、消息通知、Telegram Bot 远程控制与敏感信息加密存储。

---

## 一键安装

**Linux 服务器 / WSL（国内推荐走镜像）：**

```bash
bash <(curl -fsSL --connect-timeout 8 --max-time 30 https://ghfast.top/https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main/install.sh)
```

**macOS：**

```bash
bash <(curl -fsSL --connect-timeout 8 --max-time 30 https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main/install.sh)
```

> 需要 Homebrew，安装时会自动调用 `brew install` 安装依赖。
> 安装目录：`~/.sub-manager`（无需 sudo）

**Windows（Git Bash）：**

```bash
bash <(curl -fsSL --connect-timeout 8 --max-time 30 https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main/install.sh)
```

> 需要 Git Bash，`curl` / `git` / `jq` 通常已内置。
> 安装目录：`~/.sub-manager`

**Windows（PowerShell）：**

```powershell
# 先查找 bash.exe 路径（运行一次即可）
Get-Command bash -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
# 如果上面有输出，直接运行：
bash -c 'bash <(curl -fsSL --connect-timeout 8 --max-time 30 https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main/install.sh)'
# 如果提示找不到 bash，用完整路径（把路径替换为你的 Git 安装位置）：
& "D:\Git\bin\bash.exe" -c 'bash <(curl -fsSL --connect-timeout 8 --max-time 30 https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main/install.sh)'
```

> 也可以直接打开 **Git Bash** 终端运行上方 Git Bash 命令。
> 安装时自动通过 **Task Scheduler** 配置每分钟定时检查（开机自启）。

**OpenWrt：**

```bash
wget -O /tmp/install.sh "https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main/install.sh" && sh /tmp/install.sh
```

> 安装程序自动检测 OpenWrt，通过 opkg 安装 bash 及依赖（`curl` `git` `git-http` `jq`），定时任务通过 BusyBox crond 启用。

---

> 依赖安装失败时自动切换阿里云 / 清华 / 中科大 / 华为云镜像重试。
> 直连 GitHub 失败自动切换 `ghfast.top` 加速镜像。

---

## 启动方式

```bash
bash /opt/sub-manager/sub-manager.sh   # 直接运行
subm                                    # 全局别名（重新登录后生效）
su                                      # 安装时选择了 su 重定向后可用
```

**Windows 额外启动方式：**

```powershell
# PowerShell（自动定位 bash.exe，无需手动配置）
~/.sub-manager/sub-manager.ps1

# Git Bash
bash ~/.sub-manager/sub-manager.sh
```

---

## 功能说明

### 1. 拉取任务管理

| 功能 | 说明 |
| ---- | ---- |
| 添加任务 | 保存订阅链接、名称、拉取间隔(分钟)、备注、自定义 User-Agent |
| 编辑任务 | 修改 URL、名称、间隔、备注、User-Agent |
| 启用/禁用 | 不删除任务的情况下暂停调度 |
| 导出配置 | 导出为 JSON 文件，便于迁移备份 |
| 导入配置 | 支持合并（追加）或替换两种模式 |

本地文件保存路径：`/opt/sub-manager/data/task_<id>.txt`

#### User-Agent 自动轮换

添加任务时可留空 User-Agent，拉取遇到 `403` 时自动依次尝试：

```text
clash-meta/2.4.0 → clash.meta → ClashforWindows → ClashForAndroid → ClashX → Clash → v2rayN → sing-box → Quantumult X → Surge
```

> `clash-meta/2.4.0` 为首选 UA，与主流订阅平台（如喵喵屋）默认格式一致，兼容性最广。

也可手动指定固定 UA（如 `clash.meta`），只使用该值不轮换。

#### 自定义请求头

订阅链接需要 Token 或 Cookie 时，可在添加/编辑任务中设置（`|` 分隔多个）：

```text
Authorization:Bearer xxxxxxxx|Cookie:session=abc
```

#### 拉取代理

云服务器 IP 被订阅服务商封锁时，可配置 SOCKS5/HTTP 代理转发拉取请求：

- **全局代理**：主菜单 → 「4. 拉取代理配置」，对所有任务生效
- **任务独立代理**：添加/编辑任务时设置，优先级高于全局代理

支持格式：

```text
socks5://127.0.0.1:7890
socks5://user:pass@host:port
http://127.0.0.1:7890
```

#### 403 诊断

全部 UA 均失败时，程序会自动打印服务端响应体片段并给出排查建议：

```text
✗ 全部 UA 均返回 403
── 服务端最后响应 ──
  {"code":403,"msg":"IP not allowed"}
────────────────────
排查建议:
  1. 检查订阅链接是否已过期
  2. 编辑任务 → 自定义请求头 (如 Authorization:Bearer xxx)
  3. 在浏览器打开链接，用开发者工具查看请求头后填入
```

### 2. GitHub 推送

- 配置多个仓库，每个仓库可关联多个拉取任务
- 支持自定义推送分支与远端文件名
- **变化检测**：与仓库现有文件 diff 比较，无变化自动跳过，避免无效 commit
- 仓库不存在时自动初始化并首次推送

GitHub Token 需要 `repo` 权限，在 GitHub → Settings → Developer settings → Personal access tokens 创建。

### 3. 敏感信息加密

所有敏感字段（订阅 URL、GitHub Token、Bot Token、Bark Key 等）使用 **AES-256-CBC** 加密存储，密钥绑定本机。

- 密钥文件：`$INSTALL_DIR/.keyfile`（仅本机可读，chmod 600）
- 加密值以 `enc:` 前缀存储于 JSON 配置文件
- 首次运行时自动迁移已有明文配置
- 依赖 `openssl`，不可用时静默回退明文存储

### 4. 消息通知

| 渠道 | 配置项 | 说明 |
| ---- | ------ | ---- |
| Telegram | Bot Token + Chat ID | 通过 @BotFather 创建 Bot |
| Bark (iOS) | Bark Key + Server | iOS 推送，App Store 下载 Bark |
| Webhook | URL + HTTP 方法 | 企业微信/钉钉/飞书等 |
| PushPlus | Token | 微信公众号推送，[pushplus.plus](https://www.pushplus.plus) |
| Server酱 | SendKey | 微信推送，[sct.ftqq.com](https://sct.ftqq.com)，自动适配 SC3/SCT |

触发时机：订阅内容变化时（拉取成功且内容有更新） / 拉取失败

### 5. 定时调度

安装时自动按平台选择最优调度方式：

| 平台 | 调度方式 | 说明 |
| ---- | -------- | ---- |
| Linux (systemd) | systemd timer | 每60秒，开机自启 |
| Linux (无systemd) | crontab | 每分钟检查 |
| macOS | launchd (LaunchAgent) | 每60秒，开机自启 |
| Windows | Task Scheduler | 每分钟，开机自启，`.bat` 包装器 |
| OpenWrt | BusyBox crond | 每分钟检查 |

可通过菜单「系统设置」随时启用 / 禁用 / 查看状态。

**手动停止调度：**

| 平台 | 命令 |
| ---- | ---- |
| Linux (systemd) | `systemctl --user disable --now sub-manager.timer` |
| Linux (cron) / OpenWrt | `crontab -l \| grep -v sub-manager \| crontab -` |
| macOS | `launchctl unload ~/Library/LaunchAgents/com.sub-manager.plist` |
| Windows | `schtasks /Delete /F /TN "SubManager"` |

临时终止正在运行的进程：`pkill -f "sub-manager.sh --cron-check"`

### 6. Telegram Bot 远程控制

通过 Telegram Bot 远程管理订阅，无需登录服务器。支持**多客户端**部署，每个客户端设置唯一名称，通过 `@客户端名` 定向发送指令。

**配置：** 主菜单 → 「8. Telegram Bot」→ 设置 Bot Token、Chat ID 和客户端名称

**支持的命令：**

| 命令 | 说明 |
| ---- | ---- |
| `/help` | 显示所有命令 |
| `/status` | 查看运行状态（任务数、仓库数、版本） |
| `/clients` | 列出所有在线客户端 |
| `/tasks` | 列出所有拉取任务 |
| `/repos` | 列出所有 GitHub 仓库 |
| `/run <id>` | 立即执行指定任务（全流程：拉取→推送→通知） |
| `/toggle <id>` | 启用或禁用指定任务 |
| `/push <id>` | 立即推送指定仓库 |
| `/logs` | 查看最近日志 |
| `/addtask` | 多步骤交互添加拉取任务 |
| `/addrepo` | 多步骤交互添加 GitHub 仓库 |
| `/cancel` | 取消当前多步骤操作 |

**多客户端定向指令：**

```text
@服务器A /run 1       # 只让「服务器A」执行
@服务器B /tasks       # 只查询「服务器B」的任务列表
/status               # 所有客户端响应
```

**启动方式：**

```bash
# 前台运行（调试）
sub-manager.sh --bot

# 后台守护（菜单启动）
主菜单 → 8. Telegram Bot → 启动 Bot (后台守护)
```

Bot 仅响应配置的 Chat ID，其他用户的消息会被忽略。

### 7. 更新机制

脚本启动时自动检测新版本并弹出交互提示：

```text
  检查更新中...
  ★ 发现新版本 v1.4.0（当前 v1.3.11）

  1. 立即更新
  0. 跳过，进入主界面
```

选择 **1** 立即下载更新，选择 **0** 跳过直接进入主界面。无网络或已是最新版本时自动跳过。

「系统设置」中也可手动执行：

| 操作 | 说明 |
| ---- | ---- |
| 检查并更新 | 对比版本 → 下载主程序及所有模块 → 语法校验 → 备份旧版 → 替换 → 自动重启 |
| 回滚到上一版本 | 用备份文件还原，适合更新出问题时使用 |

CLI 直接更新（无需进菜单）：

```bash
sub-manager.sh --update          # 直接执行更新
sub-manager.sh --check-update    # 只检查是否有新版本
```

> **从 v1.3.7 及以下（单文件旧版本）升级时**，启动新版本会自动检测到 `lib/` 模块缺失并在线下载，无需手动重装。

### 8. WebDAV 同步

将所有配置打包为单个 JSON 备份文件，通过 WebDAV 上传/下载，实现跨机器迁移或定期备份。

**支持的服务：** Nextcloud / ownCloud / Seafile / 群晖 WebStation / 坚果云 / 任何标准 WebDAV 服务

**配置：** 主菜单 → 「9. WebDAV 同步」→「1. 配置 WebDAV 服务器」

| 操作 | 说明 |
| ---- | ---- |
| 立即备份配置 | 将 tasks / repos / notify / settings 打包 → AES-256-CBC 加密 → 上传到 WebDAV |
| 从备份恢复配置 | 下载备份文件 → 用备份密码解密 → 校验格式 → 覆盖本地配置 |
| 测试连接 | 发送 PROPFIND 请求验证 WebDAV 服务可达性与认证 |

**备份流程：**

```text
4 个 JSON 配置文件
    → jq 打包为单个 JSON 包
        → openssl AES-256-CBC 加密（使用独立备份密码）
            → curl PUT 上传到 WebDAV（默认路径 .enc）
```

**配置项说明：**

| 字段 | 说明 |
| ---- | ---- |
| WebDAV 地址 | 服务器根地址，如 `https://dav.example.com/dav/` |
| 用户名 / WebDAV 密码 | WebDAV 认证凭据，无认证留空 |
| 远端备份路径 | 备份文件在 WebDAV 上的存储路径，默认 `/sub-manager-backup.enc` |
| 备份加密密码 | 独立于 WebDAV 密码，用于加密备份文件内容，**必须设置** |

> 备份文件本身为二进制密文，没有正确密码无法读取。内部敏感字段同时保有 `enc:...` 双重加密。跨机迁移时需在新机器上重新输入敏感字段（Token、密码等），因各机 `.keyfile` 不同。

---

## 系统兼容性

| 平台 | 发行版 / 环境 | 包管理器 | 安装目录 |
| ---- | ------------- | -------- | -------- |
| Linux (root) | Ubuntu / Debian | apt-get | `/opt/sub-manager` |
| Linux (root) | CentOS / RHEL / Rocky / AlmaLinux | yum / dnf | `/opt/sub-manager` |
| Linux (root) | Fedora | dnf | `/opt/sub-manager` |
| Linux (root) | Alpine | apk | `/opt/sub-manager` |
| Linux (root) | Arch / Manjaro | pacman | `/opt/sub-manager` |
| Linux (non-root) | 任意 | 同上 | `~/.sub-manager` |
| macOS | Homebrew | brew | `~/.sub-manager` |
| Windows | Git Bash / WSL（Task Scheduler 自动配置） | winget / 手动 | `~/.sub-manager` |
| **OpenWrt** | 21.02 及以上 | opkg | `/opt/sub-manager` |

依赖：`curl` `git` `jq`（自动安装，Linux 支持阿里云 / 清华 / 中科大 / 华为云镜像回退）

**在本机（macOS/Windows/OpenWrt）运行的优势：** 订阅服务商通常只封锁云服务器 IP，本地宽带 IP 不受影响，可绕过 403 限制。

---

## 文件结构

**仓库源码：**

```text
Subscription-Manager/
├── sub-manager.sh          # 主程序入口（版本号、模块加载、主菜单、CLI 参数）
├── sub-manager.ps1         # Windows PowerShell 启动器
├── install.sh              # 一键安装脚本
├── lib/
│   ├── core.sh             # 基础设施：OS检测、路径变量、颜色、加密(AES-256)、配置初始化
│   ├── tasks.sh            # 拉取任务管理（增删改查、导入导出）
│   ├── repos.sh            # GitHub 仓库配置与推送
│   ├── notify.sh           # 消息通知（Telegram / Bark / Webhook）
│   ├── proxy.sh            # 代理配置
│   ├── fetch.sh            # 订阅拉取（UA轮换、403诊断、自定义请求头）
│   ├── scheduler.sh        # 定时调度（cron/launchd/systemd/schtasks）、日志、系统设置
│   ├── update.sh           # 版本检测与更新、回滚
│   ├── bot.sh              # Telegram Bot（多客户端、命令路由、状态机）
│   └── webdav.sh           # WebDAV 同步（备份/恢复配置）
└── .githooks/
    ├── pre-commit          # 自动 bump 版本号（PATCH/MINOR/MAJOR）
    └── prepare-commit-msg  # commit 消息追加版本号标记
```

**安装后目录（以 `/opt/sub-manager` 为例）：**

```text
/opt/sub-manager/
├── sub-manager.sh          # 主程序
├── sub-manager.sh.bak      # 更新前的备份（自动生成）
├── sub-manager.ps1         # Windows PowerShell 启动器（仅 Windows）
├── cron-check.bat          # Windows Task Scheduler 包装器（仅 Windows）
├── .keyfile                # AES 加密密钥（chmod 600，仅本机可读）
├── lib/                    # 功能模块（同仓库 lib/）
├── config/
│   ├── tasks.json          # 拉取任务配置（敏感字段已加密）
│   ├── repos.json          # GitHub 仓库配置（敏感字段已加密）
│   ├── notify.json         # 消息推送配置（敏感字段已加密）
│   └── webdav.json         # WebDAV 同步配置（密码已加密，按需创建）
├── data/
│   └── task_<id>.txt       # 本地订阅文件
└── logs/
    ├── main.log
    ├── error.log
    ├── cron.log
    └── bot.log
```

---

## su 快捷入口

安装时可选择将无参数 `su` 重定向为打开管理界面：

```bash
su          # 无参数 → 打开订阅管理工具
su root     # 有参数 → 正常切换用户（不受影响）
su -        # 同上
```

---

## CLI 参数

```bash
sub-manager.sh                  # 打开交互界面
sub-manager.sh --cron-check     # 检查并执行到期任务（由定时任务调用）
sub-manager.sh --run-task <id>  # 立即执行指定任务
sub-manager.sh --update         # 直接执行更新
sub-manager.sh --check-update   # 检查是否有新版本
sub-manager.sh --status         # 显示状态摘要
sub-manager.sh --bot            # 启动 Telegram Bot（前台）
```

---

## 常见问题

### PowerShell 报错 `无法将"bash"项识别为 cmdlet`

原因：Git 的 `bin` 目录不在系统 PATH 中，PowerShell 找不到 `bash.exe`。

**解决方法（任选一种）：**

1. **直接打开 Git Bash 终端**（推荐）：在开始菜单搜索 `Git Bash` 打开，然后运行安装命令。

2. **在 PowerShell 中用完整路径**：先找到 bash.exe 的位置：

   ```powershell
   # 方法一：通过 git 位置推断
   (Get-Command git).Source -replace '\\cmd\\git\.exe$', '\bin\bash.exe'
   # 方法二：全盘搜索（较慢）
   Get-ChildItem -Path C:\,D:\ -Filter bash.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
   ```

   找到路径后用 `&` 调用：

   ```powershell
   & "D:\Git\bin\bash.exe" -c 'bash <(curl -fsSL ... install.sh)'
   ```

3. **将 Git 的 bin 目录加入 PATH**（一劳永逸）：

   ```powershell
   # 查看当前 Git 安装位置
   (Get-Command git).Source
   # 假设输出 D:\Git\cmd\git.exe，则将 D:\Git\bin 加入系统 PATH：
   # 设置 → 系统 → 高级系统设置 → 环境变量 → Path → 新建 → 添加 D:\Git\bin
   # 重启 PowerShell 后 bash 命令即可直接使用
   ```

### PowerShell 报错 `"<"运算符是为将来使用而保留的`

原因：`bash <(...)` 是 Bash 的进程替换语法，PowerShell 不支持。

**解决方法：** 使用 `bash -c '...'` 包裹整个命令，或直接打开 Git Bash 终端运行。

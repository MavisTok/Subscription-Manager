# 订阅管理工具 (Subscription Manager)

> 服务器端订阅拉取 & GitHub 自动推送工具，支持定时调度与消息通知。

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

---

> 依赖安装失败时自动切换阿里云 / 清华 / 中科大等镜像重试。
> `sub-manager.sh` 找不到时自动从 GitHub 下载，无需手动上传。

---

## 启动方式

```bash
bash /opt/sub-manager/sub-manager.sh   # 直接运行
subm                                    # 全局别名（重新登录后生效）
su                                      # 安装时选择了 su 重定向后可用
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

### 3. 消息通知

| 渠道 | 配置项 |
| ---- | ------ |
| Telegram | Bot Token + Chat ID |
| Bark (iOS) | Bark Key + Server |
| Webhook | URL + HTTP 方法 (POST/GET) |

触发时机：拉取成功 / 拉取失败 / 推送成功 / 推送失败

### 4. 定时调度

- 安装时自动添加 Cron 条目（每分钟检查一次）
- 按每个任务独立设置的间隔判断是否到期执行
- 可通过菜单「系统设置」随时启用或禁用

### 5. Telegram Bot 远程控制

通过 Telegram Bot 远程管理订阅，无需登录服务器。

**配置：** 主菜单 → 「8. Telegram Bot」→ 设置 Bot Token 和 Chat ID

**支持的命令：**

| 命令 | 说明 |
| ---- | ---- |
| `/help` | 显示所有命令 |
| `/status` | 查看运行状态（任务数、仓库数、版本） |
| `/tasks` | 列出所有拉取任务 |
| `/repos` | 列出所有 GitHub 仓库 |
| `/run <id>` | 立即执行指定任务（全流程：拉取→推送→通知） |
| `/toggle <id>` | 启用或禁用指定任务 |
| `/push <id>` | 立即推送指定仓库 |
| `/logs` | 查看最近日志 |
| `/addtask` | 多步骤交互添加拉取任务 |
| `/addrepo` | 多步骤交互添加 GitHub 仓库 |
| `/cancel` | 取消当前多步骤操作 |

**启动方式：**

```bash
# 前台运行（调试）
sub-manager.sh --bot

# 后台守护（菜单启动）
主菜单 → 8. Telegram Bot → 启动 Bot (后台守护)
```

Bot 仅响应配置的 Chat ID，其他用户的消息会被忽略。

### 6. 更新机制

主菜单启动时后台静默检测，有新版本时顶部显示提示：

```text
★ 发现新版本 1.2.0，前往「系统设置」→「检查并更新」
```

「系统设置」中可执行：

| 操作 | 说明 |
| ---- | ---- |
| 检查并更新 | 对比版本 → 下载 → 语法校验 → 备份旧版 → 替换 → 自动重启 |
| 回滚到上一版本 | 用备份文件还原，适合更新出问题时使用 |

直连 GitHub 失败自动切换 `ghfast.top` 加速镜像。替换前自动备份为 `sub-manager.sh.bak`。

CLI 直接更新（无需进菜单）：

```bash
sub-manager.sh --update          # 直接执行更新
sub-manager.sh --check-update    # 只检查是否有新版本
```

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
| Windows | Git Bash / WSL | winget / 手动 | `~/.sub-manager` |

依赖：`curl` `git` `jq`（自动安装，Linux 支持阿里云 / 清华 / 中科大 / 华为云镜像回退）

**在本机（macOS/Windows）运行的优势：** 订阅服务商通常只封锁云服务器 IP，本地宽带 IP 不受影响，可绕过 403 限制。

---

## 文件结构

```text
/opt/sub-manager/
├── sub-manager.sh         # 主程序
├── sub-manager.sh.bak     # 更新前的备份（自动生成）
├── config/
│   ├── tasks.json         # 拉取任务配置
│   ├── repos.json         # GitHub 仓库配置
│   └── notify.json        # 消息推送配置
├── data/
│   └── task_<id>.txt      # 本地订阅文件
└── logs/
    ├── main.log
    ├── error.log
    └── cron.log
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
sub-manager.sh --cron-check     # 检查并执行到期任务（由 cron 调用）
sub-manager.sh --run-task <id>  # 立即执行指定任务
sub-manager.sh --update         # 直接执行更新
sub-manager.sh --check-update   # 检查是否有新版本
sub-manager.sh --status         # 显示状态摘要
```

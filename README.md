# 订阅管理工具 (Subscription Manager)

> 服务器端订阅拉取 & GitHub 自动推送工具，支持定时调度与消息通知。

---

## 文件结构

```text
/opt/sub-manager/          # 安装目录
├── sub-manager.sh         # 主程序
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

## 快速部署

将 `install.sh` 和 `sub-manager.sh` 上传到服务器同一目录，执行：

```bash
sudo bash install.sh
```

安装完成后启动：

```bash
# 方式一：直接运行
bash /opt/sub-manager/sub-manager.sh

# 方式二：全局别名（重新登录后生效）
subm

# 方式三：若安装时选择了 su 重定向
su
```

---

## 功能说明

### 1. 拉取任务管理

| 功能 | 说明 |
| ---- | ---- |
| 添加任务 | 保存订阅链接、名称、拉取间隔(分钟)、备注 |
| 编辑任务 | 修改 URL、名称、间隔、备注 |
| 启用/禁用 | 不删除任务的情况下暂停调度 |
| 导出配置 | 导出为 JSON 文件，便于迁移备份 |
| 导入配置 | 支持合并（追加）或替换两种模式 |

本地文件保存路径：`/opt/sub-manager/data/task_<id>.txt`

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

---

## 系统兼容性

安装脚本自动检测发行版并使用对应包管理器安装依赖：

| 发行版 | 包管理器 |
| ------ | -------- |
| Ubuntu / Debian | apt-get |
| CentOS / RHEL / Rocky / AlmaLinux | yum / dnf |
| Fedora | dnf |
| Alpine | apk |
| Arch / Manjaro | pacman |
| openSUSE | zypper |

依赖：`curl` `git` `jq`（安装脚本自动安装）

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
sub-manager.sh --status         # 显示状态摘要
```

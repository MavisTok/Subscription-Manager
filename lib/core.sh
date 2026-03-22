# lib/core.sh

# ── OS 检测 ────────────────────────────────────────────────
case "$(uname -s 2>/dev/null)" in
    Darwin)         OS_TYPE="macos"   ;;
    MINGW*|MSYS*|CYGWIN*) OS_TYPE="windows" ;;
    *)              OS_TYPE="linux"   ;;
esac
readonly OS_TYPE

# ── 安装目录（支持环境变量覆盖） ───────────────────────────
if [[ -n "${SUB_MANAGER_DIR:-}" ]]; then
    INSTALL_DIR="$SUB_MANAGER_DIR"
elif [[ "$OS_TYPE" == "linux" && "${EUID:-$(id -u)}" -eq 0 ]]; then
    INSTALL_DIR="/opt/sub-manager"
else
    # macOS / Windows / 非 root Linux 均使用 home 目录
    INSTALL_DIR="${HOME}/.sub-manager"
fi
readonly INSTALL_DIR
readonly KEY_FILE="${INSTALL_DIR}/.keyfile"
readonly CONFIG_DIR="${INSTALL_DIR}/config"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly LOG_DIR="${INSTALL_DIR}/logs"
readonly TASKS_FILE="${CONFIG_DIR}/tasks.json"
readonly REPOS_FILE="${CONFIG_DIR}/repos.json"
readonly NOTIFY_FILE="${CONFIG_DIR}/notify.json"
readonly SETTINGS_FILE="${CONFIG_DIR}/settings.json"

# ── 颜色 ──────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; NC='\033[0m'

# ── 跨平台兼容包装 ─────────────────────────────────────────

# 文件大小（macOS wc -c 输出含前导空格）
_filesize() { wc -c < "$1" | tr -d ' \t'; }

# 提取响应体可打印内容（替代 strings，macOS/Windows 可能无此命令）
_printable() { tr -cd '[:print:]\n' < "$1" | head -5; }

# sed -i 跨平台（macOS BSD sed 需要 ''）
_sed_i() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# crontab 命令（Windows Git Bash 无 crontab）
_has_cron() { command -v crontab &>/dev/null; }

# ── 工具函数 ───────────────────────────────────────────────
log() {
    local level="$1" msg="$2"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$LOG_DIR"
    echo "[$ts][$level] $msg" >> "${LOG_DIR}/main.log"
    echo "[$ts][$level] $msg" >> "${LOG_DIR}/$(echo "$level" | tr '[:upper:]' '[:lower:]').log"
}

press_enter() { echo ""; read -rp "  按 Enter 键继续..." _; }

clear_screen() { clear 2>/dev/null || printf '\033[2J\033[H'; }

print_header() {
    local title="${1:-订阅管理工具}"
    echo -e "${C}╔══════════════════════════════════════════════╗${NC}"
    printf "${C}║${NC}  ${W}%-44s${NC}${C}║${NC}\n" "$title"
    echo -e "${C}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

print_line() { echo -e "${C}──────────────────────────────────────────────${NC}"; }

read_input() {
    local prompt="$1" default="${2:-}" result
    if [[ -n "$default" ]]; then
        read -rp "  $prompt [$default]: " result
        echo "${result:-$default}"
    else
        read -rp "  $prompt: " result
        echo "$result"
    fi
}

confirm() {
    local prompt="${1:-确认操作}" answer
    read -rp "  $prompt [y/N]: " answer
    [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" == "y" ]]
}

# ══════════════════════════════════════════════════════════
#  加密工具（AES-256-CBC, openssl）
#  敏感字段在 JSON 中以 "enc:BASE64..." 格式存储
# ══════════════════════════════════════════════════════════

# 初始化密钥文件（首次运行自动生成随机密钥）
_enc_init() {
    command -v openssl &>/dev/null || return 1
    if [[ ! -f "$KEY_FILE" ]]; then
        openssl rand -hex 32 > "$KEY_FILE" 2>/dev/null || return 1
        chmod 600 "$KEY_FILE" 2>/dev/null
    fi
    return 0
}

# 加密明文值，返回 "enc:BASE64..." 或原值（openssl 不可用时）
_enc() {
    local val="$1"
    [[ -z "$val" || "$val" == "null" ]] && { echo "$val"; return; }
    [[ "${val:0:4}" == "enc:" ]] && { echo "$val"; return; }  # 已加密
    local key; key=$(cat "$KEY_FILE" 2>/dev/null)
    [[ -z "$key" ]] && { echo "$val"; return; }  # 无密钥则原文返回
    local out
    out=$(printf '%s' "$val" | \
        openssl enc -aes-256-cbc -pbkdf2 -pass "pass:${key}" -a -A 2>/dev/null) || {
        echo "$val"; return
    }
    echo "enc:${out}"
}

# 解密值，返回明文；非加密值原样返回；解密失败返回空
_dec() {
    local val="$1"
    [[ -z "$val" || "$val" == "null" ]] && { echo ""; return; }
    [[ "${val:0:4}" != "enc:" ]] && { echo "$val"; return; }  # 未加密，原样返回
    local encrypted="${val:4}"
    local key; key=$(cat "$KEY_FILE" 2>/dev/null)
    [[ -z "$key" ]] && { echo ""; return; }
    printf '%s' "$encrypted" | \
        openssl enc -aes-256-cbc -pbkdf2 -pass "pass:${key}" -a -A -d 2>/dev/null
}

# 脱敏显示：解密后取首4位+****+末2位
_mask() {
    local val; val=$(_dec "$1")
    [[ -z "$val" ]] && { echo "（未设置）"; return; }
    local len=${#val}
    if   [[ $len -le 4 ]];  then echo "****"
    elif [[ $len -le 8 ]];  then echo "${val:0:2}****"
    else                          echo "${val:0:4}****${val: -2}"
    fi
}

# 将现有配置文件中的明文敏感字段一次性加密（升级迁移）
_enc_migrate_configs() {
    _enc_init || return 0  # openssl 不可用则跳过

    local tmp val enc_val

    # tasks.json: url, headers
    if [[ -f "$TASKS_FILE" ]]; then
        local count; count=$(jq '.tasks | length' "$TASKS_FILE" 2>/dev/null || echo 0)
        local i=0
        while [[ $i -lt $count ]]; do
            for field in url headers; do
                val=$(jq -r ".tasks[$i].${field} // \"\"" "$TASKS_FILE" 2>/dev/null)
                if [[ -n "$val" && "$val" != "null" && "${val:0:4}" != "enc:" ]]; then
                    enc_val=$(_enc "$val")
                    tmp=$(mktemp)
                    jq --argjson idx "$i" --arg f "$field" --arg v "$enc_val" \
                       '.tasks[$idx][$f] = $v' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
                fi
            done
            i=$((i+1))
        done
    fi

    # repos.json: github_url, token
    if [[ -f "$REPOS_FILE" ]]; then
        local count; count=$(jq '.repos | length' "$REPOS_FILE" 2>/dev/null || echo 0)
        local i=0
        while [[ $i -lt $count ]]; do
            for field in github_url token; do
                val=$(jq -r ".repos[$i].${field} // \"\"" "$REPOS_FILE" 2>/dev/null)
                if [[ -n "$val" && "$val" != "null" && "${val:0:4}" != "enc:" ]]; then
                    enc_val=$(_enc "$val")
                    tmp=$(mktemp)
                    jq --argjson idx "$i" --arg f "$field" --arg v "$enc_val" \
                       '.repos[$idx][$f] = $v' "$REPOS_FILE" > "$tmp" && mv "$tmp" "$REPOS_FILE"
                fi
            done
            i=$((i+1))
        done
    fi

    # notify.json: 五个敏感字段
    if [[ -f "$NOTIFY_FILE" ]]; then
        local fields=(".providers.telegram.token" ".providers.telegram.chat_id"
                      ".providers.bark.key"        ".providers.bark.server"
                      ".providers.webhook.url")
        for jq_path in "${fields[@]}"; do
            val=$(jq -r "${jq_path} // \"\"" "$NOTIFY_FILE" 2>/dev/null)
            if [[ -n "$val" && "$val" != "null" && "${val:0:4}" != "enc:" ]]; then
                enc_val=$(_enc "$val")
                tmp=$(mktemp)
                jq --arg v "$enc_val" "(${jq_path}) = \$v" "$NOTIFY_FILE" > "$tmp" \
                    && mv "$tmp" "$NOTIFY_FILE"
            fi
        done
    fi
}

# ── 文件级加密工具（用于导出/导入/WebDAV备份） ─────────────
# _file_encrypt <in_file> <out_file> <passphrase>
_file_encrypt() {
    local in="$1" out="$2" pass="$3"
    openssl enc -aes-256-cbc -pbkdf2 -pass "pass:${pass}" \
        -in "$in" -out "$out" 2>/dev/null
}

# _file_decrypt <in_file> <out_file> <passphrase>
_file_decrypt() {
    local in="$1" out="$2" pass="$3"
    openssl enc -aes-256-cbc -pbkdf2 -d -pass "pass:${pass}" \
        -in "$in" -out "$out" 2>/dev/null
}

# _read_pass <prompt>  — 读取密码（不回显）
_read_pass() {
    local prompt="${1:-密码}" pass
    read -rsp "  ${prompt}: " pass
    echo ""
    printf '%s' "$pass"
}

# ── 初始化配置文件 ─────────────────────────────────────────
init_configs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"

    [[ -f "$TASKS_FILE" ]] || echo '{"tasks":[],"next_id":1}' > "$TASKS_FILE"
    [[ -f "$REPOS_FILE" ]] || echo '{"repos":[],"next_id":1}' > "$REPOS_FILE"
    [[ -f "$NOTIFY_FILE" ]] || cat > "$NOTIFY_FILE" << 'NOTIFYEOF'
{
  "providers": {
    "telegram": {"enabled": false, "token": "", "chat_id": ""},
    "bark":     {"enabled": false, "key": "", "server": "https://api.day.app"},
    "webhook":  {"enabled": false, "url": "", "method": "POST"}
  }
}
NOTIFYEOF
    [[ -f "$SETTINGS_FILE" ]] || cat > "$SETTINGS_FILE" << 'SETTINGSEOF'
{
  "fetch_proxy": "",
  "fetch_proxy_enabled": false
}
SETTINGSEOF
    _enc_init
    _enc_migrate_configs
}

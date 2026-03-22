#!/bin/bash
# ============================================================
#  订阅管理工具 (Subscription Manager) v1.2.0
#  功能: 订阅拉取 / GitHub推送 / 消息通知 / 定时任务
#  平台: Linux / macOS / Windows (Git Bash / WSL)
# ============================================================

readonly VERSION="1.3.2"
readonly GITHUB_RAW="https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main"
readonly GITHUB_RAW_PROXY="https://ghfast.top/${GITHUB_RAW}"

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
}

# ══════════════════════════════════════════════════════════
#  模块一: 拉取任务管理
# ══════════════════════════════════════════════════════════

task_list() {
    clear_screen
    print_header "拉取任务列表"

    local count; count=$(jq '.tasks | length' "$TASKS_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${Y}暂无任务，请先添加拉取任务${NC}"
        press_enter; return
    fi

    printf "  ${W}%-4s %-16s %-8s %-6s  %s${NC}\n" "ID" "名称" "间隔(分)" "状态" "备注"
    print_line
    jq -r '.tasks[] | [
        (.id|tostring),
        .name,
        (.interval|tostring),
        (if .enabled then "✓启用" else "✗禁用" end),
        .notes
    ] | @tsv' "$TASKS_FILE" | while IFS=$'\t' read -r id name interval status notes; do
        local scolor="$G"; [[ "$status" == "✗禁用" ]] && scolor="$R"
        printf "  %-4s %-16s %-8s ${scolor}%-6s${NC}  %s\n" \
            "$id" "${name:0:16}" "$interval" "$status" "${notes:0:30}"
    done
    echo ""
    echo -e "  ${C}URL 详情 - 输入任务ID查看, 留空返回:${NC}"
    local detail_id; detail_id=$(read_input "任务ID")
    if [[ -n "$detail_id" ]]; then
        local url last_run
        url=$(jq -r --argjson id "$detail_id" '.tasks[] | select(.id==$id) | .url' "$TASKS_FILE" 2>/dev/null)
        last_run=$(jq -r --argjson id "$detail_id" \
            '.tasks[] | select(.id==$id) | if .last_run==0 then "从未执行" else (.last_run | todate) end' \
            "$TASKS_FILE" 2>/dev/null)
        echo -e "  URL: ${C}$url${NC}"
        echo -e "  上次执行: $last_run"
        press_enter
    fi
}

task_add() {
    clear_screen
    print_header "添加拉取任务"

    local name url interval notes ua
    name=$(read_input "任务名称")
    [[ -z "$name" ]] && { echo -e "  ${R}名称不能为空${NC}"; press_enter; return; }

    url=$(read_input "订阅链接 URL")
    [[ -z "$url" ]] && { echo -e "  ${R}URL不能为空${NC}"; press_enter; return; }

    interval=$(read_input "拉取间隔(分钟)" "60")
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
        echo -e "  ${R}间隔必须为正整数${NC}"; press_enter; return
    fi

    notes=$(read_input "备注 (可选)")
    echo -e "  ${Y}自定义 User-Agent (留空=自动轮换常见客户端UA)${NC}"
    echo -e "  ${C}常见值: clash.meta / ClashForAndroid / v2rayN / Quantumult X${NC}"
    ua=$(read_input "User-Agent (可选)")
    echo -e "  ${Y}自定义请求头 (留空=不附加，格式: Header1:Value1|Header2:Value2)${NC}"
    echo -e "  ${C}示例: Authorization:Bearer token123|Cookie:session=abc${NC}"
    headers=$(read_input "自定义请求头 (可选)")
    echo -e "  ${Y}任务独立代理 (留空=使用全局代理设置)${NC}"
    echo -e "  ${C}示例: socks5://127.0.0.1:7890${NC}"
    task_proxy=$(read_input "任务代理 (可选)")

    local id; id=$(jq '.next_id' "$TASKS_FILE")
    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$name" --arg url "$url" \
       --argjson interval "$interval" --arg notes "$notes" \
       --arg ua "$ua" --arg headers "$headers" --arg proxy "$task_proxy" \
       '.tasks += [{
           "id": $id, "name": $name, "url": $url,
           "interval": $interval, "notes": $notes, "ua": $ua,
           "headers": $headers, "proxy": $proxy,
           "enabled": true, "last_run": 0
       }] | .next_id += 1' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"

    echo -e "\n  ${G}✓ 任务 \"$name\" 添加成功 (ID: $id)${NC}"
    log "INFO" "Task added: id=$id name=$name interval=${interval}m"
    press_enter
}

task_edit() {
    clear_screen
    print_header "编辑拉取任务"

    local id; id=$(read_input "请输入要编辑的任务 ID")
    local task; task=$(jq --argjson id "$id" '.tasks[] | select(.id==$id)' "$TASKS_FILE" 2>/dev/null)
    if [[ -z "$task" ]]; then
        echo -e "  ${R}未找到 ID=$id 的任务${NC}"; press_enter; return
    fi

    local cur_name cur_url cur_interval cur_notes cur_ua cur_headers
    cur_name=$(echo "$task" | jq -r '.name')
    cur_url=$(echo "$task" | jq -r '.url')
    cur_interval=$(echo "$task" | jq -r '.interval')
    cur_notes=$(echo "$task" | jq -r '.notes')
    cur_ua=$(echo "$task" | jq -r '.ua // ""')
    cur_headers=$(echo "$task" | jq -r '.headers // ""')

    echo -e "  ${C}当前配置 (直接回车保留原值):${NC}"
    local new_name new_url new_interval new_notes new_ua new_headers
    new_name=$(read_input "名称" "$cur_name")
    new_url=$(read_input "URL" "$cur_url")
    new_interval=$(read_input "间隔(分钟)" "$cur_interval")
    new_notes=$(read_input "备注" "$cur_notes")
    echo -e "  ${Y}留空=自动轮换UA / 常见值: clash.meta ClashForAndroid v2rayN${NC}"
    new_ua=$(read_input "User-Agent" "$cur_ua")
    echo -e "  ${Y}格式: Header1:Value1|Header2:Value2  (留空=不附加)${NC}"
    new_headers=$(read_input "自定义请求头" "$cur_headers")
    local cur_proxy; cur_proxy=$(echo "$task" | jq -r '.proxy // ""')
    echo -e "  ${Y}留空=使用全局代理 / 示例: socks5://127.0.0.1:7890${NC}"
    new_proxy=$(read_input "任务代理" "$cur_proxy")

    if ! [[ "$new_interval" =~ ^[0-9]+$ ]] || [[ "$new_interval" -lt 1 ]]; then
        echo -e "  ${R}间隔必须为正整数${NC}"; press_enter; return
    fi

    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$new_name" --arg url "$new_url" \
       --argjson interval "$new_interval" --arg notes "$new_notes" \
       --arg ua "$new_ua" --arg headers "$new_headers" --arg proxy "$new_proxy" \
       '(.tasks[] | select(.id==$id)) |= . + {
           "name":$name,"url":$url,"interval":$interval,"notes":$notes,
           "ua":$ua,"headers":$headers,"proxy":$proxy
       }' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"

    echo -e "\n  ${G}✓ 任务已更新${NC}"
    log "INFO" "Task edited: id=$id"
    press_enter
}

task_delete() {
    clear_screen
    print_header "删除拉取任务"

    local id; id=$(read_input "请输入要删除的任务 ID")
    local task_name; task_name=$(jq -r --argjson id "$id" \
        '.tasks[] | select(.id==$id) | .name' "$TASKS_FILE" 2>/dev/null)

    if [[ -z "$task_name" || "$task_name" == "null" ]]; then
        echo -e "  ${R}未找到 ID=$id 的任务${NC}"; press_enter; return
    fi

    confirm "确认删除任务 \"$task_name\"?" || { echo "  已取消"; press_enter; return; }

    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" '.tasks = [.tasks[] | select(.id != $id)]' \
        "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
    rm -f "${DATA_DIR}/task_${id}.txt"

    echo -e "\n  ${G}✓ 任务已删除${NC}"
    log "INFO" "Task deleted: id=$id name=$task_name"
    press_enter
}

task_toggle() {
    clear_screen
    print_header "启用/禁用任务"

    local id; id=$(read_input "请输入任务 ID")
    local cur task_name
    cur=$(jq -r --argjson id "$id" '.tasks[] | select(.id==$id) | .enabled' "$TASKS_FILE" 2>/dev/null)
    task_name=$(jq -r --argjson id "$id" '.tasks[] | select(.id==$id) | .name' "$TASKS_FILE" 2>/dev/null)

    if [[ -z "$cur" || "$cur" == "null" ]]; then
        echo -e "  ${R}未找到 ID=$id 的任务${NC}"; press_enter; return
    fi

    local new_status; [[ "$cur" == "true" ]] && new_status="false" || new_status="true"
    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" --argjson s "$new_status" \
       '(.tasks[] | select(.id==$id)) |= . + {"enabled":$s}' \
       "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"

    local label; [[ "$new_status" == "true" ]] && label="${G}已启用${NC}" || label="${R}已禁用${NC}"
    echo -e "\n  ${G}✓${NC} 任务 \"$task_name\" $label"
    press_enter
}

task_export() {
    clear_screen
    print_header "导出任务配置"

    local export_file
    export_file=$(read_input "导出文件路径" "/tmp/sub-tasks-$(date +%Y%m%d%H%M).json")
    cp "$TASKS_FILE" "$export_file"
    echo -e "\n  ${G}✓ 已导出到: $export_file${NC}"
    press_enter
}

task_import() {
    clear_screen
    print_header "导入任务配置"

    local import_file; import_file=$(read_input "导入文件路径")
    if [[ ! -f "$import_file" ]]; then
        echo -e "  ${R}文件不存在${NC}"; press_enter; return
    fi
    if ! jq empty "$import_file" 2>/dev/null; then
        echo -e "  ${R}无效的 JSON 文件${NC}"; press_enter; return
    fi

    local import_count; import_count=$(jq '.tasks | length' "$import_file" 2>/dev/null || echo 0)
    echo -e "  ${Y}文件包含 $import_count 个任务${NC}"
    echo ""
    echo "  导入模式:"
    echo "  1) 合并 (追加，重新分配ID)"
    echo "  2) 替换 (清空现有任务)"
    local mode; mode=$(read_input "选择" "1")

    if [[ "$mode" == "2" ]]; then
        confirm "确认替换所有现有任务?" || { echo "  已取消"; press_enter; return; }
        cp "$import_file" "$TASKS_FILE"
    else
        local next_id; next_id=$(jq '.next_id' "$TASKS_FILE")
        local tmp; tmp=$(mktemp)
        jq --slurpfile src "$import_file" --argjson base "$next_id" '
            .tasks += ($src[0].tasks | to_entries | map(
                .value + {"id": ($base + .key), "last_run": 0}
            )) |
            .next_id = ($base + ($src[0].tasks | length))
        ' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
    fi

    echo -e "\n  ${G}✓ 成功导入 $import_count 个任务${NC}"
    log "INFO" "Imported $import_count tasks from $import_file"
    press_enter
}

task_menu() {
    while true; do
        clear_screen
        print_header "拉取任务管理"
        local cnt; cnt=$(jq '.tasks | length' "$TASKS_FILE")
        echo -e "  ${Y}当前任务数: $cnt${NC}\n"
        echo -e "  ${C}1.${NC} 查看所有任务"
        echo -e "  ${C}2.${NC} 添加任务"
        echo -e "  ${C}3.${NC} 编辑任务"
        echo -e "  ${C}4.${NC} 删除任务"
        echo -e "  ${C}5.${NC} 启用/禁用任务"
        echo -e "  ${C}6.${NC} 导出任务配置"
        echo -e "  ${C}7.${NC} 导入任务配置"
        echo -e "  ${C}8.${NC} 立即执行任务"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) task_list ;;   2) task_add ;;    3) task_edit ;;
            4) task_delete ;; 5) task_toggle ;; 6) task_export ;;
            7) task_import ;; 8) run_task_interactive ;;
            0) return ;;
            *) echo -e "  ${R}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════
#  模块二: GitHub 仓库管理
# ══════════════════════════════════════════════════════════

repo_list() {
    clear_screen
    print_header "GitHub 仓库列表"

    local count; count=$(jq '.repos | length' "$REPOS_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${Y}暂无仓库配置${NC}"; press_enter; return
    fi

    jq -r '.repos[] | [.id, .name, .github_url, .branch,
        (.task_ids|map(tostring)|join(",")), .filename,
        ((.push_interval // 0) | tostring)] | @tsv' "$REPOS_FILE" | \
    while IFS=$'\t' read -r id name url branch task_ids filename push_interval; do
        local push_info="跟随任务"
        [[ "$push_interval" -gt 0 ]] 2>/dev/null && push_info="每 ${push_interval} 分钟"
        echo -e "  ${C}[$id]${NC} ${W}$name${NC}"
        echo -e "      仓库: ${C}$url${NC}"
        echo -e "      分支: $branch  |  文件名: ${W}$filename${NC}"
        echo -e "      关联任务IDs: $task_ids  |  定时推送: $push_info"
        print_line
    done
    press_enter
}

repo_add() {
    clear_screen
    print_header "添加 GitHub 仓库"

    local name github_url token branch filename task_ids_str
    name=$(read_input "仓库别名")
    [[ -z "$name" ]] && { echo -e "  ${R}名称不能为空${NC}"; press_enter; return; }

    github_url=$(read_input "GitHub 仓库地址 (https://github.com/user/repo)")
    [[ -z "$github_url" ]] && { echo -e "  ${R}地址不能为空${NC}"; press_enter; return; }

    echo ""
    echo -e "  ${W}GitHub Access Token 获取方式:${NC}"
    echo -e "  ${C}https://github.com/settings/tokens/new${NC}"
    echo -e "  所需权限: ${Y}Contents → Read and write${NC}"
    echo -e "  (Fine-grained token 选择对应仓库即可)"
    echo ""
    token=$(read_input "GitHub Access Token")
    branch=$(read_input "推送分支" "main")
    filename=$(read_input "推送文件名" "subscription.txt")

    echo ""
    echo -e "  ${C}可用任务:${NC}"
    jq -r '.tasks[] | "  [\(.id)] \(.name)"' "$TASKS_FILE"
    echo ""
    task_ids_str=$(read_input "关联任务 ID (多个用逗号分隔，如: 1,2,3)")

    local task_ids_json
    task_ids_json=$(echo "$task_ids_str" | tr ',' '\n' | grep -E '^[0-9]+$' | \
        jq -R 'tonumber' | jq -s '.')

    echo ""
    local push_interval_str; push_interval_str=$(read_input "定时推送间隔(分钟, 0=跟随任务定时)" "0")
    local push_interval=0
    [[ "$push_interval_str" =~ ^[0-9]+$ ]] && push_interval=$push_interval_str

    local id; id=$(jq '.next_id' "$REPOS_FILE")
    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$name" --arg url "$github_url" \
       --arg token "$token" --arg branch "$branch" \
       --arg filename "$filename" --argjson task_ids "$task_ids_json" \
       --argjson push_interval "$push_interval" \
       '.repos += [{
           "id":$id,"name":$name,"github_url":$url,
           "token":$token,"branch":$branch,
           "filename":$filename,"task_ids":$task_ids,
           "push_interval":$push_interval,"last_push":0
       }] | .next_id += 1' "$REPOS_FILE" > "$tmp" && mv "$tmp" "$REPOS_FILE"

    echo -e "\n  ${G}✓ 仓库 \"$name\" 添加成功 (ID: $id)${NC}"
    log "INFO" "Repo added: id=$id name=$name push_interval=${push_interval}m"

    # 立即测试连通性
    echo ""
    local repo_path; repo_path=$(echo "$github_url" | sed 's|https://github.com/||;s|\.git$||')
    local auth_url="https://x-access-token:${token}@github.com/${repo_path}.git"
    echo -ne "  测试推送连通性... "
    if git ls-remote --quiet "$auth_url" HEAD > /dev/null 2>&1; then
        echo -e "${G}✓ Token 有效，可以推送${NC}"
        if [[ "$push_interval" -gt 0 ]]; then
            echo -e "  ${G}定时推送已配置: 每 ${push_interval} 分钟推送一次${NC}"
        fi
    else
        echo -e "${R}✗ 连接失败，请检查 Token 权限和仓库地址${NC}"
    fi
    press_enter
}

repo_edit() {
    clear_screen
    print_header "编辑 GitHub 仓库"

    local id; id=$(read_input "请输入要编辑的仓库 ID")
    local repo; repo=$(jq --argjson id "$id" '.repos[] | select(.id==$id)' "$REPOS_FILE" 2>/dev/null)
    if [[ -z "$repo" ]]; then
        echo -e "  ${R}未找到 ID=$id 的仓库${NC}"; press_enter; return
    fi

    local cur_name cur_url cur_token cur_branch cur_filename cur_task_ids
    cur_name=$(echo "$repo" | jq -r '.name')
    cur_url=$(echo "$repo" | jq -r '.github_url')
    cur_token=$(echo "$repo" | jq -r '.token')
    cur_branch=$(echo "$repo" | jq -r '.branch')
    cur_filename=$(echo "$repo" | jq -r '.filename')
    cur_task_ids=$(echo "$repo" | jq -r '.task_ids | map(tostring) | join(",")')
    local cur_push_interval; cur_push_interval=$(echo "$repo" | jq -r '(.push_interval // 0) | tostring')

    local new_name new_url new_token new_branch new_filename new_task_ids_str
    new_name=$(read_input "名称" "$cur_name")
    new_url=$(read_input "仓库地址" "$cur_url")
    echo ""
    echo -e "  ${W}Token 获取:${NC} ${C}https://github.com/settings/tokens/new${NC}"
    echo -e "  所需权限: ${Y}Contents → Read and write${NC}"
    echo ""
    new_token=$(read_input "Access Token" "$cur_token")
    new_branch=$(read_input "分支" "$cur_branch")
    new_filename=$(read_input "文件名" "$cur_filename")

    echo ""
    jq -r '.tasks[] | "  [\(.id)] \(.name)"' "$TASKS_FILE"
    new_task_ids_str=$(read_input "关联任务 ID" "$cur_task_ids")

    local new_push_interval_str; new_push_interval_str=$(read_input "定时推送间隔(分钟, 0=跟随任务)" "$cur_push_interval")
    local new_push_interval=0
    [[ "$new_push_interval_str" =~ ^[0-9]+$ ]] && new_push_interval=$new_push_interval_str

    local new_task_ids_json
    new_task_ids_json=$(echo "$new_task_ids_str" | tr ',' '\n' | grep -E '^[0-9]+$' | \
        jq -R 'tonumber' | jq -s '.')

    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$new_name" --arg url "$new_url" --arg token "$new_token" \
       --arg branch "$new_branch" --arg filename "$new_filename" \
       --argjson task_ids "$new_task_ids_json" \
       --argjson push_interval "$new_push_interval" \
       '(.repos[] | select(.id==$id)) |= . + {
           "name":$name,"github_url":$url,"token":$token,
           "branch":$branch,"filename":$filename,"task_ids":$task_ids,
           "push_interval":$push_interval
       }' "$REPOS_FILE" > "$tmp" && mv "$tmp" "$REPOS_FILE"

    echo -e "\n  ${G}✓ 仓库已更新${NC}"
    log "INFO" "Repo edited: id=$id"
    press_enter
}

repo_delete() {
    clear_screen
    print_header "删除 GitHub 仓库"

    local id; id=$(read_input "请输入要删除的仓库 ID")
    local repo_name; repo_name=$(jq -r --argjson id "$id" \
        '.repos[] | select(.id==$id) | .name' "$REPOS_FILE" 2>/dev/null)

    if [[ -z "$repo_name" || "$repo_name" == "null" ]]; then
        echo -e "  ${R}未找到 ID=$id 的仓库${NC}"; press_enter; return
    fi

    confirm "确认删除仓库 \"$repo_name\"?" || { echo "  已取消"; press_enter; return; }

    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" '.repos = [.repos[] | select(.id != $id)]' \
        "$REPOS_FILE" > "$tmp" && mv "$tmp" "$REPOS_FILE"

    echo -e "\n  ${G}✓ 仓库已删除${NC}"
    log "INFO" "Repo deleted: id=$id name=$repo_name"
    press_enter
}

repo_test_connection() {
    clear_screen
    print_header "测试推送连通性"

    local count; count=$(jq '.repos | length' "$REPOS_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${Y}暂无仓库配置${NC}"; press_enter; return
    fi

    jq -r '.repos[] | "  [\(.id)] \(.name)"' "$REPOS_FILE"
    echo ""
    local id; id=$(read_input "请输入要测试的仓库 ID")
    local repo; repo=$(jq --argjson id "$id" '.repos[] | select(.id==$id)' "$REPOS_FILE" 2>/dev/null)
    if [[ -z "$repo" ]]; then
        echo -e "  ${R}未找到 ID=$id 的仓库${NC}"; press_enter; return
    fi

    local repo_name github_url token
    repo_name=$(echo "$repo" | jq -r '.name')
    github_url=$(echo "$repo" | jq -r '.github_url')
    token=$(echo "$repo" | jq -r '.token')

    local repo_path; repo_path=$(echo "$github_url" | sed 's|https://github.com/||;s|\.git$||')
    local auth_url="https://x-access-token:${token}@github.com/${repo_path}.git"

    echo ""
    echo -ne "  测试连接 \"${repo_name}\"... "
    if git ls-remote --quiet "$auth_url" HEAD > /dev/null 2>&1; then
        echo -e "${G}✓ Token 有效，可以推送${NC}"
        log "INFO" "Repo test OK: id=$id name=$repo_name"
    else
        echo -e "${R}✗ 连接失败${NC}"
        echo -e "  ${Y}请检查: Token 权限(Contents→Read/Write) 和 仓库地址是否正确${NC}"
        log "WARN" "Repo test FAIL: id=$id name=$repo_name"
    fi
    press_enter
}

repo_push_now() {
    clear_screen
    print_header "立即推送到仓库"

    local count; count=$(jq '.repos | length' "$REPOS_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${Y}暂无仓库配置${NC}"; press_enter; return
    fi

    jq -r '.repos[] | "  [\(.id)] \(.name)  (关联任务: \(.task_ids | map(tostring) | join(",")))"' "$REPOS_FILE"
    echo ""
    local id; id=$(read_input "请输入要推送的仓库 ID")
    local repo; repo=$(jq --argjson id "$id" '.repos[] | select(.id==$id)' "$REPOS_FILE" 2>/dev/null)
    if [[ -z "$repo" ]]; then
        echo -e "  ${R}未找到 ID=$id 的仓库${NC}"; press_enter; return
    fi

    local repo_name task_ids
    repo_name=$(echo "$repo" | jq -r '.name')
    task_ids=$(echo "$repo" | jq -r '.task_ids[]' 2>/dev/null)

    if [[ -z "$task_ids" ]]; then
        echo -e "  ${Y}该仓库未关联任何任务，无文件可推送${NC}"
        press_enter; return
    fi

    echo ""
    local any_ok=false
    while IFS= read -r tid; do
        [[ -z "$tid" ]] && continue
        local tname; tname=$(jq -r --argjson id "$tid" '.tasks[] | select(.id==$id) | .name' "$TASKS_FILE")
        local data_file="${DATA_DIR}/task_${tid}.txt"
        if [[ ! -f "$data_file" ]]; then
            echo -e "  ${Y}任务 [$tid] $tname: 尚无本地数据，请先执行拉取${NC}"
            continue
        fi
        echo -e "  ${C}推送任务 [$tid] $tname → \"$repo_name\"...${NC}"
        if push_to_github "$id" "$tid" "true"; then
            any_ok=true
        fi
    done <<< "$task_ids"

    echo ""
    [[ "$any_ok" == "true" ]] && \
        echo -e "  ${G}✓ 推送完成${NC}" || \
        echo -e "  ${R}推送失败，请检查 Token 和仓库配置${NC}"
    press_enter
}

repo_menu() {
    while true; do
        clear_screen
        print_header "GitHub 仓库管理"
        local cnt; cnt=$(jq '.repos | length' "$REPOS_FILE")
        echo -e "  ${Y}当前仓库数: $cnt${NC}\n"
        echo -e "  ${C}1.${NC} 查看所有仓库"
        echo -e "  ${C}2.${NC} 添加仓库"
        echo -e "  ${C}3.${NC} 编辑仓库"
        echo -e "  ${C}4.${NC} 删除仓库"
        echo -e "  ${C}5.${NC} 测试推送连通性"
        echo -e "  ${C}6.${NC} 立即推送到仓库"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) repo_list ;; 2) repo_add ;;
            3) repo_edit ;; 4) repo_delete ;;
            5) repo_test_connection ;;
            6) repo_push_now ;;
            0) return ;;
            *) echo -e "  ${R}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════
#  模块三: 消息推送配置
# ══════════════════════════════════════════════════════════

notify_show_status() {
    local tg bark wh
    tg=$(jq -r '.providers.telegram.enabled' "$NOTIFY_FILE")
    bark=$(jq -r '.providers.bark.enabled' "$NOTIFY_FILE")
    wh=$(jq -r '.providers.webhook.enabled' "$NOTIFY_FILE")

    local ts="${R}禁用${NC}"; [[ "$tg"   == "true" ]] && ts="${G}启用${NC}"
    local bs="${R}禁用${NC}"; [[ "$bark" == "true" ]] && bs="${G}启用${NC}"
    local ws="${R}禁用${NC}"; [[ "$wh"   == "true" ]] && ws="${G}启用${NC}"

    echo -e "  Telegram: $ts  |  Bark: $bs  |  Webhook: $ws"
}

notify_telegram() {
    clear_screen
    print_header "Telegram 通知配置"

    local cur_token cur_chat_id cur_enabled
    cur_token=$(jq -r '.providers.telegram.token' "$NOTIFY_FILE")
    cur_chat_id=$(jq -r '.providers.telegram.chat_id' "$NOTIFY_FILE")
    cur_enabled=$(jq -r '.providers.telegram.enabled' "$NOTIFY_FILE")

    echo -e "  当前状态: $([ "$cur_enabled" == "true" ] && echo -e "${G}启用${NC}" || echo -e "${R}禁用${NC}")"
    echo -e "  获取方式: 与 @BotFather 对话创建Bot，再获取 chat_id"
    echo ""

    local new_token new_chat_id enable_yn new_enabled
    new_token=$(read_input "Bot Token" "$cur_token")
    new_chat_id=$(read_input "Chat ID" "$cur_chat_id")
    read -rp "  启用 Telegram 通知? [y/N]: " enable_yn
    [[ "$(echo "$enable_yn" | tr '[:upper:]' '[:lower:]')" == "y" ]] && new_enabled="true" || new_enabled="false"

    local tmp; tmp=$(mktemp)
    jq --arg token "$new_token" --arg chat_id "$new_chat_id" \
       --argjson enabled "$new_enabled" \
       '.providers.telegram = {"enabled":$enabled,"token":$token,"chat_id":$chat_id}' \
       "$NOTIFY_FILE" > "$tmp" && mv "$tmp" "$NOTIFY_FILE"

    echo -e "\n  ${G}✓ Telegram 配置已保存${NC}"
    press_enter
}

notify_bark() {
    clear_screen
    print_header "Bark 通知配置"

    local cur_key cur_server cur_enabled
    cur_key=$(jq -r '.providers.bark.key' "$NOTIFY_FILE")
    cur_server=$(jq -r '.providers.bark.server' "$NOTIFY_FILE")
    cur_enabled=$(jq -r '.providers.bark.enabled' "$NOTIFY_FILE")

    echo -e "  Bark 是 iOS 推送应用, App Store 搜索 Bark 下载"
    echo ""

    local new_key new_server enable_yn new_enabled
    new_key=$(read_input "Bark Key" "$cur_key")
    new_server=$(read_input "Bark Server" "$cur_server")
    read -rp "  启用 Bark 通知? [y/N]: " enable_yn
    [[ "$(echo "$enable_yn" | tr '[:upper:]' '[:lower:]')" == "y" ]] && new_enabled="true" || new_enabled="false"

    local tmp; tmp=$(mktemp)
    jq --arg key "$new_key" --arg server "$new_server" \
       --argjson enabled "$new_enabled" \
       '.providers.bark = {"enabled":$enabled,"key":$key,"server":$server}' \
       "$NOTIFY_FILE" > "$tmp" && mv "$tmp" "$NOTIFY_FILE"

    echo -e "\n  ${G}✓ Bark 配置已保存${NC}"
    press_enter
}

notify_webhook() {
    clear_screen
    print_header "Webhook 通知配置"

    local cur_url cur_method cur_enabled
    cur_url=$(jq -r '.providers.webhook.url' "$NOTIFY_FILE")
    cur_method=$(jq -r '.providers.webhook.method' "$NOTIFY_FILE")
    cur_enabled=$(jq -r '.providers.webhook.enabled' "$NOTIFY_FILE")

    echo -e "  支持企业微信/钉钉/飞书/自定义 Webhook"
    echo -e "  POST 请求体: {\"title\":\"...\",\"body\":\"...\",\"status\":\"...\"}"
    echo ""

    local new_url new_method enable_yn new_enabled
    new_url=$(read_input "Webhook URL" "$cur_url")
    new_method=$(read_input "HTTP 方法 (POST/GET)" "$cur_method")
    read -rp "  启用 Webhook 通知? [y/N]: " enable_yn
    [[ "$(echo "$enable_yn" | tr '[:upper:]' '[:lower:]')" == "y" ]] && new_enabled="true" || new_enabled="false"

    local tmp; tmp=$(mktemp)
    jq --arg url "$new_url" --arg method "$new_method" \
       --argjson enabled "$new_enabled" \
       '.providers.webhook = {"enabled":$enabled,"url":$url,"method":$method}' \
       "$NOTIFY_FILE" > "$tmp" && mv "$tmp" "$NOTIFY_FILE"

    echo -e "\n  ${G}✓ Webhook 配置已保存${NC}"
    press_enter
}

notify_test() {
    clear_screen
    print_header "测试消息推送"
    echo -e "  正在发送测试消息...\n"
    send_notification "测试通知" "来自订阅管理工具的测试消息 [$(date '+%Y-%m-%d %H:%M:%S')]" "true"
    press_enter
}

notify_menu() {
    while true; do
        clear_screen
        print_header "消息推送配置"
        notify_show_status
        echo ""
        echo -e "  ${C}1.${NC} 配置 Telegram"
        echo -e "  ${C}2.${NC} 配置 Bark (iOS)"
        echo -e "  ${C}3.${NC} 配置 Webhook"
        echo -e "  ${C}4.${NC} 发送测试消息"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) notify_telegram ;; 2) notify_bark ;;
            3) notify_webhook ;; 4) notify_test ;;
            0) return ;;
            *) echo -e "  ${R}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════
#  拉取代理配置
# ══════════════════════════════════════════════════════════

# 读取全局代理（供 _do_fetch 调用）
_get_fetch_proxy() {
    local enabled; enabled=$(jq -r '.fetch_proxy_enabled' "$SETTINGS_FILE" 2>/dev/null)
    [[ "$enabled" != "true" ]] && echo "" && return
    jq -r '.fetch_proxy // ""' "$SETTINGS_FILE" 2>/dev/null
}

proxy_config() {
    clear_screen
    print_header "拉取代理配置"

    local cur_proxy cur_enabled
    cur_proxy=$(jq -r '.fetch_proxy // ""' "$SETTINGS_FILE" 2>/dev/null)
    cur_enabled=$(jq -r '.fetch_proxy_enabled' "$SETTINGS_FILE" 2>/dev/null)

    local status_label="${R}未启用${NC}"; [[ "$cur_enabled" == "true" ]] && status_label="${G}已启用${NC}"
    echo -e "  当前状态: $status_label"
    [[ -n "$cur_proxy" ]] && echo -e "  当前代理: ${C}${cur_proxy}${NC}"
    echo ""
    echo -e "  ${Y}用于解决云服务器 IP 被订阅服务商封锁的问题${NC}"
    echo -e "  支持格式:"
    echo -e "    ${C}socks5://127.0.0.1:7890${NC}"
    echo -e "    ${C}socks5://user:pass@host:port${NC}"
    echo -e "    ${C}http://127.0.0.1:7890${NC}"
    echo ""

    local new_proxy enable_yn new_enabled
    new_proxy=$(read_input "代理地址" "$cur_proxy")
    read -rp "  启用拉取代理? [y/N]: " enable_yn
    [[ "$(echo "$enable_yn" | tr '[:upper:]' '[:lower:]')" == "y" ]] && new_enabled="true" || new_enabled="false"

    local tmp; tmp=$(mktemp)
    jq --arg proxy "$new_proxy" --argjson enabled "$new_enabled" \
       '.fetch_proxy = $proxy | .fetch_proxy_enabled = $enabled' \
       "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"

    if [[ "$new_enabled" == "true" && -n "$new_proxy" ]]; then
        echo -e "\n  ${G}✓ 代理已启用: $new_proxy${NC}"
        echo -e "  ${Y}测试中...${NC}"
        local test_code
        test_code=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 8 --max-time 15 \
            --proxy "$new_proxy" \
            "https://www.google.com" 2>/dev/null)
        if [[ "$test_code" =~ ^[23] ]]; then
            echo -e "  ${G}✓ 代理连通性正常 (HTTP $test_code)${NC}"
        else
            echo -e "  ${Y}⚠ 代理测试返回 $test_code，请确认代理地址正确且可用${NC}"
        fi
    else
        echo -e "\n  ${Y}代理已禁用${NC}"
    fi
    press_enter
}

proxy_menu() {
    while true; do
        clear_screen
        print_header "拉取代理管理"

        local cur_proxy cur_enabled
        cur_proxy=$(jq -r '.fetch_proxy // ""' "$SETTINGS_FILE" 2>/dev/null)
        cur_enabled=$(jq -r '.fetch_proxy_enabled' "$SETTINGS_FILE" 2>/dev/null)
        local status_label="${R}未启用${NC}"; [[ "$cur_enabled" == "true" ]] && status_label="${G}已启用${NC}"

        echo -e "  全局代理: $status_label"
        [[ -n "$cur_proxy" ]] && echo -e "  地址:     ${C}${cur_proxy}${NC}"
        echo ""
        echo -e "  ${C}1.${NC} 配置全局代理"
        echo -e "  ${C}2.${NC} 测试代理连通性"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) proxy_config ;;
            2)
                local proxy; proxy=$(_get_fetch_proxy)
                if [[ -z "$proxy" ]]; then
                    echo -e "\n  ${Y}代理未启用${NC}"; press_enter; continue
                fi
                echo -ne "\n  测试 $proxy ... "
                local code
                code=$(curl -s -o /dev/null -w "%{http_code}" \
                    --connect-timeout 8 --max-time 15 \
                    --proxy "$proxy" "https://www.google.com" 2>/dev/null)
                [[ "$code" =~ ^[23] ]] && \
                    echo -e "${G}✓ 正常 ($code)${NC}" || \
                    echo -e "${R}✗ 失败 ($code)${NC}"
                press_enter ;;
            0) return ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════
#  核心执行: 发送通知
# ══════════════════════════════════════════════════════════

# send_notification <title> <body> [verbose=false]
send_notification() {
    local title="$1" body="$2" verbose="${3:-false}"
    local sent=false

    # Telegram
    local tg_enabled; tg_enabled=$(jq -r '.providers.telegram.enabled' "$NOTIFY_FILE")
    if [[ "$tg_enabled" == "true" ]]; then
        local tg_token tg_chat
        tg_token=$(jq -r '.providers.telegram.token' "$NOTIFY_FILE")
        tg_chat=$(jq -r '.providers.telegram.chat_id' "$NOTIFY_FILE")
        local msg="*${title}*%0A${body}"
        if curl -s --connect-timeout 10 -X POST \
            "https://api.telegram.org/bot${tg_token}/sendMessage" \
            -d "chat_id=${tg_chat}&text=${msg}&parse_mode=Markdown" \
            > /dev/null 2>&1; then
            [[ "$verbose" == "true" ]] && echo -e "  ${G}✓ Telegram 通知已发送${NC}"
            sent=true
        else
            [[ "$verbose" == "true" ]] && echo -e "  ${R}✗ Telegram 通知失败${NC}"
        fi
    fi

    # Bark
    local bark_enabled; bark_enabled=$(jq -r '.providers.bark.enabled' "$NOTIFY_FILE")
    if [[ "$bark_enabled" == "true" ]]; then
        local bark_key bark_server
        bark_key=$(jq -r '.providers.bark.key' "$NOTIFY_FILE")
        bark_server=$(jq -r '.providers.bark.server' "$NOTIFY_FILE")
        local enc_title enc_body
        enc_title=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
            "$title" 2>/dev/null || echo "$title")
        enc_body=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" \
            "$body" 2>/dev/null || echo "$body")
        if curl -s --connect-timeout 10 \
            "${bark_server}/${bark_key}/${enc_title}/${enc_body}" \
            > /dev/null 2>&1; then
            [[ "$verbose" == "true" ]] && echo -e "  ${G}✓ Bark 通知已发送${NC}"
            sent=true
        else
            [[ "$verbose" == "true" ]] && echo -e "  ${R}✗ Bark 通知失败${NC}"
        fi
    fi

    # Webhook
    local wh_enabled; wh_enabled=$(jq -r '.providers.webhook.enabled' "$NOTIFY_FILE")
    if [[ "$wh_enabled" == "true" ]]; then
        local wh_url wh_method
        wh_url=$(jq -r '.providers.webhook.url' "$NOTIFY_FILE")
        wh_method=$(jq -r '.providers.webhook.method' "$NOTIFY_FILE")
        local payload
        payload=$(jq -n --arg t "$title" --arg b "$body" \
            '{"title":$t,"body":$b}')
        if curl -s --connect-timeout 10 -X "$wh_method" "$wh_url" \
            -H "Content-Type: application/json" -d "$payload" \
            > /dev/null 2>&1; then
            [[ "$verbose" == "true" ]] && echo -e "  ${G}✓ Webhook 通知已发送${NC}"
            sent=true
        else
            [[ "$verbose" == "true" ]] && echo -e "  ${R}✗ Webhook 通知失败${NC}"
        fi
    fi

    if [[ "$sent" == "false" && "$verbose" == "true" ]]; then
        echo -e "  ${Y}未启用任何通知渠道，跳过通知${NC}"
    fi

    log "INFO" "Notification: $title"
}

# ══════════════════════════════════════════════════════════
#  核心执行: 拉取订阅
# ══════════════════════════════════════════════════════════

# 订阅拉取常用 User-Agent 列表（遇到 403/407 时自动轮换）
FETCH_UA_LIST=(
    "clash-meta/2.4.0"           # miaomiaowu 默认 UA，兼容性最广
    "clash.meta"
    "ClashforWindows/0.20.39"
    "ClashForAndroid/2.5.12"
    "ClashX/1.95.1"
    "Clash/1.18.0"
    "v2rayN/6.23"
    "sing-box/1.8.0"
    "Quantumult%2FX"
    "Surge/5.8.0"
)

# _do_fetch <url> <ua> <extra_headers> <insecure> <proxy> <out_file>
# extra_headers 格式: "Header1:Value1|Header2:Value2"
# 返回 http_code
_do_fetch() {
    local url="$1" ua="$2" extra_headers="$3" insecure="$4" proxy="$5" out="$6"

    local -a args=(
        -s -o "$out" -w "%{http_code}"
        --connect-timeout 15 --max-time 60
        -L --compressed
        -H "Accept: */*"
        -A "$ua"
    )

    # 附加自定义请求头（以 | 分隔）
    if [[ -n "$extra_headers" ]]; then
        while IFS= read -r hdr; do
            [[ -n "$hdr" ]] && args+=(-H "$hdr")
        done < <(echo "$extra_headers" | tr '|' '\n')
    fi

    [[ "$insecure" == "true" ]] && args+=(-k)
    [[ -n "$proxy" ]] && args+=(--proxy "$proxy")

    curl "${args[@]}" "$url" 2>/dev/null
}

# fetch_task <task_id> <verbose=false>
# Returns 0 on success
fetch_task() {
    local task_id="$1" verbose="${2:-false}"

    local task; task=$(jq --argjson id "$task_id" '.tasks[] | select(.id==$id)' "$TASKS_FILE")
    if [[ -z "$task" ]]; then
        log "ERROR" "fetch_task: task $task_id not found"; return 1
    fi

    local name url custom_ua custom_headers task_proxy
    name=$(echo "$task" | jq -r '.name')
    url=$(echo "$task" | jq -r '.url')
    custom_ua=$(echo "$task" | jq -r '.ua // ""')
    custom_headers=$(echo "$task" | jq -r '.headers // ""')
    task_proxy=$(echo "$task" | jq -r '.proxy // ""')
    local output_file="${DATA_DIR}/task_${task_id}.txt"

    # 代理优先级：任务独立代理 > 全局代理
    local active_proxy="$task_proxy"
    [[ -z "$active_proxy" ]] && active_proxy=$(_get_fetch_proxy)

    [[ "$verbose" == "true" ]] && echo -e "  ${C}拉取 \"$name\"...${NC}"
    [[ "$verbose" == "true" && -n "$active_proxy" ]] && \
        echo -e "  ${Y}  使用代理: $active_proxy${NC}"
    log "INFO" "Fetching task $task_id: $name proxy=${active_proxy:-none}"

    # UA 候选列表：有自定义则只用一个，否则轮换
    local -a ua_candidates=()
    if [[ -n "$custom_ua" ]]; then
        ua_candidates=("$custom_ua")
    else
        ua_candidates=("${FETCH_UA_LIST[@]}")
    fi

    local tmp_file; tmp_file=$(mktemp)
    local http_code="" used_ua="" attempt=0
    local insecure="false"

    for ua in "${ua_candidates[@]}"; do
        attempt=$(( attempt + 1 ))
        http_code=$(_do_fetch "$url" "$ua" "$custom_headers" "$insecure" "$active_proxy" "$tmp_file")

        # 2xx = 成功
        if [[ "$http_code" =~ ^2 ]]; then
            used_ua="$ua"
            break
        fi

        # SSL 错误 (000 + 空文件) 自动加 -k 重试一次
        if [[ "$http_code" == "000" && "$insecure" == "false" ]]; then
            insecure="true"
            http_code=$(_do_fetch "$url" "$ua" "$custom_headers" "$insecure" "$active_proxy" "$tmp_file")
            if [[ "$http_code" =~ ^2 ]]; then
                used_ua="$ua (insecure)"
                break
            fi
            insecure="false"
        fi

        # 非 403/407 不是 UA 问题，直接报错不轮换
        if [[ "$http_code" != "403" && "$http_code" != "407" ]]; then
            if [[ "$verbose" == "true" ]]; then
                echo -e "  ${R}✗ 拉取失败 (HTTP $http_code)${NC}"
                # 显示响应体片段，帮助诊断
                local body_snippet; body_snippet=$(_printable < <(head -c 300 "$tmp_file" 2>/dev/null))
                if [[ -n "$body_snippet" ]]; then
                    echo -e "  ${Y}── 服务端响应 ──${NC}"
                    echo "$body_snippet" | sed 's/^/  /'
                    echo -e "  ${Y}────────────────${NC}"
                fi
            fi
            log "ERROR" "Fetch failed: task=$task_id http=$http_code ua=$ua"
            rm -f "$tmp_file"
            return 1
        fi

        [[ "$verbose" == "true" ]] && \
            echo -e "  ${Y}  [${attempt}/${#ua_candidates[@]}] HTTP $http_code，切换UA重试...${NC}"
        log "WARN" "Fetch 403: task=$task_id attempt=$attempt ua=$ua"
        : > "$tmp_file"
    done

    local ret=1
    if [[ "$http_code" =~ ^2 ]]; then
        local size; size=$(_filesize "$tmp_file")
        if [[ "$size" -gt 0 ]]; then
            mv "$tmp_file" "$output_file"
            local now; now=$(date +%s)
            local tmpj; tmpj=$(mktemp)
            jq --argjson id "$task_id" --argjson ts "$now" \
               '(.tasks[] | select(.id==$id)) |= . + {"last_run":$ts}' \
               "$TASKS_FILE" > "$tmpj" && mv "$tmpj" "$TASKS_FILE"
            [[ "$verbose" == "true" ]] && \
                echo -e "  ${G}✓ 拉取成功 ($size 字节) [UA: $used_ua]${NC}" && \
                echo -e "  ${C}  → 已保存: $output_file${NC}"
            log "INFO" "Fetch OK: task=$task_id size=${size}B ua=$used_ua"
            ret=0
        else
            [[ "$verbose" == "true" ]] && echo -e "  ${R}✗ 响应内容为空${NC}"
            log "WARN" "Fetch empty: task=$task_id"
        fi
    else
        if [[ "$verbose" == "true" ]]; then
            echo -e "  ${R}✗ 全部 UA 均返回 403${NC}"
            # 最后一次响应体
            local body_snippet; body_snippet=$(_printable < <(head -c 300 "$tmp_file" 2>/dev/null))
            if [[ -n "$body_snippet" ]]; then
                echo -e "  ${Y}── 服务端最后响应 ──${NC}"
                echo "$body_snippet" | sed 's/^/  /'
                echo -e "  ${Y}────────────────────${NC}"
            fi
            echo -e "  ${Y}排查建议:${NC}"
            echo -e "    1. 检查订阅链接是否已过期"
            echo -e "    2. 编辑任务 → 自定义请求头 (如 Authorization:Bearer xxx)"
            echo -e "    3. 在浏览器打开链接，用开发者工具查看请求头后填入"
        fi
        log "ERROR" "Fetch failed all UA: task=$task_id http=$http_code"
    fi

    rm -f "$tmp_file"
    return $ret
}

# ══════════════════════════════════════════════════════════
#  核心执行: 推送到 GitHub
# ══════════════════════════════════════════════════════════

# push_to_github <repo_id> <task_id> <verbose=false>
push_to_github() {
    local repo_id="$1" task_id="$2" verbose="${3:-false}"

    local repo; repo=$(jq --argjson id "$repo_id" '.repos[] | select(.id==$id)' "$REPOS_FILE")
    if [[ -z "$repo" ]]; then
        log "ERROR" "push_to_github: repo $repo_id not found"; return 1
    fi

    local repo_name github_url token branch filename
    repo_name=$(echo "$repo" | jq -r '.name')
    github_url=$(echo "$repo" | jq -r '.github_url')
    token=$(echo "$repo" | jq -r '.token')
    branch=$(echo "$repo" | jq -r '.branch')
    filename=$(echo "$repo" | jq -r '.filename')

    local local_file="${DATA_DIR}/task_${task_id}.txt"
    if [[ ! -f "$local_file" ]]; then
        log "ERROR" "push: local file missing: $local_file"; return 1
    fi

    [[ "$verbose" == "true" ]] && echo -e "  ${C}推送到仓库 \"$repo_name\"...${NC}"

    local repo_path; repo_path=$(echo "$github_url" | sed 's|https://github.com/||;s|\.git$||')
    local auth_url="https://x-access-token:${token}@github.com/${repo_path}.git"

    local tmp_git; tmp_git=$(mktemp -d)
    local ret=0

    (
        set -e
        if git clone --depth=1 --branch "$branch" --quiet "$auth_url" "$tmp_git" 2>/dev/null; then
            local remote_file="${tmp_git}/${filename}"

            # Compare: skip if unchanged
            if [[ -f "$remote_file" ]] && diff -q "$local_file" "$remote_file" > /dev/null 2>&1; then
                [[ "$verbose" == "true" ]] && echo -e "  ${Y}→ 文件未变化，跳过推送${NC}"
                log "INFO" "Push skipped (no change): repo=$repo_id task=$task_id"
                exit 0
            fi

            cp "$local_file" "$remote_file"
            cd "$tmp_git"
            git config user.email "sub-manager@noreply"
            git config user.name "Sub Manager"
            git add "$filename"
            git commit -m "Update ${filename} [$(date '+%Y-%m-%d %H:%M:%S')]" --quiet
            git push --quiet "$auth_url" "$branch"
            [[ "$verbose" == "true" ]] && echo -e "  ${G}✓ 推送成功${NC}"
            log "INFO" "Push OK: repo=$repo_id task=$task_id"
            local _now _tmpj; _now=$(date +%s); _tmpj=$(mktemp)
            jq --argjson id "$repo_id" --argjson ts "$_now" \
               '(.repos[] | select(.id==$id)) |= . + {"last_push":$ts}' \
               "$REPOS_FILE" > "$_tmpj" && mv "$_tmpj" "$REPOS_FILE"
        else
            # Branch doesn't exist yet — init and push
            git init --quiet "$tmp_git"
            cd "$tmp_git"
            git remote add origin "$auth_url"
            cp "$local_file" "${tmp_git}/${filename}"
            git config user.email "sub-manager@noreply"
            git config user.name "Sub Manager"
            git add "$filename"
            git commit -m "Initial: ${filename} [$(date '+%Y-%m-%d %H:%M:%S')]" --quiet
            git push --quiet -u origin "HEAD:${branch}"
            [[ "$verbose" == "true" ]] && echo -e "  ${G}✓ 初始化推送成功${NC}"
            log "INFO" "Push initial OK: repo=$repo_id task=$task_id"
            local _now _tmpj; _now=$(date +%s); _tmpj=$(mktemp)
            jq --argjson id "$repo_id" --argjson ts "$_now" \
               '(.repos[] | select(.id==$id)) |= . + {"last_push":$ts}' \
               "$REPOS_FILE" > "$_tmpj" && mv "$_tmpj" "$REPOS_FILE"
        fi
    ) || ret=$?

    rm -rf "$tmp_git"
    return $ret
}

# ══════════════════════════════════════════════════════════
#  核心执行: 执行完整任务 (拉取 + 推送 + 通知)
# ══════════════════════════════════════════════════════════

# run_task <task_id> <verbose=false>
#
# 完整执行流程:
#   1. 拉取订阅
#      - 成功 → 继续推送
#      - 失败 → 检查本地缓存
#        ├─ 有缓存 → 继续推送（push_to_github 内部会与云端对比，无变化自动跳过）
#        └─ 无缓存 → 记录日志，结束
#   2. 推送到所有关联 GitHub 仓库（云端相同则自动跳过）
#   3. 发送通知（未配置或发送失败不影响整体流程）
run_task() {
    local task_id="$1" verbose="${2:-false}"
    local task_name; task_name=$(jq -r --argjson id "$task_id" \
        '.tasks[] | select(.id==$id) | .name' "$TASKS_FILE")
    local local_file="${DATA_DIR}/task_${task_id}.txt"

    # ── 步骤 1: 拉取订阅 ────────────────────────────────────
    local fetch_ok=false
    if fetch_task "$task_id" "$verbose"; then
        fetch_ok=true
    else
        if [[ -f "$local_file" ]]; then
            [[ "$verbose" == "true" ]] && \
                echo -e "  ${Y}⚠ 拉取失败，使用本地缓存继续推送流程${NC}"
            log "WARN" "Fetch failed, fallback to local cache: task=$task_id"
        else
            [[ "$verbose" == "true" ]] && \
                echo -e "  ${R}✗ 拉取失败且无本地缓存，终止流程${NC}"
            log "ERROR" "Fetch failed, no local cache: task=$task_id"
            send_notification "拉取失败" "任务「${task_name}」拉取失败且无本地缓存" 2>/dev/null || true
            return 1
        fi
    fi

    # ── 步骤 2: 推送到关联 GitHub 仓库 ──────────────────────
    # push_to_github 内部已做云端对比，文件相同时自动跳过
    local repo_ids
    repo_ids=$(jq -r --argjson tid "$task_id" \
        '.repos[] | select(.task_ids | contains([$tid])) | .id' "$REPOS_FILE")

    while IFS= read -r rid; do
        [[ -z "$rid" ]] && continue
        push_to_github "$rid" "$task_id" "$verbose" || true
    done <<< "$repo_ids"

    # ── 步骤 3: 发送通知（失败不中断流程）──────────────────
    if [[ "$fetch_ok" == "true" ]]; then
        send_notification "拉取成功" "任务「${task_name}」订阅已更新" 2>/dev/null || true
    else
        send_notification "拉取失败(缓存推送)" \
            "任务「${task_name}」拉取失败，已用本地缓存推送至 GitHub" 2>/dev/null || true
    fi
}

run_task_interactive() {
    clear_screen
    print_header "立即执行任务"

    echo -e "  ${C}当前任务:${NC}"
    jq -r '.tasks[] | "  [\(.id)] \(.name) (\(if .enabled then "启用" else "禁用" end))"' \
        "$TASKS_FILE"
    echo ""

    local id; id=$(read_input "任务 ID (留空=执行所有启用任务)")

    if [[ -z "$id" ]]; then
        echo -e "\n  ${Y}执行所有启用任务...${NC}\n"
        local task_ids
        task_ids=$(jq -r '.tasks[] | select(.enabled==true) | .id' "$TASKS_FILE")
        while IFS= read -r tid; do
            [[ -z "$tid" ]] && continue
            local tname; tname=$(jq -r --argjson id "$tid" \
                '.tasks[] | select(.id==$id) | .name' "$TASKS_FILE")
            echo -e "  ${C}── 任务 [$tid] $tname ──${NC}"
            run_task "$tid" "true"
            echo ""
        done <<< "$task_ids"
    else
        run_task "$id" "true"
    fi

    press_enter
}

# ══════════════════════════════════════════════════════════
#  定时任务 (Cron 模式)
# ══════════════════════════════════════════════════════════

cron_check() {
    local now; now=$(date +%s)

    # ── 拉取任务调度 ──────────────────────────────────────────
    local task_list
    task_list=$(jq -r '.tasks[] | select(.enabled==true) | [.id,.interval,.last_run] | @tsv' "$TASKS_FILE")

    while IFS=$'\t' read -r task_id interval last_run; do
        [[ -z "$task_id" ]] && continue
        local interval_secs=$(( interval * 60 ))
        local elapsed=$(( now - last_run ))
        if [[ "$elapsed" -ge "$interval_secs" ]]; then
            log "INFO" "Cron trigger: task=$task_id (elapsed=${elapsed}s >= ${interval_secs}s)"
            run_task "$task_id" "false"
        fi
    done <<< "$task_list"

    # ── 仓库独立定时推送调度 ──────────────────────────────────
    local repo_list
    repo_list=$(jq -r '.repos[] | select((.push_interval // 0) > 0) |
        [.id, (.push_interval // 0), (.last_push // 0),
         (.task_ids | map(tostring) | join(","))] | @tsv' "$REPOS_FILE" 2>/dev/null)

    while IFS=$'\t' read -r repo_id push_interval last_push task_ids_csv; do
        [[ -z "$repo_id" ]] && continue
        local interval_secs=$(( push_interval * 60 ))
        local elapsed=$(( now - last_push ))
        if [[ "$elapsed" -ge "$interval_secs" ]]; then
            log "INFO" "Repo push trigger: repo=$repo_id (elapsed=${elapsed}s)"
            IFS=',' read -ra tids <<< "$task_ids_csv"
            for tid in "${tids[@]}"; do
                [[ -z "$tid" ]] && continue
                [[ -f "${DATA_DIR}/task_${tid}.txt" ]] || continue
                push_to_github "$repo_id" "$tid" "false"
            done
        fi
    done <<< "$repo_list"
}

setup_cron() {
    if ! _has_cron; then
        echo -e "  ${Y}当前平台不支持 crontab，请使用系统任务计划手动设置定时执行${NC}"
        return 1
    fi
    local entry="* * * * * ${INSTALL_DIR}/sub-manager.sh --cron-check >> ${LOG_DIR}/cron.log 2>&1"
    if ! crontab -l 2>/dev/null | grep -qF "sub-manager.sh --cron-check"; then
        ( crontab -l 2>/dev/null; echo "$entry" ) | crontab -
        return 0
    fi
    return 1  # already exists
}

remove_cron() {
    _has_cron || return 0
    crontab -l 2>/dev/null | grep -v "sub-manager.sh" | crontab - 2>/dev/null
}

# ══════════════════════════════════════════════════════════
#  日志查看
# ══════════════════════════════════════════════════════════

view_logs() {
    while true; do
        clear_screen
        print_header "日志查看"
        echo -e "  ${C}1.${NC} 综合日志 (最近50条)"
        echo -e "  ${C}2.${NC} 错误日志"
        echo -e "  ${C}3.${NC} 定时任务日志"
        echo -e "  ${C}4.${NC} 清空所有日志"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1)
                clear_screen; print_header "综合日志"
                tail -50 "${LOG_DIR}/main.log" 2>/dev/null || echo -e "  ${Y}日志为空${NC}"
                press_enter ;;
            2)
                clear_screen; print_header "错误日志"
                tail -50 "${LOG_DIR}/error.log" 2>/dev/null || echo -e "  ${Y}无错误日志${NC}"
                press_enter ;;
            3)
                clear_screen; print_header "定时任务日志"
                tail -50 "${LOG_DIR}/cron.log" 2>/dev/null || echo -e "  ${Y}日志为空${NC}"
                press_enter ;;
            4)
                confirm "确认清空所有日志?" && {
                    rm -f "${LOG_DIR}"/*.log
                    echo -e "  ${G}✓ 日志已清空${NC}"
                } || echo "  已取消"
                press_enter ;;
            0) return ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════
#  更新机制
# ══════════════════════════════════════════════════════════

# _ver_gt <a> <b>  →  a > b (语义版本比较)
_ver_gt() {
    local a="$1" b="$2"
    [[ "$a" == "$b" ]] && return 1
    local winner
    winner=$(printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [[ "$winner" == "$a" ]]
}

# _fetch_raw <path> <out_file>
# 先试直连，失败再试加速镜像，返回 0=成功
_fetch_raw() {
    local path="$1" out="$2"
    curl -fsSL --connect-timeout 10 --max-time 30 \
        "${GITHUB_RAW}/${path}" -o "$out" 2>/dev/null && return 0
    curl -fsSL --connect-timeout 10 --max-time 30 \
        "${GITHUB_RAW_PROXY}/${path}" -o "$out" 2>/dev/null
}

# update_check [silent]
# silent=true 时只在有更新时输出，用于主菜单静默检查
update_check() {
    local silent="${1:-false}"
    local tmp; tmp=$(mktemp)

    [[ "$silent" == "false" ]] && echo -ne "  检查更新中..."

    if ! _fetch_raw "sub-manager.sh" "$tmp"; then
        [[ "$silent" == "false" ]] && echo -e " ${R}网络不可达${NC}"
        rm -f "$tmp"; return 1
    fi

    local remote_ver
    remote_ver=$(grep -m1 '^readonly VERSION=' "$tmp" | cut -d'"' -f2)
    rm -f "$tmp"

    if [[ -z "$remote_ver" ]]; then
        [[ "$silent" == "false" ]] && echo -e " ${R}无法解析远端版本${NC}"
        return 1
    fi

    if _ver_gt "$remote_ver" "$VERSION"; then
        echo -e " ${G}发现新版本 ${remote_ver}${NC}（当前 ${VERSION}）"
        return 0   # 有更新
    else
        [[ "$silent" == "false" ]] && echo -e " ${G}已是最新版本 (${VERSION})${NC}"
        return 1   # 无更新
    fi
}

# update_do
# 下载新脚本并替换，完成后重启
update_do() {
    clear_screen
    print_header "更新程序"

    echo -ne "  ${C}获取最新版本...${NC} "
    local tmp; tmp=$(mktemp)

    if ! _fetch_raw "sub-manager.sh" "$tmp"; then
        echo -e "${R}下载失败${NC}"
        press_enter; return 1
    fi

    local remote_ver
    remote_ver=$(grep -m1 '^readonly VERSION=' "$tmp" | cut -d'"' -f2)
    if [[ -z "$remote_ver" ]]; then
        echo -e "${R}版本信息解析失败${NC}"
        rm -f "$tmp"; press_enter; return 1
    fi
    echo -e "${G}${remote_ver}${NC}"

    if ! _ver_gt "$remote_ver" "$VERSION"; then
        echo -e "\n  ${G}当前已是最新版本 (${VERSION})，无需更新${NC}"
        rm -f "$tmp"; press_enter; return 0
    fi

    echo -e "  本地版本: ${Y}${VERSION}${NC}  →  新版本: ${G}${remote_ver}${NC}"
    echo ""

    # 验证下载文件是有效 bash 脚本
    if ! bash -n "$tmp" 2>/dev/null; then
        echo -e "  ${R}✗ 下载文件语法校验失败，已中止${NC}"
        rm -f "$tmp"; press_enter; return 1
    fi

    confirm "确认更新到 v${remote_ver}?" || { rm -f "$tmp"; echo "  已取消"; press_enter; return 0; }

    # 备份当前版本
    local bak="${INSTALL_DIR}/sub-manager.sh.bak"
    cp "${INSTALL_DIR}/sub-manager.sh" "$bak"
    echo -e "  ${Y}→ 已备份当前版本到 $(basename $bak)${NC}"

    # 替换
    mv "$tmp" "${INSTALL_DIR}/sub-manager.sh"
    chmod +x "${INSTALL_DIR}/sub-manager.sh"

    echo -e "\n  ${G}✓ 更新完成! 即将重启...${NC}"
    log "INFO" "Updated: ${VERSION} -> ${remote_ver}"
    sleep 1

    # 用新版本替换当前进程
    exec "${INSTALL_DIR}/sub-manager.sh"
}

# update_rollback
# 回滚到备份版本
update_rollback() {
    local bak="${INSTALL_DIR}/sub-manager.sh.bak"
    if [[ ! -f "$bak" ]]; then
        echo -e "  ${R}未找到备份文件${NC}"; press_enter; return 1
    fi
    local bak_ver
    bak_ver=$(grep -m1 '^readonly VERSION=' "$bak" | cut -d'"' -f2)
    confirm "回滚到备份版本 (${bak_ver:-未知})?" || { echo "  已取消"; press_enter; return 0; }
    cp "$bak" "${INSTALL_DIR}/sub-manager.sh"
    chmod +x "${INSTALL_DIR}/sub-manager.sh"
    echo -e "  ${G}✓ 已回滚，即将重启...${NC}"
    log "INFO" "Rolled back to ${bak_ver}"
    sleep 1
    exec "${INSTALL_DIR}/sub-manager.sh"
}

# ══════════════════════════════════════════════════════════
#  系统设置
# ══════════════════════════════════════════════════════════

system_settings() {
    while true; do
        clear_screen
        print_header "系统设置"

        local cron_status="${Y}不支持${NC}"
        if _has_cron; then
            cron_status="${R}未启用${NC}"
            crontab -l 2>/dev/null | grep -qF "sub-manager.sh --cron-check" && \
                cron_status="${G}已启用${NC}"
        fi

        local bak_info=""
        [[ -f "${INSTALL_DIR}/sub-manager.sh.bak" ]] && \
            bak_info=" (备份: $(grep -m1 '^readonly VERSION=' "${INSTALL_DIR}/sub-manager.sh.bak" | cut -d'"' -f2))"

        echo -e "  版本:       ${W}${VERSION}${NC}${bak_info}"
        echo -e "  安装目录:   ${INSTALL_DIR}"
        echo -e "  定时任务:   $cron_status"
        echo ""
        echo -e "  ${C}1.${NC} 检查并更新"
        echo -e "  ${C}2.${NC} 回滚到上一版本"
        echo -e "  ${C}3.${NC} 启用定时任务"
        echo -e "  ${C}4.${NC} 禁用定时任务"
        echo -e "  ${C}5.${NC} 查看 Crontab"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) update_do ;;
            2) update_rollback ;;
            3)
                if setup_cron; then
                    echo -e "\n  ${G}✓ 定时任务已启用 (每分钟检查)${NC}"
                else
                    echo -e "\n  ${Y}定时任务已存在${NC}"
                fi
                press_enter ;;
            4)
                confirm "确认禁用定时任务?" && remove_cron && \
                    echo -e "\n  ${G}✓ 定时任务已禁用${NC}"
                press_enter ;;
            5)
                if _has_cron; then
                    echo ""; crontab -l 2>/dev/null || echo -e "  ${Y}Crontab 为空${NC}"
                else
                    echo -e "\n  ${Y}当前平台不支持 crontab${NC}"
                fi
                press_enter ;;
            0) return ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════

main_menu() {
    while true; do
        clear_screen
        echo -e "${C}"
        echo "  ╔═══════════════════════════════════════════════╗"
        echo "  ║      订 阅 管 理 工 具  v${VERSION}             ║"
        echo "  ║      Subscription Manager for Linux           ║"
        echo "  ╚═══════════════════════════════════════════════╝"
        echo -e "${NC}"

        local task_cnt repo_cnt
        task_cnt=$(jq '.tasks | length' "$TASKS_FILE")
        repo_cnt=$(jq '.repos | length' "$REPOS_FILE")
        local enabled_cnt; enabled_cnt=$(jq '[.tasks[] | select(.enabled)] | length' "$TASKS_FILE")

        echo -e "  ${Y}任务: ${task_cnt} (启用 ${enabled_cnt})  |  仓库: ${repo_cnt}${NC}"

        # 静默检查更新（后台，结果存入临时文件，下次刷新菜单时展示）
        local update_flag="/tmp/sub-manager-update-available"
        if [[ -f "$update_flag" ]]; then
            local new_ver; new_ver=$(cat "$update_flag" 2>/dev/null)
            echo -e "  ${G}★ 发现新版本 ${new_ver}，前往「系统设置」→「检查并更新」${NC}"
        fi
        echo ""
        echo -e "  ${C}1.${NC} 拉取任务管理"
        echo -e "  ${C}2.${NC} GitHub 仓库配置"
        echo -e "  ${C}3.${NC} 消息推送配置"
        echo -e "  ${C}4.${NC} 拉取代理配置"
        echo -e "  ${C}5.${NC} 立即执行任务"
        echo -e "  ${C}6.${NC} 查看日志"
        echo -e "  ${C}7.${NC} 系统设置"
        echo -e "  ${C}0.${NC} 退出"
        echo ""

        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) task_menu ;;
            2) repo_menu ;;
            3) notify_menu ;;
            4) proxy_menu ;;
            5) run_task_interactive ;;
            6) view_logs ;;
            7) system_settings ;;
            0) echo -e "\n  再见!\n"; exit 0 ;;
            *) echo -e "  ${R}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════════════════

if ! command -v jq &>/dev/null; then
    echo "错误: 缺少依赖 jq，请先运行 install.sh 或手动安装"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "错误: 缺少依赖 curl，请先运行 install.sh 或手动安装"
    exit 1
fi

init_configs

case "${1:-}" in
    --cron-check)
        cron_check
        ;;
    --run-task)
        [[ -z "${2:-}" ]] && { echo "用法: $0 --run-task <task_id>"; exit 1; }
        run_task "$2" "true"
        ;;
    --update)
        update_do
        ;;
    --check-update)
        update_check "false"
        ;;
    --status)
        echo "Sub Manager v${VERSION}"
        echo "Tasks: $(jq '.tasks | length' "$TASKS_FILE") (enabled: $(jq '[.tasks[]|select(.enabled)]|length' "$TASKS_FILE"))"
        echo "Repos: $(jq '.repos | length' "$REPOS_FILE")"
        ;;
    --help|-h)
        echo "用法: $0 [选项]"
        echo "  (无参数)          打开交互界面"
        echo "  --cron-check      检查并执行到期任务 (由 cron 调用)"
        echo "  --run-task <id>   立即执行指定任务"
        echo "  --update          直接执行更新"
        echo "  --check-update    检查是否有新版本"
        echo "  --status          显示状态摘要"
        ;;
    *)
        if [[ -t 0 ]]; then
            # 后台静默检查更新（不阻塞启动）
            (
                local flag="/tmp/sub-manager-update-available"
                local tmp; tmp=$(mktemp)
                if _fetch_raw "sub-manager.sh" "$tmp" 2>/dev/null; then
                    local rv; rv=$(grep -m1 '^readonly VERSION=' "$tmp" | cut -d'"' -f2)
                    if [[ -n "$rv" ]] && _ver_gt "$rv" "$VERSION"; then
                        echo "$rv" > "$flag"
                    else
                        rm -f "$flag"
                    fi
                fi
                rm -f "$tmp"
            ) &>/dev/null &
            main_menu
        else
            echo "非交互模式下请使用参数，运行 $0 --help 查看帮助"
            exit 1
        fi
        ;;
esac

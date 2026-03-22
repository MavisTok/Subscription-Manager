# lib/bot.sh

# ══════════════════════════════════════════════════════════
#  Telegram Bot 远程控制
# ══════════════════════════════════════════════════════════

readonly BOT_STATE_FILE="${CONFIG_DIR}/bot_state.json"
readonly BOT_PID_FILE="${INSTALL_DIR}/bot.pid"
BOT_TOKEN=""; BOT_CHAT_ID=""; BOT_CLIENT_NAME=""

_bot_load_config() {
    BOT_TOKEN=$(_dec "$(jq -r '.providers.telegram.token // ""' "$NOTIFY_FILE" 2>/dev/null)")
    BOT_CHAT_ID=$(_dec "$(jq -r '.providers.telegram.chat_id // ""' "$NOTIFY_FILE" 2>/dev/null)")
    BOT_CLIENT_NAME=$(jq -r '.providers.telegram.bot_client_name // ""' "$NOTIFY_FILE" 2>/dev/null)
}

# 保存客户端名称到 notify.json
_bot_save_client_name() {
    local name="$1"
    local tmp; tmp=$(mktemp)
    jq --arg n "$name" '.providers.telegram.bot_client_name = $n' "$NOTIFY_FILE" > "$tmp" \
        && mv "$tmp" "$NOTIFY_FILE"
    BOT_CLIENT_NAME="$name"
}

# 发送消息（--data-urlencode 自动处理特殊字符）
# 多客户端模式下自动在消息前加 [客户端名] 标识
_bot_send() {
    local chat_id="$1" text="$2" parse_mode="${3:-}"
    [[ -z "$BOT_TOKEN" ]] && return 1
    [[ -n "$BOT_CLIENT_NAME" ]] && text="[${BOT_CLIENT_NAME}] ${text}"
    local args=(-s --connect-timeout 10 --max-time 20
                -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
                -d "chat_id=${chat_id}"
                --data-urlencode "text=${text}"
                -d "disable_web_page_preview=true")
    [[ -n "$parse_mode" ]] && args+=(-d "parse_mode=${parse_mode}")
    curl "${args[@]}" > /dev/null 2>&1
}

# ── 客户端路由辅助 ────────────────────────────────────────

# 从 args 字符串开头提取 @clientname，返回名称（不含 @）
_bot_extract_target() {
    echo "$1" | grep -oE '^@[A-Za-z0-9_.-]+' | tr -d '@'
}

# 去掉 args 开头的 @clientname（及后面的空格）
_bot_strip_target() {
    echo "$1" | sed 's/^@[A-Za-z0-9_.-][A-Za-z0-9_.-]* *//'
}

# 判断本客户端是否应处理该命令
# target="" → 广播，所有客户端处理
# target="x" 且本客户端无名称 → 忽略定向命令
# target="x" 且本客户端名称匹配 → 处理
_bot_is_targeted() {
    local target="$1"
    [[ -z "$target" ]] && return 0
    [[ -z "$BOT_CLIENT_NAME" ]] && return 1
    [[ "$target" == "$BOT_CLIENT_NAME" ]] && return 0
    return 1
}

# ── 状态机 ────────────────────────────────────────────────
_bot_init_state()   { [[ -f "$BOT_STATE_FILE" ]] || echo '{"state":"idle","data":{}}' > "$BOT_STATE_FILE"; }
_bot_get_state()    { _bot_init_state; jq -r '.state // "idle"' "$BOT_STATE_FILE" 2>/dev/null; }
_bot_clear_state()  { echo '{"state":"idle","data":{}}' > "$BOT_STATE_FILE"; }
_bot_set_state() {
    local state="$1" data="${2:-{}}"
    jq --arg s "$state" --argjson d "$data" '.state=$s | .data=$d' "$BOT_STATE_FILE" > "${BOT_STATE_FILE}.tmp" \
        && mv "${BOT_STATE_FILE}.tmp" "$BOT_STATE_FILE"
}
_bot_get_data() { jq -r ".data.${1} // \"\"" "$BOT_STATE_FILE" 2>/dev/null; }
_bot_update_data() {
    local key="$1" value="$2"
    jq --arg k "$key" --arg v "$value" '.data[$k]=$v' "$BOT_STATE_FILE" > "${BOT_STATE_FILE}.tmp" \
        && mv "${BOT_STATE_FILE}.tmp" "$BOT_STATE_FILE"
}

# ── 单步命令 ──────────────────────────────────────────────
_bot_cmd_clients() {
    local chat_id="$1"
    local task_cnt; task_cnt=$(jq '.tasks | length' "$TASKS_FILE" 2>/dev/null || echo 0)
    local enabled_cnt; enabled_cnt=$(jq '[.tasks[] | select(.enabled)] | length' "$TASKS_FILE" 2>/dev/null || echo 0)
    local repo_cnt; repo_cnt=$(jq '.repos | length' "$REPOS_FILE" 2>/dev/null || echo 0)
    local name_info; name_info="${BOT_CLIENT_NAME:-（未命名）}"
    _bot_send "$chat_id" "🟢 在线
名称: ${name_info}
任务: ${task_cnt} (启用 ${enabled_cnt})  |  仓库: ${repo_cnt}
版本: v${VERSION}  平台: ${OS_TYPE}"
}

_bot_cmd_help() {
    local target_hint=""
    [[ -n "$BOT_CLIENT_NAME" ]] && \
        target_hint="
多客户端定向 (可选):
/cmd @${BOT_CLIENT_NAME} [参数]  - 仅本客户端执行
/cmd                             - 所有客户端响应"
    _bot_send "$1" "📋 订阅管理 Bot v${VERSION}

任务管理:
/tasks          - 查看所有任务
/run            - 执行全部启用任务
/run <ID>       - 执行指定任务
/toggle <ID>    - 启用/禁用任务
/addtask @名称  - 添加拉取任务

仓库管理:
/repos          - 查看所有仓库
/push <ID>      - 推送到指定仓库
/addrepo @名称  - 添加 GitHub 仓库

系统:
/status         - 状态概览
/clients        - 查看所有在线客户端
/logs           - 最近20条日志
/cancel         - 取消当前操作${target_hint}"
}

_bot_cmd_status() {
    local task_cnt enabled_cnt repo_cnt
    task_cnt=$(jq '.tasks | length' "$TASKS_FILE" 2>/dev/null)
    enabled_cnt=$(jq '[.tasks[] | select(.enabled==true)] | length' "$TASKS_FILE" 2>/dev/null)
    repo_cnt=$(jq '.repos | length' "$REPOS_FILE" 2>/dev/null)
    local last; last=$(tail -1 "${LOG_DIR}/main.log" 2>/dev/null)
    _bot_send "$1" "📊 系统状态
版本: v${VERSION}  平台: ${OS_TYPE}
任务: ${task_cnt} 个 (启用 ${enabled_cnt})
仓库: ${repo_cnt} 个
最近: ${last:-无日志}"
}

_bot_cmd_tasks() {
    local count; count=$(jq '.tasks | length' "$TASKS_FILE" 2>/dev/null)
    [[ "$count" -eq 0 ]] && { _bot_send "$1" "暂无任务配置"; return; }
    local msg="📋 任务列表"$'\n'
    while IFS=$'\t' read -r id name enabled interval last_run; do
        local icon; [[ "$enabled" == "true" ]] && icon="✅" || icon="⏸"
        local last_str="从未"
        [[ "$last_run" -gt 0 ]] 2>/dev/null && \
            last_str=$(date -r "$last_run" '+%m-%d %H:%M' 2>/dev/null || \
                       date -d "@${last_run}" '+%m-%d %H:%M' 2>/dev/null)
        msg+="${icon} [${id}] ${name} | ${interval}min | ${last_str}"$'\n'
    done < <(jq -r '.tasks[] | [(.id|tostring),.name,(.enabled|tostring),(.interval|tostring),(.last_run|tostring)] | @tsv' "$TASKS_FILE")
    _bot_send "$1" "$msg"
}

_bot_cmd_repos() {
    local count; count=$(jq '.repos | length' "$REPOS_FILE" 2>/dev/null)
    [[ "$count" -eq 0 ]] && { _bot_send "$1" "暂无仓库配置"; return; }
    local msg="🗂 仓库列表"$'\n'
    while IFS=$'\t' read -r id name enc_url filename; do
        local disp_url; disp_url=$(_dec "$enc_url")
        msg+="[${id}] ${name} → ${filename}"$'\n'"    ${disp_url}"$'\n'
    done < <(jq -r '.repos[] | [(.id|tostring),.name,.github_url,.filename] | @tsv' "$REPOS_FILE")
    _bot_send "$1" "$msg"
}

_bot_cmd_run() {
    local chat_id="$1" task_id="$2"
    if [[ -z "$task_id" ]]; then
        local ids; ids=$(jq -r '.tasks[] | select(.enabled==true) | .id' "$TASKS_FILE")
        [[ -z "$ids" ]] && { _bot_send "$chat_id" "⚠️ 没有启用的任务"; return; }
        _bot_send "$chat_id" "⏳ 开始执行所有启用任务..."
        local ran=0
        while IFS= read -r tid; do
            [[ -z "$tid" ]] && continue
            local tname; tname=$(jq -r --argjson id "$tid" '.tasks[] | select(.id==$id) | .name' "$TASKS_FILE")
            run_task "$tid" "false" && \
                _bot_send "$chat_id" "✅ [$tid] $tname 完成" || \
                _bot_send "$chat_id" "❌ [$tid] $tname 失败"
            ran=$((ran+1))
        done <<< "$ids"
        _bot_send "$chat_id" "✅ 共执行 ${ran} 个任务"
    else
        local tname; tname=$(jq -r --argjson id "$task_id" '.tasks[] | select(.id==$id) | .name // ""' "$TASKS_FILE")
        [[ -z "$tname" || "$tname" == "null" ]] && { _bot_send "$chat_id" "❌ 未找到任务 ID=${task_id}"; return; }
        _bot_send "$chat_id" "⏳ 执行任务 [${task_id}] ${tname}..."
        run_task "$task_id" "false" && \
            _bot_send "$chat_id" "✅ [${task_id}] ${tname} 执行成功" || \
            _bot_send "$chat_id" "❌ [${task_id}] ${tname} 执行失败，查看 /logs"
    fi
}

_bot_cmd_toggle() {
    local chat_id="$1" task_id="$2"
    [[ -z "$task_id" ]] && { _bot_send "$chat_id" "用法: /toggle <任务ID>"; return; }
    local cur; cur=$(jq -r --argjson id "$task_id" '.tasks[] | select(.id==$id) | .enabled // "null"' "$TASKS_FILE")
    [[ "$cur" == "null" ]] && { _bot_send "$chat_id" "❌ 未找到任务 ID=${task_id}"; return; }
    local new; [[ "$cur" == "true" ]] && new="false" || new="true"
    local tname; tname=$(jq -r --argjson id "$task_id" '.tasks[] | select(.id==$id) | .name' "$TASKS_FILE")
    local tmp; tmp=$(mktemp)
    jq --argjson id "$task_id" --argjson v "$new" \
       '(.tasks[] | select(.id==$id)) |= . + {"enabled":$v}' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
    local label; [[ "$new" == "true" ]] && label="已启用 ✅" || label="已禁用 ⏸"
    _bot_send "$chat_id" "[${task_id}] ${tname} ${label}"
}

_bot_cmd_push() {
    local chat_id="$1" repo_id="$2"
    [[ -z "$repo_id" ]] && { _bot_send "$chat_id" "用法: /push <仓库ID>  查看: /repos"; return; }
    local rname; rname=$(jq -r --argjson id "$repo_id" '.repos[] | select(.id==$id) | .name // ""' "$REPOS_FILE")
    [[ -z "$rname" || "$rname" == "null" ]] && { _bot_send "$chat_id" "❌ 未找到仓库 ID=${repo_id}"; return; }
    _bot_send "$chat_id" "⏳ 推送到仓库 [${repo_id}] ${rname}..."
    local task_ids; task_ids=$(jq -r --argjson id "$repo_id" '.repos[] | select(.id==$id) | .task_ids[]' "$REPOS_FILE" 2>/dev/null)
    local ok=0 fail=0 skip=0
    while IFS= read -r tid; do
        [[ -z "$tid" ]] && continue
        if [[ ! -f "${DATA_DIR}/task_${tid}.txt" ]]; then skip=$((skip+1)); continue; fi
        push_to_github "$repo_id" "$tid" "false" && ok=$((ok+1)) || fail=$((fail+1))
    done <<< "$task_ids"
    [[ $((ok+fail+skip)) -eq 0 ]] && \
        _bot_send "$chat_id" "⚠️ 无可推送文件，请先执行 /run" || \
        _bot_send "$chat_id" "✅ 推送完成: ${ok} 成功 ${fail} 失败 ${skip} 无数据"
}

_bot_cmd_logs() {
    local lines; lines=$(tail -20 "${LOG_DIR}/main.log" 2>/dev/null)
    [[ -z "$lines" ]] && { _bot_send "$1" "日志为空"; return; }
    _bot_send "$1" "📄 最近日志（最新20条）:"$'\n'"${lines}"
}

# ── addtask 多步流程 ──────────────────────────────────────
_bot_addtask_start() {
    _bot_set_state "addtask_name" "{}"
    _bot_send "$1" "➕ 添加拉取任务 (发送 /cancel 取消)

第1步: 请输入任务名称"
}

_bot_addtask_step() {
    local chat_id="$1" text="$2" state="$3"
    case "$state" in
        addtask_name)
            _bot_update_data "name" "$text"
            _bot_set_state "addtask_url"
            _bot_send "$chat_id" "第2步: 请输入订阅 URL" ;;
        addtask_url)
            _bot_update_data "url" "$text"
            _bot_set_state "addtask_interval"
            _bot_send "$chat_id" "第3步: 请输入拉取间隔（分钟，如: 60）" ;;
        addtask_interval)
            [[ ! "$text" =~ ^[0-9]+$ ]] && { _bot_send "$chat_id" "❌ 请输入数字，如: 60"; return; }
            _bot_update_data "interval" "$text"
            _bot_set_state "addtask_confirm"
            local n; n=$(_bot_get_data "name"); local u; u=$(_bot_get_data "url")
            _bot_send "$chat_id" "确认添加:
名称: ${n}
URL: ${u}
间隔: ${text} 分钟
回复 y 确认" ;;
        addtask_confirm)
            if [[ "$(echo "$text" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
                local name; name=$(_bot_get_data "name")
                local url; url=$(_bot_get_data "url")
                local enc_url; enc_url=$(_enc "$url")
                local interval; interval=$(_bot_get_data "interval")
                local id; id=$(jq '.next_id' "$TASKS_FILE")
                local tmp; tmp=$(mktemp)
                jq --argjson id "$id" --arg name "$name" --arg url "$enc_url" \
                   --argjson interval "$interval" \
                   '.tasks += [{"id":$id,"name":$name,"url":$url,"enabled":true,
                     "interval":$interval,"last_run":0,"ua":"","headers":"","proxy":""}]
                    | .next_id += 1' "$TASKS_FILE" > "$tmp" && mv "$tmp" "$TASKS_FILE"
                _bot_clear_state
                _bot_send "$chat_id" "✅ 任务 [${id}] ${name} 已添加
使用 /run ${id} 立即执行"
            else
                _bot_send "$chat_id" "回复 y 确认，或 /cancel 取消"
            fi ;;
    esac
}

# ── addrepo 多步流程 ──────────────────────────────────────
_bot_addrepo_start() {
    _bot_set_state "addrepo_name" "{}"
    _bot_send "$1" "🗂 添加 GitHub 仓库 (发送 /cancel 取消)

第1步: 请输入仓库别名（如: my-sub）"
}

_bot_addrepo_step() {
    local chat_id="$1" text="$2" state="$3"
    case "$state" in
        addrepo_name)
            _bot_update_data "name" "$text"; _bot_set_state "addrepo_url"
            _bot_send "$chat_id" "第2步: 请输入 GitHub 仓库地址
如: https://github.com/user/repo" ;;
        addrepo_url)
            _bot_update_data "url" "$text"; _bot_set_state "addrepo_token"
            _bot_send "$chat_id" "第3步: 请输入 GitHub Access Token
获取: https://github.com/settings/tokens/new
需要权限: Contents → Read and write" ;;
        addrepo_token)
            _bot_update_data "token" "$text"; _bot_set_state "addrepo_branch"
            _bot_send "$chat_id" "第4步: 推送分支（留空=main）" ;;
        addrepo_branch)
            [[ -z "$text" || "$text" == " " ]] && text="main"
            _bot_update_data "branch" "$text"; _bot_set_state "addrepo_subdir"
            _bot_send "$chat_id" "第5步: 子目录（留空=根目录，如: public）" ;;
        addrepo_subdir)
            _bot_update_data "subdir" "$text"; _bot_set_state "addrepo_filename"
            _bot_send "$chat_id" "第6步: 文件名（如: clash.yaml）" ;;
        addrepo_filename)
            [[ -z "$text" || "$text" == " " ]] && text="subscription.txt"
            local subdir; subdir=$(_bot_get_data "subdir")
            local fp; [[ -n "$subdir" ]] && fp="${subdir}/${text}" || fp="$text"
            _bot_update_data "filepath" "$fp"; _bot_set_state "addrepo_tasks"
            local tlist; tlist=$(jq -r '.tasks[] | "[\(.id)] \(.name)"' "$TASKS_FILE")
            _bot_send "$chat_id" "第7步: 关联任务 ID（多个逗号分隔，如: 1,2）
可用任务:
${tlist}" ;;
        addrepo_tasks)
            _bot_update_data "tasks" "$text"; _bot_set_state "addrepo_confirm"
            local name; name=$(_bot_get_data "name")
            local url; url=$(_bot_get_data "url")
            local branch; branch=$(_bot_get_data "branch")
            local fp; fp=$(_bot_get_data "filepath")
            _bot_send "$chat_id" "确认添加仓库:
名称: ${name}
地址: ${url}
分支: ${branch}  路径: ${fp}
关联任务: ${text}
回复 y 确认" ;;
        addrepo_confirm)
            if [[ "$(echo "$text" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
                local name url token branch fp tasks_str
                name=$(_bot_get_data "name"); url=$(_bot_get_data "url")
                token=$(_bot_get_data "token"); branch=$(_bot_get_data "branch")
                fp=$(_bot_get_data "filepath"); tasks_str=$(_bot_get_data "tasks")
                local enc_url; enc_url=$(_enc "$url")
                local enc_token; enc_token=$(_enc "$token")
                local task_ids_json
                task_ids_json=$(echo "$tasks_str" | tr ',' '\n' | grep -E '^[0-9]+$' | jq -R 'tonumber' | jq -s '.')
                local id; id=$(jq '.next_id' "$REPOS_FILE")
                local tmp; tmp=$(mktemp)
                jq --argjson id "$id" --arg name "$name" --arg url "$enc_url" \
                   --arg token "$enc_token" --arg branch "$branch" --arg filename "$fp" \
                   --argjson task_ids "$task_ids_json" \
                   '.repos += [{"id":$id,"name":$name,"github_url":$url,
                     "token":$token,"branch":$branch,"filename":$filename,
                     "task_ids":$task_ids,"push_interval":0,"last_push":0}]
                    | .next_id += 1' "$REPOS_FILE" > "$tmp" && mv "$tmp" "$REPOS_FILE"
                _bot_clear_state
                _bot_send "$chat_id" "✅ 仓库 [${id}] ${name} 已添加
使用 /push ${id} 立即推送"
            else
                _bot_send "$chat_id" "回复 y 确认，或 /cancel 取消"
            fi ;;
    esac
}

# ── 消息分发 ──────────────────────────────────────────────
_bot_handle_message() {
    local chat_id="$1" text="$2"
    text=$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$text" ]] && return

    # /cancel 优先
    if [[ "$text" == "/cancel" ]]; then
        _bot_clear_state
        _bot_send "$chat_id" "✅ 已取消"; return
    fi

    local state; state=$(_bot_get_state)

    # 多步流程中
    [[ "$state" == addtask_* ]] && { _bot_addtask_step "$chat_id" "$text" "$state"; return; }
    [[ "$state" == addrepo_* ]] && { _bot_addrepo_step "$chat_id" "$text" "$state"; return; }

    # 解析命令
    local cmd args
    cmd=$(echo "$text" | awk '{print $1}')
    cmd="${cmd%%@*}"   # 去掉 @botname 后缀
    args=$(echo "$text" | cut -d' ' -f2-)
    [[ "$args" == "$cmd" ]] && args=""
    args=$(echo "$args" | sed 's/^[[:space:]]*//')

    # 提取可选 @target，判断本客户端是否应处理
    local target; target=$(_bot_extract_target "$args")
    if [[ -n "$target" ]]; then
        args=$(_bot_strip_target "$args")
    fi
    _bot_is_targeted "$target" || return

    # addtask / addrepo 在多客户端模式下必须指定 @target，避免并行状态冲突
    if [[ -n "$BOT_CLIENT_NAME" && -z "$target" ]]; then
        case "$cmd" in
            /addtask|/addrepo)
                _bot_send "$chat_id" "⚠️ 多客户端模式下请指定目标客户端:
${cmd} @${BOT_CLIENT_NAME}
发 /clients 查看所有在线客户端"
                return ;;
        esac
    fi

    case "$cmd" in
        /start|/help) _bot_cmd_help    "$chat_id" ;;
        /status)      _bot_cmd_status  "$chat_id" ;;
        /clients)     _bot_cmd_clients "$chat_id" ;;
        /tasks)       _bot_cmd_tasks   "$chat_id" ;;
        /repos)       _bot_cmd_repos   "$chat_id" ;;
        /run)         _bot_cmd_run     "$chat_id" "$args" ;;
        /toggle)      _bot_cmd_toggle  "$chat_id" "$args" ;;
        /push)        _bot_cmd_push    "$chat_id" "$args" ;;
        /logs)        _bot_cmd_logs    "$chat_id" ;;
        /addtask)     _bot_addtask_start "$chat_id" ;;
        /addrepo)     _bot_addrepo_start "$chat_id" ;;
        *) [[ "$text" == /* ]] && _bot_send "$chat_id" "未知命令，发 /help 查看帮助" ;;
    esac
}

# ── Bot 主循环 ────────────────────────────────────────────
bot_run() {
    _bot_load_config
    if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" == "null" ]]; then
        echo "错误: Telegram Token 未配置，请先在「消息推送配置」中配置"; exit 1
    fi
    if [[ -z "$BOT_CHAT_ID" || "$BOT_CHAT_ID" == "null" ]]; then
        echo "错误: Chat ID 未配置"; exit 1
    fi
    _bot_init_state
    echo $$ > "$BOT_PID_FILE"
    log "INFO" "Bot started: pid=$$ client=${BOT_CLIENT_NAME:-unnamed}"
    echo "Bot 已启动 (PID=$$, 客户端: ${BOT_CLIENT_NAME:-未命名})，Ctrl+C 停止"
    local start_msg="🟢 Bot 已启动 v${VERSION}，发 /help 查看命令"
    [[ -n "$BOT_CLIENT_NAME" ]] && start_msg="🟢 [${BOT_CLIENT_NAME}] Bot 已启动 v${VERSION}，发 /help 查看命令"
    _bot_send "$BOT_CHAT_ID" "$start_msg"

    local offset=0
    while true; do
        local resp
        resp=$(curl -s --connect-timeout 5 --max-time 35 \
            "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30" 2>/dev/null)
        [[ $? -ne 0 || -z "$resp" ]] && { sleep 5; continue; }
        [[ "$(echo "$resp" | jq -r '.ok // false')" != "true" ]] && { sleep 5; continue; }

        local count; count=$(echo "$resp" | jq '.result | length' 2>/dev/null)
        [[ -z "$count" || "$count" -eq 0 ]] && continue

        local max_id; max_id=$(echo "$resp" | jq '.result[-1].update_id' 2>/dev/null)
        [[ -n "$max_id" && "$max_id" != "null" ]] && offset=$((max_id + 1))

        local i=0
        while [[ $i -lt $count ]]; do
            local upd; upd=$(echo "$resp" | jq ".result[${i}]")
            local cid msg_text
            cid=$(echo "$upd" | jq -r '.message.chat.id // empty' 2>/dev/null)
            msg_text=$(echo "$upd" | jq -r '.message.text // ""' 2>/dev/null)
            if [[ -n "$cid" && "$cid" == "$BOT_CHAT_ID" ]]; then
                _bot_handle_message "$cid" "$msg_text"
            elif [[ -n "$cid" ]]; then
                log "WARN" "Bot: unauthorized chat_id=${cid}"
            fi
            i=$((i + 1))
        done
    done
}

bot_is_running() {
    [[ -f "$BOT_PID_FILE" ]] || return 1
    local pid; pid=$(cat "$BOT_PID_FILE" 2>/dev/null)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

bot_status_label() {
    if bot_is_running; then
        echo -e "${G}运行中 (PID=$(cat "$BOT_PID_FILE"))${NC}"
    else
        echo -e "${R}未运行${NC}"
    fi
}

bot_menu() {
    while true; do
        clear_screen
        print_header "Telegram Bot 管理"
        _bot_load_config
        local tok_info="未配置"; [[ -n "$BOT_TOKEN" && "$BOT_TOKEN" != "null" ]] && tok_info="${BOT_TOKEN:0:10}***"
        echo -e "  Token:      ${C}${tok_info}${NC}"
        echo -e "  Chat ID:    ${C}${BOT_CHAT_ID:-未配置}${NC}"
        echo -e "  客户端名称: ${C}${BOT_CLIENT_NAME:-（未设置，单机模式）}${NC}"
        echo -ne "  状态:       "; bot_status_label
        echo ""
        echo -e "  ${C}1.${NC} 启动 Bot (前台)"
        echo -e "  ${C}2.${NC} 启动 Bot (后台守护)"
        echo -e "  ${C}3.${NC} 停止 Bot"
        echo -e "  ${C}4.${NC} 查看 Bot 日志"
        echo -e "  ${C}5.${NC} 设置客户端名称"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1)
                echo ""
                bot_run ;;
            2)
                echo ""
                if bot_is_running; then
                    echo -e "  ${Y}Bot 已在运行 (PID=$(cat "$BOT_PID_FILE"))${NC}"
                else
                    if [[ "$OS_TYPE" == "windows" ]]; then
                        local _bexe; _bexe=$(_win_bash_path)
                        local _bscript; _bscript=$(_win_path "${INSTALL_DIR}/sub-manager.sh")
                        local _blog; _blog=$(_win_path "${LOG_DIR}/bot.log")
                        powershell.exe -NonInteractive -WindowStyle Hidden \
                            -Command "Start-Process -FilePath '$_bexe' \
                                -ArgumentList '-l','$_bscript','--bot' \
                                -RedirectStandardOutput '$_blog' \
                                -RedirectStandardError '$_blog' \
                                -WindowStyle Hidden" > /dev/null 2>&1
                    else
                        nohup bash "${INSTALL_DIR}/sub-manager.sh" --bot \
                            >> "${LOG_DIR}/bot.log" 2>&1 &
                    fi
                    sleep 1
                    bot_is_running && \
                        echo -e "  ${G}✓ Bot 已在后台启动${NC}" || \
                        echo -e "  ${R}✗ 启动失败，查看日志${NC}"
                fi
                press_enter ;;
            3)
                if bot_is_running; then
                    local pid; pid=$(cat "$BOT_PID_FILE")
                    kill "$pid" 2>/dev/null && rm -f "$BOT_PID_FILE"
                    echo -e "  ${G}✓ Bot 已停止${NC}"
                else
                    echo -e "  ${Y}Bot 未在运行${NC}"
                fi
                press_enter ;;
            4)
                clear_screen; print_header "Bot 日志"
                tail -50 "${LOG_DIR}/bot.log" 2>/dev/null || echo -e "  ${Y}日志为空${NC}"
                press_enter ;;
            5)
                echo ""
                echo -e "  ${Y}客户端名称用于多机部署时区分不同客户端${NC}"
                echo -e "  ${Y}仅使用字母、数字、下划线、连字符，如: router1 vps-hk${NC}"
                [[ -n "$BOT_CLIENT_NAME" ]] && echo -e "  当前名称: ${C}${BOT_CLIENT_NAME}${NC}"
                local new_name; new_name=$(read_input "请输入客户端名称 (留空清除)")
                new_name=$(echo "$new_name" | tr -d ' ')
                _bot_save_client_name "$new_name"
                if [[ -n "$new_name" ]]; then
                    echo -e "  ${G}✓ 客户端名称已设为: ${new_name}${NC}"
                else
                    echo -e "  ${G}✓ 客户端名称已清除（单机模式）${NC}"
                fi
                press_enter ;;
            0) return ;;
        esac
    done
}

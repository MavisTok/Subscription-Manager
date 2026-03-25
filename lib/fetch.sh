# lib/fetch.sh

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
    url=$(_dec "$(echo "$task" | jq -r '.url')")
    custom_ua=$(echo "$task" | jq -r '.ua // ""')
    custom_headers=$(_dec "$(echo "$task" | jq -r '.headers // ""')")
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
    github_url=$(_dec "$(echo "$repo" | jq -r '.github_url')")
    token=$(_dec "$(echo "$repo" | jq -r '.token')")
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

            mkdir -p "$(dirname "$remote_file")"
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
            mkdir -p "$(dirname "${tmp_git}/${filename}")"
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

    # 立即更新 last_run，防止调度器在本次失败后每分钟重复触发通知
    local _now _tmpj; _now=$(date +%s); _tmpj=$(mktemp)
    jq --argjson id "$task_id" --argjson ts "$_now" \
       '(.tasks[] | select(.id==$id)) |= . + {"last_run":$ts}' \
       "$TASKS_FILE" > "$_tmpj" && mv "$_tmpj" "$TASKS_FILE"

    # 通知状态标记文件（独立于 tasks.json，避免 jq 读写竞争）
    # 格式: "state:unix_timestamp"  (e.g. "ok:1711234567")
    local notify_flag="${DATA_DIR}/.notify_${task_id}"
    local last_notify_state="" last_notify_time=0
    if [[ -f "$notify_flag" ]]; then
        local _flag_raw; _flag_raw=$(cat "$notify_flag" 2>/dev/null)
        case "$_flag_raw" in
            *:*) last_notify_state="${_flag_raw%%:*}"
                 last_notify_time="${_flag_raw##*:}" ;;
            *)   last_notify_state="$_flag_raw"      # 兼容旧格式（无时间戳）
                 last_notify_time=0 ;;
        esac
    fi
    # 首次运行视为正常态，成功时不发通知
    [[ -z "$last_notify_state" ]] && last_notify_state="ok"

    # 获取任务间隔，用于计算通知冷却期
    local task_interval; task_interval=$(jq -r --argjson id "$task_id" \
        '.tasks[] | select(.id==$id) | .interval' "$TASKS_FILE" 2>/dev/null)
    [[ -z "$task_interval" || "$task_interval" == "null" ]] && task_interval=60
    # 通知冷却期 = max(interval × 3, 30) 分钟，防止振荡时频繁推送
    local cooldown_secs=$(( task_interval * 3 * 60 ))
    [[ "$cooldown_secs" -lt 1800 ]] && cooldown_secs=1800  # 最少 30 分钟

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
            local _nc_elapsed=$(( _now - last_notify_time ))
            if [[ "$last_notify_state" != "fail_nocache" ]] && \
               [[ "$_nc_elapsed" -ge "$cooldown_secs" || "$last_notify_time" -eq 0 ]]; then
                send_notification "拉取失败" "任务「${task_name}」拉取失败且无本地缓存" 2>/dev/null || true
                echo "fail_nocache:${_now}" > "$notify_flag"
            fi
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

    # ── 步骤 3: 智能通知（防振荡 + 冷却期）─────────────────
    # 通知策略:
    #   - ok→ok:            不通知（常规成功无需打扰）
    #   - fail→ok:          通知「已恢复」（需在冷却期外）
    #   - ok→fail:          通知「失败」（需在冷却期外）
    #   - fail→fail:        不通知（持续故障不重复推送）
    #   - 首次成功:         不通知（正常状态无需告知）
    #   - 冷却期内状态振荡: 不通知（防止时好时坏频繁推送）
    local notify_tag
    [[ "$fetch_ok" == "true" ]] && notify_tag="ok" || notify_tag="fail_cache"

    if [[ "$notify_tag" != "$last_notify_state" ]]; then
        local since_last=$(( _now - last_notify_time ))
        if [[ "$since_last" -ge "$cooldown_secs" || "$last_notify_time" -eq 0 ]]; then
            if [[ "$fetch_ok" == "true" ]]; then
                # 从故障中恢复
                send_notification "拉取恢复" \
                    "任务「${task_name}」订阅已恢复正常更新" 2>/dev/null || true
            else
                send_notification "拉取失败(缓存推送)" \
                    "任务「${task_name}」拉取失败，已用本地缓存推送至 GitHub" 2>/dev/null || true
            fi
            echo "${notify_tag}:${_now}" > "$notify_flag"
        else
            # 冷却期内不发通知，但更新状态和时间戳：
            #   - 更新状态：防止下次还判定为"状态变化"
            #   - 更新时间戳：冷却期从现在重新计算，持续振荡持续静默
            echo "${notify_tag}:${_now}" > "$notify_flag"
            log "INFO" "Notification suppressed (cooldown): task=$task_id tag=$notify_tag elapsed=${since_last}s < ${cooldown_secs}s"
        fi
    else
        log "INFO" "Notification skipped (same status): task=$task_id status=$notify_tag"
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

# lib/scheduler.sh

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

# ── Windows 调度变量（setup_cron/remove_cron 等都依赖这些）──
_schtask_name="SubManager"
_has_schtasks() { command -v schtasks &>/dev/null; }
_win_path() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
_win_bash_path() { cygpath -w "${BASH:-$(command -v bash)}" 2>/dev/null || echo "bash.exe"; }

setup_cron() {
    if [[ "$OS_TYPE" == "windows" ]]; then
        _has_schtasks || { echo -e "  ${Y}未找到 schtasks，无法创建计划任务${NC}"; return 1; }
        schtasks /Query /TN "$_schtask_name" > /dev/null 2>&1 && return 1  # already exists
        _setup_schtask; return $?
    fi
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
    if [[ "$OS_TYPE" == "windows" ]]; then
        _has_schtasks || return 0
        schtasks /Delete /F /TN "$_schtask_name" > /dev/null 2>&1 || true
        rm -f "${INSTALL_DIR}/cron-check.bat"
        return 0
    fi
    _has_cron || return 0
    crontab -l 2>/dev/null | grep -v "sub-manager.sh" | crontab - 2>/dev/null
}

# ══════════════════════════════════════════════════════════
#  保活机制 (跨平台: launchd / systemd / cron / schtasks)
# ══════════════════════════════════════════════════════════

_launchd_plist="${HOME}/Library/LaunchAgents/com.sub-manager.plist"
_systemd_dir="${HOME}/.config/systemd/user"
_systemd_svc="${_systemd_dir}/sub-manager.service"
_systemd_timer="${_systemd_dir}/sub-manager.timer"

# 创建 cron-check.bat 包装脚本并向 Task Scheduler 注册每分钟触发
_setup_schtask() {
    local bat_file="${INSTALL_DIR}/cron-check.bat"
    local bash_exe; bash_exe=$(_win_bash_path)
    local script_win; script_win=$(_win_path "${INSTALL_DIR}/sub-manager.sh")
    local log_win;    log_win=$(_win_path "${LOG_DIR}/cron.log")
    printf '@echo off\n"%s" -l "%s" --cron-check >> "%s" 2>&1\n' \
        "$bash_exe" "$script_win" "$log_win" > "$bat_file"
    local bat_win; bat_win=$(_win_path "$bat_file")
    schtasks /Create /F /TN "$_schtask_name" \
        /TR "\"$bat_win\"" \
        /SC MINUTE /MO 1 /RL HIGHEST > /dev/null 2>&1
}

# 返回当前保活状态描述
keepalive_status() {
    case "$OS_TYPE" in
        windows)
            if _has_schtasks && schtasks /Query /TN "$_schtask_name" > /dev/null 2>&1; then
                echo -e "${G}Task Scheduler 运行中${NC}"
            else
                echo -e "${R}未启用${NC}"
            fi ;;
        macos)
            if [[ -f "$_launchd_plist" ]] && \
               launchctl list 2>/dev/null | grep -q "com.sub-manager"; then
                echo -e "${G}LaunchAgent 运行中${NC}"
            elif [[ -f "$_launchd_plist" ]]; then
                echo -e "${Y}LaunchAgent 已安装(未加载)${NC}"
            elif _has_cron && crontab -l 2>/dev/null | grep -qF "sub-manager.sh --cron-check"; then
                echo -e "${Y}Cron (建议切换为 LaunchAgent)${NC}"
            else
                echo -e "${R}未启用${NC}"
            fi ;;
        linux)
            if command -v systemctl &>/dev/null && \
               systemctl --user is-active sub-manager.timer &>/dev/null 2>&1; then
                echo -e "${G}systemd timer 运行中${NC}"
            elif _has_cron && crontab -l 2>/dev/null | grep -qF "sub-manager.sh --cron-check"; then
                echo -e "${G}Cron 运行中${NC}"
            else
                echo -e "${R}未启用${NC}"
            fi ;;
        *)
            if _has_cron && crontab -l 2>/dev/null | grep -qF "sub-manager.sh --cron-check"; then
                echo -e "${G}Cron 运行中${NC}"
            else
                echo -e "${R}未启用${NC}"
            fi ;;
    esac
}

# 启用保活（自动选择最优方式）
setup_keepalive() {
    case "$OS_TYPE" in
        windows)
            _has_schtasks || { echo -e "  ${R}✗ 未找到 schtasks.exe，无法创建计划任务${NC}"; return 1; }
            if schtasks /Query /TN "$_schtask_name" > /dev/null 2>&1; then
                echo -e "  ${Y}Task Scheduler 任务已存在${NC}"
                return 0
            fi
            if _setup_schtask; then
                echo -e "  ${G}✓ Task Scheduler 任务已创建 (每分钟, 开机自启)${NC}"
            else
                echo -e "  ${R}✗ Task Scheduler 任务创建失败${NC}"
            fi
            ;;
        macos)
            mkdir -p "${HOME}/Library/LaunchAgents"
            cat > "$_launchd_plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.sub-manager</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${INSTALL_DIR}/sub-manager.sh</string>
    <string>--cron-check</string>
  </array>
  <key>StartInterval</key>     <integer>60</integer>
  <key>RunAtLoad</key>         <true/>
  <key>StandardOutPath</key>   <string>${LOG_DIR}/cron.log</string>
  <key>StandardErrorPath</key> <string>${LOG_DIR}/cron.log</string>
  <key>KeepAlive</key>         <false/>
</dict>
</plist>
PLIST
            launchctl unload "$_launchd_plist" 2>/dev/null || true
            launchctl load -w "$_launchd_plist" 2>/dev/null && \
                echo -e "  ${G}✓ LaunchAgent 已启用 (每60秒, 开机自启)${NC}" || \
                echo -e "  ${R}✗ LaunchAgent 加载失败${NC}"
            ;;
        linux)
            if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
                mkdir -p "$_systemd_dir"
                cat > "$_systemd_svc" << SVCEOF
[Unit]
Description=Sub Manager scheduled fetch/push

[Service]
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/sub-manager.sh --cron-check
StandardOutput=append:${LOG_DIR}/cron.log
StandardError=append:${LOG_DIR}/cron.log
SVCEOF
                cat > "$_systemd_timer" << TIMEREOF
[Unit]
Description=Sub Manager - run every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
TIMEREOF
                systemctl --user daemon-reload
                systemctl --user enable --now sub-manager.timer 2>/dev/null && \
                    echo -e "  ${G}✓ systemd timer 已启用 (每60秒, 开机自启)${NC}" || \
                    echo -e "  ${R}✗ systemd timer 启动失败，回退到 Cron${NC}"
            else
                setup_cron && \
                    echo -e "  ${G}✓ Cron 任务已添加 (每分钟检查)${NC}" || \
                    echo -e "  ${Y}Cron 任务已存在${NC}"
            fi
            ;;
        *)
            setup_cron && \
                echo -e "  ${G}✓ Cron 任务已添加${NC}" || \
                echo -e "  ${Y}Cron 任务已存在${NC}"
            ;;
    esac
}

# 停止保活（清理所有方式）
remove_keepalive() {
    local removed=false
    # Windows Task Scheduler
    if [[ "$OS_TYPE" == "windows" ]] && _has_schtasks; then
        if schtasks /Query /TN "$_schtask_name" > /dev/null 2>&1; then
            schtasks /Delete /F /TN "$_schtask_name" > /dev/null 2>&1 || true
            rm -f "${INSTALL_DIR}/cron-check.bat"
            removed=true
        fi
    fi
    # launchd
    if [[ -f "$_launchd_plist" ]]; then
        launchctl unload "$_launchd_plist" 2>/dev/null || true
        rm -f "$_launchd_plist"
        removed=true
    fi
    # systemd
    if [[ -f "$_systemd_timer" ]]; then
        systemctl --user disable --now sub-manager.timer 2>/dev/null || true
        rm -f "$_systemd_svc" "$_systemd_timer"
        systemctl --user daemon-reload 2>/dev/null || true
        removed=true
    fi
    # cron
    if _has_cron && crontab -l 2>/dev/null | grep -qF "sub-manager.sh --cron-check"; then
        remove_cron
        removed=true
    fi
    [[ "$removed" == "true" ]] && \
        echo -e "  ${G}✓ 保活服务已停止${NC}" || \
        echo -e "  ${Y}无保活服务在运行${NC}"
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
#  系统设置
# ══════════════════════════════════════════════════════════

system_settings() {
    while true; do
        clear_screen
        print_header "系统设置"

        local bak_info=""
        [[ -f "${INSTALL_DIR}/sub-manager.sh.bak" ]] && \
            bak_info=" (备份: $(grep -m1 '^readonly VERSION=' "${INSTALL_DIR}/sub-manager.sh.bak" | cut -d'"' -f2))"

        local ka_status; ka_status=$(keepalive_status)

        echo -e "  版本:       ${W}${VERSION}${NC}${bak_info}"
        echo -e "  安装目录:   ${INSTALL_DIR}"
        echo -e "  保活服务:   $ka_status"
        echo ""
        echo -e "  ${C}1.${NC} 检查并更新"
        echo -e "  ${C}2.${NC} 回滚到上一版本"
        echo -e "  ${C}3.${NC} 启用保活服务"
        echo -e "  ${C}4.${NC} 停止保活服务"
        echo -e "  ${C}5.${NC} 查看调度状态"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""
        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) update_do ;;
            2) update_rollback ;;
            3) echo ""; setup_keepalive; press_enter ;;
            4)
                confirm "确认停止保活服务?" && { echo ""; remove_keepalive; }
                press_enter ;;
            5)
                echo ""
                echo -e "  ${W}当前平台: ${OS_TYPE}${NC}"
                echo -ne "  保活状态: "; keepalive_status
                echo ""
                case "$OS_TYPE" in
                    windows)
                        echo -e "  ${C}Task Scheduler 任务:${NC} ${_schtask_name}"
                        if _has_schtasks && schtasks /Query /TN "$_schtask_name" > /dev/null 2>&1; then
                            echo -e "  已注册 ✓"
                            echo ""
                            schtasks /Query /TN "$_schtask_name" /FO LIST 2>/dev/null | grep -E "任务名称|状态|下次运行时间|Task Name|Status|Next Run" || true
                        else
                            echo -e "  ${Y}未注册${NC}"
                        fi
                        [[ -f "${INSTALL_DIR}/cron-check.bat" ]] && \
                            echo -e "  包装脚本: ${INSTALL_DIR}/cron-check.bat" ;;
                    macos)
                        echo -e "  ${C}LaunchAgent:${NC} ${_launchd_plist}"
                        [[ -f "$_launchd_plist" ]] && \
                            echo -e "  已安装 ✓" || echo -e "  未安装"
                        echo ""
                        launchctl list 2>/dev/null | grep "sub-manager" || true ;;
                    linux)
                        if command -v systemctl &>/dev/null; then
                            systemctl --user status sub-manager.timer 2>/dev/null || true
                        fi
                        echo ""
                        _has_cron && crontab -l 2>/dev/null | grep "sub-manager" || true ;;
                    *)
                        _has_cron && crontab -l 2>/dev/null | grep "sub-manager" || \
                            echo -e "  ${Y}无 Cron 条目${NC}" ;;
                esac
                press_enter ;;
            0) return ;;
        esac
    done
}

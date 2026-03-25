#!/bin/bash
# ============================================================
#  订阅管理工具 (Subscription Manager)
#  功能: 订阅拉取 / GitHub推送 / 消息通知 / 定时任务
#  平台: Linux / macOS / Windows (Git Bash / WSL) / OpenWrt
# ============================================================

readonly VERSION="1.3.18"  # auto-managed by .githooks/pre-commit
readonly GITHUB_RAW="https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main"
readonly GITHUB_RAW_PROXY="https://ghfast.top/${GITHUB_RAW}"

# ── 加载模块 ───────────────────────────────────────────────
_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
readonly _LIB_DIR="${_ENTRY_DIR}/lib"

# 检测是否缺少模块，老版本升级后自动补全下载
_missing=0
for _mod in core tasks repos notify proxy fetch scheduler update bot webdav; do
    [[ ! -f "${_LIB_DIR}/${_mod}.sh" ]] && _missing=$(( _missing + 1 ))
done

if [[ "$_missing" -gt 0 ]]; then
    echo "检测到 ${_missing} 个模块缺失，正在自动下载..."
    mkdir -p "$_LIB_DIR"
    _dl_ok=0
    for _mod in core tasks repos notify proxy fetch scheduler update bot webdav; do
        _f="${_LIB_DIR}/${_mod}.sh"
        [[ -f "$_f" ]] && continue
        printf "  lib/%s.sh ... " "${_mod}"
        if curl -fsSL --connect-timeout 10 --max-time 30 \
                "${GITHUB_RAW}/lib/${_mod}.sh" -o "$_f" 2>/dev/null || \
           curl -fsSL --connect-timeout 10 --max-time 30 \
                "${GITHUB_RAW_PROXY}/lib/${_mod}.sh" -o "$_f" 2>/dev/null; then
            chmod +x "$_f"
            echo "✓"
            _dl_ok=$(( _dl_ok + 1 ))
        else
            rm -f "$_f"
            echo "✗"
        fi
    done
    if [[ "$_dl_ok" -lt "$_missing" ]]; then
        echo "部分模块下载失败，请检查网络后重试，或重新安装:"
        echo "  bash <(curl -fsSL ${GITHUB_RAW_PROXY}/install.sh)"
        exit 1
    fi
    echo "模块下载完成，继续启动..."
fi
unset _missing _dl_ok _mod

for _mod in core tasks repos notify proxy fetch scheduler update bot webdav; do
    _f="${_LIB_DIR}/${_mod}.sh"
    # shellcheck disable=SC1090
    source "$_f"
done
unset _mod _f _ENTRY_DIR

# ── 主菜单 ─────────────────────────────────────────────────
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
        echo -e "  ${C}8.${NC} Telegram Bot"
        echo -e "  ${C}9.${NC} WebDAV 同步"
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
            8) bot_menu ;;
            9) webdav_menu ;;
            0) echo -e "\n  再见!\n"; exit 0 ;;
            *) echo -e "  ${R}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# ── 入口 ───────────────────────────────────────────────────

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
    --bot)
        bot_run
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
        echo "  --bot             启动 Telegram Bot (前台)"
        ;;
    *)
        if [[ -t 0 ]]; then
            clear_screen
            if update_prompt_on_start; then
                update_do
            else
                main_menu
            fi
        else
            echo "非交互模式下请使用参数，运行 $0 --help 查看帮助"
            exit 1
        fi
        ;;
esac

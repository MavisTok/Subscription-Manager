#!/bin/bash
# ============================================================
#  订阅管理工具 (Subscription Manager)
#  功能: 订阅拉取 / GitHub推送 / 消息通知 / 定时任务
#  平台: Linux / macOS / Windows (Git Bash / WSL) / OpenWrt
# ============================================================

readonly VERSION="1.3.11"  # auto-managed by .githooks/pre-commit
readonly GITHUB_RAW="https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main"
readonly GITHUB_RAW_PROXY="https://ghfast.top/${GITHUB_RAW}"

# ── 加载模块 ───────────────────────────────────────────────
_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
readonly _LIB_DIR="${_ENTRY_DIR}/lib"

for _mod in core tasks repos notify proxy fetch scheduler update bot; do
    _f="${_LIB_DIR}/${_mod}.sh"
    if [[ ! -f "$_f" ]]; then
        echo "错误: 缺少模块 ${_f}"
        echo "请重新安装: bash <(curl -fsSL ${GITHUB_RAW}/install.sh)"
        exit 1
    fi
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

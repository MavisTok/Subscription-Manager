# lib/proxy.sh

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

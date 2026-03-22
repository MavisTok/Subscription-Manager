# lib/notify.sh

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
    cur_token=$(_dec "$(jq -r '.providers.telegram.token' "$NOTIFY_FILE")")
    cur_chat_id=$(_dec "$(jq -r '.providers.telegram.chat_id' "$NOTIFY_FILE")")
    cur_enabled=$(jq -r '.providers.telegram.enabled' "$NOTIFY_FILE")

    echo -e "  当前状态: $([ "$cur_enabled" == "true" ] && echo -e "${G}启用${NC}" || echo -e "${R}禁用${NC}")"
    [[ -n "$cur_token" ]] && echo -e "  当前 Token: ${Y}$(_mask "$(jq -r '.providers.telegram.token' "$NOTIFY_FILE")")${NC}"
    echo -e "  获取方式: 与 @BotFather 对话创建Bot，再获取 chat_id"
    echo ""

    local new_token new_chat_id enable_yn new_enabled
    new_token=$(read_input "Bot Token" "$cur_token")
    new_chat_id=$(read_input "Chat ID" "$cur_chat_id")
    read -rp "  启用 Telegram 通知? [y/N]: " enable_yn
    [[ "$(echo "$enable_yn" | tr '[:upper:]' '[:lower:]')" == "y" ]] && new_enabled="true" || new_enabled="false"

    local enc_token; enc_token=$(_enc "$new_token")
    local enc_chat_id; enc_chat_id=$(_enc "$new_chat_id")
    local tmp; tmp=$(mktemp)
    jq --arg token "$enc_token" --arg chat_id "$enc_chat_id" \
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
    cur_key=$(_dec "$(jq -r '.providers.bark.key' "$NOTIFY_FILE")")
    cur_server=$(_dec "$(jq -r '.providers.bark.server' "$NOTIFY_FILE")")
    cur_enabled=$(jq -r '.providers.bark.enabled' "$NOTIFY_FILE")

    echo -e "  Bark 是 iOS 推送应用, App Store 搜索 Bark 下载"
    echo ""

    local new_key new_server enable_yn new_enabled
    new_key=$(read_input "Bark Key" "$cur_key")
    new_server=$(read_input "Bark Server" "$cur_server")
    read -rp "  启用 Bark 通知? [y/N]: " enable_yn
    [[ "$(echo "$enable_yn" | tr '[:upper:]' '[:lower:]')" == "y" ]] && new_enabled="true" || new_enabled="false"

    local enc_key; enc_key=$(_enc "$new_key")
    local enc_server; enc_server=$(_enc "$new_server")
    local tmp; tmp=$(mktemp)
    jq --arg key "$enc_key" --arg server "$enc_server" \
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
    cur_url=$(_dec "$(jq -r '.providers.webhook.url' "$NOTIFY_FILE")")
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

    local enc_url; enc_url=$(_enc "$new_url")
    local tmp; tmp=$(mktemp)
    jq --arg url "$enc_url" --arg method "$new_method" \
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
        tg_token=$(_dec "$(jq -r '.providers.telegram.token' "$NOTIFY_FILE")")
        tg_chat=$(_dec "$(jq -r '.providers.telegram.chat_id' "$NOTIFY_FILE")")
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
        bark_key=$(_dec "$(jq -r '.providers.bark.key' "$NOTIFY_FILE")")
        bark_server=$(_dec "$(jq -r '.providers.bark.server' "$NOTIFY_FILE")")
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
        wh_url=$(_dec "$(jq -r '.providers.webhook.url' "$NOTIFY_FILE")")
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

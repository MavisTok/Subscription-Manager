# lib/tasks.sh

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
        url=$(_dec "$(jq -r --argjson id "$detail_id" '.tasks[] | select(.id==$id) | .url' "$TASKS_FILE" 2>/dev/null)")
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
    local enc_url; enc_url=$(_enc "$url")
    local enc_headers; enc_headers=$(_enc "$headers")
    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$name" --arg url "$enc_url" \
       --argjson interval "$interval" --arg notes "$notes" \
       --arg ua "$ua" --arg headers "$enc_headers" --arg proxy "$task_proxy" \
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
    cur_url=$(_dec "$(echo "$task" | jq -r '.url')")
    cur_interval=$(echo "$task" | jq -r '.interval')
    cur_notes=$(echo "$task" | jq -r '.notes')
    cur_ua=$(echo "$task" | jq -r '.ua // ""')
    cur_headers=$(_dec "$(echo "$task" | jq -r '.headers // ""')")

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

    local enc_new_url; enc_new_url=$(_enc "$new_url")
    local enc_new_headers; enc_new_headers=$(_enc "$new_headers")
    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$new_name" --arg url "$enc_new_url" \
       --argjson interval "$new_interval" --arg notes "$new_notes" \
       --arg ua "$new_ua" --arg headers "$enc_new_headers" --arg proxy "$new_proxy" \
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

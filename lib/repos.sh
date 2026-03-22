# lib/repos.sh

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
        local disp_url; disp_url=$(_dec "$url")
        echo -e "  ${C}[$id]${NC} ${W}$name${NC}"
        echo -e "      仓库: ${C}$disp_url${NC}"
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
    echo -e "  ${W}推送位置配置:${NC}"
    local add_dir add_file
    add_dir=$(read_input  "子目录 (留空=根目录, 如: public / configs)")
    add_file=$(read_input "文件名 (如: clash.yaml / subscription.txt)" "subscription.txt")
    [[ -z "$add_file" ]] && add_file="subscription.txt"
    if [[ -n "$add_dir" ]]; then
        filename="${add_dir}/${add_file}"
    else
        filename="$add_file"
    fi
    echo -e "  ${G}→ 将上传到仓库路径: ${C}${filename}${NC}"

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

    local enc_github_url; enc_github_url=$(_enc "$github_url")
    local enc_token; enc_token=$(_enc "$token")
    local id; id=$(jq '.next_id' "$REPOS_FILE")
    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$name" --arg url "$enc_github_url" \
       --arg token "$enc_token" --arg branch "$branch" \
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

    # 立即测试连通性（使用明文值，未离开内存）
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

    local count; count=$(jq '.repos | length' "$REPOS_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${Y}暂无仓库配置${NC}"; press_enter; return
    fi

    echo -e "  ${W}当前仓库列表:${NC}"
    jq -r '.repos[] | "  [\(.id)] \(.name)  → \(.filename)"' "$REPOS_FILE"
    echo ""

    local id; id=$(read_input "请输入要编辑的仓库 ID")
    local repo; repo=$(jq --argjson id "$id" '.repos[] | select(.id==$id)' "$REPOS_FILE" 2>/dev/null)
    if [[ -z "$repo" ]]; then
        echo -e "  ${R}未找到 ID=$id 的仓库${NC}"; press_enter; return
    fi

    local cur_name cur_url cur_token cur_branch cur_filename cur_task_ids
    cur_name=$(echo "$repo" | jq -r '.name')
    cur_url=$(_dec "$(echo "$repo" | jq -r '.github_url')")
    cur_token=$(_dec "$(echo "$repo" | jq -r '.token')")
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
    echo ""
    # 拆分当前路径为目录 + 文件名
    local cur_dir cur_file
    if [[ "$cur_filename" == */* ]]; then
        cur_dir="${cur_filename%/*}"
        cur_file="${cur_filename##*/}"
    else
        cur_dir=""
        cur_file="$cur_filename"
    fi
    echo -e "  ${W}推送位置配置:${NC}"
    echo -e "  当前完整路径: ${C}${cur_filename}${NC}"
    local new_dir new_file
    new_dir=$(read_input  "子目录 (留空=根目录, 如: public / configs)" "$cur_dir")
    new_file=$(read_input "文件名 (如: clash.yaml / subscription.txt)" "$cur_file")
    [[ -z "$new_file" ]] && new_file="subscription.txt"
    if [[ -n "$new_dir" ]]; then
        new_filename="${new_dir}/${new_file}"
    else
        new_filename="$new_file"
    fi
    echo -e "  ${G}→ 将上传到仓库路径: ${C}${new_filename}${NC}"

    echo ""
    echo -e "  ${W}可用任务:${NC}"
    while IFS=$'\t' read -r tid tname; do
        if echo ",$cur_task_ids," | grep -qF ",$tid,"; then
            echo -e "  ${G}[${tid}] ${tname}  ← 已关联${NC}"
        else
            echo -e "  ${C}[${tid}]${NC} ${tname}"
        fi
    done < <(jq -r '.tasks[] | [(.id|tostring), .name] | @tsv' "$TASKS_FILE")
    echo -e "  ${Y}当前关联: ${cur_task_ids:-无}${NC}"
    echo ""
    new_task_ids_str=$(read_input "关联任务 ID (多个用逗号分隔)" "$cur_task_ids")

    local new_push_interval_str; new_push_interval_str=$(read_input "定时推送间隔(分钟, 0=跟随任务)" "$cur_push_interval")
    local new_push_interval=0
    [[ "$new_push_interval_str" =~ ^[0-9]+$ ]] && new_push_interval=$new_push_interval_str

    local new_task_ids_json
    new_task_ids_json=$(echo "$new_task_ids_str" | tr ',' '\n' | grep -E '^[0-9]+$' | \
        jq -R 'tonumber' | jq -s '.')

    local enc_new_url; enc_new_url=$(_enc "$new_url")
    local enc_new_token; enc_new_token=$(_enc "$new_token")
    local tmp; tmp=$(mktemp)
    jq --argjson id "$id" \
       --arg name "$new_name" --arg url "$enc_new_url" --arg token "$enc_new_token" \
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
    github_url=$(_dec "$(echo "$repo" | jq -r '.github_url')")
    token=$(_dec "$(echo "$repo" | jq -r '.token')")

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

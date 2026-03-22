# lib/update.sh

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

# update_prompt_on_start
# 启动时前台检查更新，发现新版本则提示用户选择更新或跳过
# 返回 0=用户选择立即更新, 1=无更新或跳过
update_prompt_on_start() {
    local flag="/tmp/sub-manager-update-available"
    local tmp; tmp=$(mktemp)

    echo -ne "  ${C}检查更新中...${NC}"

    # 使用较短超时避免启动等待过久
    local ok=0
    curl -fsSL --connect-timeout 5 --max-time 15 \
        "${GITHUB_RAW}/sub-manager.sh" -o "$tmp" 2>/dev/null && ok=1
    if [[ "$ok" -eq 0 ]]; then
        curl -fsSL --connect-timeout 5 --max-time 15 \
            "${GITHUB_RAW_PROXY}/sub-manager.sh" -o "$tmp" 2>/dev/null && ok=1
    fi

    if [[ "$ok" -eq 0 ]]; then
        echo -e "  ${Y}网络不可达，跳过${NC}"
        rm -f "$tmp"; return 1
    fi

    local remote_ver
    remote_ver=$(grep -m1 '^readonly VERSION=' "$tmp" | cut -d'"' -f2)
    rm -f "$tmp"

    if [[ -z "$remote_ver" ]]; then
        echo -e "  ${Y}版本解析失败，跳过${NC}"
        return 1
    fi

    if ! _ver_gt "$remote_ver" "$VERSION"; then
        echo -e "  ${G}已是最新版本 (${VERSION})${NC}"
        rm -f "$flag"
        sleep 1
        return 1
    fi

    # 发现新版本
    echo "$remote_ver" > "$flag"
    echo ""
    echo -e "  ${G}★ 发现新版本 v${remote_ver}${NC}（当前 v${VERSION}）"
    echo ""
    echo -e "  ${C}1.${NC} 立即更新"
    echo -e "  ${C}0.${NC} 跳过，进入主界面"
    echo ""
    local choice; choice=$(read_input "请选择")
    [[ "$choice" == "1" ]]
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

    if ! bash -n "$tmp" 2>/dev/null; then
        echo -e "  ${R}✗ 下载文件语法校验失败，已中止${NC}"
        rm -f "$tmp"; press_enter; return 1
    fi

    confirm "确认更新到 v${remote_ver}?" || { rm -f "$tmp"; echo "  已取消"; press_enter; return 0; }

    # 备份主文件
    local bak="${INSTALL_DIR}/sub-manager.sh.bak"
    cp "${INSTALL_DIR}/sub-manager.sh" "$bak"
    echo -e "  ${Y}→ 已备份当前版本到 $(basename "$bak")${NC}"

    # 替换主文件
    mv "$tmp" "${INSTALL_DIR}/sub-manager.sh"
    chmod +x "${INSTALL_DIR}/sub-manager.sh"

    # 更新所有 lib/*.sh 模块
    local lib_dir="${INSTALL_DIR}/lib"
    mkdir -p "$lib_dir"
    local modules=(core tasks repos notify proxy fetch scheduler update bot)
    local failed=0
    for mod in "${modules[@]}"; do
        echo -ne "  更新 lib/${mod}.sh... "
        local ltmp; ltmp=$(mktemp)
        if _fetch_raw "lib/${mod}.sh" "$ltmp" 2>/dev/null; then
            mv "$ltmp" "${lib_dir}/${mod}.sh"
            chmod +x "${lib_dir}/${mod}.sh"
            echo -e "${G}✓${NC}"
        else
            rm -f "$ltmp"
            echo -e "${R}✗ 失败${NC}"
            failed=$((failed + 1))
        fi
    done

    if [[ "$failed" -gt 0 ]]; then
        echo -e "  ${Y}⚠ ${failed} 个模块更新失败，可尝试重新运行 install.sh${NC}"
    fi

    echo -e "\n  ${G}✓ 更新完成! 即将重启...${NC}"
    log "INFO" "Updated: ${VERSION} -> ${remote_ver}"
    sleep 1
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

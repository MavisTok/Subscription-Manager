# lib/webdav.sh

# ══════════════════════════════════════════════════════════
#  WebDAV 同步 — 备份 / 恢复所有配置
#  支持: Nextcloud / ownCloud / Seafile / 群晖 / 坚果云 等
#  备份格式: JSON 包经 AES-256-CBC 加密后上传，全程密文
# ══════════════════════════════════════════════════════════

WEBDAV_FILE="${CONFIG_DIR}/webdav.json"

_webdav_init() {
    [[ -f "$WEBDAV_FILE" ]] && return 0
    cat > "$WEBDAV_FILE" << 'EOF'
{
  "url": "",
  "user": "",
  "pass": "",
  "path": "/sub-manager-backup.enc",
  "backup_pass": ""
}
EOF
}

# 读取 webdav.json 中的字段
_webdav_get() { jq -r ".${1} // \"\"" "$WEBDAV_FILE" 2>/dev/null; }

# _webdav_do <target_url> [extra curl args...]
_webdav_do() {
    local target="$1"; shift
    local user pass
    user=$(_webdav_get user)
    pass=$(_dec "$(_webdav_get pass)")
    if [[ -n "$user" ]]; then
        curl -fsSL --connect-timeout 10 --max-time 60 \
            -u "${user}:${pass}" "$@" "$target"
    else
        curl -fsSL --connect-timeout 10 --max-time 60 \
            "$@" "$target"
    fi
}

# _webdav_http_code <target_url> [extra curl args...]
_webdav_http_code() {
    local target="$1"; shift
    local user pass
    user=$(_webdav_get user)
    pass=$(_dec "$(_webdav_get pass)")
    if [[ -n "$user" ]]; then
        curl -sSL --connect-timeout 10 --max-time 15 \
            -u "${user}:${pass}" "$@" -o /dev/null -w "%{http_code}" "$target"
    else
        curl -sSL --connect-timeout 10 --max-time 15 \
            "$@" -o /dev/null -w "%{http_code}" "$target"
    fi
}

# 加解密使用 core.sh 中的 _file_encrypt / _file_decrypt

# ── 配置 WebDAV 服务器 ──────────────────────────────────────

webdav_config() {
    clear_screen
    print_header "WebDAV 配置"
    _webdav_init

    local cur_url cur_user cur_pass cur_path cur_bpass
    cur_url=$(_webdav_get url)
    cur_user=$(_webdav_get user)
    cur_pass=$(_dec "$(_webdav_get pass)")
    cur_path=$(_webdav_get path)
    cur_bpass=$(_dec "$(_webdav_get backup_pass)")
    [[ -z "$cur_path" ]] && cur_path="/sub-manager-backup.enc"

    echo -e "  支持 Nextcloud / ownCloud / Seafile / 群晖 / 坚果云 等 WebDAV 服务"
    echo -e "  备份文件将使用独立密码进行 AES-256 加密后上传"
    echo ""
    if [[ -n "$cur_url" ]]; then
        echo -e "  当前地址:     ${Y}${cur_url}${NC}"
        [[ -n "$cur_user" ]] && echo -e "  当前用户:     ${Y}${cur_user}${NC}"
        if [[ -n "$cur_bpass" ]]; then
            echo -e "  备份加密密码: ${G}已设置${NC}"
        else
            echo -e "  备份加密密码: ${R}未设置${NC}"
        fi
    fi
    echo ""

    local new_url new_user new_pass new_path new_bpass
    new_url=$(read_input "WebDAV 地址 (如 https://dav.example.com/dav/)" "$cur_url")
    [[ -z "$new_url" ]] && { echo -e "  ${R}地址不能为空${NC}"; press_enter; return 1; }

    new_user=$(read_input "用户名 (无认证则留空)" "$cur_user")
    if [[ -n "$new_user" ]]; then
        new_pass=$(read_input "WebDAV 密码" "$cur_pass")
    else
        new_pass=""
    fi

    new_path=$(read_input "远端备份文件路径" "$cur_path")
    [[ -z "$new_path" ]] && new_path="/sub-manager-backup.enc"
    [[ "${new_path:0:1}" != "/" ]] && new_path="/${new_path}"

    echo ""
    echo -e "  ${W}备份加密密码${NC}（用于加密整个备份文件，与 WebDAV 密码无关）"
    new_bpass=$(read_input "备份加密密码" "$cur_bpass")
    if [[ -z "$new_bpass" ]]; then
        echo -e "  ${R}备份加密密码不能为空${NC}"
        press_enter; return 1
    fi

    if ! command -v openssl &>/dev/null; then
        echo -e "  ${R}未检测到 openssl，无法启用加密功能${NC}"
        press_enter; return 1
    fi

    local enc_pass enc_bpass tmp
    enc_pass=$(_enc "$new_pass")
    enc_bpass=$(_enc "$new_bpass")
    tmp=$(mktemp)
    jq -n --arg url "$new_url" --arg user "$new_user" \
          --arg pass "$enc_pass" --arg path "$new_path" \
          --arg backup_pass "$enc_bpass" \
        '{url: $url, user: $user, pass: $pass, path: $path, backup_pass: $backup_pass}' \
        > "$tmp" && mv "$tmp" "$WEBDAV_FILE"

    echo -e "\n  ${G}✓ WebDAV 配置已保存${NC}"
    press_enter
}

# ── 测试连接 ────────────────────────────────────────────────

webdav_test() {
    clear_screen
    print_header "测试 WebDAV 连接"
    _webdav_init

    local url; url=$(_webdav_get url)
    if [[ -z "$url" ]]; then
        echo -e "  ${R}未配置 WebDAV 服务器，请先配置${NC}"
        press_enter; return 1
    fi

    echo -e "  地址: ${Y}${url}${NC}"
    echo -ne "  ${C}测试连接...${NC} "

    local http_code
    http_code=$(_webdav_http_code "$url" -X PROPFIND)

    case "$http_code" in
        207|200|201|204)
            echo -e "${G}✓ 连接成功 (HTTP ${http_code})${NC}" ;;
        401|403)
            echo -e "${R}✗ 认证失败 (HTTP ${http_code})，请检查用户名/密码${NC}" ;;
        404)
            echo -e "${Y}⚠ 路径不存在 (HTTP 404)，服务器可达但目录需确认${NC}" ;;
        000)
            echo -e "${R}✗ 无法连接，请检查地址及网络${NC}" ;;
        *)
            echo -e "${Y}⚠ HTTP ${http_code}，请核实配置${NC}" ;;
    esac
    press_enter
}

# ── 备份配置到 WebDAV ───────────────────────────────────────

webdav_backup() {
    clear_screen
    print_header "备份配置到 WebDAV"
    _webdav_init

    local url bpass
    url=$(_webdav_get url)
    if [[ -z "$url" ]]; then
        echo -e "  ${R}未配置 WebDAV 服务器，请先配置${NC}"
        press_enter; return 1
    fi

    bpass=$(_dec "$(_webdav_get backup_pass)")
    if [[ -z "$bpass" ]]; then
        echo -e "  ${R}未设置备份加密密码，请先在配置中设置${NC}"
        press_enter; return 1
    fi

    if ! command -v openssl &>/dev/null; then
        echo -e "  ${R}未检测到 openssl，无法加密备份${NC}"
        press_enter; return 1
    fi

    local path; path=$(_webdav_get path)
    local target="${url%/}${path}"

    echo -e "  目标: ${Y}${target}${NC}"
    echo -e "  备份: tasks.json / repos.json / notify.json / settings.json"
    echo -e "  加密: ${G}AES-256-CBC${NC}"
    echo ""

    # 1. 打包 JSON
    echo -ne "  ${C}打包配置...${NC} "
    local tmp_json; tmp_json=$(mktemp)
    local ok=0
    jq -n \
        --arg ver  "$VERSION" \
        --arg ts   "$(date '+%Y-%m-%d %H:%M:%S')" \
        --slurpfile tasks    "$TASKS_FILE" \
        --slurpfile repos    "$REPOS_FILE" \
        --slurpfile notify   "$NOTIFY_FILE" \
        --slurpfile settings "$SETTINGS_FILE" \
        '{
            version:     $ver,
            backup_time: $ts,
            files: {
                "tasks.json":    $tasks[0],
                "repos.json":    $repos[0],
                "notify.json":   $notify[0],
                "settings.json": $settings[0]
            }
        }' > "$tmp_json" 2>/dev/null && ok=1

    if [[ "$ok" -eq 0 ]]; then
        echo -e "${R}✗ 打包失败${NC}"
        rm -f "$tmp_json"; press_enter; return 1
    fi
    echo -e "${G}✓${NC}"

    # 2. 加密
    echo -ne "  ${C}加密...${NC} "
    local tmp_enc; tmp_enc=$(mktemp)
    if ! _file_encrypt "$tmp_json" "$tmp_enc" "$bpass"; then
        echo -e "${R}✗ 加密失败${NC}"
        rm -f "$tmp_json" "$tmp_enc"; press_enter; return 1
    fi
    rm -f "$tmp_json"
    local size; size=$(_filesize "$tmp_enc")
    echo -e "${G}✓${NC} (${size} 字节)"

    # 3. 上传
    echo -ne "  ${C}上传到 WebDAV...${NC} "
    if _webdav_do "$target" -T "$tmp_enc" -X PUT 2>/dev/null; then
        echo -e "${G}✓ 备份成功${NC}"
        echo -e "  备份时间: ${Y}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
        log "INFO" "WebDAV backup succeeded: ${target}"
    else
        echo -e "${R}✗ 上传失败，请检查地址/凭据/路径权限${NC}"
        rm -f "$tmp_enc"; press_enter; return 1
    fi
    rm -f "$tmp_enc"
    press_enter
}

# ── 从 WebDAV 恢复配置 ──────────────────────────────────────

webdav_restore() {
    clear_screen
    print_header "从 WebDAV 恢复配置"
    _webdav_init

    local url bpass
    url=$(_webdav_get url)
    if [[ -z "$url" ]]; then
        echo -e "  ${R}未配置 WebDAV 服务器，请先配置${NC}"
        press_enter; return 1
    fi

    bpass=$(_dec "$(_webdav_get backup_pass)")
    if [[ -z "$bpass" ]]; then
        echo -e "  ${R}未设置备份加密密码，请先在配置中设置${NC}"
        press_enter; return 1
    fi

    if ! command -v openssl &>/dev/null; then
        echo -e "  ${R}未检测到 openssl，无法解密备份${NC}"
        press_enter; return 1
    fi

    local path; path=$(_webdav_get path)
    local target="${url%/}${path}"

    echo -e "  来源: ${Y}${target}${NC}"
    echo ""

    # 1. 下载
    echo -ne "  ${C}下载备份...${NC} "
    local tmp_enc; tmp_enc=$(mktemp)
    if ! _webdav_do "$target" -o "$tmp_enc" 2>/dev/null; then
        echo -e "${R}✗ 下载失败，请检查地址或备份文件是否存在${NC}"
        rm -f "$tmp_enc"; press_enter; return 1
    fi
    echo -e "${G}✓${NC}"

    # 2. 解密
    echo -ne "  ${C}解密...${NC} "
    local tmp_json; tmp_json=$(mktemp)
    if ! _file_decrypt "$tmp_enc" "$tmp_json" "$bpass"; then
        echo -e "${R}✗ 解密失败，请确认备份加密密码正确${NC}"
        rm -f "$tmp_enc" "$tmp_json"; press_enter; return 1
    fi
    rm -f "$tmp_enc"
    echo -e "${G}✓${NC}"

    # 3. 校验格式
    if ! jq -e '.files' "$tmp_json" &>/dev/null; then
        echo -e "  ${R}备份文件格式无效${NC}"
        rm -f "$tmp_json"; press_enter; return 1
    fi

    local bak_ver bak_time
    bak_ver=$(jq -r '.version // "未知"' "$tmp_json")
    bak_time=$(jq -r '.backup_time // "未知"' "$tmp_json")
    echo -e "  备份版本: ${Y}v${bak_ver}${NC}   备份时间: ${Y}${bak_time}${NC}"
    echo ""

    echo -e "  备份包含:"
    jq -r '.files | keys[]' "$tmp_json" 2>/dev/null | while read -r fname; do
        echo -e "    ${G}·${NC} ${fname}"
    done
    echo ""

    confirm "确认用备份覆盖当前所有配置?" || {
        rm -f "$tmp_json"; echo "  已取消"; press_enter; return 0
    }

    echo ""
    local failed=0
    for fname in "tasks.json" "repos.json" "notify.json" "settings.json"; do
        if jq -e ".files[\"${fname}\"]" "$tmp_json" &>/dev/null; then
            jq ".files[\"${fname}\"]" "$tmp_json" > "${CONFIG_DIR}/${fname}"
            echo -e "  ${G}✓${NC} ${fname}"
        else
            echo -e "  ${Y}⚠${NC} ${fname} 不在备份中，已跳过"
            failed=$((failed + 1))
        fi
    done

    rm -f "$tmp_json"
    echo ""
    if [[ "$failed" -eq 0 ]]; then
        echo -e "  ${G}✓ 全部配置恢复完成${NC}"
    else
        echo -e "  ${Y}⚠ 恢复完成，${failed} 个文件不在备份中${NC}"
    fi
    log "INFO" "WebDAV restore completed (bak_ver=${bak_ver}, bak_time=${bak_time})"
    press_enter
}

# ── WebDAV 菜单 ─────────────────────────────────────────────

webdav_menu() {
    while true; do
        clear_screen
        print_header "WebDAV 同步"
        _webdav_init

        local url user path bpass_set
        url=$(_webdav_get url)
        user=$(_webdav_get user)
        path=$(_webdav_get path)
        bpass_set=$(_dec "$(_webdav_get backup_pass)")

        if [[ -n "$url" ]]; then
            echo -e "  服务器:   ${Y}${url}${NC}"
            [[ -n "$user" ]] && echo -e "  用户名:   ${Y}${user}${NC}"
            [[ -n "$path" ]] && echo -e "  备份路径: ${Y}${path}${NC}"
            if [[ -n "$bpass_set" ]]; then
                echo -e "  文件加密: ${G}已启用 (AES-256-CBC)${NC}"
            else
                echo -e "  文件加密: ${R}未设置加密密码${NC}"
            fi
        else
            echo -e "  ${Y}尚未配置 WebDAV 服务器${NC}"
        fi
        echo ""
        echo -e "  ${C}1.${NC} 配置 WebDAV 服务器"
        echo -e "  ${C}2.${NC} 立即备份配置"
        echo -e "  ${C}3.${NC} 从备份恢复配置"
        echo -e "  ${C}4.${NC} 测试连接"
        echo -e "  ${C}0.${NC} 返回主菜单"
        echo ""

        local choice; choice=$(read_input "请选择")
        case "$choice" in
            1) webdav_config ;;
            2) webdav_backup ;;
            3) webdav_restore ;;
            4) webdav_test ;;
            0) return ;;
            *) echo -e "  ${R}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

#!/bin/bash
# ============================================================
#  订阅管理工具 - 安装脚本
#  平台: Linux (Ubuntu/Debian/CentOS/Alpine/Arch/...) /
#        macOS / Windows (Git Bash / WSL)
#  依赖安装失败时自动切换镜像源重试
# ============================================================

set -e

SCRIPT_NAME="sub-manager.sh"

# ── OS 检测 ────────────────────────────────────────────────
case "$(uname -s 2>/dev/null)" in
    Darwin)             OS_TYPE="macos"   ;;
    MINGW*|MSYS*|CYGWIN*) OS_TYPE="windows" ;;
    *)                  OS_TYPE="linux"   ;;
esac

# ── 安装目录 ───────────────────────────────────────────────
if [[ -n "${SUB_MANAGER_DIR:-}" ]]; then
    INSTALL_DIR="$SUB_MANAGER_DIR"
elif [[ "$OS_TYPE" == "linux" && "${EUID:-$(id -u)}" -eq 0 ]]; then
    INSTALL_DIR="/opt/sub-manager"
else
    INSTALL_DIR="${HOME}/.sub-manager"
fi

# ── 颜色 ──────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; W='\033[1;37m'; NC='\033[0m'

echo -e "${C}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║      订 阅 管 理 工 具 - 安 装 程 序          ║"
echo "  ║      Subscription Manager Installer           ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  平台: ${W}${OS_TYPE}${NC}  |  安装目录: ${C}${INSTALL_DIR}${NC}"
echo ""

# ── Linux root 检查（macOS/Windows 不强制） ────────────────
if [[ "$OS_TYPE" == "linux" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "  ${Y}提示: 非 root 用户，将安装到 ${INSTALL_DIR}${NC}"
    echo -e "  ${Y}如需安装到 /opt/sub-manager 请用 sudo bash install.sh${NC}"
    echo ""
fi

# ══════════════════════════════════════════════════════════
#  镜像源配置
# ══════════════════════════════════════════════════════════

# 每次安装尝试的超时时间（秒）
INSTALL_TIMEOUT=45
# 镜像连通性探测超时（秒）
PROBE_TIMEOUT=5
# 源文件备份目录
SOURCES_BACKUP_DIR="/tmp/sub-manager-sources-bak"

# APT 镜像列表 (第一项为官方，后续为备用镜像)
APT_MIRRORS_UBUNTU=(
    "archive.ubuntu.com"              # 官方
    "mirrors.aliyun.com"              # 阿里云
    "mirrors.tuna.tsinghua.edu.cn"    # 清华大学
    "mirrors.ustc.edu.cn"             # 中科大
    "mirrors.163.com"                 # 网易
    "mirrors.huaweicloud.com"         # 华为云
)

APT_MIRRORS_DEBIAN=(
    "deb.debian.org"                  # 官方
    "mirrors.aliyun.com"              # 阿里云
    "mirrors.tuna.tsinghua.edu.cn"    # 清华大学
    "mirrors.ustc.edu.cn"             # 中科大
    "mirrors.huaweicloud.com"         # 华为云
)

# APK 镜像列表 (Alpine)
APK_MIRRORS=(
    "dl-cdn.alpinelinux.org"          # 官方
    "mirrors.aliyun.com"              # 阿里云
    "mirrors.tuna.tsinghua.edu.cn"    # 清华大学
    "mirrors.ustc.edu.cn"             # 中科大
    "mirrors.huaweicloud.com"         # 华为云
)

# YUM/DNF 镜像列表 (CentOS/RHEL)
YUM_MIRRORS=(
    ""                                # 官方 mirrorlist (空=不切换)
    "mirrors.aliyun.com"              # 阿里云
    "mirrors.tuna.tsinghua.edu.cn"    # 清华大学
    "mirrors.ustc.edu.cn"             # 中科大
    "mirrors.huaweicloud.com"         # 华为云
)

# Pacman 镜像列表 (Arch)
PACMAN_MIRRORS=(
    ""                                # 官方 (空=不切换)
    "mirrors.aliyun.com"              # 阿里云
    "mirrors.tuna.tsinghua.edu.cn"    # 清华大学
    "mirrors.ustc.edu.cn"             # 中科大
)

# ══════════════════════════════════════════════════════════
#  检测发行版
# ══════════════════════════════════════════════════════════
detect_distro() {
    case "$OS_TYPE" in
        macos)   echo "macos"; return ;;
        windows) echo "windows"; return ;;
    esac
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    elif [[ -f /etc/alpine-release ]]; then
        echo "alpine"
    elif [[ -f /etc/arch-release ]]; then
        echo "arch"
    elif command -v apt-get &>/dev/null; then
        echo "debian"
    elif command -v yum &>/dev/null; then
        echo "centos"
    else
        echo "unknown"
    fi
}

detect_distro_version() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${VERSION_ID:-0}" | cut -d. -f1
    else
        echo "0"
    fi
}

# ══════════════════════════════════════════════════════════
#  镜像连通性探测
# ══════════════════════════════════════════════════════════

# probe_mirror <host>
# 用 curl HEAD 请求判断镜像是否可达（兼容 macOS/Windows）
probe_mirror() {
    local host="$1"
    [[ -z "$host" ]] && return 0   # 空 = 官方源, 直接返回通过
    curl -s --connect-timeout "$PROBE_TIMEOUT" --max-time "$PROBE_TIMEOUT" \
        -o /dev/null -I "https://${host}" 2>/dev/null
}

# ══════════════════════════════════════════════════════════
#  源文件备份 / 还原
# ══════════════════════════════════════════════════════════

backup_sources() {
    local distro="$1"
    mkdir -p "$SOURCES_BACKUP_DIR"
    case "$distro" in
        ubuntu|debian|raspbian|linuxmint|pop)
            cp /etc/apt/sources.list "${SOURCES_BACKUP_DIR}/sources.list.orig" 2>/dev/null || true
            ;;
        alpine)
            cp /etc/apk/repositories "${SOURCES_BACKUP_DIR}/repositories.orig" 2>/dev/null || true
            ;;
        centos|rhel|rocky|almalinux|ol|fedora)
            mkdir -p "${SOURCES_BACKUP_DIR}/yum.repos.d"
            cp /etc/yum.repos.d/*.repo "${SOURCES_BACKUP_DIR}/yum.repos.d/" 2>/dev/null || true
            ;;
        arch|manjaro|endeavouros)
            cp /etc/pacman.d/mirrorlist "${SOURCES_BACKUP_DIR}/mirrorlist.orig" 2>/dev/null || true
            ;;
    esac
}

restore_sources() {
    local distro="$1"
    case "$distro" in
        ubuntu|debian|raspbian|linuxmint|pop)
            [[ -f "${SOURCES_BACKUP_DIR}/sources.list.orig" ]] && \
                cp "${SOURCES_BACKUP_DIR}/sources.list.orig" /etc/apt/sources.list
            ;;
        alpine)
            [[ -f "${SOURCES_BACKUP_DIR}/repositories.orig" ]] && \
                cp "${SOURCES_BACKUP_DIR}/repositories.orig" /etc/apk/repositories
            ;;
        centos|rhel|rocky|almalinux|ol|fedora)
            [[ -d "${SOURCES_BACKUP_DIR}/yum.repos.d" ]] && \
                cp "${SOURCES_BACKUP_DIR}/yum.repos.d/"*.repo /etc/yum.repos.d/ 2>/dev/null || true
            rm -f /etc/yum.repos.d/submanager-mirror.repo
            ;;
        arch|manjaro|endeavouros)
            [[ -f "${SOURCES_BACKUP_DIR}/mirrorlist.orig" ]] && \
                cp "${SOURCES_BACKUP_DIR}/mirrorlist.orig" /etc/pacman.d/mirrorlist
            ;;
    esac
}

# ══════════════════════════════════════════════════════════
#  切换镜像源
# ══════════════════════════════════════════════════════════

# set_mirror_apt <mirror> <distro>
set_mirror_apt() {
    local mirror="$1" distro="$2"
    [[ -z "$mirror" ]] && return 0

    if [[ "$distro" == "ubuntu" ]]; then
        # 替换 Ubuntu 官方域名
        sed -i \
            -e "s|archive\.ubuntu\.com|${mirror}|g" \
            -e "s|security\.ubuntu\.com|${mirror}|g" \
            -e "s|ports\.ubuntu\.com|${mirror}|g" \
            /etc/apt/sources.list
    else
        # 替换 Debian 官方域名
        sed -i \
            -e "s|deb\.debian\.org|${mirror}|g" \
            -e "s|security\.debian\.org|${mirror}|g" \
            /etc/apt/sources.list
    fi
}

# set_mirror_apk <mirror>
set_mirror_apk() {
    local mirror="$1"
    [[ -z "$mirror" ]] && return 0

    local version
    version=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2 || echo "3.18")
    cat > /etc/apk/repositories << APKREPO
https://${mirror}/alpine/v${version}/main
https://${mirror}/alpine/v${version}/community
APKREPO
}

# set_mirror_yum <mirror> <distro> <version>
set_mirror_yum() {
    local mirror="$1" distro="$2" version="$3"
    [[ -z "$mirror" ]] && return 0

    local repo_file="/etc/yum.repos.d/submanager-mirror.repo"

    case "$distro" in
        centos)
            if [[ "$version" -ge 8 ]]; then
                cat > "$repo_file" << YUMREPO
[submanager-baseos]
name=Mirror BaseOS
baseurl=https://${mirror}/centos-stream/${version}/BaseOS/\$basearch/os/
enabled=1
gpgcheck=0
priority=1

[submanager-appstream]
name=Mirror AppStream
baseurl=https://${mirror}/centos-stream/${version}/AppStream/\$basearch/os/
enabled=1
gpgcheck=0
priority=1
YUMREPO
            else
                cat > "$repo_file" << YUMREPO
[submanager-base]
name=Mirror Base
baseurl=https://${mirror}/centos/${version}/os/\$basearch/
enabled=1
gpgcheck=0
priority=1

[submanager-extras]
name=Mirror Extras
baseurl=https://${mirror}/centos/${version}/extras/\$basearch/
enabled=1
gpgcheck=0
priority=1
YUMREPO
            fi ;;
        rocky)
            cat > "$repo_file" << YUMREPO
[submanager-baseos]
name=Mirror BaseOS
baseurl=https://${mirror}/rocky/${version}/BaseOS/\$basearch/os/
enabled=1
gpgcheck=0
priority=1

[submanager-appstream]
name=Mirror AppStream
baseurl=https://${mirror}/rocky/${version}/AppStream/\$basearch/os/
enabled=1
gpgcheck=0
priority=1
YUMREPO
            ;;
        almalinux)
            cat > "$repo_file" << YUMREPO
[submanager-baseos]
name=Mirror BaseOS
baseurl=https://${mirror}/almalinux/${version}/BaseOS/\$basearch/os/
enabled=1
gpgcheck=0
priority=1

[submanager-appstream]
name=Mirror AppStream
baseurl=https://${mirror}/almalinux/${version}/AppStream/\$basearch/os/
enabled=1
gpgcheck=0
priority=1
YUMREPO
            ;;
        fedora)
            cat > "$repo_file" << YUMREPO
[submanager-fedora]
name=Mirror Fedora
baseurl=https://${mirror}/fedora/releases/\$releasever/Everything/\$basearch/os/
enabled=1
gpgcheck=0
priority=1

[submanager-updates]
name=Mirror Updates
baseurl=https://${mirror}/fedora/updates/\$releasever/Everything/\$basearch/
enabled=1
gpgcheck=0
priority=1
YUMREPO
            ;;
        *)
            cat > "$repo_file" << YUMREPO
[submanager-mirror]
name=Mirror Fallback
baseurl=https://${mirror}/centos/\$releasever/os/\$basearch/
enabled=1
gpgcheck=0
priority=1
YUMREPO
            ;;
    esac
}

# set_mirror_pacman <mirror>
set_mirror_pacman() {
    local mirror="$1"
    [[ -z "$mirror" ]] && return 0

    # 在 mirrorlist 开头插入镜像
    local entry="Server = https://${mirror}/archlinux/\$repo/os/\$arch"
    sed -i "1s|^|${entry}\n|" /etc/pacman.d/mirrorlist
}

# ══════════════════════════════════════════════════════════
#  带镜像切换的包安装
# ══════════════════════════════════════════════════════════

# _run_install_cmd <distro> <pkg>
# 执行实际的包管理器命令（带超时）
_run_install_cmd() {
    local distro="$1" pkg="$2"
    case "$distro" in
        ubuntu|debian|raspbian|linuxmint|pop)
            timeout "$INSTALL_TIMEOUT" apt-get install -y -q "$pkg" > /dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|ol)
            if command -v dnf &>/dev/null; then
                timeout "$INSTALL_TIMEOUT" dnf install -y -q "$pkg" > /dev/null 2>&1
            else
                timeout "$INSTALL_TIMEOUT" yum install -y -q "$pkg" > /dev/null 2>&1
            fi ;;
        fedora)
            timeout "$INSTALL_TIMEOUT" dnf install -y -q "$pkg" > /dev/null 2>&1 ;;
        alpine)
            timeout "$INSTALL_TIMEOUT" apk add --no-cache -q "$pkg" > /dev/null 2>&1 ;;
        arch|manjaro|endeavouros)
            timeout "$INSTALL_TIMEOUT" pacman -S --noconfirm --needed -q "$pkg" > /dev/null 2>&1 ;;
        opensuse*|sles)
            timeout "$INSTALL_TIMEOUT" zypper install -y -q "$pkg" > /dev/null 2>&1 ;;
        macos)
            if command -v brew &>/dev/null; then
                brew install -q "$pkg" > /dev/null 2>&1
            else
                return 1
            fi ;;
        windows)
            # Git Bash: 尝试 winget，通常 jq/git/curl 已预装
            winget install -e --id "jqlang.jq" > /dev/null 2>&1 || return 1 ;;
        *)
            return 1 ;;
    esac
}

# _update_index <distro>
# 更新包索引（带超时）
_update_index() {
    local distro="$1"
    case "$distro" in
        ubuntu|debian|raspbian|linuxmint|pop)
            timeout "$INSTALL_TIMEOUT" apt-get update -q > /dev/null 2>&1 ;;
        alpine)
            timeout "$INSTALL_TIMEOUT" apk update -q > /dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|ol|fedora)
            if command -v dnf &>/dev/null; then
                timeout "$INSTALL_TIMEOUT" dnf makecache -q > /dev/null 2>&1
            else
                timeout "$INSTALL_TIMEOUT" yum makecache -q > /dev/null 2>&1
            fi ;;
        arch|manjaro|endeavouros)
            timeout "$INSTALL_TIMEOUT" pacman -Sy --noconfirm -q > /dev/null 2>&1 ;;
    esac
}

# install_pkg <pkg>
# 尝试安装包，失败时自动切换镜像重试
install_pkg() {
    local pkg="$1"
    local distro="$2"   # 可选，外部传入避免重复检测
    [[ -z "$distro" ]] && distro=$(detect_distro)
    local version; version=$(detect_distro_version)

    # 决定当前发行版对应的镜像列表名
    local -a mirrors=()
    case "$distro" in
        ubuntu)              mirrors=("${APT_MIRRORS_UBUNTU[@]}") ;;
        debian|raspbian|linuxmint|pop) mirrors=("${APT_MIRRORS_DEBIAN[@]}") ;;
        alpine)              mirrors=("${APK_MIRRORS[@]}") ;;
        centos|rhel|rocky|almalinux|ol|fedora) mirrors=("${YUM_MIRRORS[@]}") ;;
        arch|manjaro|endeavouros) mirrors=("${PACMAN_MIRRORS[@]}") ;;
        *)
            # 未知发行版，直接尝试一次
            _run_install_cmd "$distro" "$pkg"
            return $?
            ;;
    esac

    backup_sources "$distro"

    local attempt=0
    local total=${#mirrors[@]}
    local success=false

    for mirror in "${mirrors[@]}"; do
        attempt=$(( attempt + 1 ))
        local label="${mirror:-官方源}"

        # 非官方镜像先探测连通性
        if [[ -n "$mirror" ]] && ! probe_mirror "$mirror"; then
            echo -e "\n    ${Y}[$attempt/$total] $label 不可达，跳过${NC}"
            continue
        fi

        # 切换到该镜像
        case "$distro" in
            ubuntu)   set_mirror_apt "$mirror" "ubuntu" ;;
            debian|raspbian|linuxmint|pop) set_mirror_apt "$mirror" "debian" ;;
            alpine)   set_mirror_apk "$mirror" ;;
            centos|rhel|rocky|almalinux|ol|fedora) set_mirror_yum "$mirror" "$distro" "$version" ;;
            arch|manjaro|endeavouros) set_mirror_pacman "$mirror" ;;
        esac

        # 刷新索引
        _update_index "$distro" 2>/dev/null || true

        # 尝试安装
        if _run_install_cmd "$distro" "$pkg"; then
            [[ "$attempt" -gt 1 ]] && \
                echo -e "\n    ${G}✓ 通过镜像 $label 安装成功${NC}"
            success=true
            break
        else
            echo -e "\n    ${Y}[$attempt/$total] $label 安装失败，尝试下一镜像...${NC}"
            # 还原后再做下一轮
            restore_sources "$distro"
            backup_sources "$distro"
        fi
    done

    # 收尾：还原原始源（保持系统整洁）
    restore_sources "$distro"

    if [[ "$success" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ══════════════════════════════════════════════════════════
#  安装依赖
# ══════════════════════════════════════════════════════════
echo -e "  ${W}[1/5] 检查并安装依赖...${NC}"
echo ""

DISTRO=$(detect_distro)
DISTRO_VER=$(detect_distro_version)
echo -e "  检测到系统: ${C}${DISTRO} ${DISTRO_VER}${NC}"
echo ""

# 更新包索引（预先探测最优镜像）
echo -ne "  更新包索引..."
case "$DISTRO" in
    ubuntu|debian|raspbian|linuxmint|pop)
        apt-get update -q > /dev/null 2>&1 && echo -e " ${G}✓${NC}" || echo -e " ${Y}失败(将在安装时重试)${NC}" ;;
    alpine)
        apk update -q > /dev/null 2>&1 && echo -e " ${G}✓${NC}" || echo -e " ${Y}失败(将在安装时重试)${NC}" ;;
    centos|rhel|rocky|almalinux|ol|fedora)
        echo -e " ${Y}跳过(rpm系按需更新)${NC}" ;;
    *)
        echo -e " ${Y}跳过${NC}" ;;
esac
echo ""

for dep in curl git jq; do
    printf "  %-10s " "$dep"
    if command -v "$dep" &>/dev/null; then
        echo -e "${G}✓ 已安装${NC}"
    else
        echo -ne "安装中 "
        if install_pkg "$dep" "$DISTRO"; then
            echo -e "${G}✓ 完成${NC}"
        else
            echo -e "${R}✗ 全部镜像安装失败${NC}"
            echo -e "  ${Y}请手动安装: ${dep}${NC}"
            echo -e "  ${Y}参考命令:${NC}"
            case "$DISTRO" in
                ubuntu|debian) echo -e "  ${C}apt-get install -y ${dep}${NC}" ;;
                centos|rhel*)  echo -e "  ${C}yum install -y ${dep}${NC}" ;;
                alpine)        echo -e "  ${C}apk add ${dep}${NC}" ;;
                arch*)         echo -e "  ${C}pacman -S ${dep}${NC}" ;;
            esac
        fi
    fi
done

# python3 可选依赖
printf "  %-10s " "python3"
command -v python3 &>/dev/null && \
    echo -e "${G}✓ 已安装${NC}" || \
    echo -e "${Y}未安装 (Bark通知URL编码将降级处理)${NC}"

# ── 创建目录 ───────────────────────────────────────────────
echo ""
echo -e "  ${W}[2/5] 创建目录结构...${NC}"
mkdir -p "${INSTALL_DIR}/config" "${INSTALL_DIR}/data" "${INSTALL_DIR}/logs"
echo -e "  ${G}✓ ${INSTALL_DIR}/${NC}"

# ── 安装主程序 ─────────────────────────────────────────────
echo ""
echo -e "  ${W}[3/5] 安装主程序...${NC}"

GITHUB_RAW="https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main"
GITHUB_RAW_PROXY="https://ghfast.top/https://raw.githubusercontent.com/MavisTok/Subscription-Manager/main"
SCRIPT_SRC=""

# 检测是否通过 bash <(curl ...) 管道方式运行
# 管道方式时 BASH_SOURCE[0] 形如 /dev/fd/63 或 /proc/self/fd/63，路径不可信
_is_pipe_run=false
if [[ "${BASH_SOURCE[0]}" == /dev/fd/* ]] || \
   [[ "${BASH_SOURCE[0]}" == /proc/*/fd/* ]] || \
   [[ "${BASH_SOURCE[0]}" == "bash" ]] || \
   [[ "${BASH_SOURCE[0]}" == "/dev/stdin" ]]; then
    _is_pipe_run=true
fi

if [[ "$_is_pipe_run" == "false" ]]; then
    SCRIPT_DIR_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
    if [[ -f "${SCRIPT_DIR_REAL}/${SCRIPT_NAME}" ]]; then
        SCRIPT_SRC="${SCRIPT_DIR_REAL}/${SCRIPT_NAME}"
    fi
fi

if [[ -z "$SCRIPT_SRC" ]] && [[ -f "./${SCRIPT_NAME}" ]]; then
    SCRIPT_SRC="./${SCRIPT_NAME}"
fi

if [[ -z "$SCRIPT_SRC" ]]; then
    # 从网络下载，先试直连，失败再走镜像
    echo -ne "  ${Y}下载 ${SCRIPT_NAME}...${NC} "
    if curl -fsSL --connect-timeout 8 --max-time 30 \
        "${GITHUB_RAW}/${SCRIPT_NAME}" -o "/tmp/${SCRIPT_NAME}" 2>/dev/null; then
        SCRIPT_SRC="/tmp/${SCRIPT_NAME}"
        echo -e "${G}✓ (直连)${NC}"
    else
        echo -ne "${Y}直连失败，切换镜像...${NC} "
        if curl -fsSL --connect-timeout 8 --max-time 30 \
            "${GITHUB_RAW_PROXY}/${SCRIPT_NAME}" \
            -o "/tmp/${SCRIPT_NAME}" 2>/dev/null; then
            SCRIPT_SRC="/tmp/${SCRIPT_NAME}"
            echo -e "${G}✓ (镜像)${NC}"
        else
            echo -e "${R}✗${NC}"
            echo -e "  ${R}下载失败，请手动执行:${NC}"
            echo -e "  ${C}curl -fsSL ${GITHUB_RAW_PROXY}/${SCRIPT_NAME} -o ${SCRIPT_NAME} && bash install.sh${NC}"
            exit 1
        fi
    fi
fi

cp "$SCRIPT_SRC" "${INSTALL_DIR}/${SCRIPT_NAME}"
chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
echo -e "  ${G}✓ 已安装到 ${INSTALL_DIR}/${SCRIPT_NAME}${NC}"

# ── 配置快捷命令 ───────────────────────────────────────────
echo ""
echo -e "  ${W}[4/5] 配置快捷命令...${NC}"

if [[ "$OS_TYPE" == "linux" && -d /etc/profile.d ]]; then
    cat > /etc/profile.d/sub-manager.sh << PROFILEEOF
# Sub Manager - 订阅管理工具
alias subm='${INSTALL_DIR}/${SCRIPT_NAME}'
PROFILEEOF
    chmod +x /etc/profile.d/sub-manager.sh
    echo -e "  ${G}✓ 添加全局别名 subm (重新登录后生效)${NC}"
fi

# 写入用户 rc 文件（Linux root 写 /root/*, macOS/普通用户写 $HOME/*）
if [[ "$OS_TYPE" == "linux" && "${EUID:-$(id -u)}" -eq 0 ]]; then
    RC_FILES=("/root/.bashrc" "/root/.zshrc")
else
    RC_FILES=("${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.bash_profile")
fi

for rc in "${RC_FILES[@]}"; do
    if [[ -f "$rc" ]] && ! grep -q "sub-manager" "$rc" 2>/dev/null; then
        echo "" >> "$rc"
        echo "# Sub Manager" >> "$rc"
        echo "alias subm='${INSTALL_DIR}/${SCRIPT_NAME}'" >> "$rc"
        echo -e "  ${G}✓ 已写入 $rc${NC}"
    fi
done

# ── 处理 'su' 快捷入口 ─────────────────────────────────────
echo ""
echo -e "  ${Y}提示: 系统已有 'su' (切换用户) 命令${NC}"
echo -e "  是否将无参数 'su' 重定向为打开管理工具?"
echo -e "  ${C}(有参数时 su root / su - 仍正常切换用户)${NC}"
read -rp "  [y/N]: " override_su

if [[ "$(echo "$override_su" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
    REAL_SU=$(command -v su 2>/dev/null || echo "/bin/su")
    [[ "$REAL_SU" == "/usr/local/bin/su" ]] && REAL_SU="/bin/su"

    cat > /usr/local/bin/su << SUWRAPEOF
#!/bin/bash
# Sub Manager 'su' 包装器
# 无参数时打开管理工具，有参数时使用系统 su
if [[ \$# -eq 0 && -t 0 ]]; then
    exec ${INSTALL_DIR}/${SCRIPT_NAME}
else
    exec ${REAL_SU} "\$@"
fi
SUWRAPEOF
    chmod +x /usr/local/bin/su
    echo -e "  ${G}✓ 'su' 已配置 (无参数 → 管理工具, 有参数 → 系统su)${NC}"
else
    echo -e "  ${Y}跳过，使用 'subm' 命令启动工具${NC}"
fi

# ── 配置 Cron ──────────────────────────────────────────────
echo ""
echo -e "  ${W}[5/5] 配置定时任务...${NC}"

start_cron_service() {
    if command -v systemctl &>/dev/null; then
        for svc in cron crond; do
            if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
                systemctl enable "$svc" --quiet 2>/dev/null || true
                systemctl start  "$svc" 2>/dev/null || true
                return
            fi
        done
    elif command -v service &>/dev/null; then
        service cron start 2>/dev/null || service crond start 2>/dev/null || true
    fi
}

if [[ "$DISTRO" == "alpine" ]]; then
    if ! command -v crond &>/dev/null; then
        install_pkg "dcron" "alpine" 2>/dev/null || true
    fi
    rc-update add dcron default > /dev/null 2>&1 || true
    rc-service dcron start 2>/dev/null || true
else
    start_cron_service
fi

CRON_ENTRY="* * * * * ${INSTALL_DIR}/${SCRIPT_NAME} --cron-check >> ${INSTALL_DIR}/logs/cron.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "sub-manager.sh --cron-check"; then
    echo -e "  ${Y}→ Cron 条目已存在，跳过${NC}"
else
    ( crontab -l 2>/dev/null; echo "$CRON_ENTRY" ) | crontab -
    echo -e "  ${G}✓ 定时任务已添加 (每分钟检查执行到期任务)${NC}"
fi

# ── 清理临时文件 ───────────────────────────────────────────
rm -rf "$SOURCES_BACKUP_DIR"

# ── 完成 ───────────────────────────────────────────────────
echo ""
echo -e "${G}  ═══════════════════════════════════════════════${NC}"
echo -e "${G}  ✓ 安装完成!${NC}"
echo -e "${G}  ═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${W}启动方式:${NC}"
echo -e "  • ${C}bash ${INSTALL_DIR}/${SCRIPT_NAME}${NC}"
echo -e "  • ${C}subm${NC}   全局别名 (重新登录后生效)"
if [[ "${override_su:-n}" == "y" ]]; then
    echo -e "  • ${C}su${NC}     无参数直接打开"
fi

if [[ "$OS_TYPE" == "macos" ]]; then
    echo ""
    echo -e "  ${Y}macOS 定时拉取建议:${NC}"
    echo -e "  使用 launchd 或直接 crontab -e 添加:"
    echo -e "  ${C}*/60 * * * * ${INSTALL_DIR}/${SCRIPT_NAME} --cron-check${NC}"
elif [[ "$OS_TYPE" == "windows" ]]; then
    echo ""
    echo -e "  ${Y}Windows 定时拉取建议:${NC}"
    echo -e "  在任务计划程序中添加触发器，执行:"
    echo -e "  ${C}bash ${INSTALL_DIR}/${SCRIPT_NAME} --cron-check${NC}"
fi
echo ""

read -rp "  是否立即打开管理界面? [Y/n]: " launch
if [[ "$(echo "$launch" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
    bash "${INSTALL_DIR}/${SCRIPT_NAME}"
fi

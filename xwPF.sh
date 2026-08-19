#!/bin/bash

# xwPF - Realm 端口转发管理工具
# Bootstrap 引导器 + 入口

# 安装路径
INSTALL_DIR="/usr/local/bin"
LIB_DIR="$INSTALL_DIR/lib"
SHORTCUT_PATH="/usr/local/bin/pf"

# 仓库地址
REPO_RAW_URL="https://raw.githubusercontent.com/online-s/realm-xwPF/main"

# 模块列表（加载顺序）
LIB_FILES=("core.sh" "rules.sh" "server.sh" "realm.sh" "ui.sh")
DEFAULT_RULE_FILES=(
    "rule-1.conf"
    "rule-2.conf"
    "rule-3.conf"
    "rule-4.conf"
    "rule-5.conf"
    "rule-6.conf"
    "rule-7.conf"
    "rule-8.conf"
    "rule-9.conf"
    "rule-10.conf"
    "rule-11.conf"
    "rule-12.conf"
    "rule-13.conf"
    "rule-14.conf"
    "rule-15.conf"
    "rule-16.conf"
)

# 颜色
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_BLUE='\033[0;34m'
_NC='\033[0m'

# 下载函数
_download() {
    local url="$1" target="$2"
    curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$target" 2>/dev/null ||
    wget -qO "$target" "$url" 2>/dev/null
}

# 安装/更新脚本文件到系统（幂等）
_bootstrap() {
    echo -e "${_YELLOW}正在安装/更新脚本文件...${_NC}"

    mkdir -p "$LIB_DIR"

    # 下载入口脚本
    if _download "$REPO_RAW_URL/xwPF.sh" "$INSTALL_DIR/xwPF.sh"; then
        chmod +x "$INSTALL_DIR/xwPF.sh"
        echo -e "  ${_GREEN}✓${_NC} xwPF.sh"
    else
        echo -e "  ${_RED}✗${_NC} xwPF.sh 下载失败"
        return 1
    fi

    # 下载所有模块
    local failed=0
    for f in "${LIB_FILES[@]}"; do
        if _download "$REPO_RAW_URL/lib/$f" "$LIB_DIR/$f"; then
            echo -e "  ${_GREEN}✓${_NC} lib/$f"
        else
            echo -e "  ${_RED}✗${_NC} lib/$f 下载失败"
            failed=1
        fi
    done

    local default_rules_dir="$INSTALL_DIR/default-rules"
    mkdir -p "$default_rules_dir"
    for f in "${DEFAULT_RULE_FILES[@]}"; do
        if _download "$REPO_RAW_URL/default-rules/$f" "$default_rules_dir/$f"; then
            echo -e "  ${_GREEN}✓${_NC} default-rules/$f"
        else
            echo -e "  ${_RED}✗${_NC} default-rules/$f 下载失败"
            failed=1
        fi
    done

    [ "$failed" -eq 1 ] && return 1

    # 创建快捷命令
    ln -sf "$INSTALL_DIR/xwPF.sh" "$SHORTCUT_PATH"
    echo -e "${_GREEN}✓ 快捷命令已创建: pf${_NC}"

    echo -e "${_GREEN}=== 脚本安装完成${_NC}"
    echo ""
}

# 加载模块
_load_libs() {
    if [ ! -d "$LIB_DIR" ] || [ ! -f "$LIB_DIR/core.sh" ]; then
        echo -e "${_RED}错误: 未找到模块目录，请先安装${_NC}"
        echo -e "${_BLUE}wget -qO- ${REPO_RAW_URL}/xwPF.sh | sudo bash -s install${_NC}"
        return 1
    fi

    for f in "${LIB_FILES[@]}"; do
        if [ -f "$LIB_DIR/$f" ]; then
            source "$LIB_DIR/$f"
        else
            echo -e "${_RED}错误: 缺少模块 $f${_NC}"
            return 1
        fi
    done
}

# 主入口
case "${1:-}" in
    install)
        [ "$(id -u)" -ne 0 ] && { echo -e "${_RED}错误: 需要 root 权限${_NC}"; exit 1; }
        _bootstrap || exit 1
        _load_libs || exit 1
        _SKIP_SCRIPT_UPDATE=1 smart_install
        ;;
    *)
        _load_libs || exit 1
        main "$@"
        ;;
esac

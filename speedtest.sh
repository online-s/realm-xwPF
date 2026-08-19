#!/bin/bash

# 中转网络链路测试工具

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'
SHORT_CONNECT_TIMEOUT=5
SHORT_MAX_TIMEOUT=7
LONG_CONNECT_TIMEOUT=15
LONG_MAX_TIMEOUT=20

# 全局变量
TARGET_IP=""
TARGET_PORT="5201"
TEST_DURATION="30"
ROLE=""

# 端口冲突处理相关变量
STOPPED_PROCESS_PID=""
STOPPED_PROCESS_CMD=""
STOPPED_PROCESS_PORT=""

# 清理标志位，防止重复执行
CLEANUP_DONE=false

# 异常退出时的清理函数
cleanup_on_exit() {
    # 防止重复执行清理
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true

    # 停止可能运行的iperf3服务
    pkill -f "iperf3.*-s" 2>/dev/null || true

    # 恢复被临时停止的进程
    restore_stopped_process

    echo -e "\n${YELLOW}脚本已退出，清理完成${NC}"
}

# 统一下载函数
download_from_sources() {
    local url="$1"
    local target_path="$2"

    if curl -fsSL --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "$url" -o "$target_path"; then
        echo -e "${GREEN}✓ 下载成功${NC}" >&2
        return 0
    else
        echo -e "${RED}✗ 下载失败${NC}" >&2
        return 1
    fi
}

# 全局测试结果数据结构
declare -A TEST_RESULTS=(
    # 延迟测试结果
    ["latency_min"]=""
    ["latency_avg"]=""
    ["latency_max"]=""
    ["latency_jitter"]=""
    ["packet_sent"]=""
    ["packet_received"]=""

    # TCP上行测试结果
    ["tcp_up_speed_mbps"]=""
    ["tcp_up_speed_mibs"]=""
    ["tcp_up_transfer"]=""
    ["tcp_up_retrans"]=""

    # TCP下行测试结果
    ["tcp_down_speed_mbps"]=""
    ["tcp_down_speed_mibs"]=""
    ["tcp_down_transfer"]=""
    ["tcp_down_retrans"]=""

    # UDP上行测试结果
    ["udp_up_speed_mbps"]=""
    ["udp_up_speed_mibs"]=""
    ["udp_up_loss"]=""
    ["udp_up_jitter"]=""

    # UDP下行测试结果
    ["udp_down_speed_mbps"]=""
    ["udp_down_speed_mibs"]=""
    ["udp_down_loss"]=""
    ["udp_down_jitter"]=""
)

# 辅助函数：安全设置测试结果
set_test_result() {
    local key="$1"
    local value="$2"
    if [ -n "$value" ] && [ "$value" != "N/A" ]; then
        TEST_RESULTS["$key"]="$value"
    else
        TEST_RESULTS["$key"]=""
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
        exit 1
    fi
}

# 工具配置数组 - 定义所有需要的工具
declare -A REQUIRED_TOOLS=(
    ["iperf3"]="apt:iperf3"
    ["hping3"]="apt:hping3"
    ["bc"]="apt:bc"
    ["nc"]="apt:netcat-openbsd"
)

# 工具状态数组
declare -A TOOL_STATUS=()

# 检查单个工具是否存在
check_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# 检测所有工具状态
detect_all_tools() {
    for tool in "${!REQUIRED_TOOLS[@]}"; do
        if check_tool "$tool"; then
            TOOL_STATUS["$tool"]="installed"
        else
            TOOL_STATUS["$tool"]="missing"
        fi
    done
}

# 获取缺失的工具列表
get_missing_tools() {
    local missing_tools=()
    for tool in "${!TOOL_STATUS[@]}"; do
        if [ "${TOOL_STATUS[$tool]}" = "missing" ]; then
            missing_tools+=("$tool")
        fi
    done
    echo "${missing_tools[@]}"
}


# 安装单个APT工具
install_apt_tool() {
    local tool="$1"
    local package="$2"

    echo -e "${BLUE}🔧 安装 $tool...${NC}"
    # 设置非交互模式，防止安装时等待用户确认
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ $tool 安装成功${NC}"
        TOOL_STATUS["$tool"]="installed"
        return 0
    else
        echo -e "${RED}✗ $tool 安装失败${NC}"
        return 1
    fi
}


# 安装缺失的工具
install_missing_tools() {
    local missing_tools=($(get_missing_tools))

    if [ ${#missing_tools[@]} -eq 0 ]; then
        return 0
    fi

    echo -e "${YELLOW}📦 安装缺失工具: ${missing_tools[*]}${NC}"

    # 更新包列表（非交互模式）
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1

    local install_failed=false

    for tool in "${missing_tools[@]}"; do
        local tool_config="${REQUIRED_TOOLS[$tool]}"
        local install_type="${tool_config%%:*}"
        local package_name="${tool_config##*:}"

        case "$install_type" in
            "apt")
                if ! install_apt_tool "$tool" "$package_name"; then
                    install_failed=true
                fi
                ;;
            *)
                echo -e "${RED}✗ 未知的安装类型: $install_type${NC}"
                install_failed=true
                ;;
        esac
    done

    if [ "$install_failed" = false ]; then
        echo -e "${GREEN}✅ 工具安装完成${NC}"
    fi
}

# 安装所需工具
install_required_tools() {
    echo -e "${BLUE}🔍 检测工具状态...${NC}"

    # 检测当前工具状态
    detect_all_tools

    # 安装缺失的工具
    install_missing_tools
}

# 验证IP地址格式
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    elif [[ $ip =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        # 域名格式
        return 0
    else
        return 1
    fi
}

# 获取本机IP
get_public_ip() {
    local ip=""

    # 优先使用ipinfo.io
    ip=$(curl -s --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "https://ipinfo.io/ip" 2>/dev/null | tr -d '\n\r ')
    if validate_ip "$ip"; then
        echo "$ip"
        return 0
    fi

    # 备用cloudflare trace
    ip=$(curl -s --connect-timeout $SHORT_CONNECT_TIMEOUT --max-time $SHORT_MAX_TIMEOUT "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null | grep "ip=" | cut -d'=' -f2 | tr -d '\n\r ')
    if validate_ip "$ip"; then
        echo "$ip"
        return 0
    fi

    return 1
}

# 验证端口号
validate_port() {
    local port="$1"
    if [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 检测端口占用情况
check_port_usage() {
    local port="$1"
    local result=""

    # 优先使用ss命令
    if command -v ss >/dev/null 2>&1; then
        result=$(ss -tlnp 2>/dev/null | grep ":$port ")
    elif command -v netstat >/dev/null 2>&1; then
        result=$(netstat -tlnp 2>/dev/null | grep ":$port ")
    else
        return 1
    fi

    if [ -n "$result" ]; then
        echo "$result"
        return 0
    else
        return 1
    fi
}

# 从端口占用信息中提取进程信息
extract_process_info() {
    local port_info="$1"
    local pid=""
    local cmd=""

    # 从ss或netstat输出中提取PID和进程名
    if echo "$port_info" | grep -q "pid="; then
        # ss格式: users:(("进程名",pid=1234,fd=5))
        pid=$(echo "$port_info" | grep -o 'pid=[0-9]\+' | cut -d'=' -f2)
        cmd=$(echo "$port_info" | grep -o '(".*"' | sed 's/("//; s/".*//')
    else
        # netstat格式: 1234/进程名
        local proc_info=$(echo "$port_info" | awk '{print $NF}' | grep -o '[0-9]\+/.*')
        if [ -n "$proc_info" ]; then
            pid=$(echo "$proc_info" | cut -d'/' -f1)
            cmd=$(echo "$proc_info" | cut -d'/' -f2)
        fi
    fi

    if [ -n "$pid" ] && [ -n "$cmd" ]; then
        echo "$pid|$cmd"
        return 0
    else
        return 1
    fi
}

# 临时停止占用端口的进程
stop_port_process() {
    local port="$1"
    local port_info=$(check_port_usage "$port")

    if [ -z "$port_info" ]; then
        return 0  # 端口未被占用
    fi

    local process_info=$(extract_process_info "$port_info")
    if [ -z "$process_info" ]; then
        echo -e "${YELLOW}⚠️  无法获取占用进程信息，跳过进程停止${NC}"
        return 1
    fi

    local pid=$(echo "$process_info" | cut -d'|' -f1)
    local cmd=$(echo "$process_info" | cut -d'|' -f2)

    echo -e "${YELLOW}检测到端口 $port 被占用${NC}"
    echo -e "${BLUE}占用进程: PID=$pid, 命令=$cmd${NC}"
    echo ""

    read -p "是否临时停止该进程以进行测试？测试完成后会自动恢复 (y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        # 获取完整的进程命令行用于恢复
        local full_cmd=$(ps -p "$pid" -o args= 2>/dev/null | head -1)
        if [ -z "$full_cmd" ]; then
            full_cmd="$cmd"  # 备用方案
        fi

        # 停止进程
        if kill "$pid" 2>/dev/null; then
            echo -e "${GREEN}✅ 进程已临时停止${NC}"

            # 记录进程信息用于恢复
            STOPPED_PROCESS_PID="$pid"
            STOPPED_PROCESS_CMD="$full_cmd"
            STOPPED_PROCESS_PORT="$port"

            # 等待端口释放
            sleep 2

            # 验证端口是否已释放
            if check_port_usage "$port" >/dev/null 2>&1; then
                echo -e "${YELLOW}⚠️  端口可能仍被占用，请手动检查${NC}"
                return 1
            else
                echo -e "${GREEN}✅ 端口 $port 已释放${NC}"
                return 0
            fi
        else
            echo -e "${RED}✗ 无法停止进程 (PID: $pid)${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}用户选择不停止进程，请手动处理端口冲突或选择其他端口${NC}"
        return 1
    fi
}

# 恢复被停止的进程
restore_stopped_process() {
    if [ -n "$STOPPED_PROCESS_CMD" ] && [ -n "$STOPPED_PROCESS_PORT" ]; then
        echo -e "${BLUE}正在恢复被停止的进程...${NC}"
        echo -e "${YELLOW}恢复命令: $STOPPED_PROCESS_CMD${NC}"

        # 在后台启动进程
        nohup $STOPPED_PROCESS_CMD >/dev/null 2>&1 &
        local new_pid=$!

        # 等待进程启动
        sleep 3

        # 检查进程是否成功启动并占用端口
        if check_port_usage "$STOPPED_PROCESS_PORT" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 进程已成功恢复 (新PID: $new_pid)${NC}"
        else
            echo -e "${YELLOW}⚠️  进程恢复可能失败，请手动检查${NC}"
            echo -e "${YELLOW}   原始命令: $STOPPED_PROCESS_CMD${NC}"
        fi

        # 清空记录
        STOPPED_PROCESS_PID=""
        STOPPED_PROCESS_CMD=""
        STOPPED_PROCESS_PORT=""
    fi
}

# 测试连通性
test_connectivity() {
    local ip="$1"
    local port="$2"

    if nc -z -w3 "$ip" "$port" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 服务端模式 - 启动服务端
landing_server_mode() {
    clear
    echo -e "${GREEN}=== 服务端 (开放测试) ===${NC}"
    echo ""

    # 输入监听端口
    while true; do
        read -p "监听测试端口 [默认5201]: " input_port
        if [ -z "$input_port" ]; then
            TARGET_PORT="5201"
        elif validate_port "$input_port"; then
            TARGET_PORT="$input_port"
        else
            echo -e "${RED}无效端口号，请输入1-65535之间的数字${NC}"
            continue
        fi

        # 检测端口冲突并处理
        echo -e "${YELLOW}检查端口 $TARGET_PORT 占用情况...${NC}"
        if check_port_usage "$TARGET_PORT" >/dev/null 2>&1; then
            if stop_port_process "$TARGET_PORT"; then
                echo -e "${GREEN}✅ 端口 $TARGET_PORT 可用${NC}"
                break
            else
                echo -e "${RED}端口 $TARGET_PORT 冲突未解决，请选择其他端口${NC}"
                continue
            fi
        else
            echo -e "${GREEN}✅ 端口 $TARGET_PORT 可用${NC}"
            break
        fi
    done

    echo ""
    echo -e "${YELLOW}启动服务中...${NC}"

    # 停止可能存在的iperf3进程
    pkill -f "iperf3.*-s.*-p.*$TARGET_PORT" 2>/dev/null

    # 启动iperf3服务端
    if iperf3 -s -p "$TARGET_PORT" -D >/dev/null 2>&1; then
        echo -e "${GREEN}✅ iperf3服务已启动 (端口$TARGET_PORT)${NC}"

        # 只在服务运行期间设置临时trap
        trap 'pkill -f "iperf3.*-s.*-p.*$TARGET_PORT" 2>/dev/null; restore_stopped_process; exit' INT TERM
    else
        echo -e "${RED}✗ iperf3服务启动失败${NC}"
        # 恢复被临时停止的进程
        restore_stopped_process
        exit 1
    fi

    # 获取本机IP
    local local_ip=$(get_public_ip || echo "获取失败")

    echo -e "${BLUE}📋 服务端信息${NC}"
    echo -e "   IP地址: ${GREEN}$local_ip${NC}"
    echo -e "   端口: ${GREEN}$TARGET_PORT${NC}"
    echo ""
    echo -e "${YELLOW}💡 请在客户端输入服务端IP: ${GREEN}$local_ip${NC}"
    echo -e "${YELLOW}   请到客户端选择1. 客户端 (本机发起测试)...${NC}"

    echo ""
    echo -e "${WHITE}按任意键停止服务${NC}"

    # 等待用户按键
    read -n 1 -s

    # 清除临时trap
    trap - INT TERM

    # 停止服务
    pkill -f "iperf3.*-s.*-p.*$TARGET_PORT" 2>/dev/null
    echo ""
    echo -e "${GREEN}iperf3服务已停止${NC}"

    # 恢复被临时停止的进程
    restore_stopped_process
}

# 执行延迟测试
run_latency_tests() {
    echo -e "${YELLOW}🟢 延迟测试${NC}"
    echo ""

    # 使用hping3进行TCP延迟测试
    if check_tool "hping3"; then
        echo -e "${GREEN}🚀 TCP应用层延迟测试 - 目标: ${TARGET_IP}:${TARGET_PORT}${NC}"
        echo ""

        # 后台执行测试，前台显示进度条
        local temp_result=$(mktemp)
        (hping3 -c "$TEST_DURATION" -i 1 -S -p "$TARGET_PORT" "$TARGET_IP" > "$temp_result" 2>&1) &
        local test_pid=$!

        show_progress_bar "$TEST_DURATION" "TCP延迟测试"

        # 等待测试完成
        wait $test_pid
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            local result=$(cat "$temp_result")
            echo ""
            echo -e "${BLUE}📋 测试数据:${NC}"
            echo "$result"

            # 解析TCP延迟统计和包统计
            local stats_line=$(echo "$result" | grep "round-trip")
            local packet_line=$(echo "$result" | grep "packets transmitted")

            if [ -n "$stats_line" ] && [ -n "$packet_line" ]; then
                # 提取延迟数据: min/avg/max
                local stats=$(echo "$stats_line" | awk -F'min/avg/max = ' '{print $2}' | awk '{print $1}')
                local min_delay=$(echo "$stats" | cut -d'/' -f1)
                local avg_delay=$(echo "$stats" | cut -d'/' -f2)
                local max_delay=$(echo "$stats" | cut -d'/' -f3)

                # 提取包统计数据
                local transmitted=$(echo "$packet_line" | awk '{print $1}')
                local received=$(echo "$packet_line" | awk '{print $4}')
                local loss_percent=$(echo "$packet_line" | grep -o '[0-9-]\+%' | head -1)

                # 计算重复包数量
                local duplicate_count=0
                if [ "$received" -gt "$transmitted" ]; then
                    duplicate_count=$((received - transmitted))
                fi

                # 计算延迟抖动 (最高延迟 - 最低延迟)
                local jitter=$(awk "BEGIN {printf \"%.1f\", $max_delay - $min_delay}")

                # 提取TTL范围
                local ttl_values=$(echo "$result" | grep "ttl=" | grep -o "ttl=[0-9]\+" | grep -o "[0-9]\+" | sort -n | uniq)
                local ttl_min=$(echo "$ttl_values" | head -1)
                local ttl_max=$(echo "$ttl_values" | tail -1)
                local ttl_range="${ttl_min}"
                if [ "$ttl_min" != "$ttl_max" ]; then
                    ttl_range="${ttl_min}-${ttl_max}"
                fi

                # 验证提取结果
                if [ -n "$min_delay" ] && [ -n "$avg_delay" ] && [ -n "$max_delay" ]; then
                    echo -e "${GREEN}TCP应用层延迟测试完成${NC}"
                    echo -e "使用指令: ${YELLOW}hping3 -c $TEST_DURATION -i 1 -S -p $TARGET_PORT $TARGET_IP${NC}"
                    echo ""
                    echo -e "${BLUE}📊 测试结果${NC}"
                    echo ""
                    echo -e "TCP延迟: ${YELLOW}最低${min_delay}ms / 平均${avg_delay}ms / 最高${max_delay}ms${NC}"

                    # 构建收发统计信息
                    local packet_info="${transmitted} 发送 / ${received} 接收"
                    if [ "$duplicate_count" -gt 0 ]; then
                        packet_info="${packet_info} (含 ${duplicate_count} 个异常包)"
                    fi

                    echo -e "收发统计: ${YELLOW}${packet_info}${NC} | 抖动: ${YELLOW}${jitter}ms${NC} | TTL范围: ${YELLOW}${ttl_range}${NC}"

                    # 收集延迟测试数据
                    set_test_result "latency_min" "$min_delay"
                    set_test_result "latency_avg" "$avg_delay"
                    set_test_result "latency_max" "$max_delay"
                    set_test_result "latency_jitter" "$jitter"
                    set_test_result "packet_sent" "$transmitted"
                    set_test_result "packet_received" "$received"

                    HPING_SUCCESS=true
                else
                    echo -e "${RED}❌ 数据提取失败${NC}"
                    HPING_SUCCESS=false
                fi
            else
                echo -e "${RED}❌ 未找到统计行${NC}"
                HPING_SUCCESS=false
            fi
        else
            echo -e "${RED}❌ 测试执行失败 (可能需要管理员权限)${NC}"
            HPING_SUCCESS=false
        fi

        rm -f "$temp_result"
        echo ""
    else
        echo -e "${YELLOW}⚠️  hping3工具不可用，跳过TCP延迟测试${NC}"
        HPING_SUCCESS=false
    fi
}

# 显示进度条
show_progress_bar() {
    local duration=$1
    local test_name="$2"

    echo -e "${BLUE}🔄 ${test_name} 进行中...${NC}"

    for ((i=1; i<=duration; i++)); do
        printf "\r  ⏱️ %d/%d秒" $i $duration
        sleep 1
    done
    echo ""
}

# 获取系统和内核信息
get_system_kernel_info() {
    # 获取系统信息
    local system_info="未知"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        system_info="$NAME $VERSION_ID"
    fi

    # 获取内核信息
    local kernel_info=$(uname -r 2>/dev/null || echo "未知")

    echo "${system_info} | 内核: ${kernel_info}"
}

# 获取TCP缓冲区信息
get_tcp_buffer_info() {
    # 获取接收缓冲区
    local rmem="未知"
    if [ -f /proc/sys/net/ipv4/tcp_rmem ]; then
        rmem=$(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || echo "未知")
    fi

    # 获取发送缓冲区
    local wmem="未知"
    if [ -f /proc/sys/net/ipv4/tcp_wmem ]; then
        wmem=$(cat /proc/sys/net/ipv4/tcp_wmem 2>/dev/null || echo "未知")
    fi

    echo "rmem:$rmem|wmem:$wmem"
}

# 获取本机TCP拥塞控制算法和队列信息
get_local_tcp_info() {
    # 获取拥塞控制算法
    local congestion=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "未知")

    # 获取队列算法 ip命令
    local qdisc="未知"
    local default_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$default_iface" ]; then
        qdisc=$(ip link show "$default_iface" 2>/dev/null | grep -o "qdisc [^ ]*" | awk '{print $2}' | head -1 || echo "未知")
    fi

    echo "${congestion}+${qdisc}"
}

# 解析iperf3输出数据
parse_iperf3_data() {
    local line="$1"
    local data_type="$2"

    case "$data_type" in
        "transfer")
            # MBytes和GBytes，统一转换为MBytes
            local transfer_data=$(echo "$line" | grep -o '[0-9.]\+\s*[MG]Bytes' | head -1)
            if [ -n "$transfer_data" ]; then
                local value=$(echo "$transfer_data" | grep -o '[0-9.]\+')
                local unit=$(echo "$transfer_data" | grep -o '[MG]Bytes')
                if [ "$unit" = "GBytes" ]; then
                    # GBytes转换为MBytes (1 GB = 1024 MB)
                    awk "BEGIN {printf \"%.1f\", $value * 1024}"
                else
                    echo "$value"
                fi
            fi
            ;;
        "bitrate")
            # 提取Mbits/sec数值
            echo "$line" | grep -o '[0-9.]\+\s*Mbits/sec' | head -1 | grep -o '[0-9.]\+'
            ;;
        "retrans")
            echo "$line" | grep -o '[0-9]\+\s*sender$' | grep -o '[0-9]\+' || echo "0"
            ;;
        "jitter")
            echo "$line" | grep -o '[0-9.]\+\s*ms' | head -1 | grep -o '[0-9.]\+'
            ;;
        "loss")
            echo "$line" | grep -o '[0-9]\+/[0-9]\+\s*([0-9.]\+%)' | head -1
            ;;
        "cpu_local")
            echo "$line" | grep -o 'local/sender [0-9.]\+%' | grep -o '[0-9.]\+%'
            ;;
        "cpu_remote")
            echo "$line" | grep -o 'remote/receiver [0-9.]\+%' | grep -o '[0-9.]\+%'
            ;;
    esac
}

# TCP上行测试
run_tcp_single_thread_test() {
    echo -e "${GREEN}🚀 TCP上行带宽测试 - 目标: ${TARGET_IP}:${TARGET_PORT}${NC}"
    echo ""

    # 后台执行iperf3，前台显示倒计时
    local temp_result=$(mktemp)
    (iperf3 -c "$TARGET_IP" -p "$TARGET_PORT" -t "$TEST_DURATION" -f m > "$temp_result" 2>&1) &
    local test_pid=$!

    show_progress_bar "$TEST_DURATION" "TCP单线程测试"

    # 等待测试完成
    wait $test_pid
    local exit_code=$?

    # 首次失败快速重试一次（针对首连接冷关闭问题）
    if [ $exit_code -ne 0 ]; then
        sleep 0.5
        : > "$temp_result"
        (iperf3 -c "$TARGET_IP" -p "$TARGET_PORT" -t "$TEST_DURATION" -f m > "$temp_result" 2>&1) &
        local test_pid2=$!
        show_progress_bar "$TEST_DURATION" "TCP单线程测试"
        wait $test_pid2
        exit_code=$?
    fi

    if [ $exit_code -eq 0 ]; then
        local result=$(cat "$temp_result")
        echo ""
        echo -e "${BLUE}📋 测试数据:${NC}"
        # 过滤杂乱信息，保留核心测试数据
        echo "$result" | sed -n '/\[ *[0-9]\]/,/^$/p' | sed '/^- - - - -/,$d' | sed '/^$/d'

        # 解析最终结果
        local final_line=$(echo "$result" | grep "sender$" | tail -1)
        local cpu_line=$(echo "$result" | grep "CPU Utilization" | tail -1)

        if [ -n "$final_line" ]; then
            local final_transfer=$(parse_iperf3_data "$final_line" "transfer")
            local final_bitrate=$(parse_iperf3_data "$final_line" "bitrate")

            # 提取重传次数
            local final_retrans=$(echo "$final_line" | awk '{print $(NF-1)}')

            # CPU使用率
            local cpu_local=""
            local cpu_remote=""
            if [ -n "$cpu_line" ]; then
                cpu_local=$(parse_iperf3_data "$cpu_line" "cpu_local")
                cpu_remote=$(parse_iperf3_data "$cpu_line" "cpu_remote")
            fi

            echo -e "${GREEN}TCP上行测试完成${NC}"
            echo -e "使用指令: ${YELLOW}iperf3 -c $TARGET_IP -p $TARGET_PORT -t $TEST_DURATION -f m${NC}"
            echo ""
            echo -e "${YELLOW}📊 测试结果${NC}"
            echo ""

            # 计算Mbps，MB/s直接使用MBytes/sec值
            local mbps="N/A"
            local mb_per_sec="N/A"
            if [ -n "$final_bitrate" ] && [[ "$final_bitrate" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                mbps=$(awk "BEGIN {printf \"%.0f\", $final_bitrate}")
                mb_per_sec=$(awk "BEGIN {printf \"%.1f\", $final_bitrate / 8}")
            fi

            echo -e "平均发送速率 (Sender): ${YELLOW}${mbps} Mbps${NC} (${YELLOW}${mb_per_sec} MB/s${NC})          总传输数据量: ${YELLOW}${final_transfer:-N/A} MB${NC}"

            # 显示重传次数（不计算重传率，避免估算误差）
            echo -e "重传次数: ${YELLOW}${final_retrans:-0} 次${NC}"

            # CPU负载
            if [ -n "$cpu_local" ] && [ -n "$cpu_remote" ]; then
                echo -e "CPU 负载: 发送端 ${YELLOW}${cpu_local}${NC} 接收端 ${YELLOW}${cpu_remote}${NC}"
            fi

            echo -e "测试时长: ${YELLOW}${TEST_DURATION} 秒${NC}"

            # 收集TCP上行测试数据
            set_test_result "tcp_up_speed_mbps" "$mbps"
            set_test_result "tcp_up_speed_mibs" "$mb_per_sec"
            set_test_result "tcp_up_transfer" "$final_transfer"
            set_test_result "tcp_up_retrans" "$final_retrans"

            # 保存TCP Mbps值，四舍五入到10的倍数，用于UDP的-b参数
            if [ "$mbps" != "N/A" ]; then
                # 复用已计算的mbps值，避免重复计算
                TCP_MBPS=$(awk "BEGIN {printf \"%.0f\", int(($mbps + 5) / 10) * 10}")
            else
                TCP_MBPS=100  # 默认值
            fi
            TCP_SINGLE_SUCCESS=true
        else
            echo -e "${RED}❌ 无法解析测试结果${NC}"
            TCP_SINGLE_SUCCESS=false
        fi
    else
        echo -e "${RED}❌ 测试执行失败${NC}"
        TCP_SINGLE_SUCCESS=false
    fi

    rm -f "$temp_result"
    echo ""
}

# 带宽测试
run_bandwidth_tests() {
    echo -e "${YELLOW}🟢 网络带宽性能测试${NC}"
    echo ""

    # 检查工具
    if ! check_tool "iperf3"; then
        echo -e "${YELLOW}⚠️  iperf3工具不可用，跳过带宽测试${NC}"
        TCP_SUCCESS=false
        UDP_SINGLE_SUCCESS=false
        UDP_DOWNLOAD_SUCCESS=false
        return
    fi

    # 连通性检查
    if ! nc -z -w3 "$TARGET_IP" "$TARGET_PORT" >/dev/null 2>&1; then
        echo -e "  ${RED}无法连接到目标服务器${NC}"
        echo -e "  ${YELLOW}请确认目标服务器运行: iperf3 -s -p $TARGET_PORT${NC}"
        TCP_SUCCESS=false
        UDP_SINGLE_SUCCESS=false
        UDP_DOWNLOAD_SUCCESS=false
        echo ""
        return
    fi

    # 预热：快速建立控制通道，提升首项成功率（输出丢弃，不影响报告）
    iperf3 -c "$TARGET_IP" -p "$TARGET_PORT" -t 1 -f m >/dev/null 2>&1 || true
    sleep 1

    # TCP上行
    run_tcp_single_thread_test

    echo ""
    sleep 2

    # UDP上行
    run_udp_single_test

    echo ""
    sleep 2

    # TCP下行
    run_tcp_download_test

    echo ""
    sleep 2

    # UDP下行
    run_udp_download_test
}

# UDP上行测试
run_udp_single_test() {
    echo -e "${GREEN}🚀 UDP上行性能测试 - 目标: ${TARGET_IP}:${TARGET_PORT}${NC}"
    echo ""

    # 根据TCP测试结果设置UDP目标带宽
    local udp_bandwidth="30M"  # 默认值
    if [ "$TCP_SINGLE_SUCCESS" = true ] && [ -n "$TCP_MBPS" ]; then
        # 直接使用TCP测试的Mbps值作为UDP目标带宽
        udp_bandwidth="${TCP_MBPS}M"
    fi

    # 后台执行iperf3，前台显示倒计时
    local temp_result=$(mktemp)
    (iperf3 -c "$TARGET_IP" -p "$TARGET_PORT" -u -b "$udp_bandwidth" -t "$TEST_DURATION" -f m > "$temp_result" 2>&1) &
    local test_pid=$!
    show_progress_bar "$TEST_DURATION" "UDP单线程测试"
    # 等待测试完成
    wait $test_pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        local result=$(cat "$temp_result")
        echo ""
        echo -e "${BLUE}📋 测试数据:${NC}"
        # 过滤杂乱信息，保留核心测试数据
        echo "$result" | sed -n '/\[ *[0-9]\]/,/^$/p' | sed '/^- - - - -/,$d' | sed '/^$/d'

        # 解析最终结果
        local sender_line=$(echo "$result" | grep "sender$" | tail -1)
        local receiver_line=$(echo "$result" | grep "receiver$" | tail -1)

        if [ -n "$sender_line" ]; then
            local final_transfer=$(parse_iperf3_data "$sender_line" "transfer")
            local final_bitrate=$(parse_iperf3_data "$sender_line" "bitrate")

            echo -e "${GREEN}UDP上行测试完成${NC}"
            echo -e "使用指令: ${YELLOW}iperf3 -c $TARGET_IP -p $TARGET_PORT -u -b $udp_bandwidth -t $TEST_DURATION -f m${NC}"
            echo ""
            echo -e "${YELLOW}📡 传输统计${NC}"
            echo ""

            # 解析接收端信息和CPU信息
            local cpu_line=$(echo "$result" | grep "CPU Utilization" | tail -1)
            local cpu_local=""
            local cpu_remote=""
            if [ -n "$cpu_line" ]; then
                cpu_local=$(parse_iperf3_data "$cpu_line" "cpu_local")
                cpu_remote=$(parse_iperf3_data "$cpu_line" "cpu_remote")
            fi

            if [ -n "$receiver_line" ]; then
                local receiver_transfer=$(parse_iperf3_data "$receiver_line" "transfer")
                local receiver_bitrate=$(parse_iperf3_data "$receiver_line" "bitrate")
                local jitter=$(parse_iperf3_data "$receiver_line" "jitter")
                local loss_info=$(parse_iperf3_data "$receiver_line" "loss")

                # receiver_bitrate格式Mbits/sec
                local recv_mbps="N/A"
                local recv_mb_per_sec="N/A"
                if [ -n "$receiver_bitrate" ] && [[ "$receiver_bitrate" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    recv_mbps=$(awk "BEGIN {printf \"%.1f\", $receiver_bitrate}")  # 直接使用Mbits/sec值
                    recv_mb_per_sec=$(awk "BEGIN {printf \"%.1f\", $receiver_bitrate / 8}")  # 转换为MB/s
                fi

                # 计算目标速率显示（与-b参数一致）
                local target_mbps=$(echo "$udp_bandwidth" | sed 's/M$//')

                echo -e "有效吞吐量 (吞吐率): ${YELLOW}${recv_mbps} Mbps${NC} (${YELLOW}${recv_mb_per_sec} MB/s${NC})"
                echo -e "丢包率 (Packet Loss): ${YELLOW}${loss_info:-N/A}${NC}"
                echo -e "网络抖动 (Jitter): ${YELLOW}${jitter:-N/A} ms${NC}"

                # 显示CPU负载
                if [ -n "$cpu_local" ] && [ -n "$cpu_remote" ]; then
                    echo -e "CPU负载: 发送端 ${YELLOW}${cpu_local}${NC} 接收端 ${YELLOW}${cpu_remote}${NC}"
                fi

                echo -e "测试目标速率: ${YELLOW}${target_mbps} Mbps${NC}"

                # 收集UDP上行测试数据
                set_test_result "udp_up_speed_mbps" "$recv_mbps"
                set_test_result "udp_up_speed_mibs" "$recv_mb_per_sec"
                set_test_result "udp_up_loss" "$loss_info"
                set_test_result "udp_up_jitter" "$jitter"
            else
                echo -e "有效吞吐量 (吞吐率): ${YELLOW}N/A${NC}"
                echo -e "丢包率 (Packet Loss): ${YELLOW}N/A${NC}"
                echo -e "网络抖动 (Jitter): ${YELLOW}N/A${NC}"
                echo -e "CPU负载: ${YELLOW}N/A${NC}"
                echo -e "测试目标速率: ${YELLOW}N/A${NC}"
            fi
            UDP_SINGLE_SUCCESS=true
        else
            echo -e "${RED}❌ 无法解析测试结果${NC}"
            UDP_SINGLE_SUCCESS=false
        fi
    else
        echo -e "${RED}❌ 测试执行失败${NC}"
        UDP_SINGLE_SUCCESS=false
    fi

    rm -f "$temp_result"
    echo ""
}

# 执行TCP下行带宽测试
run_tcp_download_test() {
    echo -e "${GREEN}🚀 TCP下行带宽测试 - 目标: ${TARGET_IP}:${TARGET_PORT}${NC}"
    echo ""

    # 后台执行测试，前台显示进度条
    local temp_result=$(mktemp)
    (iperf3 -c "$TARGET_IP" -p "$TARGET_PORT" -t "$TEST_DURATION" -f m -R > "$temp_result" 2>&1) &
    local test_pid=$!

    show_progress_bar "$TEST_DURATION" "TCP下行测试"

    # 等待测试完成
    wait $test_pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        local result=$(cat "$temp_result")
        echo ""
        echo -e "${BLUE}📋 测试数据:${NC}"
        echo "$result" | sed -n '/\[ *[0-9]\]/,/^$/p' | sed '/^- - - - -/,$d' | sed '/^$/d'

        # 解析最终结果 - 下行测试需要使用receiver行数据
        local sender_line=$(echo "$result" | grep "sender$" | tail -1)
        local receiver_line=$(echo "$result" | grep "receiver$" | tail -1)
        local cpu_line=$(echo "$result" | grep "CPU Utilization" | tail -1)

        if [ -n "$receiver_line" ]; then
            # 使用receiver行数据（真实下行速率）
            local final_transfer=$(parse_iperf3_data "$receiver_line" "transfer")
            local final_bitrate=$(parse_iperf3_data "$receiver_line" "bitrate")

            # 重传次数仍从sender行获取
            local final_retrans=""
            if [ -n "$sender_line" ]; then
                final_retrans=$(echo "$sender_line" | awk '{print $(NF-1)}')
            fi

            # 解析CPU使用率
            local cpu_local=""
            local cpu_remote=""
            if [ -n "$cpu_line" ]; then
                cpu_local=$(parse_iperf3_data "$cpu_line" "cpu_local")
                cpu_remote=$(parse_iperf3_data "$cpu_line" "cpu_remote")
            fi

            echo -e "${GREEN}TCP下行测试完成${NC}"
            echo -e "使用指令: ${YELLOW}iperf3 -c $TARGET_IP -p $TARGET_PORT -t $TEST_DURATION -f m -R${NC}"
            echo ""
            echo -e "${YELLOW}📊 测试结果${NC}"
            echo ""

            # final_bitrate格式Mbits/sec
            local mbps="N/A"
            local mb_per_sec="N/A"
            if [ -n "$final_bitrate" ] && [[ "$final_bitrate" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                mbps=$(awk "BEGIN {printf \"%.0f\", $final_bitrate}")  # 直接使用Mbits/sec值
                mb_per_sec=$(awk "BEGIN {printf \"%.1f\", $final_bitrate / 8}")  # 转换为MB/s
            fi

            echo -e "平均下行速率 (Receiver): ${YELLOW}${mbps} Mbps${NC} (${YELLOW}${mb_per_sec} MB/s${NC})          总传输数据量: ${YELLOW}${final_transfer:-N/A} MB${NC}"

            # 显示重传次数（不计算重传率，避免估算误差）
            echo -e "重传次数: ${YELLOW}${final_retrans:-0} 次${NC}"

            # 显示CPU负载
            if [ -n "$cpu_local" ] && [ -n "$cpu_remote" ]; then
                echo -e "CPU 负载: 发送端 ${YELLOW}${cpu_local}${NC} 接收端 ${YELLOW}${cpu_remote}${NC}"
            fi

            echo -e "测试时长: ${YELLOW}${TEST_DURATION} 秒${NC}"

            # 收集TCP下行测试数据
            set_test_result "tcp_down_speed_mbps" "$mbps"
            set_test_result "tcp_down_speed_mibs" "$mb_per_sec"
            set_test_result "tcp_down_transfer" "$final_transfer"
            set_test_result "tcp_down_retrans" "$final_retrans"

            # 保存TCP下行Mbps值，四舍五入到10的倍数，用于UDP下行的-b参数
            if [ "$mbps" != "N/A" ]; then
                # 复用已计算的mbps值，避免重复计算
                TCP_DOWNLOAD_MBPS=$(awk "BEGIN {printf \"%.0f\", int(($mbps + 5) / 10) * 10}")
            else
                TCP_DOWNLOAD_MBPS=100  # 默认值
            fi
            TCP_DOWNLOAD_SUCCESS=true
        else
            echo -e "${RED}❌ 无法解析测试结果${NC}"
            TCP_DOWNLOAD_SUCCESS=false
        fi
    else
        echo -e "${RED}❌ 测试执行失败${NC}"
        TCP_DOWNLOAD_SUCCESS=false
    fi

    rm -f "$temp_result"
    echo ""
}

# 执行UDP下行测试
run_udp_download_test() {
    echo -e "${GREEN}🚀 UDP下行性能测试 - 目标: ${TARGET_IP}:${TARGET_PORT}${NC}"
    echo ""

    # 根据TCP下行测试结果设置UDP目标带宽
    local udp_bandwidth="30M"  # 默认值
    if [ "$TCP_DOWNLOAD_SUCCESS" = true ] && [ -n "$TCP_DOWNLOAD_MBPS" ]; then
        # 直接使用TCP下行测试的Mbps值作为UDP目标带宽
        udp_bandwidth="${TCP_DOWNLOAD_MBPS}M"
    fi

    # 后台执行测试，前台显示进度条
    local temp_result=$(mktemp)
    (iperf3 -c "$TARGET_IP" -p "$TARGET_PORT" -u -b "$udp_bandwidth" -t "$TEST_DURATION" -f m -R > "$temp_result" 2>&1) &
    local test_pid=$!

    show_progress_bar "$TEST_DURATION" "UDP下行测试"

    # 等待测试完成
    wait $test_pid
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        local result=$(cat "$temp_result")
        echo ""
        echo -e "${BLUE}📋 测试数据:${NC}"
        # 过滤杂乱信息，保留核心测试数据
        echo "$result" | sed -n '/\[ *[0-9]\]/,/^$/p' | sed '/^- - - - -/,$d' | sed '/^$/d'

        # 解析最终结果
        local sender_line=$(echo "$result" | grep "sender$" | tail -1)
        local receiver_line=$(echo "$result" | grep "receiver$" | tail -1)

        if [ -n "$sender_line" ]; then
            echo -e "${GREEN}UDP下行测试完成${NC}"
            echo -e "使用指令: ${YELLOW}iperf3 -c $TARGET_IP -p $TARGET_PORT -u -b $udp_bandwidth -t $TEST_DURATION -f m -R${NC}"
            echo ""
            echo -e "${YELLOW}📡 传输统计${NC}"
            echo ""

            # 解析接收端信息和CPU信息
            local cpu_line=$(echo "$result" | grep "CPU Utilization" | tail -1)
            local cpu_local=""
            local cpu_remote=""
            if [ -n "$cpu_line" ]; then
                cpu_local=$(parse_iperf3_data "$cpu_line" "cpu_local")
                cpu_remote=$(parse_iperf3_data "$cpu_line" "cpu_remote")
            fi

            if [ -n "$receiver_line" ]; then
                local receiver_transfer=$(parse_iperf3_data "$receiver_line" "transfer")
                local receiver_bitrate=$(parse_iperf3_data "$receiver_line" "bitrate")
                local jitter=$(parse_iperf3_data "$receiver_line" "jitter")
                local loss_info=$(parse_iperf3_data "$receiver_line" "loss")

                # receiver_bitrate格式Mbits/sec
                local recv_mbps="N/A"
                local recv_mb_per_sec="N/A"
                if [ -n "$receiver_bitrate" ] && [[ "$receiver_bitrate" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    recv_mbps=$(awk "BEGIN {printf \"%.1f\", $receiver_bitrate}")  # 直接使用Mbits/sec值
                    recv_mb_per_sec=$(awk "BEGIN {printf \"%.1f\", $receiver_bitrate / 8}")  # 转换为MB/s
                fi

                # 计算目标速率显示（与-b参数一致）
                local target_mbps=$(echo "$udp_bandwidth" | sed 's/M$//')

                echo -e "有效吞吐量 (吞吐率): ${YELLOW}${recv_mbps} Mbps${NC} (${YELLOW}${recv_mb_per_sec} MB/s${NC})"
                echo -e "丢包率 (Packet Loss): ${YELLOW}${loss_info:-N/A}${NC}"
                echo -e "网络抖动 (Jitter): ${YELLOW}${jitter:-N/A} ms${NC}"

                # 显示CPU负载
                if [ -n "$cpu_local" ] && [ -n "$cpu_remote" ]; then
                    echo -e "CPU负载: 发送端 ${YELLOW}${cpu_local}${NC} 接收端 ${YELLOW}${cpu_remote}${NC}"
                fi

                echo -e "测试目标速率: ${YELLOW}${target_mbps} Mbps${NC}"

                # 收集UDP下行测试数据
                set_test_result "udp_down_speed_mbps" "$recv_mbps"
                set_test_result "udp_down_speed_mibs" "$recv_mb_per_sec"
                set_test_result "udp_down_loss" "$loss_info"
                set_test_result "udp_down_jitter" "$jitter"
            else
                echo -e "有效吞吐量 (吞吐率): ${YELLOW}N/A${NC}"
                echo -e "丢包率 (Packet Loss): ${YELLOW}N/A${NC}"
                echo -e "网络抖动 (Jitter): ${YELLOW}N/A${NC}"
                echo -e "CPU负载: ${YELLOW}N/A${NC}"
                echo -e "测试目标速率: ${YELLOW}N/A${NC}"
            fi

            UDP_DOWNLOAD_SUCCESS=true
        else
            echo -e "${RED}❌ 无法解析测试结果${NC}"
            UDP_DOWNLOAD_SUCCESS=false
        fi
    else
        echo -e "${RED}❌ 测试执行失败${NC}"
        UDP_DOWNLOAD_SUCCESS=false
    fi

    rm -f "$temp_result"
    echo ""
}


# 全局测试结果变量
HPING_SUCCESS=false
TCP_SINGLE_SUCCESS=false
TCP_DOWNLOAD_SUCCESS=false
TCP_SUCCESS=false
UDP_SINGLE_SUCCESS=false
UDP_DOWNLOAD_SUCCESS=false


# 主要性能测试函数
run_performance_tests() {
    echo -e "${GREEN}🚀 开始网络性能测试${NC}"
    echo -e "${BLUE}目标: $TARGET_IP:$TARGET_PORT${NC}"
    echo -e "${BLUE}测试时长: ${TEST_DURATION}秒${NC}"
    echo ""

    # 重置测试结果
    HPING_SUCCESS=false
    TCP_SINGLE_SUCCESS=false
    TCP_DOWNLOAD_SUCCESS=false
    TCP_SUCCESS=false
    UDP_SINGLE_SUCCESS=false
    UDP_DOWNLOAD_SUCCESS=false

    # 执行各项测试
    run_latency_tests
    run_bandwidth_tests

    # 设置TCP总体成功状态
    if [ "$TCP_SINGLE_SUCCESS" = true ] || [ "$TCP_DOWNLOAD_SUCCESS" = true ]; then
        TCP_SUCCESS=true
    fi

    # 生成综合报告
    generate_final_report
}

# 生成最终报告
generate_final_report() {
    echo -e "${GREEN}===================== 网络链路测试功能完整报告 =====================${NC}"
    echo ""

    # 报告标题
    echo -e "${BLUE}✍️ 参数测试报告${NC}"
    echo -e "─────────────────────────────────────────────────────────────────"
    echo -e "  本机（客户端）发起测试"

    # 隐藏完整IP地址，只显示前两段
    local masked_ip=$(echo "$TARGET_IP" | awk -F'.' '{print $1"."$2".*.*"}')
    echo -e "  目标: $masked_ip:$TARGET_PORT"

    echo -e "  测试方向: 客户端 ↔ 服务端 "
    echo -e "  单项测试时长: ${TEST_DURATION}秒"

    # 显示系统和内核信息
    local system_kernel_info=$(get_system_kernel_info)
    echo -e "  系统：${YELLOW}${system_kernel_info}${NC}"

    # 获取并显示本机TCP信息
    local local_tcp_info=$(get_local_tcp_info)
    echo -e "  本机：${YELLOW}${local_tcp_info}${NC}（拥塞控制算法+队列）"

    # 显示TCP缓冲区信息
    local tcp_buffer_info=$(get_tcp_buffer_info)
    local rmem_info=$(echo "$tcp_buffer_info" | cut -d'|' -f1 | cut -d':' -f2)
    local wmem_info=$(echo "$tcp_buffer_info" | cut -d'|' -f2 | cut -d':' -f2)
    echo -e "  TCP接收缓冲区（rmem）：${YELLOW}${rmem_info}${NC}"
    echo -e "  TCP发送缓冲区（wmem）：${YELLOW}${wmem_info}${NC}"
    echo ""

    # 核心性能数据展示
    echo -e "${WHITE}⚡ 网络链路参数分析（基于hping3 & iperf3）${NC}"
    echo -e "─────────────────────────────────────────────────────────────────────────────────"
    echo -e "    ${WHITE}PING & 抖动${NC}           ${WHITE}⬆️ TCP上行带宽${NC}                     ${WHITE}⬇️ TCP下行带宽${NC}"
    echo -e "─────────────────────  ─────────────────────────────  ─────────────────────────────"

    # 第一行数据
    printf "  平均: %-12s  " "${TEST_RESULTS[latency_avg]}ms"
    printf "  %-29s  " "${TEST_RESULTS[tcp_up_speed_mbps]} Mbps (${TEST_RESULTS[tcp_up_speed_mibs]} MB/s)"
    printf "  %-29s\n" "${TEST_RESULTS[tcp_down_speed_mbps]} Mbps (${TEST_RESULTS[tcp_down_speed_mibs]} MB/s)"

    # 第二行数据
    printf "  最低: %-12s  " "${TEST_RESULTS[latency_min]}ms"
    printf "  %-29s  " "总传输量: ${TEST_RESULTS[tcp_up_transfer]} MB"
    printf "  %-29s\n" "总传输量: ${TEST_RESULTS[tcp_down_transfer]} MB"

    # 第三行数据
    printf "  最高: %-12s  " "${TEST_RESULTS[latency_max]}ms"
    printf "  %-29s  " "重传: ${TEST_RESULTS[tcp_up_retrans]} 次"
    printf "  %-29s\n" "重传: ${TEST_RESULTS[tcp_down_retrans]} 次"

    # 第四行数据
    printf "  抖动: %-12s\n" "${TEST_RESULTS[latency_jitter]}ms"
    echo ""

    echo -e "─────────────────────────────────────────────────────────────────────────────────────────────"
    echo -e " 方向       │ 吞吐量                   │ 丢包率                   │ 抖动"
    echo -e "─────────────────────────────────────────────────────────────────────────────────────────────"

    # UDP上行
    if [ "$UDP_SINGLE_SUCCESS" = true ] && [ -n "${TEST_RESULTS[udp_up_speed_mbps]}" ]; then
        local speed_text="${TEST_RESULTS[udp_up_speed_mbps]} Mbps (${TEST_RESULTS[udp_up_speed_mibs]} MB/s)"
        local loss_text="${TEST_RESULTS[udp_up_loss]}"
        local jitter_text="${TEST_RESULTS[udp_up_jitter]} ms"

        [ ${#speed_text} -gt 25 ] && speed_text="${speed_text:0:25}"
        [ ${#loss_text} -gt 25 ] && loss_text="${loss_text:0:25}"
        [ ${#jitter_text} -gt 25 ] && jitter_text="${jitter_text:0:25}"

        printf " %-11s │ ${YELLOW}%-25s${NC} │ ${YELLOW}%-25s${NC} │ ${YELLOW}%-25s${NC}\n" \
            "⬆️ UDP上行" "$speed_text" "$loss_text" "$jitter_text"
    else
        printf " %-11s │ ${RED}%-25s${NC} │ ${RED}%-25s${NC} │ ${RED}%-25s${NC}\n" \
            "⬆️ UDP上行" "测试失败" "N/A" "N/A"
    fi

    # UDP下行
    if [ "$UDP_DOWNLOAD_SUCCESS" = true ] && [ -n "${TEST_RESULTS[udp_down_speed_mbps]}" ]; then
        local speed_text="${TEST_RESULTS[udp_down_speed_mbps]} Mbps (${TEST_RESULTS[udp_down_speed_mibs]} MB/s)"
        local loss_text="${TEST_RESULTS[udp_down_loss]}"
        local jitter_text="${TEST_RESULTS[udp_down_jitter]} ms"

        [ ${#speed_text} -gt 25 ] && speed_text="${speed_text:0:25}"
        [ ${#loss_text} -gt 25 ] && loss_text="${loss_text:0:25}"
        [ ${#jitter_text} -gt 25 ] && jitter_text="${jitter_text:0:25}"

        printf " %-11s │ ${YELLOW}%-25s${NC} │ ${YELLOW}%-25s${NC} │ ${YELLOW}%-25s${NC}\n" \
            "⬇️ UDP下行" "$speed_text" "$loss_text" "$jitter_text"
    else
        printf " %-11s │ ${RED}%-25s${NC} │ ${RED}%-25s${NC} │ ${RED}%-25s${NC}\n" \
            "⬇️ UDP下行" "测试失败" "N/A" "N/A"
    fi

    echo ""
    echo -e "─────────────────────────────────────────────────────────────────"

    echo -e "测试完成时间: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S') | 脚本开源地址：https://github.com/zywe03/realm-xwPF"
    echo -e "${WHITE}按任意键返回主菜单...${NC}"
    read -n 1 -s
}

# 客户端模式 - 发起测试
relay_server_mode() {
    clear
    echo -e "${GREEN}=== 客户端 (本机发起测试) ===${NC}"
    echo ""

    # 输入服务端IP (目标服务器)
    while true; do
        read -p "服务端IP (目标服务器) [默认127.0.0.1]: " TARGET_IP

        if [ -z "$TARGET_IP" ]; then
            TARGET_IP="127.0.0.1"
            break
        elif validate_ip "$TARGET_IP"; then
            break
        else
            echo -e "${RED}无效的IP地址或域名格式${NC}"
        fi
    done

    # 输入测试端口
    while true; do
        read -p "测试端口 [默认5201]: " input_port
        if [ -z "$input_port" ]; then
            TARGET_PORT="5201"
            break
        elif validate_port "$input_port"; then
            TARGET_PORT="$input_port"
            break
        else
            echo -e "${RED}无效端口号，请输入1-65535之间的数字${NC}"
        fi
    done

    # 输入测试时长
    while true; do
        read -p "测试时长(秒) [默认30]: " input_duration
        if [ -z "$input_duration" ]; then
            TEST_DURATION="30"
            break
        elif [[ $input_duration =~ ^[0-9]+$ ]] && [ "$input_duration" -ge 5 ] && [ "$input_duration" -le 300 ]; then
            TEST_DURATION="$input_duration"
            break
        else
            echo -e "${RED}测试时长必须是5-300秒之间的数字${NC}"
        fi
    done

    echo ""
    echo -e "${YELLOW}连接检查...${NC}"

    # 测试连通性
    if test_connectivity "$TARGET_IP" "$TARGET_PORT"; then
        echo -e "${GREEN}✅ 连接正常，开始测试${NC}"
        echo ""

        # 开始性能测试
        run_performance_tests
    else
        echo -e "${RED}✗ 无法连接到 $TARGET_IP:$TARGET_PORT${NC}"
        echo -e "${YELLOW}请确认：${NC}"
        echo -e "${YELLOW}1. 服务端已启动iperf3服务${NC}"
        echo -e "${YELLOW}2. IP地址和端口正确${NC}"
        echo -e "${YELLOW}3. 防火墙已放行端口${NC}"
        echo ""
        echo -e "${WHITE}按任意键返回主菜单...${NC}"
        read -n 1 -s
    fi
}

# 检测脚本位置
get_script_paths() {
    local paths=("$(readlink -f "$0" 2>/dev/null || echo "$0")")
    local common_paths=("/usr/local/bin/speedtest.sh" "/etc/realm/speedtest.sh" "./speedtest.sh")

    for path in "${common_paths[@]}"; do
        [ -f "$path" ] && paths+=("$path")
    done

    printf '%s\n' "${paths[@]}" | sort -u
}

# 卸载脚本
uninstall_speedtest() {
    clear
    echo -e "${RED}=== 卸载测速测试工具 ===${NC}"
    echo ""

    echo -e "${YELLOW}将执行以下操作：${NC}"
    echo -e "${BLUE}• 停止可能运行的测试服务${NC}"
    echo -e "${BLUE}• 删除脚本相关工具${NC}"
    echo -e "${BLUE}• 删除脚本文件${NC}"
    echo -e "${BLUE}• 清理临时文件${NC}"
    echo ""

    read -p "确认卸载？(y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        # 停止可能运行的iperf3服务
        echo -e "${YELLOW}停止测试服务...${NC}"
        pkill -f "iperf3.*-s" 2>/dev/null || true

        # 删除脚本相关工具
        echo -e "${BLUE}删除脚本相关工具...${NC}"
        echo -e "${GREEN}✅ 删除脚本相关工具完成${NC}"

        # 清理临时文件
        echo -e "${BLUE}清理临时文件...${NC}"
        rm -f /tmp/speedtest_* 2>/dev/null || true

        # 删除脚本文件
        echo -e "${BLUE}删除脚本文件...${NC}"
        local scripts=($(get_script_paths))
        local deleted_count=0

        for script_path in "${scripts[@]}"; do
            if [ -f "$script_path" ]; then
                rm -f "$script_path"
                echo -e "${GREEN}✅ 删除 $script_path${NC}"
                ((deleted_count++))
            fi
        done

        if [ $deleted_count -eq 0 ]; then
            echo -e "${YELLOW}未找到脚本文件${NC}"
        fi

        echo ""
        echo -e "${GREEN}✅ 卸载完成${NC}"
        echo -e "${WHITE}按任意键退出...${NC}"
        read -n 1 -s
        exit 0
    else
        show_main_menu
    fi
}

# 主菜单
show_main_menu() {
    clear
    echo -e "${GREEN}=== 网络链路测试(先开放,再发起) ===${NC}"
    echo ""
    echo "请选择操作:"
    echo -e "${GREEN}1.${NC} 客户端 (本机发起测试)"
    echo -e "${BLUE}2.${NC} 服务端 (开放测试)"
    echo -e "${RED}3.${NC} 卸载脚本"
    echo -e "${YELLOW}4.${NC} 更新脚本"
    echo -e "${WHITE}0.${NC} 返回上级菜单"
    echo ""

    while true; do
        read -p "请输入选择 [0-4]: " choice
        case $choice in
            1)
                ROLE="relay"
                relay_server_mode
                show_main_menu
                ;;
            2)
                ROLE="landing"
                landing_server_mode
                show_main_menu
                ;;
            3)
                uninstall_speedtest
                ;;
            4)
                manual_update_script
                show_main_menu
                ;;
            0)
                echo -e "${BLUE}返回中转脚本主菜单...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-4${NC}"
                ;;
        esac
    done
}

# 更新脚本
manual_update_script() {
    echo -e "${YELLOW}正在更新脚本...${NC}"

    local script_url="https://raw.githubusercontent.com/zywe03/realm-xwPF/main/speedtest.sh"
    local temp_file=$(mktemp)

    if download_from_sources "$script_url" "$temp_file"; then
        mv "$temp_file" "$0"
        chmod +x "$0"
        echo -e "${GREEN}✅ 更新完成，重新启动脚本${NC}"
        exec "$0"
    else
        rm -f "$temp_file"
        echo -e "${RED}✗ 更新失败${NC}"
    fi

    read -p "按回车键返回..."
}

# 主函数
main() {
    check_root

    # 检测工具状态并安装缺失的工具
    install_required_tools

    # 显示主菜单
    show_main_menu
}

# 执行主函数
main "$@"
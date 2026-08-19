#!/bin/bash

# Telegram通知模块

# 网络参数：防止重复source时的readonly冲突
if [[ -z "${TELEGRAM_MAX_RETRIES:-}" ]]; then
    readonly TELEGRAM_MAX_RETRIES=2
    readonly TELEGRAM_CONNECT_TIMEOUT=5
    readonly TELEGRAM_MAX_TIMEOUT=15
fi

telegram_is_enabled() {
    local enabled=$(jq -r '.notifications.telegram.enabled // false' "$CONFIG_FILE")
    [ "$enabled" = "true" ]
}

send_telegram_message() {
    local message="$1"

    local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    local chat_id=$(jq -r '.notifications.telegram.chat_id // ""' "$CONFIG_FILE" 2>/dev/null || echo "")

    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        log_notification "Telegram配置不完整"
        return 1
    fi

    # URL编码：Telegram API要求空格和换行符必须编码
    local encoded_message=$(printf '%s' "$message" | sed 's/ /%20/g; s/\n/%0A/g')

    local retry_count=0

    # 重试机制
    while [ $retry_count -le $TELEGRAM_MAX_RETRIES ]; do
        local response=$(curl -s --connect-timeout $TELEGRAM_CONNECT_TIMEOUT --max-time $TELEGRAM_MAX_TIMEOUT -X POST \
            "https://api.telegram.org/bot${bot_token}/sendMessage" \
            -d "chat_id=${chat_id}" \
            -d "text=${encoded_message}" \
            -d "parse_mode=HTML" \
            2>/dev/null)

        # Telegram API成功响应的标准判断
        if echo "$response" | grep -q '"ok":true'; then
            if [ $retry_count -gt 0 ]; then
                log_notification "Telegram消息发送成功 (重试第${retry_count}次后成功)"
            else
                log_notification "Telegram消息发送成功"
            fi
            return 0
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -le $TELEGRAM_MAX_RETRIES ]; then
            sleep 2  # 避免频繁请求被限流
        fi
    done

    log_notification "Telegram消息发送失败 (已重试${TELEGRAM_MAX_RETRIES}次)"
    return 1
}

# 标准通知接口：主脚本通过此函数调用Telegram通知
telegram_send_status_notification() {
    local status_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$status_enabled" != "true" ]; then
        log_notification "Telegram状态通知未启用"
        return 1
    fi

    # 使用HTML格式消息
    local server_name=$(jq -r '.notifications.telegram.server_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "$(hostname)")
    local message=$(format_status_message "$server_name")
    if send_telegram_message "$message"; then
        log_notification "Telegram状态通知发送成功"
        return 0
    else
        log_notification "Telegram状态通知发送失败"
        return 1
    fi
}

# 向后兼容
telegram_send_status() {
    telegram_send_status_notification
}

telegram_test() {
    echo -e "${BLUE}=== 发送测试消息 ===${NC}"
    echo

    if ! telegram_is_enabled; then
        echo -e "${RED}请先配置Telegram Bot信息${NC}"
        sleep 2
        return 1
    fi

    echo "正在发送测试消息..."

    # 使用真实状态消息测试：确保配置正确性
    if telegram_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

telegram_configure() {
    while true; do
        local status_notifications_enabled=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")
        local bot_token=$(jq -r '.notifications.telegram.bot_token // ""' "$CONFIG_FILE")

        # 判断配置状态
        local config_status="[未配置]"
        if [ -n "$bot_token" ] && [ "$bot_token" != "" ] && [ "$bot_token" != "null" ]; then
            config_status="[已配置]"
        fi

        # 判断开关状态
        local enable_status="[关闭]"
        if [ "$status_notifications_enabled" = "true" ]; then
            enable_status="[开启]"
        fi

        local status_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

        echo -e "${BLUE}=== Telegram通知配置 ===${NC}"
        local interval_display="未设置"
        if [ -n "$status_interval" ] && [ "$status_interval" != "null" ]; then
            interval_display="每${status_interval}"
        fi
        echo -e "当前状态: ${enable_status} | ${config_status} | 状态通知: ${interval_display}"
        echo
        echo "1. 配置Bot信息 (Token + Chat ID + 服务器名称)"
        echo "2. 通知设置管理"
        echo "3. 发送测试消息"
        echo "4. 查看通知日志"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-4]: " choice

        case $choice in
            1) telegram_configure_bot ;;
            2) telegram_manage_settings ;;
            3) telegram_test ;;
            4) telegram_view_logs ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

telegram_configure_bot() {
    echo -e "${BLUE}=== 配置Telegram Bot信息 ===${NC}"
    echo
    echo -e "${GREEN}配置步骤说明:${NC}"
    echo "1. 与 @BotFather 对话创建机器人"
    echo "2. 获取 Bot Token (格式: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz)"
    echo "3. 获取 Chat ID (个人聊天或群组ID)"
    echo "4. 设置服务器名称用于标识"
    echo

    local current_token=$(jq -r '.notifications.telegram.bot_token' "$CONFIG_FILE")
    local current_chat_id=$(jq -r '.notifications.telegram.chat_id' "$CONFIG_FILE")
    local current_server_name=$(jq -r '.notifications.telegram.server_name' "$CONFIG_FILE")

    if [ "$current_token" != "" ] && [ "$current_token" != "null" ]; then
        # 安全显示：隐藏Token中间部分防止泄露
        local masked_token="${current_token:0:10}...${current_token: -10}"
        echo -e "${GREEN}当前Token: $masked_token${NC}"
    fi
    if [ "$current_chat_id" != "" ] && [ "$current_chat_id" != "null" ]; then
        echo -e "${GREEN}当前Chat ID: $current_chat_id${NC}"
    fi
    if [ "$current_server_name" != "" ] && [ "$current_server_name" != "null" ]; then
        echo -e "${GREEN}当前服务器名: $current_server_name${NC}"
    fi
    echo

    read -p "请输入Bot Token: " bot_token
    if [ -z "$bot_token" ]; then
        echo -e "${RED}Token不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$bot_token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}Token格式错误，请检查${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    read -p "请输入Chat ID: " chat_id
    if [ -z "$chat_id" ]; then
        echo -e "${RED}Chat ID不能为空${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    if ! [[ "$chat_id" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}Chat ID格式错误，必须是数字${NC}"
        sleep 2
        telegram_configure_bot
        return
    fi

    local default_server_name=$(hostname)
    read -p "请输入服务器名称 (回车默认: $default_server_name): " server_name
    if [ -z "$server_name" ]; then
        server_name="$default_server_name"
    fi

    # 原子性配置更新：确保配置完整性
    update_config ".notifications.telegram.bot_token = \"$bot_token\" |
        .notifications.telegram.chat_id = \"$chat_id\" |
        .notifications.telegram.server_name = \"$server_name\" |
        .notifications.telegram.enabled = true |
        .notifications.telegram.status_notifications.enabled = true"

    echo -e "${GREEN}基本配置保存成功！${NC}"
    echo

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval=$(select_notification_interval)

    update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    # 立即生效
    setup_telegram_notification_cron

    echo
    echo "正在发送测试通知..."

    # 配置完成后立即测试：验证配置正确性
    if telegram_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

telegram_manage_settings() {
    while true; do
        echo -e "${BLUE}=== 通知设置管理 ===${NC}"
        echo "1. 状态通知间隔"
        echo "2. 开启/关闭切换"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1) telegram_configure_interval ;;
            2) telegram_toggle_status_notifications ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

telegram_configure_interval() {
    local current_interval=$(jq -r '.notifications.telegram.status_notifications.interval' "$CONFIG_FILE")

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval_display="未设置"
    if [ -n "$current_interval" ] && [ "$current_interval" != "null" ]; then
        interval_display="$current_interval"
    fi
    echo -e "当前间隔: $interval_display"
    echo
    local interval=$(select_notification_interval)

    update_config ".notifications.telegram.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    setup_telegram_notification_cron

    sleep 2
}

telegram_toggle_status_notifications() {
    local current_status=$(jq -r '.notifications.telegram.status_notifications.enabled // false' "$CONFIG_FILE")

    if [ "$current_status" = "true" ]; then
        update_config ".notifications.telegram.status_notifications.enabled = false"
        echo -e "${GREEN}状态通知已关闭${NC}"
    else
        update_config ".notifications.telegram.status_notifications.enabled = true"
        echo -e "${GREEN}状态通知已开启${NC}"
    fi

    setup_telegram_notification_cron
    sleep 2
}

telegram_view_logs() {
    echo -e "${BLUE}=== 通知日志 ===${NC}"
    echo

    local log_file="$CONFIG_DIR/logs/notification.log"
    if [ ! -f "$log_file" ]; then
        echo -e "${YELLOW}暂无通知日志${NC}"
        sleep 2
        return
    fi

    echo "最近20条通知日志:"
    echo "────────────────────────────────────────────────────────"
    tail -n 20 "$log_file"
    echo "────────────────────────────────────────────────────────"
    echo
    read -p "按回车键返回..."
}

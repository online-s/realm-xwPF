#!/bin/bash

# 企业wx 群机器人通知模块

# 网络参数：防止重复source时的readonly冲突
if [[ -z "${WECOM_MAX_RETRIES:-}" ]]; then
    readonly WECOM_MAX_RETRIES=2
    readonly WECOM_CONNECT_TIMEOUT=5
    readonly WECOM_MAX_TIMEOUT=15
fi

wecom_is_enabled() {
    local enabled=$(jq -r '.notifications.wecom.enabled // false' "$CONFIG_FILE")
    [ "$enabled" = "true" ]
}

send_wecom_message() {
    local message="$1"

    local webhook_url=$(jq -r '.notifications.wecom.webhook_url // ""' "$CONFIG_FILE" 2>/dev/null || echo "")

    if [ -z "$webhook_url" ]; then
        log_notification "企业wx Webhook未配置"
        return 1
    fi

    # 处理换行符和特殊字符：企业wx 要求JSON中使用\n而不是真实换行
    local encoded_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')

    local json_data="{\"msgtype\": \"text\", \"text\": {\"content\": \"$encoded_message\"}}"

    local retry_count=0

    # 重试机制
    while [ $retry_count -le $WECOM_MAX_RETRIES ]; do
        local response=$(curl -s --connect-timeout $WECOM_CONNECT_TIMEOUT --max-time $WECOM_MAX_TIMEOUT \
            -H "Content-Type: application/json" \
            -d "$json_data" \
            "$webhook_url" 2>/dev/null)

        # 企业wx API成功响应的标准判断
        if echo "$response" | grep -q '"errcode":0'; then
            if [ $retry_count -gt 0 ]; then
                log_notification "企业wx 消息发送成功 (重试第${retry_count}次后成功)"
            else
                log_notification "企业wx 消息发送成功"
            fi
            return 0
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -le $WECOM_MAX_RETRIES ]; then
            sleep 2  # 避免频繁请求被限流
        fi
    done

    log_notification "企业wx 消息发送失败 (已重试${WECOM_MAX_RETRIES}次)"
    return 1
}

# 标准通知接口：主脚本通过此函数调用企业wx 通知
wecom_send_status_notification() {
    local status_enabled=$(jq -r '.notifications.wecom.status_notifications.enabled // false' "$CONFIG_FILE")
    if [ "$status_enabled" != "true" ]; then
        log_notification "企业wx 状态通知未启用"
        return 1
    fi

    # 使用text格式消息
    local server_name=$(jq -r '.notifications.wecom.server_name // ""' "$CONFIG_FILE" 2>/dev/null || echo "$(hostname)")
    local message=$(format_text_status_message "$server_name")
    if send_wecom_message "$message"; then
        log_notification "企业wx 状态通知发送成功"
        return 0
    else
        log_notification "企业wx 状态通知发送失败"
        return 1
    fi
}

# 向后兼容
wecom_send_status() {
    wecom_send_status_notification
}

wecom_test() {
    echo -e "${BLUE}=== 发送测试消息 ===${NC}"
    echo

    if ! wecom_is_enabled; then
        echo -e "${RED}请先配置企业wx Webhook信息${NC}"
        sleep 2
        return 1
    fi

    echo "正在发送测试消息..."

    # 使用真实状态消息测试：确保配置正确性
    if wecom_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

wecom_configure() {
    while true; do
        local status_notifications_enabled=$(jq -r '.notifications.wecom.status_notifications.enabled // false' "$CONFIG_FILE")
        local webhook_url=$(jq -r '.notifications.wecom.webhook_url // ""' "$CONFIG_FILE")

        # 判断配置状态
        local config_status="[未配置]"
        if [ -n "$webhook_url" ] && [ "$webhook_url" != "" ] && [ "$webhook_url" != "null" ]; then
            config_status="[已配置]"
        fi

        # 判断开关状态
        local enable_status="[关闭]"
        if [ "$status_notifications_enabled" = "true" ]; then
            enable_status="[开启]"
        fi

        local status_interval=$(jq -r '.notifications.wecom.status_notifications.interval' "$CONFIG_FILE")

        echo -e "${BLUE}=== 企业wx 通知配置 ===${NC}"
        local interval_display="未设置"
        if [ -n "$status_interval" ] && [ "$status_interval" != "null" ]; then
            interval_display="每${status_interval}"
        fi
        echo -e "当前状态: ${enable_status} | ${config_status} | 状态通知: ${interval_display}"
        echo
        echo "1. 配置Webhook信息 (Webhook URL + 服务器名称)"
        echo "2. 通知设置管理"
        echo "3. 发送测试消息"
        echo "4. 查看通知日志"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-4]: " choice

        case $choice in
            1) wecom_configure_webhook ;;
            2) wecom_manage_settings ;;
            3) wecom_test ;;
            4) wecom_view_logs ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

wecom_configure_webhook() {
    echo -e "${BLUE}=== 配置企业wx Webhook信息 ===${NC}"
    echo
    echo -e "${GREEN}配置步骤说明:${NC}"
    echo "1. 在企业wx 群中添加群机器人"
    echo "2. 获取机器人的 Webhook URL"
    echo "3. 设置服务器名称用于标识"
    echo
    echo -e "${YELLOW}注意：请妥善保管Webhook地址，避免泄露！${NC}"
    echo

    local current_webhook=$(jq -r '.notifications.wecom.webhook_url' "$CONFIG_FILE")
    local current_server_name=$(jq -r '.notifications.wecom.server_name' "$CONFIG_FILE")

    if [ "$current_webhook" != "" ] && [ "$current_webhook" != "null" ]; then
        # 安全显示：隐藏URL中间部分防止泄露
        local masked_webhook="${current_webhook:0:50}...${current_webhook: -20}"
        echo -e "${GREEN}当前Webhook: $masked_webhook${NC}"
    fi
    if [ "$current_server_name" != "" ] && [ "$current_server_name" != "null" ]; then
        echo -e "${GREEN}当前服务器名: $current_server_name${NC}"
    fi
    echo

    read -p "请输入Webhook URL: " webhook_url
    if [ -z "$webhook_url" ]; then
        echo -e "${RED}Webhook URL不能为空${NC}"
        sleep 2
        wecom_configure_webhook
        return
    fi

    # 验证Webhook URL格式
    if ! [[ "$webhook_url" =~ ^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Webhook URL格式错误，请检查${NC}"
        echo "正确格式: https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY"
        sleep 3
        wecom_configure_webhook
        return
    fi

    local default_server_name=$(hostname)
    read -p "请输入服务器名称 (回车默认: $default_server_name): " server_name
    if [ -z "$server_name" ]; then
        server_name="$default_server_name"
    fi

    # 原子性配置更新：确保配置完整性
    update_config ".notifications.wecom.webhook_url = \"$webhook_url\" |
        .notifications.wecom.server_name = \"$server_name\" |
        .notifications.wecom.enabled = true |
        .notifications.wecom.status_notifications.enabled = true"

    echo -e "${GREEN}基本配置保存成功！${NC}"
    echo

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval=$(select_notification_interval)

    update_config ".notifications.wecom.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    # 立即生效
    setup_wecom_notification_cron

    echo
    echo "正在发送测试通知..."

    # 配置完成后立即测试：验证配置正确性
    if wecom_send_status_notification; then
        echo -e "${GREEN}状态通知发送成功！${NC}"
    else
        echo -e "${RED}状态通知发送失败${NC}"
    fi

    sleep 3
}

wecom_manage_settings() {
    while true; do
        echo -e "${BLUE}=== 通知设置管理 ===${NC}"
        echo "1. 状态通知间隔"
        echo "2. 开启/关闭切换"
        echo "0. 返回上级菜单"
        echo
        read -p "请选择操作 [0-2]: " choice

        case $choice in
            1) wecom_configure_interval ;;
            2) wecom_toggle_status_notifications ;;
            0) return 0 ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

wecom_configure_interval() {
    local current_interval=$(jq -r '.notifications.wecom.status_notifications.interval' "$CONFIG_FILE")

    echo -e "${BLUE}=== 状态通知间隔设置 ===${NC}"
    local interval_display="未设置"
    if [ -n "$current_interval" ] && [ "$current_interval" != "null" ]; then
        interval_display="$current_interval"
    fi
    echo -e "当前间隔: $interval_display"
    echo
    local interval=$(select_notification_interval)

    update_config ".notifications.wecom.status_notifications.interval = \"$interval\""
    echo -e "${GREEN}状态通知间隔已设置为: $interval${NC}"

    setup_wecom_notification_cron

    sleep 2
}

wecom_toggle_status_notifications() {
    local current_status=$(jq -r '.notifications.wecom.status_notifications.enabled // false' "$CONFIG_FILE")

    if [ "$current_status" = "true" ]; then
        update_config ".notifications.wecom.status_notifications.enabled = false"
        echo -e "${GREEN}状态通知已关闭${NC}"
    else
        update_config ".notifications.wecom.status_notifications.enabled = true"
        echo -e "${GREEN}状态通知已开启${NC}"
    fi

    setup_wecom_notification_cron
    sleep 2
}

wecom_view_logs() {
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
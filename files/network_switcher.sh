#!/bin/sh

# ==============================================
# 网络切换脚本 - OpenWrt插件版
# ==============================================

# 环境设置
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
export HOME="/root"
umask 0022
cd /tmp

# ==============================================
# UCI配置读取
# ==============================================

CONFIG_FILE="/etc/config/network_switcher"
DAEMON_MODE=0

# 从UCI读取配置
read_uci_config() {
    # 基本设置
    ENABLED=$(uci get network_switcher.settings.enabled 2>/dev/null || echo "0")
    AUTO_MODE=$(uci get network_switcher.settings.auto_mode 2>/dev/null || echo "1")
    CHECK_INTERVAL=$(uci get network_switcher.settings.check_interval 2>/dev/null || echo "60")
    PING_TARGETS=$(uci get network_switcher.settings.ping_targets 2>/dev/null || echo "8.8.8.8 1.1.1.1 223.5.5.5")
    PING_COUNT=$(uci get network_switcher.settings.ping_count 2>/dev/null || echo "3")
    PING_TIMEOUT=$(uci get network_switcher.settings.ping_timeout 2>/dev/null || echo "3")
    SWITCH_WAIT_TIME=$(uci get network_switcher.settings.switch_wait_time 2>/dev/null || echo "3")
    
    # 接口配置
    WAN_ENABLED=$(uci get network_switcher.wan.enabled 2>/dev/null || echo "1")
    WAN_INTERFACE=$(uci get network_switcher.wan.interface 2>/dev/null || echo "wan")
    WAN_METRIC=$(uci get network_switcher.wan.metric 2>/dev/null || echo "10")
    
    WWAN_ENABLED=$(uci get network_switcher.wwan.enabled 2>/dev/null || echo "1")
    WWAN_INTERFACE=$(uci get network_switcher.wwan.interface 2>/dev/null || echo "wwan")
    WWAN_METRIC=$(uci get network_switcher.wwan.metric 2>/dev/null || echo "20")
}

# ==============================================
# 文件路径配置
# ==============================================

SCRIPT_NAME="network-switcher"
LOCK_FILE="/var/lock/network_switcher.lock"
LOG_FILE="/var/log/network_switcher.log"
STATE_FILE="/var/state/network_switcher.state"
DEBUG_LOG="/tmp/network_switcher_debug.log"

# ==============================================
# 函数定义
# ==============================================

log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
    logger -t "$SCRIPT_NAME" "$message"
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && [ -d "/proc/$lock_pid" ]; then
            log "另一个实例正在运行 (PID: $lock_pid)，退出"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# 获取接口状态
get_interface_status() {
    local interface="$1"
    if ubus call network.interface."$interface" status >/dev/null 2>&1; then
        ubus call network.interface."$interface" status | jsonfilter -e '@.up' 2>/dev/null || echo "false"
    else
        echo "false"
    fi
}

get_interface_device() {
    local interface="$1"
    ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null
}

get_interface_gateway() {
    local interface="$1"
    ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null
}

get_current_default_interface() {
    ip route show default 2>/dev/null | head -1 | awk '{print $5}'
}

# 接口可用性检查
is_interface_available() {
    local interface="$1"
    local device=""
    
    device=$(get_interface_device "$interface")
    if [ -z "$device" ]; then
        return 1
    fi
    
    if ! ip link show "$device" 2>/dev/null | grep -q "state UP"; then
        return 1
    fi
    
    local gateway=$(get_interface_gateway "$interface")
    if [ -z "$gateway" ]; then
        return 1
    fi
    
    if ip route show | grep -q "dev $device"; then
        return 0
    else
        return 1
    fi
}

# 网络连通性测试
test_network_connectivity() {
    local interface="$1"
    local device=""
    
    device=$(get_interface_device "$interface")
    if [ -z "$device" ]; then
        return 1
    fi
    
    local success_count=0
    local test_targets="$PING_TARGETS"
    
    for target in $test_targets; do
        if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
            success_count=$((success_count + 1))
            break
        fi
    done
    
    if [ "$success_count" -ge 1 ]; then
        return 0
    else
        return 1
    fi
}

# 接口就绪检查
is_interface_ready_for_switch() {
    local interface="$1"
    
    if ! is_interface_available "$interface"; then
        return 1
    fi
    
    if ! test_network_connectivity "$interface"; then
        return 1
    fi
    
    return 0
}

# 执行路由切换
perform_route_switch() {
    local target_interface="$1"
    local gateway=""
    local device=""
    
    if [ "$target_interface" = "$WAN_INTERFACE" ]; then
        gateway=$(get_interface_gateway "$WAN_INTERFACE")
        device=$(get_interface_device "$WAN_INTERFACE")
        
        if [ -z "$gateway" ] || [ -z "$device" ]; then
            return 1
        fi
        
        ip route del default via $(get_interface_gateway "$WWAN_INTERFACE") dev $(get_interface_device "$WWAN_INTERFACE") metric $WWAN_METRIC 2>/dev/null
        ip route replace default via "$gateway" dev "$device" metric $WAN_METRIC
        
    else
        gateway=$(get_interface_gateway "$WWAN_INTERFACE")
        device=$(get_interface_device "$WWAN_INTERFACE")
        
        if [ -z "$gateway" ] || [ -z "$device" ]; then
            return 1
        fi
        
        ip route del default via $(get_interface_gateway "$WAN_INTERFACE") dev $(get_interface_device "$WAN_INTERFACE") metric $WAN_METRIC 2>/dev/null
        ip route replace default via "$gateway" dev "$device" metric $WWAN_METRIC
    fi
    
    sleep $SWITCH_WAIT_TIME
    return 0
}

# 验证切换
verify_switch() {
    local target_interface="$1"
    local expected_device=""
    
    expected_device=$(get_interface_device "$target_interface")
    if [ -z "$expected_device" ]; then
        return 1
    fi
    
    local current_interface=$(get_current_default_interface)
    if [ "$current_interface" != "$expected_device" ]; then
        return 1
    fi
    
    if test_network_connectivity "$target_interface"; then
        return 0
    else
        return 1
    fi
}

# 接口切换
switch_interface() {
    local target_interface="$1"
    local current_interface=$(get_current_default_interface)
    
    log "开始切换到: $target_interface"
    
    # 如果已经是目标接口且网络正常
    local target_device=$(get_interface_device "$target_interface")
    if [ "$current_interface" = "$target_device" ]; then
        if test_network_connectivity "$target_interface"; then
            log "已经是目标接口且网络正常"
            return 0
        fi
    fi
    
    # 检查目标接口
    if ! is_interface_ready_for_switch "$target_interface"; then
        log "目标接口 $target_interface 不适合切换"
        return 1
    fi
    
    # 执行切换
    if ! perform_route_switch "$target_interface"; then
        log "路由切换执行失败"
        return 1
    fi
    
    if verify_switch "$target_interface"; then
        log "切换到 $target_interface 成功"
        echo "$target_interface" > "$STATE_FILE"
        return 0
    else
        log "切换验证失败"
        return 1
    fi
}

# 自动切换
auto_switch() {
    if [ "$ENABLED" != "1" ]; then
        return 0
    fi
    
    log "执行自动网络切换检查"
    
    local wan_ready=$(is_interface_ready_for_switch "$WAN_INTERFACE" && echo "true" || echo "false")
    local wwan_ready=$(is_interface_ready_for_switch "$WWAN_INTERFACE" && echo "true" || echo "false")
    
    # WAN优先策略
    if [ "$wan_ready" = "true" ]; then
        local current_device=$(get_current_default_interface)
        local wan_device=$(get_interface_device "$WAN_INTERFACE")
        
        if [ "$current_device" != "$wan_device" ]; then
            log "WAN接口就绪，切换到WAN"
            switch_interface "$WAN_INTERFACE"
        elif ! test_network_connectivity "$WAN_INTERFACE"; then
            log "当前WAN接口网络异常，重新切换"
            switch_interface "$WAN_INTERFACE"
        else
            log "WAN接口正常，保持现状"
        fi
    elif [ "$wwan_ready" = "true" ]; then
        local current_device=$(get_current_default_interface)
        local wwan_device=$(get_interface_device "$WWAN_INTERFACE")
        
        if [ "$current_device" != "$wwan_device" ]; then
            log "WAN不可用，切换到WWAN"
            switch_interface "$WWAN_INTERFACE"
        elif ! test_network_connectivity "$WWAN_INTERFACE"; then
            log "当前WWAN接口网络异常，重新切换"
            switch_interface "$WWAN_INTERFACE"
        else
            log "WWAN接口正常，保持现状"
        fi
    else
        log "所有接口都不可用"
    fi
}

# 显示状态
show_status() {
    read_uci_config
    
    echo "=== 网络切换器状态 ==="
    echo "服务状态: $([ "$ENABLED" = "1" ] && echo "已启用" || echo "已禁用")"
    echo "模式: $([ "$AUTO_MODE" = "1" ] && echo "自动" || echo "手动")"
    echo "检查间隔: ${CHECK_INTERVAL}秒"
    echo ""
    
    # 当前默认路由
    local default_interface=$(get_current_default_interface)
    echo "当前默认出口: $default_interface"
    
    # 各接口状态
    for interface in "$WAN_INTERFACE" "$WWAN_INTERFACE"; do
        echo -e "\n--- $interface 状态 ---"
        local status=$(get_interface_status "$interface")
        local device=$(get_interface_device "$interface")
        local gateway=$(get_interface_gateway "$interface")
        local available=$(is_interface_available "$interface" && echo "✓ 可用" || echo "✗ 不可用")
        local ready=$(is_interface_ready_for_switch "$interface" && echo "✓ 就绪" || echo "✗ 未就绪")
        
        echo "接口状态: $status"
        echo "基本可用: $available"
        echo "切换就绪: $ready"
        echo "设备名: $device"
        echo "网关: $gateway"
    done
    
    # 显示状态文件
    if [ -f "$STATE_FILE" ]; then
        echo -e "\n保存的状态: $(cat "$STATE_FILE")"
    fi
}

# 守护进程模式
run_daemon() {
    log "启动网络切换守护进程"
    DAEMON_MODE=1
    
    while true; do
        if [ "$AUTO_MODE" = "1" ] && [ "$ENABLED" = "1" ]; then
            auto_switch
        fi
        
        # 重新读取配置（支持热重载）
        read_uci_config
        sleep "$CHECK_INTERVAL"
    done
}

# 停止守护进程
stop_daemon() {
    log "停止网络切换守护进程"
    pkill -f "network_switcher daemon"
    sleep 2
    pkill -9 -f "network_switcher daemon" 2>/dev/null
}

# 主函数
main() {
    acquire_lock
    trap release_lock EXIT
    
    # 读取配置
    read_uci_config
    
    case "$1" in
        auto)
            auto_switch
            ;;
        status)
            show_status
            ;;
        switch)
            case "$2" in
                wan)
                    switch_interface "$WAN_INTERFACE"
                    ;;
                wwan)
                    switch_interface "$WWAN_INTERFACE"
                    ;;
                *)
                    echo "用法: $0 switch [wan|wwan]"
                    exit 1
                    ;;
            esac
            ;;
        daemon)
            run_daemon
            ;;
        stop)
            stop_daemon
            ;;
        test)
            echo "=== 网络连通性测试 ==="
            for interface in "$WAN_INTERFACE" "$WWAN_INTERFACE"; do
                echo -e "\n测试 $interface:"
                if is_interface_ready_for_switch "$interface"; then
                    echo "✓ 就绪"
                else
                    echo "✗ 未就绪"
                fi
            done
            ;;
        *)
            echo "网络切换器 - OpenWrt插件版"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "命令:"
            echo "  auto           - 自动切换"
            echo "  status         - 显示状态"
            echo "  switch [接口]  - 手动切换 (wan/wwan)"
            echo "  daemon         - 守护进程模式"
            echo "  stop           - 停止守护进程"
            echo "  test           - 测试连通性"
            echo ""
            echo "配置: 通过LuCI界面或编辑 /etc/config/network_switcher"
            ;;
    esac
}

# 执行主函数
main "$@"

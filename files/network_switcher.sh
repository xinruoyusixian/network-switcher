#!/bin/sh

# ==============================================
# 网络切换脚本 - OpenWrt插件版 v1.2.0
# ==============================================

export PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin"
export HOME="/root"
umask 0022

# ==============================================
# 文件路径配置
# ==============================================

CONFIG_FILE="/etc/config/network_switcher"
LOCK_FILE="/var/lock/network_switcher.lock"
LOG_FILE="/var/log/network_switcher.log"
STATE_FILE="/var/state/network_switcher.state"
PID_FILE="/var/run/network_switcher.pid"

# ==============================================
# 配置读取函数 - 修复版本
# ==============================================

read_uci_config() {
    # 基本设置
    ENABLED=$(uci -q get network_switcher.settings.enabled || echo "1")
    CHECK_INTERVAL=$(uci -q get network_switcher.settings.check_interval || echo "60")
    PING_COUNT=$(uci -q get network_switcher.settings.ping_count || echo "3")
    PING_TIMEOUT=$(uci -q get network_switcher.settings.ping_timeout || echo "3")
    SWITCH_WAIT_TIME=$(uci -q get network_switcher.settings.switch_wait_time || echo "3")
    PING_SUCCESS_COUNT=$(uci -q get network_switcher.settings.ping_success_count || echo "1")
    
    # 读取Ping目标
    PING_TARGETS=""
    local index=0
    while uci -q get network_switcher.@settings[0].ping_targets[$index] >/dev/null; do
        local target=$(uci -q get network_switcher.@settings[0].ping_targets[$index])
        PING_TARGETS="$PING_TARGETS $target"
        index=$((index + 1))
    done
    
    if [ -z "$PING_TARGETS" ]; then
        PING_TARGETS="8.8.8.8 1.1.1.1 223.5.5.5"
    fi
    
    # 读取接口配置 - 修复版本
    INTERFACES=""
    INTERFACE_COUNT=0
    PRIMARY_INTERFACE=""
    
    # 获取所有配置段
    local config_output=$(uci show network_switcher 2>/dev/null)
    
    # 处理有名称的接口（如wan, wwan）
    for section in $(echo "$config_output" | grep "network_switcher.*=interface" | cut -d'.' -f2 | cut -d'=' -f1); do
        # 跳过settings和schedule
        if [ "$section" = "settings" ] || [ "$section" = "schedule" ]; then
            continue
        fi
        
        local enabled=$(uci -q get network_switcher.$section.enabled || echo "1")
        local interface=$(uci -q get network_switcher.$section.interface)
        local primary=$(uci -q get network_switcher.$section.primary || echo "0")
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
            INTERFACES="$INTERFACES $interface"
            
            if [ "$primary" = "1" ]; then
                PRIMARY_INTERFACE="$interface"
            fi
            echo "找到接口: $interface (enabled=$enabled, primary=$primary)"
        fi
    done
    
    # 处理匿名接口（如@interface[1]）
    local anonymous_count=0
    while uci -q get network_switcher.@interface[$anonymous_count] >/dev/null; do
        local enabled=$(uci -q get network_switcher.@interface[$anonymous_count].enabled || echo "1")
        local interface=$(uci -q get network_switcher.@interface[$anonymous_count].interface)
        local primary=$(uci -q get network_switcher.@interface[$anonymous_count].primary || echo "0")
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
            INTERFACES="$INTERFACES $interface"
            
            if [ "$primary" = "1" ]; then
                PRIMARY_INTERFACE="$interface"
            fi
            echo "找到匿名接口: $interface (enabled=$enabled, primary=$primary)"
        fi
        
        anonymous_count=$((anonymous_count + 1))
    done
    
    # 如果没有主接口，使用第一个接口
    if [ -z "$PRIMARY_INTERFACE" ] && [ $INTERFACE_COUNT -gt 0 ]; then
        PRIMARY_INTERFACE=$(echo $INTERFACES | awk '{print $1}')
    fi
    
    echo "配置读取完成: 接口数量=$INTERFACE_COUNT, 接口列表=$INTERFACES, 主接口=$PRIMARY_INTERFACE"
}

# ==============================================
# 核心功能函数
# ==============================================

log() {
    local message="$1"
    local level="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$lock_pid" ] && [ -d "/proc/$lock_pid" ]; then
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# 服务控制
service_control() {
    local action="$1"
    
    case "$action" in
        "start")
            echo "正在启动网络切换服务..."
            read_uci_config
            
            echo "DEBUG: ENABLED=$ENABLED, INTERFACE_COUNT=$INTERFACE_COUNT"
            echo "DEBUG: INTERFACES=$INTERFACES"
            
            if [ $INTERFACE_COUNT -eq 0 ]; then
                echo "错误: 未配置任何有效的网络接口"
                echo "请到'设置'页面添加并启用网络接口"
                return 1
            fi
            
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    echo "服务已在运行 (PID: $pid)"
                    return 0
                fi
            fi
            
            mkdir -p /var/lock /var/log /var/state /var/run
            
            log "启动网络切换服务" "SERVICE"
            
            # 启动守护进程
            /usr/bin/network_switcher daemon >/dev/null 2>&1 &
            local pid=$!
            echo $pid > "$PID_FILE"
            sleep 2
            
            if [ -d "/proc/$pid" ]; then
                echo "服务启动成功 (PID: $pid)"
                echo "已配置接口: $INTERFACES"
                return 0
            else
                echo "服务启动失败"
                return 1
            fi
            ;;
        "stop")
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    kill $pid 2>/dev/null
                    sleep 1
                    if [ -d "/proc/$pid" ]; then
                        kill -9 $pid 2>/dev/null
                    fi
                    log "停止网络切换服务" "SERVICE"
                    echo "服务停止成功"
                else
                    echo "服务未运行"
                fi
                rm -f "$PID_FILE"
            else
                local pids=$(pgrep -f "network_switcher daemon" 2>/dev/null)
                if [ -n "$pids" ]; then
                    for pid in $pids; do
                        kill $pid 2>/dev/null
                    done
                    echo "服务停止成功"
                else
                    echo "服务未运行"
                fi
            fi
            ;;
        "restart")
            service_control stop
            sleep 2
            service_control start
            ;;
        "status")
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    echo "运行中 (PID: $pid)"
                    return 0
                else
                    echo "已停止"
                    return 1
                fi
            else
                if pgrep -f "network_switcher daemon" >/dev/null 2>&1; then
                    echo "运行中"
                    return 0
                else
                    echo "已停止"
                    return 1
                fi
            fi
            ;;
    esac
}

# 获取已配置接口
get_configured_interfaces() {
    read_uci_config
    for iface in $INTERFACES; do
        echo "$iface"
    done
    
    # 如果没有接口，返回默认值
    if [ $INTERFACE_COUNT -eq 0 ]; then
        echo "wan"
        echo "wwan"
    fi
}

# 获取接口设备
get_interface_device() {
    local interface="$1"
    ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null
}

# 网络连通性测试
test_network_connectivity() {
    local interface="$1"
    local device=$(get_interface_device "$interface")
    
    if [ -z "$device" ]; then
        return 1
    fi
    
    local success_count=0
    for target in $PING_TARGETS; do
        if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
            success_count=$((success_count + 1))
        fi
    done
    
    [ $success_count -ge $PING_SUCCESS_COUNT ]
}

# 接口切换
switch_interface() {
    local target_interface="$1"
    
    echo "开始切换到: $target_interface"
    log "开始切换到: $target_interface" "SWITCH"
    
    local device=$(get_interface_device "$target_interface")
    if [ -z "$device" ]; then
        echo "错误: 无法获取接口设备"
        return 1
    fi
    
    local gateway=$(ubus call network.interface.$target_interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    if [ -z "$gateway" ]; then
        echo "错误: 无法获取网关"
        return 1
    fi
    
    # 获取metric
    local metric="10"
    local config_sections=$(uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1)
    for section in $config_sections; do
        local iface=$(uci -q get network_switcher.$section.interface)
        if [ "$iface" = "$target_interface" ]; then
            metric=$(uci -q get network_switcher.$section.metric || echo "10")
            break
        fi
    done
    
    # 处理匿名接口
    local anonymous_count=0
    while uci -q get network_switcher.@interface[$anonymous_count] >/dev/null; do
        local iface=$(uci -q get network_switcher.@interface[$anonymous_count].interface)
        if [ "$iface" = "$target_interface" ]; then
            metric=$(uci -q get network_switcher.@interface[$anonymous_count].metric || echo "10")
            break
        fi
        anonymous_count=$((anonymous_count + 1))
    done
    
    # 执行切换
    ip route del default 2>/dev/null
    ip route replace default via "$gateway" dev "$device" metric "$metric"
    
    sleep $SWITCH_WAIT_TIME
    
    # 验证切换
    local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    if [ "$current_device" = "$device" ]; then
        if test_network_connectivity "$target_interface"; then
            echo "切换到 $target_interface 成功"
            log "切换到 $target_interface 成功" "SWITCH"
            echo "$target_interface" > "$STATE_FILE"
            return 0
        fi
    fi
    
    echo "切换验证失败"
    log "切换到 $target_interface 失败" "ERROR"
    return 1
}

# 自动切换
auto_switch() {
    read_uci_config
    
    if [ "$ENABLED" != "1" ]; then
        return 0
    fi
    
    echo "自动切换: 检查接口连通性..."
    
    # 优先尝试主接口
    if [ -n "$PRIMARY_INTERFACE" ]; then
        local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
        local primary_device=$(get_interface_device "$PRIMARY_INTERFACE")
        
        echo "主接口: $PRIMARY_INTERFACE, 当前设备: $current_device, 主接口设备: $primary_device"
        
        if [ "$current_device" != "$primary_device" ] || ! test_network_connectivity "$PRIMARY_INTERFACE"; then
            echo "检查主接口 $PRIMARY_INTERFACE 连通性..."
            if test_network_connectivity "$PRIMARY_INTERFACE"; then
                echo "主接口连通正常，执行切换"
                switch_interface "$PRIMARY_INTERFACE" && return 0
            else
                echo "主接口连通失败"
            fi
        else
            echo "主接口已是当前接口且连通正常"
            return 0
        fi
    fi
    
    # 尝试其他接口
    for interface in $INTERFACES; do
        if [ "$interface" != "$PRIMARY_INTERFACE" ]; then
            echo "检查接口 $interface 连通性..."
            if test_network_connectivity "$interface"; then
                echo "接口 $interface 连通正常，执行切换"
                switch_interface "$interface" && return 0
            else
                echo "接口 $interface 连通失败"
            fi
        fi
    done
    
    echo "所有接口都不可用"
    log "所有接口都不可用" "ERROR"
    return 1
}

# 显示状态
show_status() {
    read_uci_config
    
    echo "=== 网络切换器状态 ==="
    echo "服务状态: $(service_control status)"
    echo "检查间隔: ${CHECK_INTERVAL}秒"
    echo "主接口: ${PRIMARY_INTERFACE:-未设置}"
    echo ""
    
    # 当前接口
    local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    local current_interface=""
    for interface in $INTERFACES; do
        local device=$(get_interface_device "$interface")
        if [ "$device" = "$current_device" ]; then
            current_interface="$interface"
            break
        fi
    done
    
    if [ -n "$current_interface" ]; then
        echo "当前互联网出口: $current_interface"
    else
        echo "当前互联网出口: $current_device"
    fi
    
    echo -e "\n=== 接口状态 ==="
    
    if [ $INTERFACE_COUNT -eq 0 ]; then
        echo "未配置任何网络接口"
    else
        for interface in $INTERFACES; do
            echo -e "\n--- $interface"
            local device=$(get_interface_device "$interface")
            local gateway=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
            local status=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || echo "false")
            
            echo "  设备: $device"
            echo "  状态: $status"
            echo "  网关: $gateway"
            
            if [ "$status" = "true" ] && [ -n "$device" ] && [ -n "$gateway" ]; then
                if test_network_connectivity "$interface"; then
                    echo "  网络: ✓ 连通"
                else
                    echo "  网络: ✗ 断开"
                fi
            else
                echo "  网络: ✗ 不可用"
            fi
        done
    fi
}

# 测试连通性
test_connectivity() {
    read_uci_config
    
    echo "=== 网络连通性测试 ==="
    echo "测试目标: $PING_TARGETS"
    echo ""
    
    if [ $INTERFACE_COUNT -eq 0 ]; then
        echo "未配置任何网络接口"
        return
    fi
    
    for interface in $INTERFACES; do
        echo "测试接口: $interface"
        local device=$(get_interface_device "$interface")
        
        if [ -z "$device" ]; then
            echo "  ✗ 接口未就绪"
            continue
        fi
        
        echo "  设备: $device"
        echo "  Ping测试:"
        
        local success_count=0
        for target in $PING_TARGETS; do
            echo -n "    $target ... "
            if ping -I "$device" -c 2 -W 2 "$target" >/dev/null 2>&1; then
                echo "✓"
                success_count=$((success_count + 1))
            else
                echo "✗"
            fi
        done
        
        if [ $success_count -ge $PING_SUCCESS_COUNT ]; then
            echo "  结果: ✓ 通过 ($success_count/$(echo $PING_TARGETS | wc -w))"
        else
            echo "  结果: ✗ 失败 ($success_count/$(echo $PING_TARGETS | wc -w))"
        fi
        echo ""
    done
}

# 守护进程
run_daemon() {
    echo "启动守护进程 (PID: $$)"
    echo $$ > "$PID_FILE"
    log "启动守护进程" "SERVICE"
    
    while true; do
        read_uci_config
        
        if [ "$ENABLED" = "1" ] && [ $INTERFACE_COUNT -gt 0 ]; then
            auto_switch
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# 清理日志
clear_log() {
    > "$LOG_FILE"
    echo "日志已清空"
    log "日志已清空" "SERVICE"
}

# ==============================================
# 主函数
# ==============================================

main() {
    acquire_lock
    trap release_lock EXIT
    
    case "$1" in
        start|stop|restart|status)
            service_control "$1"
            ;;
        daemon)
            run_daemon
            ;;
        auto)
            auto_switch
            ;;
        switch)
            if [ -n "$2" ]; then
                switch_interface "$2"
            else
                echo "用法: $0 switch <接口名>"
                echo "可用接口:"
                get_configured_interfaces
            fi
            ;;
        test)
            test_connectivity
            ;;
        status)
            show_status
            ;;
        configured_interfaces)
            get_configured_interfaces
            ;;
        clear_log)
            clear_log
            ;;
        current_interface)
            ip route show default 2>/dev/null | head -1 | awk '{print $5}'
            ;;
        *)
            echo "网络切换器 v1.2.0"
            echo ""
            echo "用法: $0 <命令>"
            echo ""
            echo "命令:"
            echo "  start       启动服务"
            echo "  stop        停止服务" 
            echo "  restart     重启服务"
            echo "  status      服务状态"
            echo "  daemon      守护进程"
            echo "  auto        自动切换"
            echo "  switch IF   切换到接口"
            echo "  test        网络测试"
            echo "  configured_interfaces 已配置接口"
            echo "  clear_log   清空日志"
            echo "  current_interface 当前接口"
            ;;
    esac
}

main "$@"

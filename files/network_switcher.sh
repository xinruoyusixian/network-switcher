#!/bin/sh

# ==============================================
# 网络切换脚本 - OpenWrt插件版 v1.2.2
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
    
    # 读取接口配置 - 修复版本，不输出调试信息
    INTERFACES=""
    INTERFACE_COUNT=0
    PRIMARY_INTERFACE=""
    local seen_interfaces=""
    
    # 处理命名接口
    local config_sections=$(uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1)
    
    for section in $config_sections; do
        if [ "$section" = "settings" ] || [ "$section" = "schedule" ]; then
            continue
        fi
        
        local enabled=$(uci -q get network_switcher.$section.enabled || echo "1")
        local interface=$(uci -q get network_switcher.$section.interface)
        local primary=$(uci -q get network_switcher.$section.primary || echo "0")
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            # 检查是否已经见过这个接口（避免重复）
            if echo "$seen_interfaces" | grep -q "\b$interface\b"; then
                continue
            fi
            
            INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
            INTERFACES="$INTERFACES $interface"
            seen_interfaces="$seen_interfaces $interface"
            
            if [ "$primary" = "1" ]; then
                PRIMARY_INTERFACE="$interface"
            fi
        fi
    done
    
    # 处理匿名接口（如果有的话）
    local anonymous_count=0
    while uci -q get network_switcher.@interface[$anonymous_count] >/dev/null; do
        local enabled=$(uci -q get network_switcher.@interface[$anonymous_count].enabled || echo "1")
        local interface=$(uci -q get network_switcher.@interface[$anonymous_count].interface)
        local primary=$(uci -q get network_switcher.@interface[$anonymous_count].primary || echo "0")
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            # 检查是否已经见过这个接口（避免重复）
            if echo "$seen_interfaces" | grep -q "\b$interface\b"; then
                anonymous_count=$((anonymous_count + 1))
                continue
            fi
            
            INTERFACE_COUNT=$((INTERFACE_COUNT + 1))
            INTERFACES="$INTERFACES $interface"
            seen_interfaces="$seen_interfaces $interface"
            
            if [ "$primary" = "1" ]; then
                PRIMARY_INTERFACE="$interface"
            fi
        fi
        
        anonymous_count=$((anonymous_count + 1))
    done
    
    # 如果没有主接口，使用第一个接口
    if [ -z "$PRIMARY_INTERFACE" ] && [ $INTERFACE_COUNT -gt 0 ]; then
        PRIMARY_INTERFACE=$(echo $INTERFACES | awk '{print $1}')
    fi
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

# 改进的锁机制 - 不输出错误信息
acquire_lock_silent() {
    local max_retries=2
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if [ -f "$LOCK_FILE" ]; then
            local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [ -n "$lock_pid" ] && [ -d "/proc/$lock_pid" ]; then
                retry_count=$((retry_count + 1))
                sleep 1
                continue
            else
                rm -f "$LOCK_FILE" 2>/dev/null
            fi
        fi
        
        echo $$ > "$LOCK_FILE" 2>/dev/null
        if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        sleep 1
    done
    
    return 1
}

acquire_lock() {
    if ! acquire_lock_silent; then
        echo "另一个实例正在运行，无法获取锁"
        exit 1
    fi
}

release_lock() {
    if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$LOCK_FILE"
    fi
}

# 清理残留进程和文件
cleanup_stale_processes() {
    # 清理锁文件
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -z "$lock_pid" ] || [ ! -d "/proc/$lock_pid" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # 清理PID文件
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -z "$pid" ] || [ ! -d "/proc/$pid" ]; then
            rm -f "$PID_FILE"
        fi
    fi
    
    # 杀死残留的守护进程
    local stale_pids=$(pgrep -f "network_switcher daemon" 2>/dev/null)
    if [ -n "$stale_pids" ]; then
        for pid in $stale_pids; do
            if [ "$pid" != "$$" ]; then
                kill $pid 2>/dev/null
            fi
        done
    fi
}

# 服务控制
service_control() {
    local action="$1"
    
    case "$action" in
        "start")
            echo "正在启动网络切换服务..."
            
            # 先清理残留
            cleanup_stale_processes
            
            read_uci_config
            
            if [ $INTERFACE_COUNT -eq 0 ]; then
                echo "错误: 未配置任何有效的网络接口"
                return 1
            fi
            
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    echo "服务已在运行 (PID: $pid)"
                    return 0
                fi
            fi
            
            # 创建必要的目录
            mkdir -p /var/lock /var/log /var/state /var/run
            
            log "启动网络切换服务" "SERVICE"
            
            # 启动守护进程
            run_daemon &
            local pid=$!
            echo $pid > "$PID_FILE"
            sleep 2
            
            if [ -d "/proc/$pid" ]; then
                echo "服务启动成功 (PID: $pid)"
                return 0
            else
                echo "服务启动失败"
                return 1
            fi
            ;;
        "stop")
            echo "正在停止网络切换服务..."
            
            # 先清理残留
            cleanup_stale_processes
            
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    echo "停止服务 (PID: $pid)"
                    kill $pid 2>/dev/null
                    sleep 2
                    
                    if [ -d "/proc/$pid" ]; then
                        kill -9 $pid 2>/dev/null
                        echo "强制停止服务"
                    fi
                    
                    log "停止网络切换服务" "SERVICE"
                else
                    echo "服务未运行"
                fi
                rm -f "$PID_FILE"
            else
                echo "服务未运行"
            fi
            
            # 确保清理锁文件
            release_lock
            echo "服务停止完成"
            ;;
        "restart")
            echo "正在重启网络切换服务..."
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

# 获取已配置接口（只返回接口名称，无调试信息）
get_configured_interfaces() {
    # 使用静默锁，如果获取不到锁就跳过
    if acquire_lock_silent; then
        read_uci_config
        for iface in $INTERFACES; do
            echo "$iface"
        done
        release_lock
    else
        # 如果获取不到锁，直接从UCI读取（可能不完整但不会阻塞）
        uci show network_switcher 2>/dev/null | grep -E "(\.interface=|@interface\[.*\.interface=)" | \
        awk -F'=' '{print $2}' | tr -d "'" | sort | uniq
    fi
}

# 获取接口设备
get_interface_device() {
    local interface="$1"
    ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null
}

# 检查接口是否可用
is_interface_available() {
    local interface="$1"
    local device=$(get_interface_device "$interface")
    
    if [ -z "$device" ]; then
        return 1
    fi
    
    # 检查接口状态
    if ! ip link show "$device" 2>/dev/null | grep -q "state UP"; then
        return 1
    fi
    
    # 检查是否有网关
    local gateway=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    if [ -z "$gateway" ]; then
        return 1
    fi
    
    return 0
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
    
    # 检查命名接口
    local config_sections=$(uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1)
    for section in $config_sections; do
        if [ "$section" = "settings" ] || [ "$section" = "schedule" ]; then
            continue
        fi
        
        local iface=$(uci -q get network_switcher.$section.interface)
        if [ "$iface" = "$target_interface" ]; then
            metric=$(uci -q get network_switcher.$section.metric || echo "10")
            break
        fi
    done
    
    # 检查匿名接口
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
        else
            echo "切换后网络测试失败"
        fi
    else
        echo "路由切换验证失败"
    fi
    
    echo "切换验证失败"
    log "切换到 $target_interface 失败" "ERROR"
    return 1
}

# 自动切换
auto_switch() {
    read_uci_config
    
    if [ "$ENABLED" != "1" ]; then
        echo "服务未启用"
        return 0
    fi
    
    # 优先尝试主接口
    if [ -n "$PRIMARY_INTERFACE" ]; then
        if is_interface_available "$PRIMARY_INTERFACE" && test_network_connectivity "$PRIMARY_INTERFACE"; then
            local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
            local primary_device=$(get_interface_device "$PRIMARY_INTERFACE")
            
            if [ "$current_device" != "$primary_device" ]; then
                switch_interface "$PRIMARY_INTERFACE" && return 0
            else
                return 0
            fi
        fi
    fi
    
    # 尝试其他接口
    for interface in $INTERFACES; do
        if [ "$interface" != "$PRIMARY_INTERFACE" ]; then
            if is_interface_available "$interface" && test_network_connectivity "$interface"; then
                local current_device=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
                local target_device=$(get_interface_device "$interface")
                
                if [ "$current_device" != "$target_device" ]; then
                    switch_interface "$interface" && return 0
                else
                    return 0
                fi
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
        
        if is_interface_available "$interface"; then
            echo "  Ping测试:"
            
            local success_count=0
            for target in $PING_TARGETS; do
                echo -n "    $target ... "
                if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
                    echo "✓ 成功"
                    success_count=$((success_count + 1))
                else
                    echo "✗ 失败"
                fi
            done
            
            if [ $success_count -ge $PING_SUCCESS_COUNT ]; then
                echo "  总体结果: ✓ 通过 ($success_count/$PING_SUCCESS_COUNT)"
            else
                echo "  总体结果: ✗ 失败 ($success_count/$PING_SUCCESS_COUNT)"
            fi
        else
            echo "  接口不可用"
        fi
        echo ""
    done
}

# 守护进程
run_daemon() {
    log "启动守护进程" "SERVICE"
    
    # 设置信号处理
    trap 'log "收到信号，退出守护进程" "SERVICE"; exit 0' TERM INT
    
    while true; do
        read_uci_config
        
        if [ "$ENABLED" = "1" ] && [ $INTERFACE_COUNT -gt 0 ]; then
            auto_switch
        else
            log "服务已禁用或无接口配置，退出守护进程" "SERVICE"
            break
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# 清理日志
clear_log() {
    if [ -f "$LOG_FILE" ]; then
        > "$LOG_FILE"
        echo "日志已清空"
        log "日志已清空" "SERVICE"
    else
        echo "日志文件不存在"
    fi
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
        cleanup)
            cleanup_stale_processes
            ;;
        *)
            echo "网络切换器 v1.2.2"
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
            echo "  cleanup     清理残留进程"
            ;;
    esac
}

main "$@"

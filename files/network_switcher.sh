#!/bin/sh

# ==============================================
# 网络切换脚本 - OpenWrt插件版 v1.2.0
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

# 从UCI读取配置 - 修复版本
read_uci_config() {
    # 基本设置
    ENABLED=$(uci get network_switcher.settings.enabled 2>/dev/null || echo "0")
    CHECK_INTERVAL=$(uci get network_switcher.settings.check_interval 2>/dev/null || echo "60")
    PING_COUNT=$(uci get network_switcher.settings.ping_count 2>/dev/null || echo "3")
    PING_TIMEOUT=$(uci get network_switcher.settings.ping_timeout 2>/dev/null || echo "3")
    SWITCH_WAIT_TIME=$(uci get network_switcher.settings.switch_wait_time 2>/dev/null || echo "3")
    PING_SUCCESS_COUNT=$(uci get network_switcher.settings.ping_success_count 2>/dev/null || echo "1")
    
    # 读取Ping目标列表
    PING_TARGETS=""
    local target_index=1
    while true; do
        local target=$(uci get network_switcher.settings.ping_targets 2>/dev/null | awk -v i=$target_index '{print $i}')
        [ -z "$target" ] && break
        PING_TARGETS="$PING_TARGETS $target"
        target_index=$((target_index + 1))
    done
    # 如果没有配置目标，使用默认值
    if [ -z "$PING_TARGETS" ]; then
        PING_TARGETS="8.8.8.8 1.1.1.1 223.5.5.5"
    fi
    
    # 读取接口配置
    INTERFACES=""
    INTERFACE_COUNT=0
    PRIMARY_INTERFACE=""
    
    # 使用临时文件来收集接口信息
    local temp_file=$(mktemp)
    
    uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
        if [ "$section" != "settings" ] && [ "$section" != "schedule" ]; then
            local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
            local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
            local primary=$(uci get network_switcher.$section.primary 2>/dev/null || echo "0")
            
            if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
                echo "INTERFACE_COUNT=$((INTERFACE_COUNT + 1))" >> "$temp_file"
                echo "INTERFACES=\"$INTERFACES $interface\"" >> "$temp_file"
                
                if [ "$primary" = "1" ]; then
                    echo "PRIMARY_INTERFACE=\"$interface\"" >> "$temp_file"
                fi
            fi
        fi
    done
    
    # 从临时文件读取变量
    if [ -f "$temp_file" ]; then
        source "$temp_file"
        rm -f "$temp_file"
    fi
    
    # 如果没有设置主接口，使用第一个启用的接口
    if [ -z "$PRIMARY_INTERFACE" ] && [ $INTERFACE_COUNT -gt 0 ]; then
        PRIMARY_INTERFACE=$(echo $INTERFACES | awk '{print $1}')
    fi
    
    # 读取定时任务
    SCHEDULE_ENABLED=$(uci get network_switcher.schedule.enabled 2>/dev/null || echo "0")
    SCHEDULE_TIMES=$(uci get network_switcher.schedule.times 2>/dev/null || echo "")
    SCHEDULE_TARGETS=$(uci get network_switcher.schedule.targets 2>/dev/null || echo "")
}

# ==============================================
# 文件路径配置
# ==============================================

SCRIPT_NAME="network-switcher"
LOCK_FILE="/var/lock/network_switcher.lock"
LOG_FILE="/var/log/network_switcher.log"
STATE_FILE="/var/state/network_switcher.state"
PID_FILE="/var/run/network_switcher.pid"

# ==============================================
# 函数定义
# ==============================================

# 简化日志函数 - 只记录重要操作
log() {
    local message="$1"
    local level="$2"
    
    # 只记录重要操作日志
    case "$level" in
        "SWITCH"|"ERROR"|"SCHEDULE"|"SERVICE")
            local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo "[$timestamp] $message" >> "$LOG_FILE"
            ;;
    esac
}

# 清空日志函数
clear_log() {
    > "$LOG_FILE"
    log "日志已被清空" "SERVICE"
    echo "日志清空成功"
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

# 检查接口配置是否有效
check_interface_config() {
    local enabled_count=0
    local temp_file=$(mktemp)
    
    uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
        local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
        local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            echo "enabled_count=$((enabled_count + 1))" >> "$temp_file"
        fi
    done
    
    if [ -f "$temp_file" ]; then
        source "$temp_file"
        rm -f "$temp_file"
    fi
    
    if [ $enabled_count -lt 1 ]; then
        echo "错误: 未配置任何有效的网络接口"
        return 1
    fi
    
    return 0
}

# 验证接口是否存在
validate_interface() {
    local interface="$1"
    if ubus call network.interface."$interface" status >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 服务控制函数
service_control() {
    local action="$1"
    case "$action" in
        "start")
            echo "正在启动网络切换服务..."
            
            # 重新读取配置
            read_uci_config
            echo "配置读取完成: ENABLED=$ENABLED, 接口数量=$INTERFACE_COUNT"
            
            if [ -f "$PID_FILE" ]; then
                local pid=$(cat "$PID_FILE")
                if [ -d "/proc/$pid" ]; then
                    echo "服务已在运行 (PID: $pid)"
                    return 0
                fi
            fi
            
            # 检查接口配置
            if ! check_interface_config; then
                echo "服务启动失败: 接口未配置"
                return 1
            fi
            
            # 验证所有启用的接口是否存在
            local invalid_interfaces=""
            local has_valid_interface=0
            local temp_file=$(mktemp)
            
            uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
                local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
                local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
                if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
                    if validate_interface "$interface"; then
                        echo "has_valid_interface=1" >> "$temp_file"
                        echo "接口 $interface 验证通过"
                    else
                        echo "invalid_interfaces=\"$invalid_interfaces $interface\"" >> "$temp_file"
                        echo "接口 $interface 验证失败"
                    fi
                fi
            done
            
            if [ -f "$temp_file" ]; then
                source "$temp_file"
                rm -f "$temp_file"
            fi
            
            if [ $has_valid_interface -eq 0 ]; then
                echo "服务启动失败: 没有有效的网络接口"
                return 1
            fi
            
            if [ -n "$invalid_interfaces" ]; then
                echo "警告: 以下接口不存在: $invalid_interfaces"
            fi
            
            # 创建必要的目录
            mkdir -p /var/lock /var/log /var/state /var/run
            
            log "启动网络切换服务" "SERVICE"
            echo "正在启动守护进程..."
            
            # 直接运行守护进程
            /usr/bin/network_switcher daemon >/dev/null 2>&1 &
            local pid=$!
            echo $pid > "$PID_FILE"
            sleep 2
            
            if [ -d "/proc/$pid" ]; then
                echo "服务启动成功 (PID: $pid)"
                echo "当前配置:"
                echo "  检查间隔: ${CHECK_INTERVAL}秒"
                echo "  Ping目标: $PING_TARGETS"
                echo "  主接口: $PRIMARY_INTERFACE"
                echo "  已配置接口: $INTERFACES"
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
                # 如果没有PID文件，尝试通过进程名停止
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
                # 检查是否有相关进程在运行
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

# 获取当前互联网出口接口
get_current_internet_interface() {
    # 获取默认路由的接口
    local default_iface=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
    
    if [ -n "$default_iface" ]; then
        # 尝试通过接口找到对应的逻辑接口名
        local temp_file=$(mktemp)
        
        uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
            local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
            local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
            
            if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
                local device=$(ubus call network.interface.$interface status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
                if [ "$device" = "$default_iface" ]; then
                    echo "$interface" > "$temp_file"
                    break
                fi
            fi
        done
        
        if [ -f "$temp_file" ]; then
            local result=$(cat "$temp_file")
            rm -f "$temp_file"
            echo "$result"
            return 0
        fi
    fi
    
    # 如果没找到，返回设备名
    echo "$default_iface"
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
    local required_success=$PING_SUCCESS_COUNT
    
    # 计算实际需要的成功次数（不能大于目标数量）
    local target_count=$(echo "$test_targets" | wc -w)
    if [ $required_success -gt $target_count ]; then
        required_success=$target_count
    fi
    
    for target in $test_targets; do
        if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
            success_count=$((success_count + 1))
            if [ $success_count -ge $required_success ]; then
                break
            fi
        fi
    done
    
    if [ $success_count -ge $required_success ]; then
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
    
    # 删除所有现有的默认路由
    ip route del default 2>/dev/null
    
    # 添加新的默认路由
    gateway=$(get_interface_gateway "$target_interface")
    device=$(get_interface_device "$target_interface")
    
    if [ -z "$gateway" ] || [ -z "$device" ]; then
        return 1
    fi
    
    # 获取该接口的metric
    local metric="10"
    local temp_file=$(mktemp)
    
    uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
        local iface=$(uci get network_switcher.$section.interface 2>/dev/null)
        if [ "$iface" = "$target_interface" ]; then
            metric=$(uci get network_switcher.$section.metric 2>/dev/null || echo "10")
            echo "$metric" > "$temp_file"
            break
        fi
    done
    
    if [ -f "$temp_file" ]; then
        metric=$(cat "$temp_file")
        rm -f "$temp_file"
    fi
    
    ip route replace default via "$gateway" dev "$device" metric "$metric"
    
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
    
    log "开始切换到: $target_interface" "SWITCH"
    echo "开始切换到: $target_interface"
    
    # 如果已经是目标接口且网络正常
    local target_device=$(get_interface_device "$target_interface")
    if [ "$current_interface" = "$target_device" ]; then
        if test_network_connectivity "$target_interface"; then
            echo "已经是目标接口且网络正常"
            return 0
        fi
    fi
    
    # 检查目标接口
    if ! is_interface_ready_for_switch "$target_interface"; then
        echo "目标接口 $target_interface 不适合切换"
        return 1
    fi
    
    # 执行切换
    echo "执行路由切换..."
    if ! perform_route_switch "$target_interface"; then
        echo "路由切换执行失败"
        return 1
    fi
    
    echo "验证切换结果..."
    if verify_switch "$target_interface"; then
        log "切换到 $target_interface 成功" "SWITCH"
        echo "$target_interface" > "$STATE_FILE"
        echo "切换到 $target_interface 成功"
        return 0
    else
        log "切换验证失败" "ERROR"
        echo "切换验证失败"
        return 1
    fi
}

# 自动切换（多接口支持，优先使用主接口）
auto_switch() {
    if [ "$ENABLED" != "1" ]; then
        return 0
    fi
    
    # 首先检查主接口是否就绪
    if [ -n "$PRIMARY_INTERFACE" ] && is_interface_ready_for_switch "$PRIMARY_INTERFACE"; then
        local current_device=$(get_current_default_interface)
        local primary_device=$(get_interface_device "$PRIMARY_INTERFACE")
        
        if [ "$current_device" != "$primary_device" ]; then
            log "主接口就绪，切换到主接口: $PRIMARY_INTERFACE" "SWITCH"
            switch_interface "$PRIMARY_INTERFACE" && return 0
        elif ! test_network_connectivity "$PRIMARY_INTERFACE"; then
            log "主接口网络异常，重新切换到主接口: $PRIMARY_INTERFACE" "SWITCH"
            switch_interface "$PRIMARY_INTERFACE" && return 0
        else
            # 主接口正常，保持
            return 0
        fi
    fi
    
    # 如果主接口不可用，按优先级顺序切换其他接口
    local sorted_interfaces=""
    local temp_file=$(mktemp)
    
    uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
        local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
        local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
        local metric=$(uci get network_switcher.$section.metric 2>/dev/null || echo "999")
        
        # 跳过主接口，因为已经检查过了
        if [ "$enabled" = "1" ] && [ -n "$interface" ] && [ "$interface" != "$PRIMARY_INTERFACE" ]; then
            echo "$metric:$interface" >> "$temp_file"
        fi
    done
    
    if [ -f "$temp_file" ]; then
        sort -n "$temp_file" | cut -d: -f2 > "${temp_file}_sorted"
        sorted_interfaces=$(cat "${temp_file}_sorted" 2>/dev/null | tr '\n' ' ')
        rm -f "$temp_file" "${temp_file}_sorted"
    fi
    
    # 尝试按优先级顺序切换
    for interface in $sorted_interfaces; do
        if is_interface_ready_for_switch "$interface"; then
            local current_device=$(get_current_default_interface)
            local target_device=$(get_interface_device "$interface")
            
            if [ "$current_device" != "$target_device" ]; then
                log "自动切换到: $interface" "SWITCH"
                switch_interface "$interface" && return 0
            elif ! test_network_connectivity "$interface"; then
                log "重新验证接口: $interface" "SWITCH"
                switch_interface "$interface" && return 0
            else
                # 当前接口正常，保持
                return 0
            fi
        fi
    done
    
    log "所有接口都不可用" "ERROR"
    return 1
}

# 显示状态
show_status() {
    read_uci_config
    
    echo "=== 网络切换器状态 ==="
    echo "服务状态: $(service_control status)"
    echo "检查间隔: ${CHECK_INTERVAL}秒"
    if [ -n "$PRIMARY_INTERFACE" ]; then
        echo "主接口: $PRIMARY_INTERFACE"
    fi
    echo ""
    
    # 当前互联网出口接口
    local internet_interface=$(get_current_internet_interface)
    if [ -n "$internet_interface" ]; then
        echo "当前互联网出口: $internet_interface"
    else
        echo "当前互联网出口: -"
    fi
    
    # 显示所有启用的接口状态
    echo -e "\n=== 接口状态 ==="
    local enabled_count=0
    local temp_file=$(mktemp)
    
    uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
        local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
        local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
        local metric=$(uci get network_switcher.$section.metric 2>/dev/null || echo "999")
        local primary=$(uci get network_switcher.$section.primary 2>/dev/null || echo "0")
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            echo "enabled_count=$((enabled_count + 1))" >> "$temp_file"
            echo -e "\n--- $interface (优先级: $metric)" >> "$temp_file"
            if [ "$primary" = "1" ]; then
                echo "  主接口" >> "$temp_file"
            fi
            
            local status=$(get_interface_status "$interface")
            local device=$(get_interface_device "$interface")
            local gateway=$(get_interface_gateway "$interface")
            local available=$(is_interface_available "$interface" && echo "✓ 可用" || echo "✗ 不可用")
            local ready=$(is_interface_ready_for_switch "$interface" && echo "✓ 就绪" || echo "✗ 未就绪")
            
            echo "  接口状态: $status" >> "$temp_file"
            echo "  基本可用: $available" >> "$temp_file"
            echo "  切换就绪: $ready" >> "$temp_file"
            echo "  设备名: $device" >> "$temp_file"
            echo "  网关: $gateway" >> "$temp_file"
        fi
    done
    
    if [ -f "$temp_file" ]; then
        source "$temp_file" 2>/dev/null
        cat "$temp_file"
        rm -f "$temp_file"
    fi
    
    if [ $enabled_count -eq 0 ]; then
        echo "⚠️ 未配置任何有效的网络接口"
    fi
    
    # 显示状态文件
    if [ -f "$STATE_FILE" ]; then
        echo -e "\n保存的状态: $(cat "$STATE_FILE")"
    fi
}

# 测试连通性
test_connectivity() {
    read_uci_config
    
    echo "=== 网络连通性测试 ==="
    echo "测试目标: $PING_TARGETS"
    echo "成功要求: $PING_SUCCESS_COUNT/$PING_COUNT"
    echo ""
    
    local has_enabled_interfaces=0
    local temp_file=$(mktemp)
    
    uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
        local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
        local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
        
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            echo "has_enabled_interfaces=1" >> "$temp_file"
            echo "测试接口: $interface" >> "$temp_file"
            local device=$(get_interface_device "$interface")
            if [ -z "$device" ]; then
                echo "  ✗ 无法获取设备名" >> "$temp_file"
                continue
            fi
            
            echo "  设备: $device" >> "$temp_file"
            echo "  基本状态: $(is_interface_available "$interface" && echo "✓ 可用" || echo "✗ 不可用")" >> "$temp_file"
            
            if is_interface_available "$interface"; then
                echo "  连通性测试:" >> "$temp_file"
                local success_count=0
                for target in $PING_TARGETS; do
                    echo -n "    测试 $target ... " >> "$temp_file"
                    if ping -I "$device" -c $PING_COUNT -W $PING_TIMEOUT "$target" >/dev/null 2>&1; then
                        echo "✓ 成功" >> "$temp_file"
                        success_count=$((success_count + 1))
                    else
                        echo "✗ 失败" >> "$temp_file"
                    fi
                done
                
                local target_count=$(echo "$PING_TARGETS" | wc -w)
                local required_success=$PING_SUCCESS_COUNT
                if [ $required_success -gt $target_count ]; then
                    required_success=$target_count
                fi
                
                if [ $success_count -ge $required_success ]; then
                    echo "  总体结果: ✓ 通过 ($success_count/$required_success)" >> "$temp_file"
                else
                    echo "  总体结果: ✗ 失败 ($success_count/$required_success)" >> "$temp_file"
                fi
            fi
            echo "" >> "$temp_file"
        fi
    done
    
    if [ -f "$temp_file" ]; then
        source "$temp_file" 2>/dev/null
        cat "$temp_file"
        rm -f "$temp_file"
    fi
    
    if [ $has_enabled_interfaces -eq 0 ]; then
        echo "⚠️ 未配置任何有效的网络接口，无法进行测试"
    fi
}

# 守护进程模式
run_daemon() {
    DAEMON_MODE=1
    log "启动网络切换守护进程" "SERVICE"
    echo $$ > "$PID_FILE"
    
    while true; do
        # 重新读取配置
        read_uci_config
        
        if [ "$ENABLED" = "1" ]; then
            # 自动模式检查
            auto_switch
        else
            # 如果服务被禁用，退出守护进程
            log "服务已禁用，停止守护进程" "SERVICE"
            break
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# 获取可用接口列表
get_available_interfaces() {
    echo "wan"
    # 从网络配置中获取更多接口
    uci show network | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read iface; do
        if [ "$iface" != "wan" ] && [ "$iface" != "loopback" ]; then
            echo "$iface"
        fi
    done
}

# 获取已配置的接口列表 - 修复版本
get_configured_interfaces() {
    local temp_file=$(mktemp)
    
    uci show network_switcher 2>/dev/null | grep "=interface" | cut -d'.' -f2 | cut -d'=' -f1 | while read section; do
        local enabled=$(uci get network_switcher.$section.enabled 2>/dev/null || echo "0")
        local interface=$(uci get network_switcher.$section.interface 2>/dev/null)
        if [ "$enabled" = "1" ] && [ -n "$interface" ]; then
            echo "$interface" >> "$temp_file"
        fi
    done
    
    if [ -f "$temp_file" ]; then
        cat "$temp_file"
        rm -f "$temp_file"
    fi
}

# 获取主接口
get_primary_interface() {
    read_uci_config
    echo "$PRIMARY_INTERFACE"
}

# 主函数
main() {
    acquire_lock
    trap release_lock EXIT
    
    # 读取配置
    read_uci_config
    
    case "$1" in
        start|stop|restart|status)
            service_control "$1"
            ;;
        auto)
            auto_switch
            ;;
        status)
            show_status
            ;;
        switch)
            local target="$2"
            if [ -n "$target" ]; then
                switch_interface "$target"
            else
                echo "用法: $0 switch [接口名]"
                echo "可用接口:"
                get_configured_interfaces
            fi
            ;;
        daemon)
            run_daemon
            ;;
        test)
            test_connectivity
            ;;
        interfaces)
            get_available_interfaces
            ;;
        configured_interfaces)
            get_configured_interfaces
            ;;
        clear_log)
            clear_log
            ;;
        current_interface)
            get_current_internet_interface
            ;;
        primary_interface)
            get_primary_interface
            ;;
        *)
            echo "网络切换器 - OpenWrt插件版 v1.2.0"
            echo ""
            echo "用法: $0 [命令]"
            echo ""
            echo "服务控制:"
            echo "  start        - 启动服务"
            echo "  stop         - 停止服务"
            echo "  restart      - 重启服务"
            echo "  status       - 服务状态"
            echo ""
            echo "网络操作:"
            echo "  auto         - 自动切换"
            echo "  switch [接口] - 手动切换到指定接口"
            echo "  test         - 测试连通性"
            echo ""
            echo "其他:"
            echo "  daemon       - 守护进程模式"
            echo "  interfaces   - 获取可用接口列表"
            echo "  configured_interfaces - 获取已配置接口列表"
            echo "  current_interface - 获取当前互联网出口接口"
            echo "  primary_interface - 获取主接口"
            echo "  clear_log    - 清空日志"
            echo ""
            echo "配置: 通过LuCI界面或编辑 /etc/config/network_switcher"
            ;;
    esac
}

# 执行主函数
main "$@"

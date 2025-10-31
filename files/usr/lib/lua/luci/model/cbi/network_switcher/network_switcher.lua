m = Map("network_switcher", translate("Network Switcher Configuration"), 
    translate("An intelligent network interface switcher with automatic failover between WAN and WWAN interfaces."))

-- 全局设置
s = m:section(TypedSection, "settings", translate("Global Settings"))
s.anonymous = true

enabled = s:option(Flag, "enabled", translate("Enable"), translate("Enable the network switcher service"))
enabled.default = "0"

auto_mode = s:option(Flag, "auto_mode", translate("Auto Mode"), 
    translate("Enable automatic switching based on network connectivity"))
auto_mode.default = "1"

check_interval = s:option(Value, "check_interval", translate("Check Interval"), 
    translate("Interval in seconds between network checks"))
check_interval.datatype = "uinteger"
check_interval.default = "60"

ping_targets = s:option(Value, "ping_targets", translate("Ping Targets"), 
    translate("IP addresses to test connectivity, separated by spaces"))
ping_targets.default = "8.8.8.8 1.1.1.1 223.5.5.5"

ping_count = s:option(Value, "ping_count", translate("Ping Count"), 
    translate("Number of ping packets to send for each test"))
ping_count.datatype = "range(1,10)"
ping_count.default = "3"

ping_timeout = s:option(Value, "ping_timeout", translate("Ping Timeout"), 
    translate("Timeout in seconds for each ping attempt"))
ping_timeout.datatype = "range(1,10)"
ping_timeout.default = "3"

switch_wait_time = s:option(Value, "switch_wait_time", translate("Switch Wait Time"), 
    translate("Time to wait after switching before verification"))
switch_wait_time.datatype = "range(1,10)"
switch_wait_time.default = "3"

-- WAN接口配置
wan_s = m:section(TypedSection, "wan", translate("Primary Interface (WAN) Settings"))
wan_s.anonymous = true

wan_enabled = wan_s:option(Flag, "enabled", translate("Enable"), translate("Enable WAN interface"))
wan_enabled.default = "1"

wan_interface = wan_s:option(Value, "interface", translate("Interface Name"), 
    translate("Name of the WAN interface (e.g., wan)"))
wan_interface.default = "wan"

wan_metric = wan_s:option(Value, "metric", translate("Route Metric"), 
    translate("Routing metric (lower value = higher priority)"))
wan_metric.datatype = "uinteger"
wan_metric.default = "10"

-- WWAN接口配置
wwan_s = m:section(TypedSection, "wwan", translate("Backup Interface (WWAN) Settings"))
wwan_s.anonymous = true

wwan_enabled = wwan_s:option(Flag, "enabled", translate("Enable"), translate("Enable WWAN interface"))
wwan_enabled.default = "1"

wwan_interface = wwan_s:option(Value, "interface", translate("Interface Name"), 
    translate("Name of the WWAN interface (e.g., wwan)"))
wwan_interface.default = "wwan"

wwan_metric = wwan_s:option(Value, "metric", translate("Route Metric"), 
    translate("Routing metric (lower value = higher priority)"))
wwan_metric.datatype = "uinteger"
wwan_metric.default = "20"

-- 操作按钮部分
local actions_s = m:section(TypedSection, "_actions", translate("Quick Actions"))
actions_s.anonymous = true

local status_btn = actions_s:option(Button, "_status", translate("Current Status"))
status_btn.inputtitle = translate("Refresh Status")
status_btn.inputstyle = "apply"
function status_btn.write()
    -- 状态通过AJAX获取，这里只是刷新页面
end

local test_btn = actions_s:option(Button, "_test", translate("Test Connectivity"))
test_btn.inputtitle = translate("Run Test")
test_btn.inputstyle = "apply"
function test_btn.write()
    -- 测试通过AJAX执行
end

local switch_wan_btn = actions_s:option(Button, "_switch_wan", translate("Switch to WAN"))
switch_wan_btn.inputtitle = translate("Switch Now")
switch_wan_btn.inputstyle = "apply"
function switch_wan_btn.write()
    -- 切换通过AJAX执行
end

local switch_wwan_btn = actions_s:option(Button, "_switch_wwan", translate("Switch to WWAN"))
switch_wwan_btn.inputtitle = translate("Switch Now")
switch_wwan_btn.inputstyle = "apply"
function switch_wwan_btn.write()
    -- 切换通过AJAX执行
end

return m

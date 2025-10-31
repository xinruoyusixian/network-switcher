m = Map("network_switcher", translate("Network Switcher Configuration"), 
    translate("An intelligent network interface switcher with automatic failover and schedule support."))

-- 服务控制部分
local service_s = m:section(TypedSection, "_service", translate("Service Control"))
service_s.anonymous = true

local service_status = service_s:option(DummyValue, "_status", translate("Service Status"))
service_status.template = "network_switcher/service_status"

-- 全局设置
s = m:section(TypedSection, "settings", translate("Global Settings"))
s.anonymous = true
s.addremove = false

enabled = s:option(Flag, "enabled", translate("Enable Service"), 
    translate("Enable the network switcher service"))
enabled.default = "0"

operation_mode = s:option(ListValue, "operation_mode", translate("Operation Mode"), 
    translate("Select the operation mode"))
operation_mode:value("auto", translate("Auto Mode (Failover)"))
operation_mode:value("manual", translate("Manual Mode"))
operation_mode.default = "auto"

check_interval = s:option(Value, "check_interval", translate("Check Interval (seconds)"), 
    translate("Interval in seconds between network checks (auto mode only)"))
check_interval.datatype = "uinteger"
check_interval.default = "60"
check_interval.placeholder = "60"
check_interval:depends("operation_mode", "auto")

-- 网络测试设置
local test_title = s:option(DummyValue, "test_settings", translate("Network Test Settings"))
test_title.default = ""

ping_targets = s:option(DynamicList, "ping_targets", translate("Ping Targets"), 
    translate("IP addresses to test connectivity (one per line)"))
ping_targets.default = "8.8.8.8 1.1.1.1 223.5.5.5 114.114.114.114"
ping_targets.placeholder = "8.8.8.8"

ping_count = s:option(Value, "ping_count", translate("Ping Count"), 
    translate("Number of ping packets to send for each test (1-10)"))
ping_count.datatype = "range(1,10)"
ping_count.default = "3"
ping_count.placeholder = "3"

ping_timeout = s:option(Value, "ping_timeout", translate("Ping Timeout (seconds)"), 
    translate("Timeout in seconds for each ping attempt (1-10)"))
ping_timeout.datatype = "range(1,10)"
ping_timeout.default = "3"
ping_timeout.placeholder = "3"

switch_wait_time = s:option(Value, "switch_wait_time", translate("Switch Wait Time (seconds)"), 
    translate("Time to wait after switching before verification (1-10)"))
switch_wait_time.datatype = "range(1,10)"
switch_wait_time.default = "3"
switch_wait_time.placeholder = "3"

-- 获取可用接口
local uci = require("luci.model.uci").cursor()
local interface_list = { "wan", "wwan" }

-- 从网络配置获取更多接口
uci:foreach("network", "interface",
    function(section)
        if section[".name"] ~= "loopback" and section[".name"] ~= "wan" and section[".name"] ~= "wwan" then
            table.insert(interface_list, section[".name"])
        end
    end
)

-- 接口配置部分
interfaces_s = m:section(TypedSection, "interface", translate("Interface Configuration"),
    translate("Configure network interfaces for switching. Interfaces are used in priority order (lower metric = higher priority)."))
interfaces_s.anonymous = true
interfaces_s.addremove = true
interfaces_s.template = "cbi/tblsection"

enabled = interfaces_s:option(Flag, "enabled", translate("Enable"))
enabled.default = "1"

iface_name = interfaces_s:option(ListValue, "interface", translate("Interface"))
for _, iface in ipairs(interface_list) do
    iface_name:value(iface, iface)
end

metric = interfaces_s:option(Value, "metric", translate("Priority"), 
    translate("Lower value = higher priority (1-999)"))
metric.datatype = "range(1,999)"
metric.default = "10"

-- 定时任务配置
schedule_s = m:section(TypedSection, "schedule", translate("Schedule Settings"),
    translate("Configure scheduled interface switching. Format: HH:MM for times, interface names or 'auto' for targets."))
schedule_s.anonymous = true
schedule_s.addremove = false

schedule_enabled = schedule_s:option(Flag, "enabled", translate("Enable Schedule"), 
    translate("Enable scheduled switching"))
schedule_enabled.default = "0"

schedule_times = schedule_s:option(DynamicList, "times", translate("Schedule Times"), 
    translate("Switch times in HH:MM format (one per line)"))
schedule_times.default = "08:00 18:00"
schedule_times.placeholder = "08:00"

schedule_targets = schedule_s:option(DynamicList, "targets", translate("Switch Targets"), 
    translate("Target interface for each time, use 'auto' for auto mode"))
schedule_targets.default = "auto wwan"
schedule_targets.placeholder = "auto"

-- 快速操作部分
local actions_s = m:section(TypedSection, "_actions", translate("Quick Actions"))
actions_s.anonymous = true

local status_btn = actions_s:option(Button, "_status", translate("Current Status"))
status_btn.inputtitle = translate("Refresh Status")
status_btn.inputstyle = "apply"
function status_btn.write()
    luci.http.redirect(luci.dispatcher.build_url("admin/services/network_switcher/overview"))
end

local test_btn = actions_s:option(Button, "_test", translate("Test Connectivity"))
test_btn.inputtitle = translate("Run Test Now")
test_btn.inputstyle = "apply"
function test_btn.write()
    luci.http.redirect(luci.dispatcher.build_url("admin/services/network_switcher/overview"))
end

return m

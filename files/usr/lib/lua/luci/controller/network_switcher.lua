m = Map("network_switcher", "网络切换器配置", 
    "一个智能的网络接口切换器，支持自动故障切换和定时切换功能。")

-- 服务控制部分
local service_s = m:section(TypedSection, "_service", "服务控制")
service_s.anonymous = true

-- 全局设置
s = m:section(TypedSection, "settings", "全局设置")
s.anonymous = true
s.addremove = false

enabled = s:option(Flag, "enabled", "启用服务", 
    "启用网络切换器服务")
enabled.default = "0"

operation_mode = s:option(ListValue, "operation_mode", "运行模式", 
    "选择运行模式")
operation_mode:value("auto", "自动模式 (故障切换)")
operation_mode:value("manual", "手动模式")
operation_mode.default = "auto"

check_interval = s:option(Value, "check_interval", "检查间隔(秒)", 
    "网络检查的时间间隔(仅自动模式)")
check_interval.datatype = "uinteger"
check_interval.default = "60"
check_interval.placeholder = "60"
check_interval:depends("operation_mode", "auto")

-- 网络测试设置
local test_title = s:option(DummyValue, "test_settings", "网络测试设置")
test_title.default = ""

ping_targets = s:option(DynamicList, "ping_targets", "Ping目标", 
    "用于测试连通性的IP地址(每行一个)")
ping_targets.default = "8.8.8.8 1.1.1.1 223.5.5.5 114.114.114.114"
ping_targets.placeholder = "8.8.8.8"

ping_count = s:option(Value, "ping_count", "Ping次数", 
    "每次测试发送的ping包数量(1-10)")
ping_count.datatype = "range(1,10)"
ping_count.default = "3"
ping_count.placeholder = "3"

ping_timeout = s:option(Value, "ping_timeout", "Ping超时(秒)", 
    "每次ping尝试的超时时间(1-10)")
ping_timeout.datatype = "range(1,10)"
ping_timeout.default = "3"
ping_timeout.placeholder = "3"

switch_wait_time = s:option(Value, "switch_wait_time", "切换等待时间(秒)", 
    "切换后验证前的等待时间(1-10)")
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
interfaces_s = m:section(TypedSection, "interface", "接口配置",
    "配置网络接口用于切换。接口按优先级顺序使用(metric值越小优先级越高)。")
interfaces_s.anonymous = true
interfaces_s.addremove = true
interfaces_s.template = "cbi/tblsection"

enabled = interfaces_s:option(Flag, "enabled", "启用")
enabled.default = "1"

iface_name = interfaces_s:option(ListValue, "interface", "接口名称")
for _, iface in ipairs(interface_list) do
    iface_name:value(iface, iface)
end

metric = interfaces_s:option(Value, "metric", "优先级", 
    "metric值越小优先级越高(1-999)")
metric.datatype = "range(1,999)"
metric.default = "10"

-- 定时任务配置
schedule_s = m:section(TypedSection, "schedule", "定时任务设置",
    "配置定时接口切换。时间格式: HH:MM，目标可以是接口名称或'auto'。")
schedule_s.anonymous = true
schedule_s.addremove = false

schedule_enabled = schedule_s:option(Flag, "enabled", "启用定时任务", 
    "启用定时切换功能")
schedule_enabled.default = "0"

schedule_times = schedule_s:option(DynamicList, "times", "定时时间", 
    "切换时间，HH:MM格式(每行一个)")
schedule_times.default = "08:00 18:00"
schedule_times.placeholder = "08:00"

schedule_targets = schedule_s:option(DynamicList, "targets", "切换目标", 
    "每个时间对应的目标接口，使用'auto'表示自动模式")
schedule_targets.default = "auto wwan"
schedule_targets.placeholder = "auto"

-- 快速操作部分
local actions_s = m:section(TypedSection, "_actions", "快速操作")
actions_s.anonymous = true

local status_btn = actions_s:option(Button, "_status", "当前状态")
status_btn.inputtitle = "刷新状态"
status_btn.inputstyle = "apply"
function status_btn.write()
    luci.http.redirect(luci.dispatcher.build_url("admin/services/network_switcher/overview"))
end

local test_btn = actions_s:option(Button, "_test", "测试连通性")
test_btn.inputtitle = "立即测试"
test_btn.inputstyle = "apply"
function test_btn.write()
    luci.http.redirect(luci.dispatcher.build_url("admin/services/network_switcher/overview"))
end

return m

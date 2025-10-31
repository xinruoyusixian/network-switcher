local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

m = Map("network_switcher", "网络切换器配置", 
    "一个智能的网络接口切换器，支持自动故障切换和定时切换功能。")

-- 全局设置
s = m:section(TypedSection, "settings", "全局设置")
s.anonymous = true
s.addremove = false

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
s:option(DummyValue, "test_settings", "网络测试设置")

ping_target1 = s:option(Value, "ping_target1", "Ping目标 1", "第一个测试目标IP")
ping_target1.default = "8.8.8.8"
ping_target1.placeholder = "8.8.8.8"

ping_target2 = s:option(Value, "ping_target2", "Ping目标 2", "第二个测试目标IP")
ping_target2.default = "1.1.1.1"
ping_target2.placeholder = "1.1.1.1"

ping_target3 = s:option(Value, "ping_target3", "Ping目标 3", "第三个测试目标IP")
ping_target3.default = "223.5.5.5"
ping_target3.placeholder = "223.5.5.5"

ping_target4 = s:option(Value, "ping_target4", "Ping目标 4", "第四个测试目标IP")
ping_target4.default = "114.114.114.114"
ping_target4.placeholder = "114.114.114.114"

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
schedule_times.default = "08:00"
schedule_times.placeholder = "08:00"

-- 获取目标接口列表（包括auto选项）
local target_list = {"auto"}
for _, iface in ipairs(interface_list) do
    table.insert(target_list, iface)
end

schedule_targets = schedule_s:option(DynamicList, "targets", "切换目标", 
    "每个时间对应的目标接口，使用'auto'表示自动模式")
schedule_targets.default = "auto"
schedule_targets.placeholder = "auto"
for _, target in ipairs(target_list) do
    schedule_targets:value(target, target)
end

-- 保存前处理函数，将单个ping目标合并为列表
function m.on_commit(self)
    local ping_targets = {}
    local target1 = ping_target1:formvalue("settings") or "8.8.8.8"
    local target2 = ping_target2:formvalue("settings") or "1.1.1.1"
    local target3 = ping_target3:formvalue("settings") or "223.5.5.5"
    local target4 = ping_target4:formvalue("settings") or "114.114.114.114"
    
    if target1 and target1 ~= "" then table.insert(ping_targets, target1) end
    if target2 and target2 ~= "" then table.insert(ping_targets, target2) end
    if target3 and target3 ~= "" then table.insert(ping_targets, target3) end
    if target4 and target4 ~= "" then table.insert(ping_targets, target4) end
    
    uci:set("network_switcher", "settings", "ping_targets", table.concat(ping_targets, " "))
    uci:commit("network_switcher")
end

return m

-- 文件: files/usr/lib/lua/luci/model/cbi/network_switcher/network_switcher.lua
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

m = Map("network_switcher", "网络切换器配置", 
    "一个智能的网络接口切换器，支持自动故障切换和定时切换功能。")

-- 全局设置
s = m:section(TypedSection, "settings", "全局设置")
s.anonymous = true
s.addremove = false

check_interval = s:option(Value, "check_interval", "检查间隔(秒)", 
    "网络检查的时间间隔")
check_interval.datatype = "uinteger"
check_interval.default = "60"
check_interval.placeholder = "60"

-- 网络测试设置
s:option(DummyValue, "test_settings", "网络测试设置")

-- 使用DynamicList作为Ping目标
ping_targets = s:option(DynamicList, "ping_targets", "Ping目标", 
    "用于测试连通性的IP地址(每行一个，可点击+号添加)")
ping_targets.default = {"8.8.8.8", "1.1.1.1", "223.5.5.5"}
ping_targets.placeholder = "8.8.8.8"

-- 添加Ping成功次数选项
ping_success_count = s:option(Value, "ping_success_count", "Ping成功次数", 
    "需要成功Ping通的目标数量才认为网络正常(默认1)")
ping_success_count.datatype = "uinteger"
ping_success_count.default = "1"
ping_success_count.placeholder = "1"

ping_count = s:option(Value, "ping_count", "Ping次数", 
    "对每个目标发送的ping包数量(1-10)")
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
local interface_list = { "wan" }

-- 从网络配置获取更多接口（排除loopback）
uci:foreach("network", "interface",
    function(section)
        if section[".name"] ~= "loopback" and section[".name"] ~= "wan" then
            table.insert(interface_list, section[".name"])
        end
    end
)

-- 接口配置部分
interfaces_s = m:section(TypedSection, "interface", "接口配置",
    "配置网络接口用于切换。接口按优先级顺序使用(metric值越小优先级越高)。设置主接口用于自动切换的默认选择。")
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

-- 添加主接口选项
primary = interfaces_s:option(Flag, "primary", "主接口", 
    "设置为主接口，自动切换时优先使用")
primary.default = "0"

-- 处理主接口设置，确保只有一个主接口
function primary.write(self, section, value)
    -- 如果设置为1，先清除其他接口的主接口设置
    if value == "1" then
        uci:foreach("network_switcher", "interface", 
            function(s)
                if s[".name"] ~= section then
                    uci:set("network_switcher", s[".name"], "primary", "0")
                end
            end)
    end
    Flag.write(self, section, value)
end

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

-- 设置默认接口配置
function m.on_after_commit(self)
    -- 检查是否已经有接口配置
    local has_interfaces = false
    uci:foreach("network_switcher", "interface",
        function(section)
            has_interfaces = true
        end
    )
    
    -- 如果没有接口配置，创建默认的wan接口
    if not has_interfaces then
        uci:section("network_switcher", "interface", "wan", {
            enabled = "1",
            interface = "wan",
            metric = "10",
            primary = "1"
        })
        uci:commit("network_switcher")
    end
end

return m

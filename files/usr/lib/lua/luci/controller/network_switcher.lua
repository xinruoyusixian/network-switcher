module("luci.controller.network_switcher", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/network_switcher") then
        return
    end
    
    entry({"admin", "services", "network_switcher"}, firstchild(), "网络切换器", 60).dependent = false
    entry({"admin", "services", "network_switcher", "overview"}, template("network_switcher/overview"), "概览", 1)
    entry({"admin", "services", "network_switcher", "settings"}, cbi("network_switcher/network_switcher"), "设置", 2)
    entry({"admin", "services", "network_switcher", "log"}, template("network_switcher/log"), "日志", 3)
    
    -- AJAX 接口
    entry({"admin", "services", "network_switcher", "status"}, call("action_status"))
    entry({"admin", "services", "network_switcher", "switch"}, call("action_switch"))
    entry({"admin", "services", "network_switcher", "test"}, call("action_test"))
    entry({"admin", "services", "network_switcher", "get_log"}, call("action_get_log"))
    entry({"admin", "services", "network_switcher", "service_control"}, call("action_service_control"))
    entry({"admin", "services", "network_switcher", "clear_log"}, call("action_clear_log"))
    entry({"admin", "services", "network_switcher", "get_interfaces"}, call("action_get_interfaces"))
    entry({"admin", "services", "network_switcher", "get_configured_interfaces"}, call("action_get_configured_interfaces"))
    entry({"admin", "services", "network_switcher", "get_current_interface"}, call("action_get_current_interface"))
end

function action_status()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local response = {}
    
    -- 获取服务状态
    local service_output = sys.exec("/usr/bin/network_switcher status 2>/dev/null | head -1")
    if service_output:match("运行中") then
        response.service = "running"
    else
        response.service = "stopped"
    end
    
    -- 执行状态检查
    local status_output = sys.exec("/usr/bin/network_switcher status 2>/dev/null")
    response.status_output = status_output
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_switch()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local interface = lucihttp.formvalue("interface")
    local response = {}
    
    if interface then
        -- 实时执行并获取输出
        local command = interface == "auto" and "auto" or "switch " .. interface
        local handle = io.popen("/usr/bin/network_switcher " .. command .. " 2>&1")
        local result = handle:read("*a")
        handle:close()
        
        response.success = true
        response.message = result
    else
        response.success = false
        response.message = "无效的接口"
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_test()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    -- 实时执行测试
    local handle = io.popen("/usr/bin/network_switcher test 2>&1")
    local result = handle:read("*a")
    handle:close()
    
    local response = {
        success = true,
        output = result
    }
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_get_log()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    local nixio = require("nixio")
    
    local log_content = ""
    local log_file = "/var/log/network_switcher.log"
    
    if nixio.fs.access(log_file) then
        log_content = sys.exec("tail -n 100 " .. log_file)
    else
        log_content = "日志文件不存在或为空"
    end
    
    lucihttp.prepare_content("text/plain")
    lucihttp.write(log_content)
end

function action_service_control()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local action = lucihttp.formvalue("action")
    local response = {}
    
    if action == "start" or action == "stop" or action == "restart" then
        local result = sys.exec("/usr/bin/network_switcher " .. action .. " 2>&1")
        response.success = true
        response.message = result
    else
        response.success = false
        response.message = "无效的操作"
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_clear_log()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local result = sys.exec("/usr/bin/network_switcher clear_log 2>&1")
    local response = {
        success = true,
        message = result
    }
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_get_interfaces()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local interfaces = sys.exec("/usr/bin/network_switcher interfaces 2>/dev/null")
    local interface_list = {}
    
    for line in interfaces:gmatch("[^\r\n]+") do
        if line ~= "" then
            table.insert(interface_list, line)
        end
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(interface_list)
end

function action_get_configured_interfaces()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local interfaces = sys.exec("/usr/bin/network_switcher configured_interfaces 2>/dev/null")
    local interface_list = {}
    
    for line in interfaces:gmatch("[^\r\n]+") do
        if line ~= "" and line ~= "wan" then  -- 过滤掉空行和重复的wan
            table.insert(interface_list, line)
        end
    end
    
    -- 确保至少包含wan接口
    local has_wan = false
    for _, iface in ipairs(interface_list) do
        if iface == "wan" then
            has_wan = true
            break
        end
    end
    
    if not has_wan then
        table.insert(interface_list, 1, "wan")
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(interface_list)
end

function action_get_current_interface()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local current_interface = sys.exec("/usr/bin/network_switcher current_interface 2>/dev/null")
    
    lucihttp.prepare_content("text/plain")
    lucihttp.write(current_interface)
end

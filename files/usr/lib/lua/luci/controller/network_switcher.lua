module("luci.controller.network_switcher", package.seeall)

function index()
    entry({"admin", "services", "network_switcher"}, firstchild(), _("Network Switcher"), 60).dependent = false
    entry({"admin", "services", "network_switcher", "overview"}, template("network_switcher/overview"), _("Overview"), 1)
    entry({"admin", "services", "network_switcher", "settings"}, cbi("network_switcher/network_switcher"), _("Settings"), 2)
    entry({"admin", "services", "network_switcher", "log"}, template("network_switcher/log"), _("Log"), 3)
    
    -- AJAX 接口
    entry({"admin", "services", "network_switcher", "status"}, call("action_status"))
    entry({"admin", "services", "network_switcher", "switch"}, call("action_switch"))
    entry({"admin", "services", "network_switcher", "test"}, call("action_test"))
    entry({"admin", "services", "network_switcher", "get_log"}, call("action_get_log"))
    entry({"admin", "services", "network_switcher", "service_control"}, call("action_service_control"))
end

function action_status()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    local uci = require("luci.model.uci").cursor()
    
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
        local handle = io.popen("/usr/bin/network_switcher switch " .. interface .. " 2>&1")
        local result = handle:read("*a")
        handle:close()
        
        response.success = true
        response.message = result
    else
        response.success = false
        response.message = "Invalid interface"
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
        log_content = "Log file not found or empty"
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
        response.message = "Invalid action"
    end
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

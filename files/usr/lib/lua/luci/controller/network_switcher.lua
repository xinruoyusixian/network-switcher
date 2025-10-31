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
end

function action_status()
    local lucihttp = require("luci.http")
    local uci = require("luci.model.uci").cursor()
    local sys = require("luci.sys")
    
    local response = {}
    
    -- 获取服务状态
    response.service = sys.init.enabled("network_switcher") and "running" or "stopped"
    
    -- 执行状态检查
    local status_output = sys.exec("/usr/bin/network_switcher status 2>/dev/null")
    response.status_output = status_output
    
    -- 获取当前配置
    response.config = {
        enabled = uci:get("network_switcher", "settings", "enabled") or "0",
        auto_mode = uci:get("network_switcher", "settings", "auto_mode") or "1",
        check_interval = uci:get("network_switcher", "settings", "check_interval") or "60"
    }
    
    lucihttp.prepare_content("application/json")
    lucihttp.write_json(response)
end

function action_switch()
    local lucihttp = require("luci.http")
    local sys = require("luci.sys")
    
    local interface = lucihttp.formvalue("interface")
    local response = {}
    
    if interface == "wan" or interface == "wwan" then
        local result = sys.exec("/usr/bin/network_switcher switch " .. interface .. " 2>&1")
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
    
    local result = sys.exec("/usr/bin/network_switcher test 2>&1")
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
        log_content = sys.exec("tail -n 50 " .. log_file)
    else
        log_content = "Log file not found"
    end
    
    lucihttp.prepare_content("text/plain")
    lucihttp.write(log_content)
end

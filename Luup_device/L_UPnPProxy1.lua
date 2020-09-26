--
-- UPnP Event Proxy plugin
-- Copyright (C) 2013 Deborah Pickett
--
-- Version 0.0 2013-04-14 by Deborah Pickett
--
-- Minor mods by A-Lurker 26 Sept 2020

module ("L_UPnPProxy1", package.seeall)

local PLUGIN_NAME     = 'UPnPProxy'
local PLUGIN_SID      = 'urn:futzle-com:serviceId:'..PLUGIN_NAME..'1'
local PLUGIN_VERSION  = '0.52'
local THIS_LUL_DEVICE = nil

local initScriptPath = "/etc/init.d/upnp-proxy-daemon"
local taskHandle = -1

local http  = require("socket.http")
local ltn12 = require("ltn12")

-- Extend luup.variable_set() with variableSet()
local function variableSet (k, v)
    --luup.log (k..' = '..tostring(v),50)
    luup.variable_set(PLUGIN_SID, k, v, THIS_LUL_DEVICE)
end

local initScript = [=[#!/bin/sh /etc/rc.common
# Copyright (C) 2007 OpenWrt.org
START=80
PID_FILE=/var/run/upnp-event-proxy.pid
PROXY_DAEMON=/tmp/upnp-event-proxy.lua
start() {
	if [ -f "$PID_FILE" ]; then
		# May already be running.
		PID=$(cat "$PID_FILE")
		if [ -d "/proc/$PID" ]; then
			COMMAND=$(readlink "/proc/$PID/exe")
			if [ "$COMMAND" = "/usr/bin/lua" ]; then
				echo "Daemon is already running"
				return 1
			fi
		fi
	fi
	# Find and decompress the proxy daemon Lua source.
	if [ -f /etc/cmh-ludl/L_UPnPProxyDaemon.lua.lzo ]; then
		PROXY_DAEMON_LZO=/etc/cmh-ludl/L_UPnPProxyDaemon.lua.lzo
	elif [ -f /etc/cmh-lu/L_UPnPProxyDaemon.lua.lzo ]; then
		PROXY_DAEMON_LZO=/etc/cmh-lu/L_UPnPProxyDaemon.lua.lzo
	fi
	if [ -n "$PROXY_DAEMON_LZO" ]; then
		/usr/bin/pluto-lzo d "$PROXY_DAEMON_LZO" /tmp/upnp-event-proxy.lua
	fi
	# Close file descriptors.
	for fd in /proc/self/fd/*; do
		fd=${fd##*/}
		case $fd in
			0|1|2) ;;
			*) eval "exec $fd<&-"
		esac
	done
	# Run daemon.
	/usr/bin/lua "$PROXY_DAEMON" </dev/null >/dev/null 2>&1 &
	echo "$!" > "$PID_FILE"
}
stop() {
	if [ -f "$PID_FILE" ]; then
		PID=$(cat "$PID_FILE")
		if [ -d "/proc/$PID" ]; then
			COMMAND=$(readlink "/proc/$PID/exe")
			if [ "$COMMAND" = "/usr/bin/lua" ]; then
				/bin/kill -KILL "$PID" && /bin/rm "$PID_FILE"
				return 0
			fi
		fi
	fi
	echo "Daemon is not running"
	return 1
}
]=]

local function task(message, mode)
    taskHandle = luup.task(message, mode, string.format("%s[%d]", luup.devices[THIS_LUL_DEVICE].description, THIS_LUL_DEVICE), taskHandle)
end

local function createInitScript()
    task("Creating init script", 1)
    local f = io.open(initScriptPath, "w")
    f:write(initScript)
    f:close()
    task("Created init script", 4)
    task("Making init script executable", 1)
    os.execute("chmod +x " .. initScriptPath)
    task("Made init script executable", 4)
    task("Enabling init script", 1)
    os.execute(initScriptPath .. " enable")
    task("Enabled init script", 4)
    task("Starting init script", 1)
    os.execute(initScriptPath .. " start")
    task("Started init script", 4)
end

-- This is a time out target; function needs to be global
function updateProxyVersion()
    -- Get API version.
    task("Checking that proxy is running", 1)
    local ProxyApiVersion
    local t = {}
    local request, code = http.request({
        url = "http://localhost:2529/version",
        sink = ltn12.sink.table(t)
    })

    if (request == nil and code == "timeout") then
        task("Checking that proxy is running (retrying)", 1)
        luup.call_delay("updateProxyVersion", 5, "")
        return
    elseif (request == nil and code ~= "closed") then
        -- Proxy not running.
        task("Proxy is not running", 4)
        variableSet("Status", 0)
        variableSet("StatusText", "Not Running")
    else
        -- Proxy is running, note its version number.
        task("Proxy is running", 4)
        ProxyApiVersion = table.concat(t)
        variableSet("Status", 1)
        variableSet("StatusText", "Running")
        variableSet("API", ProxyApiVersion)
    end

    -- Check again in a while.
    luup.call_delay("updateProxyVersion", 400, "")
end

-- This is a time out target; function needs to be global
function restartNeeded(message)
    task(message, 2)
end

function uninstall(lul_device)
    local f = io.open(initScriptPath, "r")
    if (f) then
        -- File exists.
        f:close()
        task("Stopping init script", 1)
        os.execute(initScriptPath .. " stop")
        task("Stopped init script", 4)
        task("Disabling init script", 1)
        os.execute(initScriptPath .. " disable")
        task("Disabling init script", 4)
        task("Removing init script", 1)
        os.execute("rm " .. initScriptPath)
        task("Removed init script", 4)
        task("Delete the UPnP Event Proxy device, then reload Luup engine.", 1)
    end
end

-- Let's do it
-- Function must be global
function initialize(lul_device)
    THIS_LUL_DEVICE = lul_device

    luup.log('Heliotrope start',50)

    -- set up some defaults:
    variableSet('PluginVersion', PLUGIN_VERSION)

    -- Create the init script in /etc/init.d/upnp-proxy-daemon.
    local f = io.open(initScriptPath, "r")
    if (f) then
        -- File already exists.
        if (f:read("*a") == initScript) then
            luup.log("Init script unchanged.")
            f:close()
        else
            luup.log("Init script different; will be recreated.")
            f:close()
            task("Stopping init script", 1)
            os.execute(initScriptPath .. " stop")
            task("Stopped init script", 4)
            createInitScript()
            luup.call_delay("restartNeeded", 1, "Restart Luup engine to complete installation")
            return true
        end
    else
        luup.log("Init script absent; will be created.")
        createInitScript()
        luup.call_delay("restartNeeded", 1, "Restart Luup engine to complete installation")
        return true
    end

    -- Proxy should be running now.

    luup.call_delay("updateProxyVersion", 1, "")
    return true
end

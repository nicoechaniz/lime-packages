#!/usr/bin/lua

network = {}

local bit = require("bit")
local ip = require("luci.ip")
local libuci = require("uci")
local fs = require("nixio.fs")

local config = require("lime.config")
local utils = require("lime.utils")

network.limeIfNamePrefix="lm_"
network.protoParamsSeparator=":"
network.protoVlanSeparator="-"

function network.get_mac(ifname)
	local mac = assert(fs.readfile("/sys/class/net/"..ifname.."/address")):gsub("\n","")
	return utils.split(mac, ":")
end

function network.primary_interface()
	return config.get("network", "primary_interface")
end

function network.primary_mac()
	return network.get_mac(network.primary_interface())
end

function network.generate_host(ipprefix, hexsuffix)
    -- use only the 8 rightmost nibbles for IPv4, or 32 nibbles for IPv6
    hexsuffix = hexsuffix:sub((ipprefix[1] == 4) and -8 or -32)

    -- convert hexsuffix into a cidr instance, using same prefix and family of ipprefix
    local ipsuffix = ip.Hex(hexsuffix, ipprefix:prefix(), ipprefix[1])

    local ipaddress = ipprefix
    -- if it's a network prefix, fill in host bits with ipsuffix
    if ipprefix:equal(ipprefix:network()) then
        for i in ipairs(ipprefix[2]) do
            -- reset ipsuffix netmask bits to 0
            ipsuffix[2][i] = bit.bxor(ipsuffix[2][i],ipsuffix:network()[2][i])
            -- fill in ipaddress host part, with ipsuffix bits
            ipaddress[2][i] = bit.bor(ipaddress[2][i],ipsuffix[2][i])
        end
    end

    return ipaddress
end

function network.primary_address(offset)
    local offset = offset or 0
    local pm = network.primary_mac()
    local ipv4_template = config.get("network", "main_ipv4_address")
    local ipv6_template = config.get("network", "main_ipv6_address")

    ipv4_template = utils.applyMacTemplate10(ipv4_template, pm)
    ipv6_template = utils.applyMacTemplate16(ipv6_template, pm)

    ipv4_template = utils.applyNetTemplate10(ipv4_template)
    ipv6_template = utils.applyNetTemplate16(ipv6_template)

    local m4, m5, m6 = tonumber(pm[4], 16), tonumber(pm[5], 16), tonumber(pm[6], 16)
    local hexsuffix = utils.hex((m4 * 256*256 + m5 * 256 + m6) + offset)
    return network.generate_host(ip.IPv4(ipv4_template), hexsuffix),
           network.generate_host(ip.IPv6(ipv6_template), hexsuffix)
end

function network.setup_rp_filter()
	local sysctl_file_path = "/etc/sysctl.conf";
	local sysctl_options = "";
	local sysctl_file = io.open(sysctl_file_path, "r");
	while sysctl_file:read(0) do
		local sysctl_line = sysctl_file:read();
		if not string.find(sysctl_line, ".rp_filter") then sysctl_options = sysctl_options .. sysctl_line .. "\n" end 
	end
	sysctl_file:close()
	
	sysctl_options = sysctl_options .. "net.ipv4.conf.default.rp_filter=2\nnet.ipv4.conf.all.rp_filter=2\n";
	sysctl_file = io.open(sysctl_file_path, "w");
	sysctl_file:write(sysctl_options);
	sysctl_file:close();
end

function network.setup_dns()
	local content = {}
	for _,server in pairs(config.get("network", "resolvers")) do
		table.insert(content, server)
	end
	local uci = libuci:cursor()
	uci:foreach("dhcp", "dnsmasq", function(s) uci:set("dhcp", s[".name"], "server", content) end)
	uci:save("dhcp")
	fs.writefile("/etc/dnsmasq.conf", "conf-dir=/etc/dnsmasq.d\n")
	fs.mkdir("/etc/dnsmasq.d")
end

function network.clean()
	print("Clearing network config...")

	local uci = libuci:cursor()

	uci:delete("network", "globals", "ula_prefix")

	-- Delete interfaces and devices generated by LiMe
	uci:foreach("network", "interface", function(s) if s[".name"]:match(network.limeIfNamePrefix) then uci:delete("network", s[".name"]) end end)
	uci:foreach("network", "device", function(s) if s[".name"]:match(network.limeIfNamePrefix) then uci:delete("network", s[".name"]) end end)
	uci:save("network")

	print("Disabling odhcpd")
	io.popen("/etc/init.d/odhcpd disable || true"):close()

	print("Cleaning dnsmasq")
	uci:foreach("dhcp", "dnsmasq", function(s) uci:delete("dhcp", s[".name"], "server") end)
	uci:save("dhcp")

	print("Disabling 6relayd...")
	fs.writefile("/etc/config/6relayd", "")
end

function network.get_lan_devices()
	local devices = {}
	local uci = libuci:cursor()

	-- Look for ethernet interfaces that are already in "lan", put by a human
	-- or by openwrt scripts
	local lan_ifnames = uci:get("network", "lan", "ifname") or {}
	 -- convert "option" string into "list" table
	if type(lan_ifnames) == "string" then lan_ifnames = utils.split(lan_ifnames, " ") end
	
	for _,ifname in pairs(lan_ifnames) do
		if ifname:match("^eth%d") and not ifname:match(network.protoVlanSeparator.."%d$") then
			table.insert(devices, ifname)
		end
	end

	-- Scan for plain wireless interfaces
	uci:foreach("wireless", "wifi-iface", function(s) table.insert(devices, s["ifname"]) end)

	return devices
end

function network.configure()

	network.setup_rp_filter()

	network.setup_dns()

	local generalProtocols = config.get("network", "protocols")
	for _,protocol in pairs(generalProtocols) do
		local protoModule = "lime.proto."..utils.split(protocol,":")[1]
		if utils.isModuleAvailable(protoModule) then
			local proto = require(protoModule)
			xpcall(function() proto.configure(utils.split(protocol, network.protoParamsSeparator)) end,
			       function(errmsg) print(errmsg) ; print(debug.traceback()) end)
		end
	end

	local specificIfaces = {}
	config.foreach("net", function(iface) specificIfaces[iface[".name"]] = iface end)

	-- Scan for lan physical devices, if there is a specific config apply that otherwise apply general config
	for _,device in pairs(network.get_lan_devices()) do
		local owrtIf = specificIfaces[device]
		local deviceProtos = generalProtocols
		if owrtIf then deviceProtos = owrtIf["protocols"] end

		for _,protoParams in pairs(deviceProtos) do
			local args = utils.split(protoParams, network.protoParamsSeparator)
			if args[1] == "manual" then break end -- If manual is specified do not configure interface
			local protoModule = "lime.proto."..args[1]
			if utils.isModuleAvailable(protoModule) then
				local proto = require(protoModule)
				xpcall(function() proto.setup_interface(device, args) end,
				       function(errmsg) print(errmsg) ; print(debug.traceback()) end)
			end
		end
	end
end

function network.createVlanIface(linuxBaseIfname, vid, openwrtNameSuffix, vlanProtocol)

	vlanProtocol = vlanProtocol or "8021ad"
	openwrtNameSuffix = openwrtNameSuffix or ""

	local owrtDeviceName = network.limeIfNamePrefix..linuxBaseIfname..openwrtNameSuffix.."_dev"
	local owrtInterfaceName = network.limeIfNamePrefix..linuxBaseIfname..openwrtNameSuffix.."_if"
	owrtDeviceName = owrtDeviceName:gsub("[^%w_]", "_") -- sanitize uci section name
	owrtInterfaceName = owrtInterfaceName:gsub("[^%w_]", "_") -- sanitize uci section name

	local vlanId = vid
	--! Do not use . as separator as this will make netifd create an 802.1q interface anyway
	--! and sanitize linuxBaseIfName because it can contain dots as well (i.e. switch ports)
	local linux802adIfName = linuxBaseIfname:gsub("[^%w_]", "_")..network.protoVlanSeparator..vlanId
	local ifname = linuxBaseIfname
	if string.sub(linuxBaseIfname, 1, 4) == "wlan" then ifname = "@"..network.limeIfNamePrefix..linuxBaseIfname end

	local uci = libuci:cursor()

	uci:set("network", owrtDeviceName, "device")
	uci:set("network", owrtDeviceName, "type", vlanProtocol)
	uci:set("network", owrtDeviceName, "name", linux802adIfName)
	uci:set("network", owrtDeviceName, "ifname", ifname)
	uci:set("network", owrtDeviceName, "vid", vlanId)

	uci:set("network", owrtInterfaceName, "interface")
	uci:set("network", owrtInterfaceName, "ifname", linux802adIfName)
	uci:set("network", owrtInterfaceName, "proto", "none")
	uci:set("network", owrtInterfaceName, "auto", "1")

	uci:save("network")

	return owrtInterfaceName, linux802adIfName, owrtDeviceName
end

return network

-- Contract test: a host that is a dotted IPv4 address is used as it is, with
-- no DNS lookup; anything else (an out-of-range address, a short address, a
-- hostname) goes to DNS. Run from the MPAPI repository root:
-- luajit tests/ipv4_host_test.lua
local T = dofile('tests/support.lua')
local check = T.check

local lookups, connected_to
package.loaded['socket'] = {
	dns = {
		toip = function(host)
			lookups[#lookups + 1] = host
			return '9.9.9.9'
		end,
	},
	tcp = function()
		return {
			settimeout = function() end,
			connect = function(_, ip)
				connected_to = ip
				return true
			end,
			setoption = function() end,
			close = function() end,
		}
	end,
}

local net = dofile('networking/nakama_net.lua')

local function open(host)
	lookups, connected_to = {}, nil
	local stream, err = net.open(host, 7350, false, 1)
	check(stream, 'open failed for ' .. host .. ': ' .. tostring(err))
end

open('1.2.3.4')
check(#lookups == 0, 'an IPv4 address must not go to DNS')
check(connected_to == '1.2.3.4', 'an IPv4 address is connected to as it is')

for _, host in ipairs({ '256.1.1.1', '1.2.3', 'example.com' }) do
	open(host)
	check(#lookups == 1 and lookups[1] == host, host .. ' must go to DNS')
	check(connected_to == '9.9.9.9', host .. ' connects to the resolved address')
end

T.done('ipv4_host_test')

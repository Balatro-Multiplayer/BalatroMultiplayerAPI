-- When The Order is on, and the gates that let a consuming mod turn it, or parts of it, on.
MPAPI._internal.the_order = MPAPI._internal.the_order or {}

-- Generic extension points, same idiom as MPAPI.register_mod_isolation
-- (api/layers/pool_gating.lua) -- a platform file exposes a registry, and a
-- consuming mod (PvP, or any future one) registers its own predicate, instead
-- of this file branching on a PVP-specific global directly.
MPAPI._order_gates = MPAPI._order_gates or {}
function MPAPI.register_order_gate(fn)
	MPAPI._order_gates[#MPAPI._order_gates + 1] = fn
end

MPAPI._voucher_queue_gates = MPAPI._voucher_queue_gates or {}
function MPAPI.register_voucher_queue_gate(fn)
	MPAPI._voucher_queue_gates[#MPAPI._voucher_queue_gates + 1] = fn
end

MPAPI._idol_gates = MPAPI._idol_gates or {}
function MPAPI.register_idol_gate(fn)
	MPAPI._idol_gates[#MPAPI._idol_gates + 1] = fn
end

function MPAPI.should_use_the_order()
	if MPAPI.is_layer_active('the_order') then return true end
	for _, gate in ipairs(MPAPI._order_gates) do
		if gate() then return true end
	end
	return false
end

-- Some consumers (PvP's major-league ruleset) want the culled/stable voucher
-- queue (vouchers.lua) without the full Order treatment, so the voucher hooks
-- additionally gate on this.
MPAPI._internal.the_order.voucher_queue_follows_the_order = function()
	for _, gate in ipairs(MPAPI._voucher_queue_gates) do
		if gate() then return true end
	end
	return false
end

-- Same idea for The Idol (PvP's major-league ruleset again): its card follows
-- The Order's pick while the rest of the run does not.
MPAPI._internal.the_order.idol_follows_the_order = function()
	for _, gate in ipairs(MPAPI._idol_gates) do
		if gate() then return true end
	end
	return false
end

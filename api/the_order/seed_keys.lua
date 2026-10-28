-- Seed suffixes for random queues. Under The Order, ante_based gives 0, so the queue runs the
-- whole game instead of restarting each ante, and order_round_based gives one key per ante and
-- blind, so both players draw the same result on the same blind.
function MPAPI.ante_based()
	if MPAPI.should_use_the_order() then return 0 end
	return G.GAME.round_resets.ante
end

function MPAPI.order_round_based(ante_based)
	if MPAPI.should_use_the_order() then
		return G.GAME.round_resets.ante
			.. (G.GAME.blind.config.blind.key or '')
			.. (G.GAME.blind_on_deck or '')
	end
	if ante_based then return MPAPI.ante_based() end
	return ''
end

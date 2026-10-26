-- The name of every opcode a replay log can hold, shared by all mods. Use these in place of the
-- raw strings: a typo in a name is then a nil that fails at once, not a handler that never runs.
-- The values are the exact strings on the wire and in saved logs, so never change one.
-- The mods' own opcodes are listed here too, so one file names every opcode a log can hold.
MPAPI.OPCODE = {
	-- Framing: open and close one log block.
	MATCH_MANIFEST = 'match_manifest',
	LOBBY_INFO = 'lobby_info',
	RUN_INFO = 'run_info',
	MANIFEST = 'manifest',
	END = 'end',
	CHK = 'chk',
	-- The core Balatro loop.
	MONEY_DELTA = 'money_delta',
	SELL = 'sell',
	CASHOUT = 'cashout',
	REROLL = 'reroll',
	HAND_SCORED = 'hand_scored',
	BUY = 'buy',
	OPEN_PACK = 'open_pack',
	VOUCHER = 'voucher',
	USE = 'use',
	PACK_PICK = 'pack_pick',
	PACK_SKIP = 'pack_skip',
	REORDER = 'reorder',
	PLAY = 'play',
	DISCARD = 'discard',
	SELECT_BLIND = 'select_blind',
	SKIP_BLIND = 'skip_blind',
	LEAVE_SHOP = 'leave_shop',
	-- PvP.
	READY_BLIND = 'ready_blind',
	SET_ANTE_KEY = 'set_ante_key',
	HAND_RESULT = 'hand_result',
	ROUND_DOLLARS = 'round_dollars',
	NET_PIZZA = 'net_pizza',
	NET_MAGNET = 'net_magnet',
	LIFE_LOST = 'life_lost',
	-- Speedrunning.
	RUN_COMPLETE = 'run_complete',
	RUN_DIED = 'run_died',
	RUN_RESTARTED = 'run_restarted',
}

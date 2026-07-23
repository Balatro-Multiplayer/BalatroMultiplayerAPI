-- Server-generated draft support. The consumer's draft only ever runs inside
-- matchmaking, and every matchmaking queue has a server draft policy.
--
-- The contract with consumers:
--   fetch_draft_pool(match_id, cb)  -> cb(pool) with an array of { key, stake }
--                                      items ready for BanPick, or cb(nil) on ANY
--                                      failure (no connection, no match id, no
--                                      policy for the queue, transport error) --
--                                      the caller must abort the draft on nil.

MPAPI.matchmaking = MPAPI.matchmaking or {}

function MPAPI.matchmaking.fetch_draft_pool(match_id, callback)
	local conn = MPAPI.get_connection()
	if not conn or not conn.api or not conn.jwt_token or not match_id then
		callback(nil)
		return
	end
	conn.api:issue_draft_pool(conn.jwt_token, match_id, function(err, data)
		if err or not data or type(data.pool) ~= 'table' then
			if err then
				MPAPI.sendDebugMessage('[draft] pool fetch failed (caller must abort the draft): ' .. tostring(err.message or err))
			end
			callback(nil)
			return
		end
		-- The pool is a list of self-describing items: { key, stake }, and for a
		-- composite deck additionally { decks = { key, ... }, name? } -- the
		-- composition rides on the item, so there is no separate config fetch.
		callback(data.pool)
	end)
end

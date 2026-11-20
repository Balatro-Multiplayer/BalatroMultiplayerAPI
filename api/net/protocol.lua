-- Wire constants of the request/answer layer. Must match nakama/src/lobby/protocol.ts
-- (BalatroMultiplayerServer); the shared contract and golden fixtures are
-- tests/fixtures/net-v1/.
return {
	-- Sent in the join metadata; a SNAPSHOT without one means an old server.
	PROTOCOL_VERSION = 1,
	Op = {
		-- Client to server: {v, reqId, type, payload}.
		REQUEST = 8,
		-- Server to client: the existing rejoin snapshot, plus rev, connectionId, protocol and match.
		SNAPSHOT = 100,
		-- Server to the sender only: {reqId, ok = true, rev} or {reqId, ok = false, reason}.
		ANSWER = 114,
		-- Server to every seated player: {rev, changed, full?}.
		STATE = 115,
	},
}

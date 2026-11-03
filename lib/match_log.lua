-- MPAPI.match_log(level, msg, tag): the one gate for log lines that carry match
-- data (match ids, lobby codes, seeds, scores, results, the replay log).
--
-- Contract: it writes to the Lovely log only when the Dev mod is installed
-- (MPAPI.dev.active()). Level is 'debug', 'info' or 'trace'. Warnings and
-- errors never go through it: call sendWarnMessage / sendErrorMessage directly.
-- tag is optional and defaults to the MPAPI mod id. The Dev mod loads after
-- MPAPI, so the check runs at each call, never at file load.
local LEVEL_WRITERS = {
	debug = function(msg, tag)
		sendDebugMessage(msg, tag)
	end,
	info = function(msg, tag)
		sendInfoMessage(msg, tag)
	end,
	trace = function(msg, tag)
		sendTraceMessage(msg, tag)
	end,
}

function MPAPI.match_log(level, msg, tag)
	local write = LEVEL_WRITERS[level]
	if not write then
		error('MPAPI.match_log: level must be debug, info or trace, got ' .. tostring(level))
	end
	if not (MPAPI.dev and MPAPI.dev.active()) then
		return
	end
	write(msg, tag or MPAPI.id)
end

-- Pure helpers for representing failure as a value rather than mixing nil returns
-- with thrown errors.
--
-- An error value is a table { kind = MPAPI.ErrorKind.*, message = string } whose
-- __tostring yields the message, so legacy callbacks that do tostring(err) or
-- string-concatenate the error keep producing the same human-readable text while
-- new callers can branch on err.kind.
MPAPI.Result = MPAPI.Result or {}

local function error_text(value)
	if type(value) == 'table' and value.message then
		return value.message
	end
	return tostring(value)
end

-- __concat keeps error values drop-in compatible with the legacy string errors:
-- callers that do ('prefix: ' .. err) keep producing the message text instead of
-- erroring on a table operand.
local error_mt = {
	__tostring = function(self)
		return self.message or tostring(self.kind)
	end,
	__concat = function(a, b)
		return error_text(a) .. error_text(b)
	end,
}

MPAPI.make_error = function(kind, message)
	return setmetatable({ kind = kind, message = message or kind }, error_mt)
end

MPAPI.Result.ok = function(value)
	return { ok = true, value = value }
end

MPAPI.Result.err = function(kind, message)
	return { ok = false, error = MPAPI.make_error(kind, message) }
end

MPAPI.Result.is_ok = function(result)
	return type(result) == 'table' and result.ok == true
end

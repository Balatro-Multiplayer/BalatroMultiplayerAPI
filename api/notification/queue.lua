-- The login overlay queue: Notifications waiting to be shown one at a time.
-- Pure data, no UI. An entry is { id, text, on_shown? }: `id` dedups (a live
-- push and the login list can carry the same Notification), `on_shown` runs
-- once when the entry is put on screen (the inbox marks it read there).
-- Anything that wants a pop up at login, a warning for example, adds an entry
-- here, so no two pop ups cover each other.
local Queue = {}

function Queue.new()
	return { pending = {}, seen = {}, position = 0, total = 0, open = false }
end

-- Adds an entry unless its id was already taken. Returns whether it was added.
function Queue.add(q, entry)
	if entry.id ~= nil then
		if q.seen[entry.id] then
			return false
		end
		q.seen[entry.id] = true
	end
	if #q.pending == 0 and not q.open then
		-- A new batch: "1 of N" counts from here.
		q.position = 0
		q.total = 0
	end
	q.total = q.total + 1
	q.pending[#q.pending + 1] = entry
	return true
end

-- Notes an id as taken without queueing it (a live Notification that went to chat).
function Queue.mark_seen(q, id)
	if id ~= nil then
		q.seen[id] = true
	end
end

function Queue.is_seen(q, id)
	return id ~= nil and q.seen[id] == true
end

function Queue.has_pending(q)
	return #q.pending > 0
end

-- The next entry with its place in the batch: entry, position, total.
-- nil when nothing waits.
function Queue.next(q)
	if #q.pending == 0 then
		return nil
	end
	local entry = table.remove(q.pending, 1)
	q.position = q.position + 1
	q.open = true
	return entry, q.position, q.total
end

-- The entry on screen is gone.
function Queue.close(q)
	q.open = false
end

-- Drops what has not been shown (the connection ended). Anything unread is
-- still stored server-side and is listed again at the next login.
function Queue.forget(q)
	q.pending = {}
	q.seen = {}
	q.position = 0
	q.total = 0
	q.open = false
end

return Queue

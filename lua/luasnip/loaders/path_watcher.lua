local Path = require("luasnip.util.path")
local uv = vim.uv or vim.loop
local util = require("luasnip.util.util")
local log = require("luasnip.util.log").new("path-watcher")

local M = {}

local PathWatcher = {}
local PathWatcher_mt = {
	__index = PathWatcher
}

function PathWatcher:change(full)
	log.info("detected change at path %s", full)
	if not self.is_present then
		-- this is certainly unexpected.
		log.warn("PathWatcher at %s detected change, but path does not exist logically. Not triggering callback.", full)
	else
		self.callbacks.change(self.path)
	end
end
function PathWatcher:add()
	if self.is_present then
		-- already added
		return
	end
	log.info("adding path %s", self.path)
	self.is_present = true

	self.callbacks.add(self.path)
end
function PathWatcher:remove()
	if not self.is_present then
		-- already removed
		return
	end
	log.debug("removing path %s", self.path)
	log.info("path %s was removed, stopping watcher.", self.path)

	self.is_present = false

	self.callbacks.remove(self.path)

	-- Would have to re-register for new file to receive new notifications.
	self:stop()
end

function PathWatcher:start()
	-- does not work on nfs-drive, at least if it's edited from another
	-- machine.
	local success, err = self.fs_event:start(self.path, {}, function(err, relpath, events)
		vim.schedule_wrap(function()
		log.debug("raw: path: %s; err: %s; relpath: %s; change: %s; rename: %s", self.path, err, relpath, events.change, events.rename)

		if events.rename then
			if not uv.fs_stat(self.path) then
				self:remove()
			else
				self:add()
			end
		elseif events.change then
			self:change()
		end
		end)()
	end)

	if not success then
		log.error("Could not start monitoring fs-events for path %s due to error %s.", self.path, err)
	end

	if uv.fs_stat(self.path) then
		self:add()
		-- no else, never added the path, never call remove.
	end
end

function PathWatcher:stop()
	self.fs_event:stop()
end

local callback_mt = {
	__index = function() return util.nop end
}
function M.new(path, callbacks)
	local path_stat = uv.fs_stat(path)
	if not path_stat then
		return nil
	end

	-- do nothing on missing callback.
	callbacks = setmetatable(callbacks or {}, callback_mt)

	local o = setmetatable({
		path = path,
		fs_event = uv.new_fs_event(),
		-- initially, should be cleared up very quickly.
		is_present = false,
		callbacks = callbacks,
	}, PathWatcher_mt)

	o:start()

	return o
end

return M

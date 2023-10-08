local Path = require("luasnip.util.path")
local uv = vim.uv
local util = require("luasnip.util.util")
local log = require("luasnip.util.log").new("tree-watcher")

local M = {}

local TreeWatcher = {}
local TreeWatcher_mt = {
	__index = TreeWatcher
}
function TreeWatcher:stop_recursive()
	for _, child_watcher in ipairs(self.dir_watchers) do
		child_watcher.fs_event:stop()
	end
	self.fs_event:stop()
end

-- these functions maintain our logical view of the directory, and call
-- callbacks when we detect a change.
function TreeWatcher:new_file(rel, full)
	if self.files[rel] then
		-- already added
		return
	end
	self.files[rel] = true
	self.callbacks.new_file(full)
end
function TreeWatcher:new_dir(rel, full)
	if self.dir_watchers[rel] then
		-- already added
		return
	end
	-- first do callback for this directory, then look into (and potentially do
	-- callbacks for) children.
	self.callbacks.new_dir(full)
	self.dir_watchers[rel] = M.new(full, self.depth-1, self.callbacks)
end

function TreeWatcher:change_child(rel, full)
	if self.dir_watchers[rel] then
		self.callbacks.change_dir(full)
	elseif self.files[rel] then
		self.callbacks.change_file(full)
	end
end

function TreeWatcher:remove_child(rel, full)
	if self.dir_watchers[rel] then
		-- should have been stopped by the watcher for the child, or it was not
		-- even started due to depth.
		self.dir_watchers[rel]:remove_root()
		self.dir_watchers[rel] = nil

		self.callbacks.remove_dir(full)
	elseif self.files[rel] then
		self.files[rel] = nil

		self.callbacks.remove_file(full)
	end
end

function TreeWatcher:remove_root()
	if self.removed then
		-- already removed
		return
	end
	self.removed = true
	-- stop own, children should have handled themselves, if they are watched.
	self.fs_event:stop()

	-- removing entries (set them to nil) is apparently fine when iterating via
	-- pairs.
	for relpath, _ in pairs(self.files) do
		local child_full = Path.join(self.root, relpath)
		self:remove_child(relpath, child_full)
	end
	for relpath, _ in pairs(self.dir_watchers) do
		local child_full = Path.join(self.root, relpath)
		self:remove_child(relpath, child_full)
	end

	self.callbacks.remove_root(self.root)
end

local callback_mt = {
	__index = function() return util.nop end
}
function M.new(root, depth, callbacks)
	-- do nothing on missing callback.
	callbacks = setmetatable(callbacks or {}, callback_mt)

	local o = setmetatable({
		root = root,
		fs_event = uv.new_fs_event(),
		files = {},
		dir_watchers = {},
		removed = false,
		callbacks = callbacks,
		depth = depth
	}, TreeWatcher_mt)

	-- don't watch children.
	if depth == 0 then
		return o
	end

	-- does not work on nfs-drive, at least if it's edited from another
	-- machine.
	o.fs_event:start(root, {}, function(err, relpath, events)
		if o.removed then
			return
		end
		vim.schedule_wrap(function()
		log.info("raw: root: %s; err: %s; relpath: %s; change: %s; rename: %s", o.root, err, relpath, events.change, events.rename)
		local full_path = Path.join(root, relpath)
		local path_stat = uv.fs_stat(full_path)

		-- try to figure out what happened in the directory.
		if events.rename then
			if not uv.fs_stat(root) then
				o:remove_root()
				return
			end
			if not path_stat then
				o:remove_child(relpath, full_path)
				return
			end

			local f_type
			if path_stat.type == "link" then
				f_type = uv.fs_stat(uv.fs_realpath(full_path))
			else
				f_type = path_stat.type
			end

			if f_type == "file" then
				o:new_file(relpath, full_path)
				return
			elseif f_type == "directory" then
				o:new_dir(relpath, full_path)
				return
			end
		elseif events.change then
			o:change_child(relpath, full_path)
		end
		end)()
	end)

	-- do initial scan after starting the watcher.
	-- Scanning first, and then starting the watcher leaves a period of time
	-- where a new file may be created (after scanning, before watching), where
	-- we wont know about it.
	-- If I understand the uv-eventloop correctly, this function, `new`, will
	-- be executed completely before a callback is called, so o.files and
	-- o.dir_watchers should be populated correctly when a callback is
	-- received, even if it was received before all directories/files were
	-- added.
	-- This difference can be observed, at least on my machine, by watching a
	-- directory A, and then creating a nested directory B, and children for it
	-- in one command, ie. `mkdir -p A/B/{1,2,3,4,5,6,7,8,9}`.
	-- If the callback is registered after the scan, the latter directories
	-- (ie. 4-9) did not show up, whereas everything did work correctly if the
	-- watcher was activated before the scan.
	-- (almost everything, one directory was included in the initial scan and
	-- the watch-event, but that seems okay for our purposes)
	local files, dirs = Path.scandir(root)
	for _, file in ipairs(files) do
		local relpath = file:sub(#root+2)
		o:new_file(relpath, file)
	end
	for _, dir in ipairs(dirs) do
		local relpath = dir:sub(#root+2)
		o:new_dir(relpath, dir)
	end

	return o
end

return M

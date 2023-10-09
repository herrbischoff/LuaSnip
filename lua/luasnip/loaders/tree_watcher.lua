local Path = require("luasnip.util.path")
local uv = vim.uv or vim.loop
local util = require("luasnip.util.util")
local log = require("luasnip.util.log").new("tree-watcher")

local M = {}

local TreeWatcher = {}
local TreeWatcher_mt = {
	__index = TreeWatcher
}
function TreeWatcher:stop_recursive()
	for _, child_watcher in ipairs(self.dir_watchers) do
		child_watcher:stop()
	end
	self:stop()
end

function TreeWatcher:stop()
	self.fs_event:stop()
end
function TreeWatcher:start()
	if self.depth == 0 then
		-- don't watch children for 0-depth.
		return
	end

	log.info("start monitoring directory %s", self.root)

	-- does not work on nfs-drive, at least if it's edited from another
	-- machine.
	self.fs_event:start(self.root, {}, function(err, relpath, events)
		if self.removed then
			return
		end
		vim.schedule_wrap(function()
		log.debug("raw: self.root: %s; err: %s; relpath: %s; change: %s; rename: %s", self.root, err, relpath, events.change, events.rename)
		local full_path = Path.join(self.root, relpath)
		local path_stat = uv.fs_stat(full_path)

		-- try to figure out what happened in the directory.
		if events.rename then
			if not uv.fs_stat(self.root) then
				self:remove_root()
				return
			end
			if not path_stat then
				self:remove_child(relpath, full_path)
				return
			end

			local f_type
			if path_stat.type == "link" then
				f_type = uv.fs_stat(uv.fs_realpath(full_path))
			else
				f_type = path_stat.type
			end

			if f_type == "file" then
				self:new_file(relpath, full_path)
				return
			elseif f_type == "directory" then
				self:new_dir(relpath, full_path)
				return
			end
		elseif events.change then
			self:change_child(relpath, full_path)
		end
		end)()
	end)

	-- do initial scan after starting the watcher.
	-- Scanning first, and then starting the watcher leaves a period of time
	-- where a new file may be created (after scanning, before watching), where
	-- we wont know about it.
	-- If I understand the uv-eventloop correctly, this function, `new`, will
	-- be executed completely before a callback is called, so self.files and
	-- self.dir_watchers should be populated correctly when a callback is
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
	local files, dirs = Path.scandir(self.root)
	for _, file in ipairs(files) do
		local relpath = file:sub(#self.root+2)
		self:new_file(relpath, file)
	end
	for _, dir in ipairs(dirs) do
		local relpath = dir:sub(#self.root+2)
		self:new_dir(relpath, dir)
	end
end

-- these functions maintain our logical view of the directory, and call
-- callbacks when we detect a change.
function TreeWatcher:new_file(rel, full)
	if self.files[rel] then
		-- already added
		return
	end

	log.debug("new file %s %s", rel, full)
	self.files[rel] = true
	self.callbacks.new_file(full)
end
function TreeWatcher:new_dir(rel, full)
	if self.dir_watchers[rel] then
		-- already added
		return
	end

	log.debug("new dir %s %s", rel, full)
	-- first do callback for this directory, then look into (and potentially do
	-- callbacks for) children.
	self.callbacks.new_dir(full)
	self.dir_watchers[rel] = M.new(full, self.depth-1, self.callbacks)
end

function TreeWatcher:change_child(rel, full)
	if self.dir_watchers[rel] then
		log.debug("changed dir %s %s", rel, full)
		self.callbacks.change_dir(full)
	elseif self.files[rel] then
		log.debug("changed file %s %s", rel, full)
		self.callbacks.change_file(full)
	end
end

function TreeWatcher:remove_child(rel, full)
	if self.dir_watchers[rel] then
		log.debug("removing dir %s %s", rel, full)
		-- should have been stopped by the watcher for the child, or it was not
		-- even started due to depth.
		self.dir_watchers[rel]:remove_root()
		self.dir_watchers[rel] = nil

		self.callbacks.remove_dir(full)
	elseif self.files[rel] then
		log.debug("removing file %s %s", rel, full)
		self.files[rel] = nil

		self.callbacks.remove_file(full)
	end
end

function TreeWatcher:remove_root()
	if self.removed then
		-- already removed
		return
	end
	log.debug("removing root %s", self.root)
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
-- root needs to be an absolute path.
function M.new(root, depth, callbacks, opts)
	opts = opts or {}

	-- if lazy is set, watching a non-existing directory will create a watcher
	-- for the parent-directory (or its parent, if it does not yet exist).
	local lazy = vim.F.if_nil(opts.lazy, false)

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

	-- if the path does not yet exist, set watcher up s.t. it will start
	-- watching when the directory is created.
	if not uv.fs_stat(root) and lazy then
		-- root does not yet exist, need to create a watcher that notifies us
		-- of its creation.
		local parent_path = Path.parent(root)
		if not parent_path then
			error(("Could not find parent-path for %s"):format(root))
		end

		log.info("Path %s does not exist yet, watching %s for creation.", root, parent_path)

		local parent_watcher
		parent_watcher = M.new(parent_path, 1, {
			new_dir = function(full)
				if full == root then
					o:start()
					-- directory was created, stop watching.
					parent_watcher:stop()
				end
			end,
		}, { lazy = true })
	else
		o:start()
	end

	return o
end

return M

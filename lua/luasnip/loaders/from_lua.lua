-- loads snippets from directory structured almost like snipmate-collection:
-- - files all named <ft>.lua
-- - each returns table containing keys (optional) "snippets" and
--   "autosnippets", value for each a list of snippets.
--
-- cache:
-- - lazy_load_paths: {
-- 	{
-- 		add_opts = {...},
-- 		ft1 = {filename1, filename2},
-- 		ft2 = {filename1},
-- 		...
-- 	}, {
-- 		add_opts = {...},
-- 		ft1 = {filename1},
-- 		...
-- 	}
-- }
--
-- each call to load generates a new entry in that list. We cannot just merge
-- all files for some ft since add_opts might be different (they might be from
-- different lazy_load-calls).

local loader_util = require("luasnip.loaders.util")
local ls = require("luasnip")
local log = require("luasnip.util.log").new("lua-loader")
local session = require("luasnip.session")
local util = require("luasnip.util.util")
local autotable = require("luasnip.util.auto_table").autotable
local tree_watcher = require("luasnip.loaders.fs_watchers").tree
local path_watcher = require("luasnip.loaders.fs_watchers").path
local digraph = require("luasnip.util.directed_graph")

local Data = require("luasnip.loaders.data")

local M = {}

-- ASSUMPTION: this function will only be called inside the snippet-constructor,
-- to find the location of the lua-loaded file calling it.
-- It is not exported, because it will (in its current state) only ever be used
-- in one place, and it feels a bit wrong to expose put a function into `M`.
-- Instead, it is inserted into the global environment before a luasnippet-file
-- is loaded, and removed from it immediately when this is done
local function get_loaded_file_debuginfo()
	-- we can skip looking at the first four stackframes, since
	-- 1   is this function
	-- 2   is the snippet-constructor
	-- ... (here anything is going on, could be 0 stackframes, could be many)
	-- n-2 (at least 3) is the loaded file
	-- n-1 (at least 4) is pcall
	-- n   (at least 5) is _luasnip_load_file
	local current_call_depth = 4
	local debuginfo

	repeat
		current_call_depth = current_call_depth + 1
		debuginfo = debug.getinfo(current_call_depth, "n")
	until debuginfo.name == "_luasnip_load_file"

	-- ret is stored into a local, and not returned immediately to prevent tail
	-- call optimization, which seems to invalidate the stackframe-numbers
	-- determined earlier.
	--
	-- current_call_depth-0 is _luasnip_load_file,
	-- current_call_depth-1 is pcall, and
	-- current_call_depth-2 is the lua-loaded file.
	-- "Sl": get only source-file and current line.
	local ret = debug.getinfo(current_call_depth - 2, "Sl")
	return ret
end

local function search_lua_rtp(modulename)
	-- essentially stolen from vim.loader.
	local rtp_lua_path = package.path
	for _, path in ipairs(vim.api.nvim_get_runtime_file("", true)) do
		rtp_lua_path = rtp_lua_path .. (";%s/lua/?.lua;%s/lua/?/init.lua"):format(path, path)
	end

	return package.searchpath(modulename, rtp_lua_path)
end

local function _luasnip_load_file(file)
		-- vim.loader.enabled does not seem to be official api, so always reset
		-- if the loader is available.
		-- To be sure, even pcall it, in case there are conditions under which
		-- it might error.
	if vim.loader then
		-- pcall, not sure if this can fail in some way..
		-- Does not seem like it though
		local ok, res = pcall(vim.loader.reset, file)
		if not ok then
			log.warn("Could not reset cache for file %s\n: %s", file, res)
		end
	end

	local func, error_msg = loadfile(file)
	if error_msg then
		log.error("Failed to load %s\n: %s", file, error_msg)
		error(string.format("Failed to load %s\n: %s", file, error_msg))
	end

	-- the loaded file may add snippets to these tables, they'll be
	-- combined with the snippets returned regularly.
	local file_added_snippets = {}
	local file_added_autosnippets = {}

	local dependent_files = {}

	-- setup snip_env in func
	local func_env
	local function ls_tracked_dofile(filename)
		local package_func, err_msg = loadfile(filename)
		if package_func then
			setfenv(package_func, func_env)
			table.insert(dependent_files, filename)
		else
			error(("File %s could not be loaded: %s"):format(filename, err_msg))
		end

		return package_func()
	end
	func_env = vim.tbl_extend(
		"force",
		-- extend the current(expected!) globals with the snip_env, and the
		-- two tables.
		_G,
		ls.get_snip_env(),
		{
			ls_file_snippets = file_added_snippets,
			ls_file_autosnippets = file_added_autosnippets,
			ls_tracked_dofile = ls_tracked_dofile,
			ls_tracked_dopackage = function(package_name)
				local package_file = search_lua_rtp(package_name)
				if not package_file then
					error(("Could not find package %s in rtp/package.path"):format(package_name))
				end
				return ls_tracked_dofile(package_file)
			end
		}
	)
	-- defaults snip-env requires metatable for resolving
	-- lazily-initialized keys. If we have to combine this with an eventual
	-- metatable of _G, look into unifying ls.setup_snip_env and this.
	setmetatable(func_env, getmetatable(ls.get_snip_env()))
	setfenv(func, func_env)

	-- Since this function has to reach the snippet-constructor, and fenvs
	-- aren't inherited by called functions, we have to set it in the global
	-- environment.
	_G.__luasnip_get_loaded_file_frame_debuginfo = util.ternary(
		session.config.loaders_store_source,
		get_loaded_file_debuginfo,
		nil
	)
	local run_ok, file_snippets, file_autosnippets = pcall(func)
	-- immediately nil it.
	_G.__luasnip_get_loaded_file_frame_debuginfo = nil

	if not run_ok then
		log.error("Failed to execute\n: %s", file, file_snippets)
		error("Failed to execute " .. file .. "\n: " .. file_snippets)
	end

	-- make sure these aren't nil.
	file_snippets = file_snippets or {}
	file_autosnippets = file_autosnippets or {}

	vim.list_extend(file_snippets, file_added_snippets)
	vim.list_extend(file_autosnippets, file_added_autosnippets)

	return file_snippets, file_autosnippets, dependent_files
end

local function lua_package_file_filter(fname)
	return fname:match("%.lua$")
end

--- Collection watches all files that belong to a collection of snippets below
--- some root, and registers new files.
local Collection = {}
local Collection_mt = {
	__index = Collection
}

function Collection.new(root, lazy, include_ft, exclude_ft, add_opts, lazy_watcher, fs_event_providers)
	local ft_filter = loader_util.ft_filter(include_ft, exclude_ft)
	local o = setmetatable({
		root = root,
		file_filter = function(path)
			if not path:sub(1, #root) == root then
				log.warn("Tried to filter file `%s`, which is not inside the root `%s`.", path, root)
				return false
			end
			return lua_package_file_filter(path) and ft_filter(path)
		end,
		add_opts = add_opts,
		lazy = lazy,
		-- store ft -> set of files that should be lazy-loaded.
		lazy_files = autotable(2, {warn = false}),
		-- store, for all files in this collection, their filetype.
		-- No need to always recompute it, and we can use this to store which
		-- files belong to the collection.
		loaded_path_ft = {},
		file_dependencies = digraph.new_labeled(),
		fs_event_providers = fs_event_providers
	}, Collection_mt)

	-- only register files up to a depth of 2.
	local watcher_ok, err = pcall(tree_watcher, root, 2, {
		-- don't handle removals for now.
		new_file = function(path)
			-- detected new file, make sure it is allowed by our filters.
			if o.file_filter(path) then
				o:add_file(path, loader_util.collection_file_ft(o.root, path))
			end
		end,
		change_file = function(path)
			o:reload(path)
		end
	}, {lazy = lazy_watcher, fs_event_providers = fs_event_providers})

	if not watcher_ok then
		error(("Could not create watcher: %s"):format(err))
	end

	log.info("Initialized snippet-collection at `%s`", root)

	return o
end

-- Add file with some filetype to collection.
function Collection:add_file(path, ft)
	Data.lua_ft_paths[ft][path] = true

	if self.lazy then
		if not session.loaded_fts[ft] then
			log.info("Registering lazy-load-snippets for ft `%s` from file `%s`", ft, path)

			-- only register to load later.
			self.lazy_files[ft][path] = true
			return
		else
			log.info(
				"Filetype `%s` is already active, loading immediately.",
				ft
			)
		end
	end

	self:load_file(path, ft)
end
function Collection:load_file(path, ft)
	log.info(
		"Adding snippets for filetype `%s` from file `%s`",
		ft,
		path
	)
	self.loaded_path_ft[path] = ft

	local snippets, autosnippets, dependent_files = _luasnip_load_file(path)

	-- ignored if it already exists.
	self.file_dependencies:set_vertex(path)
	-- make sure we don't retain any old dependencies.
	self.file_dependencies:clear_edges(path)

	for _, file_dependency in ipairs(dependent_files) do
		-- ignored if it already exists.
		self.file_dependencies:set_vertex(file_dependency)
		-- path depends on dependent_file => if dependent_file is changed, path
		-- should be updated.
		self.file_dependencies:set_edge(file_dependency, path, path)

		path_watcher(file_dependency, {
			change = function(_)
				local depending_files = self.file_dependencies:connected_component(file_dependency, "Forward")
				for _, file in ipairs(depending_files) do
					-- We obviously don't want to load snippet-files that are
					-- not loaded already.
					-- However, since we only have dependency-information for
					-- files that were loaded, this is given if they are one of
					-- the depending_files and a snippet-file.
					-- The latter has to be checked here, otherwise we may load
					-- a utility-file thinking it provides snippets.

					-- Prevent loading one of the utility-files as a snippet-file.
					-- This will not reject any snippet-file in
					-- depending_files. This is because since they are in
					-- depending_files, we have their dependency-information,
					-- which can only be obtained by loading them, and so there
					-- can't be any unloaded files in there.
					if self.loaded_path_ft[file] then
						self:load_file(file, self.loaded_path_ft[file])
					end
				end
			end
		}, {lazy = false, fs_event_providers = self.fs_event_providers})
	end

	loader_util.add_file_snippets(ft, path, snippets, autosnippets, self.add_opts)

	ls.refresh_notify(ft)
end
function Collection:do_lazy_load(ft)
	if session.loaded_fts[ft] then
		-- ft is already loaded, skip reload.
		return
	end

	for file, _ in pairs(self.lazy_files[ft]) do
		self:load_file(file, ft)
	end
end

-- will only do something, if the file at `path` was loaded previously.
function Collection:reload(path)
	local path_ft = self.loaded_path_ft[path]
	if not path_ft then
		-- file not yet loaded.
		return
	end

	-- will override previously-loaded snippets from this path.
	self:load_file(path, path_ft)

	-- clean snippets if enough were removed.
	ls.clean_invalidated({ inv_limit = 100 })
end

function M._load_lazy_loaded_ft(ft)
	log.info("Loading lazy-load-snippets for filetype `%s`", ft)

	for _, collection in ipairs(Data.lua_collections) do
		collection:do_lazy_load(ft)
	end
end

local function _load(lazy, opts)
	opts = opts or {}

	local paths = opts.paths
	local add_opts = loader_util.make_add_opts(opts)
	local include = opts.include
	local exclude = opts.exclude
	local lazy_paths = opts.lazy_paths or {}
	local fs_event_providers = vim.F.if_nil(opts.fs_event_providers, {autocmd = true, uv = false})

	local collection_roots = loader_util.resolve_root_paths(paths, "luasnippets")
	local lazy_roots = loader_util.resolve_lazy_root_paths(lazy_paths)

	log.info("Found roots `%s` for paths `%s`.", vim.inspect(collection_roots), vim.inspect(paths))
	log.info("Determined roots `%s` for lazy_paths `%s`.", vim.inspect(lazy_roots), vim.inspect(lazy_paths))

	for paths_lazy, roots in pairs({[true] = lazy_roots, [false] = collection_roots}) do
		for _, collection_root in ipairs(roots) do
			local ok, coll_or_err = pcall(Collection.new, collection_root, lazy, include, exclude, add_opts, paths_lazy, fs_event_providers)

			if not ok then
				log.error("Could not create collection at %s: %s", collection_root, coll_or_err)
			else
				table.insert(Data.lua_collections, coll_or_err)
			end
		end
	end
end

--- Load lua-snippet-collections immediately.
--- @param opts LuaSnip.Loaders.LoadOpts?
function M.load(opts)
	_load(false, opts)
end

--- Load lua-snippet-collections on demand.
--- @param opts LuaSnip.Loaders.LoadOpts?
function M.lazy_load(opts)
	_load(true, opts)
	-- load for current buffer on startup.
	M._load_lazy_loaded_ft(vim.api.nvim_get_current_buf())
end

return M

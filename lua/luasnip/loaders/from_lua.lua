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

local cache = require("luasnip.loaders._caches").lua
local loader_util = require("luasnip.loaders.util")
local ls = require("luasnip")
local log = require("luasnip.util.log").new("lua-loader")
local session = require("luasnip.session")
local util = require("luasnip.util.util")
local autotable = require("luasnip.util.auto_table").autotable
local tree_watcher = require("luasnip.loaders.tree_watcher").new

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

	-- setup snip_env in func
	local func_env = vim.tbl_extend(
		"force",
		-- extend the current(expected!) globals with the snip_env, and the
		-- two tables.
		_G,
		ls.get_snip_env(),
		{
			ls_file_snippets = file_added_snippets,
			ls_file_autosnippets = file_added_autosnippets,
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

	return file_snippets, file_autosnippets
end

M.collections = {}

local function lua_package_file_filter(fname)
	return fname:match("%.lua$")
end

--- Collection watches all files that belong to a collection of snippets below
--- some root, and registers new files.
local Collection = {}
local Collection_mt = {
	__index = Collection
}
function Collection:new(root, lazy, include_ft, exclude_ft, add_opts)
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
		path_ft = {}
	}, Collection_mt)

	-- only register files up to a depth of 2.
	o.watcher = tree_watcher(root, 2, {
		-- don't handle removals for now.
		new_file = function(path)
			vim.schedule_wrap(function()
				-- detected new file, make sure it is allowed by our filters.
				if o.file_filter(path) then
					o:add_file(path, loader_util.collection_file_ft(o.root, path))
				end
			end)()
		end,
		change_file = function(path)
			vim.schedule_wrap(function()
				o:reload(path)
			end)()
		end
	})

	log.info("Initialized snippet-collection at `%s`", root)

	return o
end

-- Add file with some filetype to collection.
function Collection:add_file(path, ft)
	require("luasnip.loaders.data").lua_ft_paths[ft][path] = true
	self.path_ft[path] = ft

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

	self:add_file_snippets(path, ft)
end
function Collection:add_file_snippets(path, ft)
	log.info(
		"Adding snippets for filetype `%s` from file `%s`",
		ft,
		path
	)
	local snippets, autosnippets = _luasnip_load_file(path)

	loader_util.add_file_snippets(ft, path, snippets, autosnippets, self.add_opts)

	ls.refresh_notify(ft)
end
function Collection:do_lazy_load(ft)
	if session.loaded_fts[ft] then
		-- skip if already loaded.
		return
	end

	for file, _ in pairs(self.lazy_files[ft]) do
		self:add_file_snippets(file, ft)
	end
end
-- will only do something, if the file at `path` is actually in the collection.
function Collection:reload(path)
	local path_ft = self.path_ft[path]
	if not path_ft then
		-- file not in this collection.
		return
	end

	if self.lazy and not session.loaded_fts[path_ft] then
		-- file known, but not yet loaded.
		return
	end

	-- will override previously-loaded snippets from this path.
	self:add_file_snippets(path, path_ft)

	-- clean snippets if enough were removed.
	ls.clean_invalidated({ inv_limit = 100 })
end

function M._load_lazy_loaded_ft(ft)
	log.info("Loading lazy-load-snippets for filetype `%s`", ft)

	for _, collection in ipairs(M.collections) do
		collection:do_lazy_load(ft)
	end
end

local function _load(lazy, opts)
	opts = opts or {}

	local paths = opts.paths
	local add_opts = loader_util.make_add_opts(opts)
	local include = opts.include
	local exclude = opts.exclude

	local collection_roots = loader_util.resolve_root_paths(opts.paths, "luasnippets")
	log.info("Found roots `%s` for paths `%s`.", vim.inspect(collection_roots), vim.inspect(paths))

	for _, collection_root in ipairs(collection_roots) do
		table.insert(M.collections, Collection:new(collection_root, lazy, include, exclude, add_opts))
	end
end

function M.load(opts)
	_load(false, opts)
end

function M.lazy_load(opts)
	_load(true, opts)
	-- load for current buffer on startup.
	M._load_lazy_loaded_ft(vim.api.nvim_get_current_buf())
end

return M

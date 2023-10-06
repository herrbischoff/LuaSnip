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
local Path = require("luasnip.util.path")
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
	-- n   (at least 5) is _luasnip_load_files
	local current_call_depth = 4
	local debuginfo

	repeat
		current_call_depth = current_call_depth + 1
		debuginfo = debug.getinfo(current_call_depth, "n")
	until debuginfo.name == "_luasnip_load_files"

	-- ret is stored into a local, and not returned immediately to prevent tail
	-- call optimization, which seems to invalidate the stackframe-numbers
	-- determined earlier.
	--
	-- current_call_depth-0 is _luasnip_load_files,
	-- current_call_depth-1 is pcall, and
	-- current_call_depth-2 is the lua-loaded file.
	-- "Sl": get only source-file and current line.
	local ret = debug.getinfo(current_call_depth - 2, "Sl")
	return ret
end

local function _luasnip_load_files(ft, files, add_opts)
	for _, file in ipairs(files) do
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

		-- keep track of snippet-source.
		cache.path_snippets[file] = {
			add_opts = add_opts,
			ft = ft,
		}

		ls.add_snippets(
			ft,
			file_snippets,
			vim.tbl_extend("keep", {
				type = "snippets",
				key = "__snippets_" .. file,
				-- prevent refresh here, will be done outside loop.
				refresh_notify = false,
			}, add_opts)
		)
		ls.add_snippets(
			ft,
			file_autosnippets,
			vim.tbl_extend("keep", {
				type = "autosnippets",
				key = "__autosnippets_" .. file,
				-- prevent refresh here, will be done outside loop.
				refresh_notify = false,
			}, add_opts)
		)
		log.info(
			"Adding %s snippets and %s autosnippets from %s to ft `%s`",
			#file_snippets,
			#file_autosnippets,
			file,
			ft
		)
	end

	ls.refresh_notify(ft)
end


-- map ft->set of files (table where files are keys, and they are either true
-- or nil, can use pairs to iterate over them).
local ft_paths = require("luasnip.loaders.data").lua_ft_paths

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
				error(("Path `%s` is not a child of root `%s`"):format(path, root))
			end
			return lua_package_file_filter(path) and ft_filter(path)
		end,
		add_opts = add_opts,
		lazy = lazy,
		lazy_files = autotable(2, {warn = false}),
	}, Collection_mt)

	-- only register files up to a depth of 2.
	o.watcher = tree_watcher(root, 2, {
		-- don't handle removals for now.
		new_file = function(path)
			vim.schedule_wrap(function()
				o:new_file(path)
			end)()
		end,
		changed_file = function(path)
			vim.schedule_wrap(function()
				o:reload(path)
			end)()
		end
	})

	return o
end

-- notify collection about a potential new file.
function Collection:new_file(path)
	if not self.file_filter(path) then
		return
	end

	local file_ft = loader_util.collection_file_ft(self.root, path)

	ft_paths[file_ft][path] = true

	if self.lazy then
		if not session.loaded_fts[file_ft] then
			log.info("Registering lazy-load-snippets for ft `%s` from file `%s`", file_ft, path)

			-- only register to load later.
			table.insert(self.lazy_files[file_ft], path)
			return
		else
			log.info(
				"Immediately loading lazy-load-snippets for already-active filetype `%s` from file `%s`",
				file_ft,
				path
			)
		end
	end

	_luasnip_load_files(file_ft, {path}, self.add_opts)
end
function Collection:do_lazy_load(ft)
	if session.loaded_fts[ft] then
		-- skip if already loaded.
		return
	end

	log.info("Loading lazy-load-snippets for filetype `%s`", ft)
	for _, file in ipairs(self.lazy_files) do
		_luasnip_load_files(ft, {file}, self.add_opts)
	end
end
function Collection:reload(fname)
	local file_ft = loader_util.collection_file_ft(self.root, fname)

	if self.lazy and not session.loaded_fts[file_ft] then
		return
	end

	_luasnip_load_files(file_ft, {fname}, self.add_opts)
	-- clean snippets if enough were removed.
	ls.clean_invalidated({ inv_limit = 100 })
end

function M._load_lazy_loaded_ft(ft)
	for _, collection in ipairs(M.collections) do
		collection:do_lazy_load(ft)
	end
end

function M.load(opts)
	opts = opts or {}

	local collection_roots = loader_util.resolve_root_paths(opts.path, "luasnippets")
	local add_opts = loader_util.add_opts(opts)

	for _, collection_root in ipairs(collection_roots) do
		table.insert(M.collections, Collection:new(collection_root, false, opts.include, opts.exclude, add_opts))
	end
end

function M.lazy_load(opts)
	opts = opts or {}

	local collection_roots = loader_util.resolve_root_paths(opts.path, "luasnippets")
	local add_opts = loader_util.add_opts(opts)

	for _, collection_root in ipairs(collection_roots) do
		table.insert(M.collections, Collection:new(collection_root, true, opts.include, opts.exclude, add_opts))
	end

	-- load for current buffer on startup.
	M._load_lazy_loaded_ft(vim.api.nvim_get_current_buf())
end

-- Make sure filename is normalized
function M._reload_file(filename)
	local file_cache = cache.path_snippets[filename]
	-- only clear and load(!!! snippets may not actually be loaded, lazy_load)
	-- if the snippets were really loaded.
	-- normally file_cache should exist if the autocommand was registered, just
	-- be safe here.
	if file_cache then
		local add_opts = file_cache.add_opts
		local ft = file_cache.ft

		log.info("Re-loading snippets contributed by %s", filename)
		_luasnip_load_files(ft, { filename }, add_opts)
		ls.clean_invalidated({ inv_limit = 100 })
	end
end

function M.edit_snippet_files()
	loader_util.edit_snippet_files(cache.ft_paths)
end

return M

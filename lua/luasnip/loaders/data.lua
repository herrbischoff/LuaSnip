--- This module stores all files loaded by any of the loaders, ordered by their
--- filetype.
--- This is to facilitate luasnip.loaders.edit_snippets, and to handle
--- persistency of data, which is not automatically given, since the module-name
--- we use (luasnip.loaders.*) is not necessarily the one used by the user
--- (luasnip/loader/*, for example).

local autotable = require("luasnip.util.auto_table").autotable

local M = {
	lua_collections = {},
	lua_ft_paths = autotable(2),

	snipmate_collections = {},
	snipmate_ft_paths = autotable(2),
	-- set by loader.
	snipmate_cache = nil,
}

return M

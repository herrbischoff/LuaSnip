--- This module stores all files loaded by any of the loaders, ordered by their
--- filetype.
--- This is to facilitate luasnip.loaders.edit_snippets.

local autotable = require("luasnip.util.auto_table").autotable

local M = {}

M.lua_ft_paths = autotable(2)

return M

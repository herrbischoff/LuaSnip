local M = {}

local refresh_enqueued = false
local next_refresh_fts = {}

function M.refresh_notify(ft)
	next_refresh_fts[ft] = true

	if not refresh_enqueued then
		vim.schedule(function()
			for enq_ft, _ in pairs(next_refresh_fts) do
				require("luasnip").refresh_notify(enq_ft)
			end

			next_refresh_fts = {}
			refresh_enqueued = false
		end)

		refresh_enqueued = true
	end
end

local clean_enqueued = false
function M.clean_invalidated()
	if not clean_enqueued then
		vim.schedule(function()
			require("luasnip").clean_invalidated({inv_limit = 100})
		end)
	end
	clean_enqueued = true
end

return M

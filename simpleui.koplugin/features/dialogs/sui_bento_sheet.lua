-- sui_bento_sheet.lua — Simple UI
-- Action sheet that places a module in the bento grid of its page: its width
-- (1/3, 1/2, 2/3, full), its position and, optionally, further actions of the
-- caller, and removes the module. A strip at the top shows the module's row as it will render; unless
-- the screen has auto-adjust off, a width change makes the neighbour of the
-- row adjust, and the strip says which module was adjusted. The sheet grows to
-- fit and never paginates.
--
--   BentoSheet.show{
--       mod_id        string     module to place (required)
--       pfx           string     settings prefix of the screen (required)
--       layout        table?     layout being edited; loaded when absent
--       subtitle      string?    summary shown after the preview label under the title
--       rows          table[]?   extra action rows { text, sui_icon, chevron,
--                                callback }, listed before "Remove"; the sheet
--                                closes before they run
--       on_changed    function?  after every change has been saved
--       on_removed    function?  after the module has been removed
--   }
--   -> window, or nil when the screen is unknown or the module is not placed
--      on any page.

local ActionSheet     = require("engines/sui_action_sheet")
local BentoPreview    = require("engines/sui_bento_preview")
local Bento           = require("infra/sui_bento")
local Config          = require("infra/sui_config")
local Layout          = require("infra/sui_layout")
local _               = require("infra/sui_i18n").translate
local T               = require("ffi/util").template

local BentoSheet = {}

-- Left/right move the module; up/down move its whole row (captions above).
-- A full-width module owns its row, so only up/down are offered.
local MOVES = {
    { dir = "left",  text = "←" },
    { dir = "right", text = "→" },
    { dir = "up",    text = "↑" },
    { dir = "down",  text = "↓" },
}

function BentoSheet.show(opts)
    local mod_id, pfx = opts.mod_id, opts.pfx
    local layout_key, screen_id = Layout.screenFor(pfx)
    if not layout_key then return nil end
    local layout = opts.layout or Layout.load(pfx, layout_key)
    if not Layout.findPage(layout, mod_id) then return nil end

    local win, message
    local buildSections

    -- Which modules besides the placed one changed width.
    local function describe(changed)
        local others = {}
        for _i, id in ipairs(changed) do
            if id ~= mod_id then others[#others + 1] = id end
        end
        if #others == 1 then
            return T(_("%1 adjusted to %2"), Layout.getModuleName(others[1]),
                Config.bentoSpanLabel(Config.getBentoSpan(others[1], pfx)))
        elseif #others > 1 then
            return _("Neighbouring modules adjusted")
        end
    end

    -- Spans of the page of the placed module.
    local function pageSpans()
        local _ids, spans = Layout.pageSpans(Layout.findPage(layout, mod_id), pfx)
        return spans
    end

    -- Saves and repaints once a change has been made. A move always saves: it
    -- reorders the page even when no width changed.
    local function commit(changed, always)
        if #changed > 0 or always then
            Layout.save(layout, pfx, layout_key, screen_id)
            if opts.on_changed then opts.on_changed() end
        end
        message = describe(changed)
        if win then win:update{ sections = buildSections() } end
    end

    -- Widths the auto-adjust took from the other modules, kept to give them
    -- back when auto-adjust is turned off.
    local originals = {}

    local function setWidth(span)
        local before  = pageSpans()
        local changed = Layout.setSpan(layout, pfx, mod_id, span)
        for _i, id in ipairs(changed) do
            if id ~= mod_id and originals[id] == nil then originals[id] = before[id] end
        end
        commit(changed)
    end

    local function move(dir)
        originals = {}
        commit(Layout.move(layout, pfx, mod_id, dir), true)
    end

    -- Turning auto-adjust on fits the row around the current width; turning
    -- it off returns the neighbours to the widths they had.
    local function setAutofit(on)
        Config.setBentoAutofit(on, pfx)
        if on then
            setWidth(pageSpans()[mod_id])
            return
        end
        local changed = {}
        for id, span in pairs(originals) do
            Config.setBentoSpan(span, id, pfx)
            changed[#changed + 1] = id
        end
        originals = {}
        commit(changed)
    end

    -- Asks, then takes the module off its page. The sheet is already closed.
    local function confirmRemove()
        require("features/dialogs/sui_dialogs").confirm{
            text        = _("Delete") .. " " .. Layout.getModuleName(mod_id) .. "?",
            ok_callback = function()
                Layout.remove(layout, pfx, mod_id)
                Layout.save(layout, pfx, layout_key, screen_id)
                if opts.on_changed then opts.on_changed() end
                if opts.on_removed then opts.on_removed() end
            end,
        }
    end

    function buildSections()
        local page = Layout.findPage(layout, mod_id)
        local ids, spans = Layout.pageSpans(page, pfx)
        local can = Bento.canMove(ids, spans, mod_id)

        local widths = {}
        for _i, option in ipairs(Config.bentoSpanOptions()) do
            widths[#widths + 1] = {
                text     = option.label,
                selected = spans[mod_id] == option.value,
                callback = function() setWidth(option.value) end,
            }
        end
        local full = spans[mod_id] == Bento.FULL
        local moves = {}
        for _i, move_option in ipairs(MOVES) do
            local dir = move_option.dir
            if not (full and (dir == "left" or dir == "right")) then
                moves[#moves + 1] = {
                    text     = move_option.text,
                    enabled  = can[dir],
                    callback = function() move(dir) end,
                }
            end
        end
        local move_labels = full and { { text = _("Position"), from = 1 } } or {
            { text = _("Position"), from = 1 },
            { text = _("Move row"), from = 3 },
        }

        local autofit = Config.isBentoAutofit(pfx)
        local bento_rows = Bento.pack(ids, spans)
        local row_no, own_row
        for r, candidate in ipairs(bento_rows) do
            for _i, id in ipairs(candidate.ids) do
                if id == mod_id then row_no, own_row = r, candidate end
            end
        end

        -- The row of the module, then what the last change did to it.
        local function preview(ctx)
            return BentoPreview.build(ctx, {
                ids        = own_row.ids,
                spans      = spans,
                label_for  = Layout.getModuleName,
                span_label = Config.bentoSpanLabel,
                highlight  = mod_id,
            }, T(_("Row %1 of %2"), row_no, #bento_rows), message)
        end

        local sections = {
            { type = "widget",   build = preview },
            { type = "note",     text = _("Width") },
            { type = "segments", items = widths },
            { type = "note",     columns = #moves, labels = move_labels },
            { type = "segments", items = moves },
            ActionSheet.list{ {
                text     = _("Adjust row automatically"),
                sui_icon = "convert",
                toggle   = autofit,
                callback = function() setAutofit(not autofit) end,
            } },
        }
        local rows = {}
        for _i, row in ipairs(opts.rows or {}) do
            rows[#rows + 1] = {
                text     = row.text,
                sui_icon = row.sui_icon,
                chevron  = row.chevron,
                callback = function()
                    win:close()
                    row.callback()
                end,
            }
        end
        rows[#rows + 1] = {
            text     = _("Remove"),
            sui_icon = "delete",
            callback = function()
                win:close()
                confirmRemove()
            end,
        }
        sections[#sections + 1] = ActionSheet.list(rows)
        return sections
    end

    win = ActionSheet.show{
        name     = "sui_win_bento_sheet",
        title    = _("Width and Position"),
        icon     = "layout",
        message  = opts.subtitle and (_("Home Screen row preview") .. " · " .. opts.subtitle)
                   or _("Home Screen row preview"),
        sections = buildSections(),
    }
    return win
end

return BentoSheet

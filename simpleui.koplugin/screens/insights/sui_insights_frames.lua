-- sui_insights_frames.lua — Simple UI
-- Frames of the Reading Insights window: categories (a header above their content),
-- cards (a title with a chart or other content) and rows of figure tiles. Cards
-- and tiles share the borders, radii and gaps below; icons take the accent colour.
--
-- Usage:
--   local card_w    = Frames.cardWidth(inner_w, SZ)     -- width of a card in a category
--   local content_w = Frames.contentWidth(inner_w, SZ)  -- width inside a card
--   Frames.panel{ w = card_w, SZ = SZ, content = widget }   -- a card without a title
--   Frames.headerHeight{ SZ = SZ, inner_w = inner_w, title = _("Today") }
--   local items = Frames.flow{
--       inner_w = w, SZ = SZ, max_h = avail_h,
--       categories = { {
--           title = _("Today"),
--           children = {
--               Frames.tiles{ w = card_w, SZ = SZ, items = {
--                   { icon = "clock", label = _("Total time"), value = "57m" },
--                   { icon = "page",  label = _("Pages read"), value = "24" },
--               } },
--               Frames.card{ w = card_w, SZ = SZ, title = _("By hour"), icon = "clock", content = chart },
--           },
--       } },
--   }
--   -- items: the blocks to place in the window, packed page by page up to `max_h`.

local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local RightContainer  = require("ui/widget/container/rightcontainer")
local RoundedFrame    = require("infra/sui_backdrop").RoundedFrame
local SUIStyle        = require("features/sui_style")
local UI              = require("infra/sui_core")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen

local Frames = {}

local TILE_VALUE_BOOST = 1.3   -- value size of a tile, relative to FS_TITLE

local function metrics(SZ)
    local function s(n) return SZ(Screen:scaleBySize(n)) end
    return {
        s = s, border = SUIStyle.BORDER_SZ,
        section_gap = s(12),
        card_pad  = s(12), card_r  = s(10), gap = s(8),
        tile_pad  = s(12),
    }
end

-- Width of a card or tile row placed in a category of `inner_w`.
function Frames.cardWidth(inner_w)
    return inner_w
end

-- Width of the content of a card placed in a category of `inner_w`.
function Frames.contentWidth(inner_w, SZ)
    local m = metrics(SZ)
    return Frames.cardWidth(inner_w) - 2 * (m.border + m.card_pad)
end

local function text(str, face, max_w, o)
    o = o or {}
    return UI.makeColoredText{
        text = str, face = face, fgcolor = o.color or SUIStyle.COLOR.text_primary, bold = o.bold,
        max_width = max_w, truncate_with_ellipsis = true,
    }
end

-- The icon `icon` in a box of `d` px, in the accent colour when one is set.
local function badge(icon, d)
    return CenterContainer:new{
        dimen = Geom:new{ w = d, h = d },
        UI.makeAccentText({
            text = SUIStyle.icon(icon), face = SUIStyle.glyphFace(d), padding = 0,
        }, SUIStyle.COLOR.text_primary),
    }
end

-- Icon and bold title side by side, `w` wide at most.
local function header(o, m, w, badge_d, face)
    local gap = m.s(10)
    return HorizontalGroup:new{ align = "center",
        badge(o.icon, badge_d),
        HorizontalSpan:new{ width = gap },
        text(o.title, face, w - badge_d - gap, { bold = true }),
    }
end

local function outline(m, w, h, radius, padding, content)
    return RoundedFrame:new{
        bordersize = m.border, color = SUIStyle.COLOR.gray, radius = radius, padding = padding,
        width = w, height = h, content,
    }
end

-- A bordered panel of width `w` around `content`, without a title.
--   w, SZ, content
function Frames.panel(o)
    local m = metrics(o.SZ)
    return outline(m, o.w, nil, m.card_r, m.card_pad, o.content)
end

-- A card of width `w`: badge and title above `content`.
--   w, SZ, title, icon, content
function Frames.card(o)
    local m = metrics(o.SZ)
    local inner_w = o.w - 2 * (m.border + m.card_pad)
    local face = Font:getFace(SUIStyle.FACE_REGULAR, o.SZ(SUIStyle.FS_DETAIL))
    return outline(m, o.w, nil, m.card_r, m.card_pad, VerticalGroup:new{ align = "left",
        header(o, m, inner_w, m.s(24), face),
        VerticalSpan:new{ width = m.s(10) },
        o.content,
    })
end

-- A row of figure tiles sharing the width `w`. Two tiles put the icon beside the
-- figure; more stack icon, value and label so each fits its share.
--   w, SZ, items = { { icon, label, value, sub (optional line), on_tap (optional) }, ... }
function Frames.tiles(o)
    local m, n, SZ = metrics(o.SZ), #o.items, o.SZ
    local tile_w   = math.floor((o.w - (n - 1) * m.gap) / n)
    local inner_w  = tile_w - 2 * (m.border + m.tile_pad)
    local stacked  = n > 2
    local face_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_DETAIL))
    local face_sub = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION))
    local face_val = Font:getFace(SUIStyle.FACE_REGULAR,
        math.floor(SZ(SUIStyle.FS_TITLE) * (stacked and 1 or TILE_VALUE_BOOST)))
    local badge_d  = m.s(stacked and 28 or 32)
    local badge_gap = m.s(10)

    local contents, tallest = {}, 0
    for i, item in ipairs(o.items) do
        local text_w = stacked and inner_w or inner_w - badge_d - badge_gap
        local label = text(item.label, face_lbl, text_w)
        local value = text(item.value, face_val, text_w, { bold = true })
        local sub = item.sub and text(item.sub, face_sub, text_w)
        local content
        if stacked then
            content = VerticalGroup:new{ align = "center",
                badge(item.icon, badge_d), VerticalSpan:new{ width = m.s(6) }, value, label, sub,
            }
        else
            content = HorizontalGroup:new{ align = "center",
                badge(item.icon, badge_d),
                HorizontalSpan:new{ width = badge_gap },
                VerticalGroup:new{ align = "left", label, value, sub },
            }
        end
        contents[i] = content
        tallest = math.max(tallest, content:getSize().h)
    end

    local tile_h = tallest + 2 * (m.border + m.tile_pad)
    local Container = stacked and CenterContainer or LeftContainer
    local row = HorizontalGroup:new{ align = "top" }
    for i, item in ipairs(o.items) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = m.gap } end
        local tile = outline(m, tile_w, tile_h, m.card_r, m.tile_pad,
            Container:new{ dimen = Geom:new{ w = inner_w, h = tallest }, contents[i] })
        if item.on_tap then
            tile = require("engines/sui_window").Input.tapable(tile, { on_tap = item.on_tap },
                Geom:new{ w = tile_w, h = tile_h })
        end
        row[#row + 1] = tile
    end
    return row
end

-- A list of full-width rows in one card, a hairline between them: the icon, the
-- label (with an optional line under it) and the value at the right edge.
--   w, SZ, items = { { icon, label, value, sub (optional line) }, ... }
function Frames.rows(o)
    local m, SZ = metrics(o.SZ), o.SZ
    local row_w   = o.w - 2 * m.border
    local inner_w = row_w - 2 * m.card_pad
    local face_lbl = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_BODY))
    local face_sub = Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_CAPTION))
    local badge_d, gap, row_min_h = m.s(28), m.s(12), m.s(52)

    local body = VerticalGroup:new{ align = "left" }
    for i, item in ipairs(o.items) do
        local value = text(item.value, face_lbl, inner_w - badge_d - gap, { bold = true })
        local text_w = math.max(1, inner_w - badge_d - 2 * gap - value:getSize().w)
        local label = VerticalGroup:new{ align = "left",
            text(item.label, face_lbl, text_w),
            item.sub and text(item.sub, face_sub, text_w),
        }
        local row_h = math.max(row_min_h, label:getSize().h + 2 * m.gap)
        if i > 1 then
            body[#body + 1] = CenterContainer:new{
                dimen = Geom:new{ w = row_w, h = m.border },
                LineWidget:new{
                    dimen = Geom:new{ w = inner_w, h = m.border }, background = SUIStyle.COLOR.gray,
                },
            }
        end
        body[#body + 1] = CenterContainer:new{
            dimen = Geom:new{ w = row_w, h = row_h },
            HorizontalGroup:new{ align = "center",
                badge(item.icon, badge_d),
                HorizontalSpan:new{ width = gap },
                LeftContainer:new{ dimen = Geom:new{ w = text_w + gap, h = row_h }, label },
                RightContainer:new{ dimen = Geom:new{ w = value:getSize().w, h = row_h }, value },
            },
        }
    end
    return outline(m, o.w, nil, m.card_r, 0, body)
end

-- Children kept together as one unit: they never split across pages.
--   SZ, children
function Frames.stack(o)
    local gap = metrics(o.SZ).gap
    local group = VerticalGroup:new{ align = "left" }
    for i, child in ipairs(o.children) do
        if i > 1 then group[#group + 1] = VerticalSpan:new{ width = gap } end
        group[#group + 1] = child
    end
    return group
end

local HEAD_GAP = 10   -- before scaling: space between a category title and its first child

local function categoryFace(SZ)
    return Font:getFace(SUIStyle.FACE_REGULAR, SZ(SUIStyle.FS_SUBTITLE))
end

-- Height of the header a category puts above its first child on a page.
--   SZ, inner_w, title
function Frames.headerHeight(o)
    local m = metrics(o.SZ)
    return m.section_gap + text(o.title, categoryFace(o.SZ), o.inner_w, { bold = true }):getSize().h + m.s(HEAD_GAP)
end

-- The blocks of a list of categories, each a bold `title` above its children and
-- as tall as the content it holds. Children fill a page in order, whichever
-- category they belong to; a child that does not fit the page left starts the next
-- one, under the header of its category again. A child taller than `max_h` is kept
-- whole on a page of its own. The first block of every page after the first is
-- flagged `force_new_page`, so the window breaks pages where they were counted.
--   inner_w, SZ, max_h, categories = { { title, children }, ... }
function Frames.flow(o)
    local m = metrics(o.SZ)
    local face = categoryFace(o.SZ)
    local head_gap = m.s(HEAD_GAP)

    local blocks, used = {}, 0
    for _i, cat in ipairs(o.categories) do
        local head_h = Frames.headerHeight{ SZ = o.SZ, inner_w = o.inner_w, title = cat.title }
        local block
        for _j, child in ipairs(cat.children) do
            local child_h = child:getSize().h
            if block and used + m.gap + child_h <= o.max_h then
                block[#block + 1] = VerticalSpan:new{ width = m.gap }
                block[#block + 1] = child
                used = used + m.gap + child_h
            else
                local new_page = used > 0 and used + head_h + child_h > o.max_h
                block = VerticalGroup:new{ align = "left",
                    VerticalSpan:new{ width = m.section_gap },
                    text(cat.title, face, o.inner_w, { bold = true }),
                    VerticalSpan:new{ width = head_gap },
                    child,
                }
                block.force_new_page = new_page or nil
                blocks[#blocks + 1] = block
                used = (new_page and 0 or used) + head_h + child_h
            end
        end
    end
    return blocks
end

return Frames

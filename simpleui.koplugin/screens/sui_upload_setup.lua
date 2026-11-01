-- Kindle side of the book-upload page: shows a QR code, the phone sends
-- files, the books land in the library folder.
local UIManager = require("ui/uimanager")
local _ = require("infra/sui_i18n").translate
local M = {}

local function notice(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout })
end

--- Opens the page; the QR code stays until the phone closes it or the
--- idle timeout expires.
function M.phone()
    require("ui/network/manager"):runWhenOnline(function() M._phone() end)
end

function M._phone()
    local Web = require("features/sui_upload_web")
    local page
    local url, err = Web.start(function(kind)
        if kind == "stopped" and page then
            local closing = page
            page = nil
            UIManager:close(closing)
        end
    end)
    if not url then
        notice(_("Could not start the upload page.") .. "\n" .. _(tostring(err)))
        return
    end
    local Screen = require("device").screen
    local Geom = require("ui/geometry")
    local Font = require("ui/font")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local QRWidget = require("ui/widget/qrwidget")
    local Button = require("ui/widget/button")
    local w, h = Screen:getWidth(), Screen:getHeight()
    local inner = w - 2 * Size.padding.large * 3
    local qr_size = math.floor(math.min(w, h) * 0.62)
    page = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = w, h = h }, covers_fullscreen = true }
    local function cancel() Web.stop() end
    local content = VerticalGroup:new{ align = "center",
        TextWidget:new{ text = _("Send books to the Kindle"), face = Font:getFace("tfont", 24), bold = true },
        VerticalSpan:new{ width = Size.padding.large * 2 },
        QRWidget:new{ text = url, width = qr_size, height = qr_size },
        VerticalSpan:new{ width = Size.padding.large * 2 },
        TextBoxWidget:new{ width = inner, alignment = "center", face = Font:getFace("cfont", 18),
            text = _("Scan with a phone on the same Wi-Fi, then pick a file to send.") },
        VerticalSpan:new{ width = Size.padding.default },
        TextWidget:new{ text = url:gsub("%?t=.*$", ""), face = Font:getFace("infont", 16), fgcolor = Blitbuffer.COLOR_DARK_GRAY },
        VerticalSpan:new{ width = Size.padding.default },
        TextBoxWidget:new{ width = inner, alignment = "center", face = Font:getFace("cfont", 15), fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            text = _("Available for 5 minutes and closes after the upload. Use only on a Wi-Fi network you trust.") },
        VerticalSpan:new{ width = Size.padding.large * 2 },
        Button:new{ text = _("Cancel"), width = math.floor(w * 0.5), callback = cancel, show_parent = page },
    }
    page[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, content } }
    function page:onShow() UIManager:setDirty(self, "full") end
    function page:onCloseWidget()
        UIManager:setDirty(nil, "full")
        if Web.running() then Web.stop() end
    end
    UIManager:show(page)
end

--- Menu entry: opens the upload page directly.
function M.show()
    M.phone()
end

return M

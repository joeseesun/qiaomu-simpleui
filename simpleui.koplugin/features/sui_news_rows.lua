-- Adapt the Obsidian client's source/date + title + right thumbnail hierarchy
-- while retaining native MenuItem gestures, focus and pagination.
local M = {}
function M.apply(menu)
    if not menu.item_group then return end
    local Screen=require("device").screen
    local Font=require("ui/font")
    local BB=require("ffi/blitbuffer")
    local Geom=require("ui/geometry")
    local Text=require("ui/widget/textwidget")
    local Box=require("ui/widget/textboxwidget")
    local Group=require("ui/widget/verticalgroup")
    local HGroup=require("ui/widget/horizontalgroup")
    local Span=require("ui/widget/verticalspan")
    local HSpan=require("ui/widget/horizontalspan")
    local Left=require("ui/widget/container/leftcontainer")
    local Right=require("ui/widget/container/rightcontainer")
    local Overlap=require("ui/widget/overlapgroup")
    local Center=require("ui/widget/container/centercontainer")
    local Frame=require("ui/widget/container/framecontainer")
    local News=require("features/sui_news")
    local Images=require("features/sui_news_images")
    local gap=Screen:scaleBySize(8)
    local face=Font:getFace("smallinfofont",18)
    local probe=Box:new{text="阅读",face=face,width=1000}
    local line=probe:getSize().h;probe:free()
    for _,row in ipairs(menu.item_group) do
        local e=row.entry and row.entry.news_entry
        if e then
            local flag=News.flag(e.id)
            local h=row.dimen.h
            local thumb=Images.path(e.image)
            local image
            local size=math.min(Screen:scaleBySize(64),h-gap*2)
            if thumb then
                local ok,result=pcall(function() return require("ui/widget/imagewidget"):new{
                    file=thumb,width=size,height=size,scale_factor=0,
                } end)
                if ok then image=result end
            end
            local copy_w=row.content_width-(image and size+gap or 0)
            local meta_face=Font:getFace("infont",12)
            local date=Text:new{text=(e.published or ""):sub(6,10),face=meta_face,fgcolor=BB.COLOR_DARK_GRAY}
            local origin=Text:new{
                text=(e.sourceName~="" and e.sourceName or e.sourceId),
                face=meta_face,fgcolor=BB.COLOR_DARK_GRAY,
                max_width=math.max(1,copy_w-date:getSize().w-gap),
            }
            local meta_h=math.max(origin:getSize().h,date:getSize().h)
            local meta=Overlap:new{allow_mirroring=false,dimen=Geom:new{w=copy_w,h=meta_h},
                Left:new{dimen=Geom:new{w=copy_w,h=meta_h},origin},
                Right:new{dimen=Geom:new{w=copy_w,h=meta_h},date},
            }
            local title=Box:new{
                text=(flag.starred and "★ " or "")..News.title(e),face=face,bold=not flag.read,
                width=copy_w,height=math.min(line*2,h-meta:getSize().h-gap*3),
                height_adjust=true,height_overflow_show_ellipsis=true,alignment="left",
            }
            local copy=Group:new{align="left",meta,Span:new{width=gap},title}
            local content=HGroup:new{align="center",
                Left:new{dimen=Geom:new{w=copy_w,h=h-gap},copy},
                image and HSpan:new{width=gap},image,
            }
            -- Keep the native underline container so focus feedback still works.
            local underline=row._underline_container
            for i=#underline,1,-1 do
                if underline[i].free then underline[i]:free() end
                underline[i]=nil
            end
            underline[1]=Center:new{
                dimen=Geom:new{w=row.content_width,h=h},
                Frame:new{padding=0,bordersize=0,content},
            }
        end
    end
end
return M

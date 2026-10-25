"""Execute the actual screen gesture/layout functions against native widget contracts."""
from pathlib import Path
import re
from lupa.lua54 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]/'simpleui.koplugin'
engine=(ROOT/'engines/sui_screen_engine.lua').read_text()
functions=[re.search(r'function ScreenWidget:'+name+r'\([^\n]*\).*?\nend\n',engine,re.S).group()
           for name in ['onScreenSwipe','_initLayout']]
lua=LuaRuntime(unpack_returned_tuples=True)
lua.globals().source='\n'.join(functions)
lua.execute('''
ScreenWidget={}
local function widget(o)
 o=o or {}
 function o:getSize()
  if self.kind=="frame" then
   local c=self[1]:getSize()
   return {w=c.w+(self.padding_left or 0)+(self.padding_right or 0),h=c.h}
  end
  return self.dimen or {w=0,h=0}
 end
 return o
end
local function factory(kind)
 return {new=function(_,o) o=widget(o);o.kind=kind;return o end}
end
Geom={new=function(_,o) return o end}
Screen={getWidth=function() return 1072 end}
UI={getContentHeight=function() return 1280 end,SIDE_PAD=function() return 40 end,getInnerW=function() return 992 end}
VerticalGroup=factory("group");FrameContainer=factory("frame");VerticalSpan=factory("span")
BottomContainer=factory("bottom");OverlapGroup=factory("overlap")
ScrollableContainer=factory("scroll")
ScrollableContainer.getScrollbarWidth=function() return 30 end
ScrollableContainer.onScrollableSwipe=function(self,_,ges)
 self.direction=ges.direction;return self.scrollable==true
end
SUIWallpaper={styleGetBgWidget=function() return nil end}
buildChevronFooter=function() return {widget=widget()} end
buildDotFooter=function() return {widget=widget()} end
assert(load(source))()
local screen=setmetatable({}, {__index=ScreenWidget})
screen:_initLayout()
assert(screen._layout_inner_w==962,"reserve scrollbar gutter before cover layout")
assert(screen._body_scroll.dimen.h==1280 and screen.cropping_widget==screen._body_scroll,
 "scroll and dirty-region crop must end above the navbar")
screen._fmGestureAction=function() return "file_manager" end
screen._isSideEdge=function() return false end
screen._swipeBookMod=function() return true end
screen._body_scroll.scrollable=true
assert(screen:onScreenSwipe(nil,{direction="north"})==true)
assert(screen._body_scroll.direction=="north")
assert(screen._body_scroll:onScrollableSwipe(nil,{direction="west"})==false,
 "scroll must not steal grid pagination")
assert(screen:onScreenSwipe(nil,{direction="west"})==true)
screen._body_scroll.scrollable=false
assert(screen:onScreenSwipe(nil,{direction="south"})=="file_manager")
''')
print('PASS: bar-aware viewport/crop, scrollbar gutter, vertical swipe, horizontal grid navigation, non-overflow fallback.')

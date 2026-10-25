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

# Native IconButton passes icon to IconWidget as a symbolic name. A file path
# silently becomes icon-not-found; exercise the actual title-row builder and
# the project's existing native-image replacement helper together.
label=(ROOT/'engines/sui_section_label.lua').read_text()
style=(ROOT/'features/sui_style.lua').read_text()
title_row=re.search(r'local function buildTitleRow\(.*?\nend\n',label,re.S).group()
restore=re.search(r'function M.restoreDefaultIcon\(.*?\nend\n',style,re.S).group()
icons=LuaRuntime(unpack_returned_tuples=True)
icons.globals().builder_source=title_row+'\nreturn buildTitleRow'
icons.globals().restore_source=restore
icons.globals().plugin_root=str(ROOT)
icons.execute('''
local function widget(o)
 o=o or {}
 function o:getSize() return self.dimen or {w=self.width or 24,h=self.height or 24} end
 function o:free() end
 function o:init() end
 return o
end
local factory={new=function(_,o) return widget(o) end}
CenterContainer=factory;HorizontalGroup=factory;HorizontalSpan=factory;LeftContainer=factory
Geom={new=function(_,o) return o end}
PAD=8
LabelStyle={color=function() end,makeText=function() return widget() end}
PageNav={indicatorFace=function() end}
UI={makeColoredText=function() return widget() end}
Paths={getPluginDir=function() return plugin_root.."/" end}
IconButton={new=function(_,o)
 o=widget(o)
 o.image=widget{icon=o.icon,file="resources/icons/icon-not-found.svg"}
 return o
end}
M={}
assert(load(restore_source))()
SUIStyle=M
local build=assert(load(builder_source))()
local invoked=false
local row,stops=build({text="Recently added",on_menu=function() invoked=true end},992,1,nil,true)
local more=stops[1].widget
assert(more.image.file==plugin_root.."/icons/qiaomu_more.svg",
 "overflow icon must load its SVG file, not the native warning fallback")
assert(more.image.icon==nil)
more.callback();assert(invoked)
''')
print('PASS: shelf overflow uses a real icon file and retains its menu callback.')

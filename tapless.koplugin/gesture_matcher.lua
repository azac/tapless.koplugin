-- Choose the native kernel only on its supported ABI; retain Lua everywhere else.
local dir = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]+$')
local Original = dofile(dir .. '/lua_matcher.lua')
Original.backend = 'lua'
local choose = dofile(dir .. '/native_loader.lua')
return choose(dir, Original)

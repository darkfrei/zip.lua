zip.lua is a pure Lua/FFI zip writer/reader module for LuaJIT and Love2D.

## features:
- deflate compression using system zlib (ffi)
- no external Lua dependencies (use any serialisation instead of serpent)
- works on Windows, Linux, macOS
- compatible with Love2D save/load
- supports reading and writing standard .zip archives
- supports stored and deflated entries
- supports central directory and EOCD
- compatible with Lua 5.1 / LuaJIT

## usage example:

```lua
local zip = require("zip")
local archive = zip.new("optional comment")

archive:addFile("hello.txt", "hello world", true)

local data = { a = 1, b = true, c = {1,2,3} }
local serialized = serializeTable(data)
archive:addFile("table.lua", serialized, true)

archive:save("test.zip")

local loaded = zip.load("test.zip")
for _, e in ipairs(loaded.entries) do
    print(e.filename, #e.data)
end
```

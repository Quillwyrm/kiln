local parts = {}
local i = 0

while i < 25000 do
    parts[#parts + 1] = tostring(i)
    i = i + 1
end

local s = table.concat(parts, "")
print(#s)

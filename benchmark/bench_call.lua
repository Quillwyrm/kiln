local function work(a, b)
    return (a + b * 3 + 11) % 1000
end

local n = 1000000
local mod = 100000
local total = 0
local i = 0

while i < n do
    total = (total + work(i, total)) % mod
    i = i + 1
end

print(total)

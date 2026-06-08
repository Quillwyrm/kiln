local n = 2000000
local mod = 100000
local a = 1
local b = 2
local c = 3
local total = 0
local i = 0

while i < n do
    a = (a + i + 7) % mod
    b = (b + a * 3 + 11) % mod
    c = (c + a + b) % mod
    total = (total + a + b + c) % mod
    i = i + 1
end

print(total + a + b + c)

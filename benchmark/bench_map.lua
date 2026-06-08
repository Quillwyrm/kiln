local n = 750000
local mod = 100000
local m = {}
m["a"] = 1
m["b"] = 2
m["c"] = 3
m["d"] = 4
local total = 0
local i = 0

while i < n do
    m["a"] = (m["a"] + i + m["d"]) % mod
    m["b"] = (m["b"] + m["a"] + 7) % mod
    m["c"] = m["a"] + m["b"]
    if m["c"] > mod then
        m["c"] = m["c"] % mod
    end
    total = (total + m["a"] + m["b"] + m["c"]) % mod
    i = i + 1
end

print(total + m["a"] + m["b"] + m["c"])

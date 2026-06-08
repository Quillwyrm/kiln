local n = 50000
local mod = 100000
local rounds = 5
local total = 0
local r = 0

while r < rounds do
    local arr = {}
    local i = 0

    while i < n do
        arr[i + 1] = i % 1000
        i = i + 1
    end

    i = 0
    while i < n do
        arr[i + 1] = (arr[i + 1] + i) % mod
        total = (total + arr[i + 1]) % mod
        i = i + 1
    end

    r = r + 1
end

print(total)

local function bench()
    local n = 100000000
    local i = 0
    local sum = 0

    while i < n do
        sum = sum + i
        i = i + 1
    end

    return sum
end

print(bench())

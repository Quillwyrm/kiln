local function run()
    local n = 5000000
    local i = 0
    local a = 1
    local b = 2
    local c = 3
    local total = 0

    while i < n do
        a = (a + i + 7) % 1000
        b = (b + a * 3 + 11) % 1000
        c = (c + a + b) % 1000

        if c > 500 then
            total = total + c - a
        else
            total = total + b - c
        end

        i = i + 1
    end

    return total + a + b + c
end

print(run())

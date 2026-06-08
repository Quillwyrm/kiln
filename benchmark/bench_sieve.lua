local function sieve(limit)
    local is_prime = {}
    local i = 2

    while i <= limit do
        is_prime[i] = true
        i = i + 1
    end

    i = 2
    while i * i <= limit do
        if is_prime[i] then
            local j = i * i
            while j <= limit do
                is_prime[j] = false
                j = j + i
            end
        end
        i = i + 1
    end

    local count = 0
    i = 2
    while i <= limit do
        if is_prime[i] then
            count = count + 1
        end
        i = i + 1
    end

    return count
end

local total = 0
local r = 0

while r < 3 do
    total = total + sieve(100000)
    r = r + 1
end

print(total)

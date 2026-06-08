local n = 10000000
local half = 5000000
local i = 0
local total = 0

while i < n do
    if i < half then
        total = total + 1
    else
        total = total + 2
    end
    i = i + 1
end

print(total)

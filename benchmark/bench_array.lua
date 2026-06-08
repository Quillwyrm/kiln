local arr = {}
for i = 0, 99999 do
    arr[#arr + 1] = i
end
local total = 0
for i = 1, #arr do
    total = total + (arr[i] % 100)
end
print(total)

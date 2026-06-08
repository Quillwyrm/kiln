local m = {}
for i = 0, 24999 do
    m[tostring(i)] = i
end
local sum = 0
for i = 0, 24999 do
    sum = sum + m[tostring(i)]
end
print(sum)

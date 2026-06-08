arr = []
for i in range(100000):
    arr.append(i)
total = sum(v % 100 for v in arr)
print(total)

m = {}
for i in range(25000):
    m[str(i)] = i
total = 0
for i in range(25000):
    total += m[str(i)]
print(total)

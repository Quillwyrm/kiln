n = 10000000
half = 5000000
i = 0
total = 0

while i < n:
    if i < half:
        total += 1
    else:
        total += 2
    i += 1

print(total)

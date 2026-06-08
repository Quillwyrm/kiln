n = 50000
mod = 100000
rounds = 5
total = 0
r = 0

while r < rounds:
    arr = []
    i = 0

    while i < n:
        arr.append(i % 1000)
        i += 1

    i = 0
    while i < n:
        arr[i] = (arr[i] + i) % mod
        total = (total + arr[i]) % mod
        i += 1

    r += 1

print(total)

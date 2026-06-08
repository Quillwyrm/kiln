def work(a, b):
    return (a + b * 3 + 11) % 1000

n = 1000000
mod = 100000
total = 0
i = 0

while i < n:
    total = (total + work(i, total)) % mod
    i += 1

print(total)

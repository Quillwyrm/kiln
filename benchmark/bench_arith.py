n = 2000000
mod = 100000
a = 1
b = 2
c = 3
total = 0
i = 0

while i < n:
    a = (a + i + 7) % mod
    b = (b + a * 3 + 11) % mod
    c = (c + a + b) % mod
    total = (total + a + b + c) % mod
    i += 1

print(total + a + b + c)

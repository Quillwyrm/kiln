def bench():
    n = 10000000
    i = 0
    total = 0

    while i < n:
        total = total + i
        i = i + 1

    return total


print(bench())

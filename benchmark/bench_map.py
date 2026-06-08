n = 750000
mod = 100000
m = {"a": 1, "b": 2, "c": 3, "d": 4}
total = 0
i = 0

while i < n:
    m["a"] = (m["a"] + i + m["d"]) % mod
    m["b"] = (m["b"] + m["a"] + 7) % mod
    m["c"] = m["a"] + m["b"]
    if m["c"] > mod:
        m["c"] = m["c"] % mod
    total = (total + m["a"] + m["b"] + m["c"]) % mod
    i += 1

print(total + m["a"] + m["b"] + m["c"])

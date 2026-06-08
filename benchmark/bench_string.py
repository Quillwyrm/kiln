parts = []
i = 0

while i < 25000:
    parts.append(str(i))
    i += 1

s = "".join(parts)
print(len(s))

def bench():
    n = 3_000_000
    i = 0
    total = 0

    items = [1, 2, 3, 4, 5, 6, 7, 8]

    state = {
        "a": 1,
        "b": 2,
        "c": 3,
        "d": 4,
    }

    while i < n:
        index = i % 8

        value = items[index]
        value = (value + state["a"] + i) % 100000
        items[index] = value

        state["a"] = (state["a"] + value + state["d"]) % 100000
        state["b"] = (state["b"] + items[index] + 7) % 100000
        state["c"] = state["a"] + state["b"] + value

        if state["c"] > 100000:
            state["c"] = state["c"] % 100000

        total = total + value + state["a"] + state["b"] + state["c"]

        i = i + 1

    return total + items[0] + items[1] + state["a"] + state["b"] + state["c"]


print(bench())

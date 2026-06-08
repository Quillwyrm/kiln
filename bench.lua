local function bench()
    local n = 3000000
    local i = 0
    local total = 0

    local items = {1, 2, 3, 4, 5, 6, 7, 8}

    local state = {
        a = 1,
        b = 2,
        c = 3,
        d = 4,
    }

    while i < n do
        local index = (i % 8) + 1

        local value = items[index]
        value = (value + state["a"] + i) % 100000
        items[index] = value

        state["a"] = (state["a"] + value + state["d"]) % 100000
        state["b"] = (state["b"] + items[index] + 7) % 100000
        state["c"] = state["a"] + state["b"] + value

        if state["c"] > 100000 then
            state["c"] = state["c"] % 100000
        end

        total = total + value + state["a"] + state["b"] + state["c"]

        i = i + 1
    end

    return total + items[1] + items[2] + state["a"] + state["b"] + state["c"]
end

print(bench())

local function bench()
    local n = 3000000
    local i = 0
    local total = 0

    local state = {
        a = 1,
        b = 2,
        c = 3,
        d = 4,
    }

    while i < n do
        state["a"] = (state["a"] + i + state["d"]) % 100000
        state["b"] = (state["b"] + state["a"] + 7) % 100000
        state["c"] = state["a"] + state["b"]

        if state["c"] > 100000 then
            state["c"] = state["c"] % 100000
        end

        total = total + state["a"] + state["b"] + state["c"]

        i = i + 1
    end

    return total + state["a"] + state["b"] + state["c"]
end

print(bench())

-- ============================================================
-- 配方 key：袋内 8 个素材的多重集（与顺序无关）
-- 链搜索（scripts/chain.lua）与配方史（scripts/bag_tracker.lua）共用同一口径：
-- 排序后用 "," 拼接，例如 { 12, 8, 12, 15 } → "8,12,12,15"
-- 单独抽出来是为了避免两边各写一份排序逻辑、以后改了一边忘另一边。
-- ============================================================

local Recipe = {}

-- 排序副本：忽略 0 / nil / 非数字（0 = 空位）
function Recipe.Sorted(slots)
    local sorted = {}
    for i = 1, #(slots or {}) do
        local id = slots[i]
        if type(id) == "number" and id > 0 then
            sorted[#sorted + 1] = id
        end
    end
    table.sort(sorted)
    return sorted
end

-- 配方 key："a,b,c..."
function Recipe.Key(slots)
    return table.concat(Recipe.Sorted(slots), ",")
end

return Recipe

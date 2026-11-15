-- ============================================================
-- 数据表：素材 ID 表（名称 / 估值 / 颜色）+ 掉落物 → 素材映射
-- 数值来源：prompts/step1.md §3，请勿自行改动数值
-- ============================================================

local M = {}

-- 素材 ID → 名称 / 单字简称 / 估值（用于“浪费”评分）/ 显示颜色
M.MAX_ID = 29

M.NAMES = {
    [0]  = { zh = "无",       en = "None",          shortZh = "无",   shortEn = "-",   value = 0,  color = { 0.50, 0.50, 0.50 } },
    [1]  = { zh = "红心",     en = "Red Heart",     shortZh = "红",   shortEn = "R",   value = 1,  color = { 0.90, 0.16, 0.16 } },
    [2]  = { zh = "魂心",     en = "Soul Heart",    shortZh = "魂",   shortEn = "S",   value = 4,  color = { 0.82, 0.86, 0.96 } },
    [3]  = { zh = "黑心",     en = "Black Heart",   shortZh = "黑",   shortEn = "Bk",  value = 5,  color = { 0.55, 0.38, 0.80 } },
    [4]  = { zh = "永恒心",   en = "Eternal Heart", shortZh = "永",   shortEn = "E",   value = 5,  color = { 0.95, 0.86, 0.36 } },
    [5]  = { zh = "金心",     en = "Gold Heart",    shortZh = "金",   shortEn = "G",   value = 5,  color = { 0.98, 0.78, 0.22 } },
    [6]  = { zh = "骨心",     en = "Bone Heart",    shortZh = "骨",   shortEn = "Bo",  value = 5,  color = { 0.88, 0.88, 0.80 } },
    [7]  = { zh = "腐心",     en = "Rotten Heart",  shortZh = "腐",   shortEn = "Rt",  value = 1,  color = { 0.58, 0.74, 0.32 } },
    [8]  = { zh = "硬币",     en = "Penny",         shortZh = "币",   shortEn = "C",   value = 1,  color = { 0.86, 0.76, 0.36 } },
    [9]  = { zh = "五分币",   en = "Nickel",        shortZh = "五",   shortEn = "N",   value = 3,  color = { 0.80, 0.82, 0.88 } },
    [10] = { zh = "十分币",   en = "Dime",          shortZh = "十",   shortEn = "D",   value = 5,  color = { 0.76, 0.78, 0.94 } },
    [11] = { zh = "幸运币",   en = "Lucky Penny",   shortZh = "幸",   shortEn = "L",   value = 8,  color = { 0.42, 0.92, 0.50 } },
    [12] = { zh = "钥匙",     en = "Key",           shortZh = "钥",   shortEn = "K",   value = 2,  color = { 0.86, 0.72, 0.32 } },
    [13] = { zh = "金钥匙",   en = "Golden Key",    shortZh = "金钥", shortEn = "GK",  value = 7,  color = { 1.00, 0.86, 0.26 } },
    [14] = { zh = "充能钥匙", en = "Charged Key",   shortZh = "充",   shortEn = "CK",  value = 5,  color = { 0.42, 0.82, 1.00 } },
    [15] = { zh = "炸弹",     en = "Bomb",          shortZh = "炸",   shortEn = "B",   value = 2,  color = { 0.62, 0.62, 0.62 } },
    [16] = { zh = "金炸弹",   en = "Golden Bomb",   shortZh = "金炸", shortEn = "GB",  value = 7,  color = { 0.96, 0.80, 0.22 } },
    [17] = { zh = "Giga炸弹", en = "Giga Bomb",     shortZh = "G炸",  shortEn = "GG",  value = 10, color = { 1.00, 0.30, 0.30 } },
    [18] = { zh = "微型电池", en = "Micro Battery", shortZh = "微电", shortEn = "mB",  value = 2,  color = { 0.52, 0.90, 0.32 } },
    [19] = { zh = "小电池",   en = "Lil Battery",   shortZh = "小电", shortEn = "sB",  value = 4,  color = { 0.52, 0.90, 0.32 } },
    [20] = { zh = "大电池",   en = "Mega Battery",  shortZh = "大电", shortEn = "lB",  value = 8,  color = { 0.52, 0.90, 0.32 } },
    [21] = { zh = "卡牌",     en = "Card",          shortZh = "卡",   shortEn = "Ca",  value = 2,  color = { 0.92, 0.92, 0.92 } },
    [22] = { zh = "药丸",     en = "Pill",          shortZh = "丸",   shortEn = "Pi",  value = 2,  color = { 0.92, 0.62, 0.92 } },
    [23] = { zh = "符文",     en = "Rune",          shortZh = "符",   shortEn = "Ru",  value = 4,  color = { 0.72, 0.62, 0.96 } },
    [24] = { zh = "骰子碎片", en = "Dice Shard",    shortZh = "骰",   shortEn = "Di",  value = 4,  color = { 0.82, 0.82, 0.92 } },
    [25] = { zh = "裂纹钥匙", en = "Cracked Key",   shortZh = "裂",   shortEn = "Cr",  value = 2,  color = { 0.92, 0.86, 0.60 } },
    [26] = { zh = "金便士",   en = "Golden Penny",  shortZh = "金便", shortEn = "GP",  value = 7,  color = { 1.00, 0.86, 0.30 } },
    [27] = { zh = "金药丸",   en = "Golden Pill",   shortZh = "金丸", shortEn = "GPi", value = 7,  color = { 0.96, 0.72, 0.50 } },
    [28] = { zh = "金电池",   en = "Golden Battery", shortZh = "金电", shortEn = "GBa", value = 7, color = { 0.92, 0.92, 0.42 } },
    [29] = { zh = "便便块",   en = "Poop",          shortZh = "便便", shortEn = "Po",  value = 0,  color = { 0.52, 0.36, 0.20 } },
}

-- 掉落物映射：key = Variant .. "." .. SubType，ids = 贡献的素材 ID 序列（顺序即入袋顺序）
M.PICKUPS = {
    ["10.1"]    = { ids = { 1 },       name = { zh = "红心",       en = "Red Heart" } },
    ["10.2"]    = { ids = { 1 },       name = { zh = "半红心",     en = "Half Red Heart" } },
    ["10.3"]    = { ids = { 2 },       name = { zh = "魂心",       en = "Soul Heart" } },
    ["10.4"]    = { ids = { 4 },       name = { zh = "永恒心",     en = "Eternal Heart" } },
    ["10.5"]    = { ids = { 1, 1 },    name = { zh = "双红心",     en = "Double Heart" } },
    ["10.6"]    = { ids = { 3 },       name = { zh = "黑心",       en = "Black Heart" } },
    ["10.7"]    = { ids = { 5 },       name = { zh = "金心",       en = "Gold Heart" } },
    ["10.8"]    = { ids = { 2 },       name = { zh = "半魂心",     en = "Half Soul Heart" } },
    ["10.9"]    = { ids = { 1 },       name = { zh = "受惊红心",   en = "Scared Heart" } },
    ["10.10"]   = { ids = { 2, 1 },    name = { zh = "混合心",     en = "Blended Heart" } },
    ["10.11"]   = { ids = { 6 },       name = { zh = "骨心",       en = "Bone Heart" } },
    ["10.12"]   = { ids = { 7 },       name = { zh = "腐心",       en = "Rotten Heart" } },
    ["20.1"]    = { ids = { 8 },       name = { zh = "硬币",       en = "Penny" } },
    ["20.2"]    = { ids = { 9 },       name = { zh = "五分币",     en = "Nickel" } },
    ["20.3"]    = { ids = { 10 },      name = { zh = "十分币",     en = "Dime" } },
    ["20.4"]    = { ids = { 8, 8 },    name = { zh = "双硬币",     en = "Double Penny" } },
    ["20.5"]    = { ids = { 11 },      name = { zh = "幸运币",     en = "Lucky Penny" } },
    ["20.6"]    = { ids = { 9 },       name = { zh = "黏性五分币", en = "Sticky Nickel" } },
    ["20.7"]    = { ids = { 26 },      name = { zh = "金便士",     en = "Golden Penny" } },
    ["30.1"]    = { ids = { 12 },      name = { zh = "钥匙",       en = "Key" } },
    ["30.2"]    = { ids = { 13 },      name = { zh = "金钥匙",     en = "Golden Key" } },
    ["30.3"]    = { ids = { 12, 12 },  name = { zh = "钥匙圈",     en = "Key Ring" } },
    ["30.4"]    = { ids = { 14 },      name = { zh = "充能钥匙",   en = "Charged Key" } },
    ["40.1"]    = { ids = { 15 },      name = { zh = "炸弹",       en = "Bomb" } },
    ["40.2"]    = { ids = { 15, 15 },  name = { zh = "双炸弹",     en = "Double Bomb" } },
    ["40.4"]    = { ids = { 16 },      name = { zh = "金炸弹",     en = "Golden Bomb" } },
    ["40.7"]    = { ids = { 17 },      name = { zh = "Giga炸弹",   en = "Giga Bomb" } },
    ["42.0"]    = { ids = { 29 },      name = { zh = "便便块",     en = "Poop" } },
    ["42.1"]    = { ids = { 29 },      name = { zh = "大便便块",   en = "Big Poop" } },
    ["70.14"]   = { ids = { 27 },      name = { zh = "金药丸",     en = "Golden Pill" } },
    ["70.2062"] = { ids = { 27 },      name = { zh = "金马药丸",   en = "Golden Horse Pill" } },
    ["90.1"]    = { ids = { 19 },      name = { zh = "小电池",     en = "Lil Battery" } },
    ["90.2"]    = { ids = { 18 },      name = { zh = "微型电池",   en = "Micro Battery" } },
    ["90.3"]    = { ids = { 20 },      name = { zh = "大电池",     en = "Mega Battery" } },
    ["90.4"]    = { ids = { 28 },      name = { zh = "金电池",     en = "Golden Battery" } },
    ["300.49"]  = { ids = { 24 },      name = { zh = "骰子碎片",   en = "Dice Shard" } },
    ["300.50"]  = { ids = { 21 },      name = { zh = "紧急联络卡", en = "Emergency Contact" } },
    ["300.78"]  = { ids = { 25 },      name = { zh = "裂纹钥匙",   en = "Cracked Key" } },
}

-- 卡牌类 / 药丸类兜底规则用到的素材 ID
M.CARD_INGREDIENT = 21  -- 普通卡牌
M.RUNE_INGREDIENT = 23  -- 符文
M.PILL_INGREDIENT = 22  -- 药丸

-- 判断某张卡是否为符文（原生 API，失败时按普通卡牌处理）
local function cardIsRune(subType)
    if ItemConfig == nil then
        return false
    end
    local ok, card = pcall(function()
        return ItemConfig:GetCard(subType)
    end)
    if not ok or card == nil then
        return false
    end
    local okRune, isRune = pcall(function()
        return card:IsRune()
    end)
    return okRune and isRune == true
end

-- 掉落物 / 卡牌 / 药丸 → 素材列表；查不到返回 nil（不参与规划）
function M.FromPickup(variant, subType)
    local entry = M.PICKUPS[variant .. "." .. subType]
    if entry ~= nil then
        return entry.ids
    end
    if variant == 300 then
        -- 卡牌类：0 = 空
        if subType == 0 then
            return nil
        end
        if cardIsRune(subType) then
            return { M.RUNE_INGREDIENT }
        end
        return { M.CARD_INGREDIENT }
    elseif variant == 70 then
        -- 药丸类：0 = 空
        if subType == 0 then
            return nil
        end
        return { M.PILL_INGREDIENT }
    end
    return nil
end

-- 取掉落物名称（用于日志与面板文案）
function M.PickupLabel(variant, subType, lang)
    local entry = M.PICKUPS[variant .. "." .. subType]
    if entry ~= nil and entry.name ~= nil then
        return (lang == "en") and entry.name.en or entry.name.zh
    end
    return (lang == "en") and ("Pickup " .. variant .. "." .. subType) or ("掉落物 " .. variant .. "." .. subType)
end

function M.Name(id, lang)
    local info = M.NAMES[id]
    if info == nil then
        return (lang == "en") and ("#" .. tostring(id)) or ("素材" .. tostring(id))
    end
    return (lang == "en") and info.en or info.zh
end

function M.ShortName(id, lang)
    local info = M.NAMES[id]
    if info == nil then
        return tostring(id)
    end
    return (lang == "en") and info.shortEn or info.shortZh
end

function M.Value(id)
    local info = M.NAMES[id]
    return info and info.value or 0
end

function M.Color(id)
    local info = M.NAMES[id]
    if info == nil then
        return 1.0, 1.0, 1.0
    end
    return info.color[1], info.color[2], info.color[3]
end

return M


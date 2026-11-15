-- ============================================================
-- 扫描：房间/本层掉落物、背包卡牌药丸 → 素材计数表与“原子”（一次拾取动作）
-- 说明：原子（atom）= 一种掉落物来源，ids 为一次拾取贡献的素材序列（顺序 = 入袋顺序）
--       count = 该来源在范围内出现的次数
-- ============================================================

local Ingredients = require("scripts.data.ingredients")
local config = require("scripts.config")

local Scan = {}

local floorRooms = {}   -- [listIndex] = { atoms = {atom...} }

local function currentListIndex()
    local level = Game():GetLevel()
    if level == nil then
        return 0
    end
    local desc = level:GetCurrentRoomDesc()
    if desc == nil then
        return 0
    end
    return desc.ListIndex
end

local function isShopItem(entity)
    local ok, isShop = pcall(function()
        return entity:ToPickup():IsShopItem()
    end)
    return ok and isShop == true
end

local function spriteAnimation(entity)
    local ok, anim = pcall(function()
        return entity:GetSprite():GetAnimation()
    end)
    if ok and type(anim) == "string" then
        return anim
    end
    return ""
end

local function entityIsGone(entity)
    local okExists, exists = pcall(function() return entity:Exists() end)
    if okExists and not exists then
        return true
    end
    local okDead, dead = pcall(function() return entity:IsDead() end)
    return okDead and dead == true
end

-- 按 kind 聚合原子清单
local function aggregate(list)
    local byKind = {}
    local merged = {}
    for _, atom in ipairs(list) do
        local entry = byKind[atom.kind]
        if entry == nil then
            entry = {
                kind = atom.kind,
                ids = atom.ids,
                count = 0,
                fromInventory = atom.fromInventory == true,
                ingredientId = atom.ingredientId,
                variant = atom.variant,
                subtype = atom.subtype,
            }
            byKind[atom.kind] = entry
            merged[#merged + 1] = entry
        end
        entry.count = entry.count + (atom.count or 1)
    end
    table.sort(merged, function(a, b)
        return a.kind < b.kind
    end)
    return merged
end

-- 扫描当前房间，返回 { listIndex, entries, atoms, collectors }，并覆盖更新本层记录
function Scan.ScanRoom()
    local result = {
        listIndex = currentListIndex(),
        entries = {},
        atoms = {},
        collectors = {},
    }
    local entities = Isaac.FindByType(EntityType.ENTITY_PICKUP, -1, -1, false, false)
    local raw = {}
    for _, entity in ipairs(entities) do
        local ids = Ingredients.FromPickup(entity.Variant, entity.SubType)
        if ids ~= nil and not entityIsGone(entity) then
            local shop = isShopItem(entity)
            local collecting = (spriteAnimation(entity) == "Collect")
            local posX, posY = nil, nil
            local initSeed = nil
            pcall(function()
                posX = entity.Position.X
                posY = entity.Position.Y
                initSeed = entity.InitSeed
            end)
            result.entries[#result.entries + 1] = {
                index = entity.Index,
                -- 换房后 Index 会被复用；InitSeed 在同一局内唯一，优先用它做去重 key
                seed = initSeed,
                variant = entity.Variant,
                subtype = entity.SubType,
                ids = ids,
                collecting = collecting,
                shop = shop,
                x = posX,
                y = posY,
            }
            if not collecting and not shop then
                raw[#raw + 1] = {
                    kind = entity.Variant .. "." .. entity.SubType,
                    ids = ids,
                    count = 1,
                    fromInventory = false,
                    variant = entity.Variant,
                    subtype = entity.SubType,
                }
            end
        end
    end
    result.atoms = aggregate(raw)

    -- 会“拿走/吃掉”掉落物的非玩家实体：使魔、Bumbino、Ultra Greed、老虎机/乞丐
    -- 事件模拟时用它们的位置判断“这个掉落物不是玩家拿的”
    local COLLECTOR_TYPES = {
        EntityType.ENTITY_FAMILIAR,
        EntityType.ENTITY_SLOT,
    }
    if EntityType.ENTITY_BUMBINO ~= nil then
        COLLECTOR_TYPES[#COLLECTOR_TYPES + 1] = EntityType.ENTITY_BUMBINO
    end
    if EntityType.ENTITY_ULTRA_GREED ~= nil then
        COLLECTOR_TYPES[#COLLECTOR_TYPES + 1] = EntityType.ENTITY_ULTRA_GREED
    end
    for _, entityType in ipairs(COLLECTOR_TYPES) do
        local found = Isaac.FindByType(entityType, -1, -1, false, false)
        for _, entity in ipairs(found) do
            local posX, posY = nil, nil
            pcall(function()
                posX = entity.Position.X
                posY = entity.Position.Y
            end)
            if posX ~= nil and posY ~= nil then
                result.collectors[#result.collectors + 1] = {
                    type = entityType,
                    x = posX,
                    y = posY,
                }
            end
        end
    end

    floorRooms[result.listIndex] = { atoms = result.atoms }
    return result
end

-- 本层所有房间合并后的原子清单
function Scan.GetFloorAtoms()
    local all = {}
    for _, room in pairs(floorRooms) do
        for _, atom in ipairs(room.atoms) do
            all[#all + 1] = atom
        end
    end
    return aggregate(all)
end

-- 背包里的卡牌 / 药丸 → 原子清单
function Scan.GetInventoryAtoms(player)
    local list = {}
    if not config.IncludeInventory or player == nil then
        return list
    end
    for i = 0, 3 do
        local cardId = player:GetCard(i)
        if cardId ~= nil and cardId ~= 0 then
            local ids = Ingredients.FromPickup(300, cardId)
            if ids ~= nil then
                list[#list + 1] = {
                    kind = "inv.card." .. tostring(cardId),
                    ids = ids,
                    count = 1,
                    fromInventory = true,
                    ingredientId = ids[1],
                    variant = 300,
                    subtype = cardId,
                }
            end
        end
        local pillId = player:GetPill(i)
        if pillId ~= nil and pillId ~= 0 then
            local ids = Ingredients.FromPickup(70, pillId)
            if ids ~= nil then
                list[#list + 1] = {
                    kind = "inv.pill." .. tostring(pillId),
                    ids = ids,
                    count = 1,
                    fromInventory = true,
                    ingredientId = ids[1],
                    variant = 70,
                    subtype = pillId,
                }
            end
        end
    end
    return aggregate(list)
end

-- 合并两份原子清单（按 kind 累加）
function Scan.Merge(atomsA, atomsB)
    local all = {}
    for _, atom in ipairs(atomsA or {}) do
        all[#all + 1] = atom
    end
    for _, atom in ipairs(atomsB or {}) do
        all[#all + 1] = atom
    end
    return aggregate(all)
end

-- 由原子清单计算素材计数表、可用素材数与缓存签名
function Scan.Describe(atoms)
    local counts = {}
    local available = 0
    local parts = {}
    for _, atom in ipairs(atoms) do
        local count = atom.count or 1
        available = available + count * #atom.ids
        for _, id in ipairs(atom.ids) do
            counts[id] = (counts[id] or 0) + count
        end
        parts[#parts + 1] = atom.kind .. "x" .. tostring(count)
    end
    table.sort(parts)
    return {
        atoms = atoms,
        counts = counts,
        available = available,
        signature = table.concat(parts, ";"),
    }
end

function Scan.ResetFloor()
    floorRooms = {}
end

function Scan.GetFloorRoomCount()
    local n = 0
    for _ in pairs(floorRooms) do
        n = n + 1
    end
    return n
end

return Scan


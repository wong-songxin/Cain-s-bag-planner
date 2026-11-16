-- ============================================================
-- 扫描：房间/本层掉落物、背包卡牌药丸 → 素材计数表与“原子”（一次拾取动作）
-- 说明：原子（atom）= 一种掉落物来源，ids 为一次拾取贡献的素材序列（顺序 = 入袋顺序）
--       count = 该来源在范围内出现的次数
-- ============================================================

local Ingredients = require("scripts.data.ingredients")
local config = require("scripts.config")

local Scan = {}

local floorRooms = {}   -- [listIndex] = { atoms = {atom...}, signature = "...", frame = n, levelKey = "..." }
-- ------------------------------------------------------------
-- 回退（控制台 rewind / 时间回溯）恢复用：按游戏帧号记录「房间被扫描到的样子」。
-- rewind 会把整局状态倒回若干帧，本层已探索房间的掉落物信息不能因此丢失；
-- 内容没变的重复扫描不记新历史点，只在房间内容真的变化时追加。
-- ------------------------------------------------------------
local floorHistory = {} -- { { frame, levelKey, listIndex, atoms, signature }, ... }
local HISTORY_LIMIT = 2000

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

-- 当前楼层标识：换层 / rewind 跨层时用来隔离不同楼层的扫描记录
local function currentLevelKey()
    local ok, stage, stageType = pcall(function()
        local level = Game():GetLevel()
        return level:GetStage(), level:GetStageType()
    end)
    if ok and type(stage) == "number" then
        return tostring(stage) .. ":" .. tostring(stageType or 0)
    end
    return nil
end

-- 整局帧号（换房不归零）；取不到时返回 nil（不记录历史）
local function currentGameFrame()
    local value = nil
    pcall(function()
        value = Game():GetFrameCount()
    end)
    if type(value) == "number" then
        return value
    end
    return nil
end

local function historyWindow()
    local value = config.RewindFrames
    if type(value) ~= "number" then
        return 10800
    end
    return value
end

local function atomsSignature(atoms)
    local parts = {}
    for _, atom in ipairs(atoms or {}) do
        parts[#parts + 1] = atom.kind .. "x" .. tostring(atom.count or 1)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function noteFloorHistory(frame, levelKey, listIndex, atoms, signature)
    if historyWindow() <= 0 or frame == nil then
        return
    end
    local last = floorHistory[#floorHistory]
    if last ~= nil and last.frame == frame and last.listIndex == listIndex
        and last.levelKey == levelKey then
        last.atoms = atoms
        last.signature = signature
    else
        floorHistory[#floorHistory + 1] = {
            frame = frame,
            levelKey = levelKey,
            listIndex = listIndex,
            atoms = atoms,
            signature = signature,
        }
    end
    local cutoff = frame - historyWindow()
    while #floorHistory > 1 and floorHistory[1].frame < cutoff do
        table.remove(floorHistory, 1)
    end
    while #floorHistory > HISTORY_LIMIT do
        table.remove(floorHistory, 1)
    end
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

    -- 会“吃掉”场上掉落物的实体：官方只有这 5 个跟班（其余实体——包括捐款机等所有 slot、
    -- Bumbino、Ultra Greed——都不会吃地上的掉落物；把它们算成收集者会让袋子吸走的掉落物被误跳过）。
    -- id = type.variant.subtype，subtype 固定 0：
    --   3.24.0  Bum Friend   3.64.0  Dark Bum   3.88.0  Bumbo
    --   3.90.0  Key Bum      3.102.0 Super Bum
    local PICKUP_EATING_FAMILIARS = {
        [24] = "Bum Friend",
        [64] = "Dark Bum",
        [88] = "Bumbo",
        [90] = "Key Bum",
        [102] = "Super Bum",
    }
    if config.CollectorSkip ~= false and EntityType.ENTITY_FAMILIAR ~= nil then
        local extraCollectors = config.ExtraCollectorFamiliars
        for _, entity in ipairs(Isaac.FindByType(EntityType.ENTITY_FAMILIAR, -1, -1, false, false)) do
            local posX, posY = nil, nil
            local variant, subtype, entityIndex = nil, nil, nil
            pcall(function()
                posX = entity.Position.X
                posY = entity.Position.Y
                variant = entity.Variant
                subtype = entity.SubType
                entityIndex = entity.Index
            end)
            local name = nil
            if variant ~= nil and (subtype == nil or subtype == 0) then
                name = PICKUP_EATING_FAMILIARS[variant]
                if name == nil and type(extraCollectors) == "table" then
                    local extra = extraCollectors[variant]
                    if extra == true then
                        name = "extra:" .. tostring(variant)
                    elseif type(extra) == "string" then
                        name = extra
                    end
                end
            end
            if name ~= nil and posX ~= nil and posY ~= nil then
                result.collectors[#result.collectors + 1] = {
                    type = EntityType.ENTITY_FAMILIAR,
                    variant = variant,
                    subtype = subtype,
                    index = entityIndex,
                    name = name,
                    x = posX,
                    y = posY,
                }
            end
        end
    end

    local levelKey = currentLevelKey()
    local frame = currentGameFrame()
    local signature = atomsSignature(result.atoms)
    local existing = floorRooms[result.listIndex]
    if existing == nil or existing.signature ~= signature or existing.levelKey ~= levelKey then
        floorRooms[result.listIndex] = {
            atoms = result.atoms,
            signature = signature,
            frame = frame,
            levelKey = levelKey,
        }
        noteFloorHistory(frame, levelKey, result.listIndex, result.atoms, signature)
    end
    result.levelKey = levelKey
    result.frame = frame
    return result
end

-- 本层所有房间合并后的原子清单（换层 / 回退后只统计当前楼层）
function Scan.GetFloorAtoms()
    local all = {}
    local levelKey = currentLevelKey()
    for _, room in pairs(floorRooms) do
        if levelKey == nil or room.levelKey == levelKey then
            for _, atom in ipairs(room.atoms) do
                all[#all + 1] = atom
            end
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
    floorHistory = {}
end

-- 回退（控制台 rewind）后调用：把本层房间记录恢复到目标帧之前的状态
-- frame = Game():GetFrameCount()（整局帧号）；返回恢复后的房间数
function Scan.RestoreAtFrame(frame)
    local target = frame
    if type(target) ~= "number" then
        target = currentGameFrame()
    end
    if type(target) ~= "number" then
        return Scan.GetFloorRoomCount()
    end
    -- 目标帧之前没有任何记录（模组刚加载 / 回退超出保留窗口）→ 保留现有扫描结果，别清空
    local usable = {}
    for _, entry in ipairs(floorHistory) do
        if entry.frame <= target then
            usable[#usable + 1] = entry
        end
    end
    if #usable == 0 then
        return Scan.GetFloorRoomCount()
    end
    -- 目标帧之后的记录属于「被回退掉的时间线」，已失效（玩家可能换了操作）
    floorHistory = usable
    local levelKey = currentLevelKey()
    floorRooms = {}
    for _, entry in ipairs(usable) do
        if levelKey == nil or entry.levelKey == levelKey then
            floorRooms[entry.listIndex] = {
                atoms = entry.atoms,
                signature = entry.signature,
                frame = entry.frame,
                levelKey = entry.levelKey,
            }
        end
    end
    return Scan.GetFloorRoomCount()
end

-- 历史点数（日志 / 离线测试用）
function Scan.GetHistoryCount()
    return #floorHistory
end

function Scan.GetFloorRoomCount()
    local n = 0
    local levelKey = currentLevelKey()
    for _, room in pairs(floorRooms) do
        if levelKey == nil or room.levelKey == levelKey then
            n = n + 1
        end
    end
    return n
end

return Scan


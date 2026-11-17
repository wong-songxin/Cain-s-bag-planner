-- ============================================================
-- 跨会话持久化：退出游戏再进入（Continue）时恢复合成袋模拟与配方史
-- 硬约束：只用模组数据接口 Isaac.SaveModData / LoadModData / HasModData / RemoveModData
--         （忏悔原生，按「当前存档位」隔离），绝不直接读写游戏存档文件。
-- 格式：自带紧凑文本（不依赖游戏 resources/scripts/json.lua），带版本号，坏数据一律降级：
--   CB|v=1|seed=..|frame=..|stage=..|stageType=..|listIndex=..|savedAt=..
--     |slots=1,2,3|hist=100:1,2;200:1,2,3|seen=<配方key>;<配方key>|crafted=<配方key>;...
--   说明：hist 里每条是「帧号:当时槽位」；配方 key 由 scripts/recipe.lua 统一产生（8 个数逗号拼接），
--         所以 seen/crafted 里允许出现逗号，条目之间用分号分隔。
-- ============================================================

local Persist = {}

local PREFIX = "CB"
local VERSION = 1
local BAG_SIZE = 8
local MAX_HISTORY = 64          -- 解码时最多接受多少条历史（防御异常数据）

local function joinIntList(list)
    local parts = {}
    for i = 1, #list do
        parts[i] = tostring(list[i])
    end
    return table.concat(parts, ",")
end

-- 逗号分隔的整数列表；格式非法 / 超过 maxCount 返回 nil
local function parseIntList(text, maxCount)
    local list = {}
    if text == nil or text == "" then
        return list
    end
    local count = 0
    for part in string.gmatch(text, "([^,]+)") do
        local value = tonumber(part)
        if value == nil or value % 1 ~= 0 then
            return nil
        end
        count = count + 1
        if count > maxCount then
            return nil
        end
        list[count] = value
    end
    return list
end

-- 配方 key = 8 个素材 id 的逗号拼接（与 scripts/recipe.lua 口径一致）
local function isRecipeKey(key)
    if type(key) ~= "string" then
        return false
    end
    local count = 0
    for part in string.gmatch(key, "([^,]+)") do
        local value = tonumber(part)
        if value == nil or value % 1 ~= 0 or value < 1 then
            return false
        end
        count = count + 1
    end
    return count == BAG_SIZE
end

local function splitRecipes(text)
    local list = {}
    if text == nil or text == "" then
        return list
    end
    for part in string.gmatch(text, "([^;]+)") do
        if isRecipeKey(part) then
            list[#list + 1] = part
        end
    end
    return list
end

-- payload → 紧凑文本（nil = 无法编码）
function Persist.Encode(payload)
    if type(payload) ~= "table" then
        return nil
    end
    local fields = { PREFIX }
    local function add(key, value)
        if value ~= nil then
            fields[#fields + 1] = key .. "=" .. tostring(value)
        end
    end
    add("v", VERSION)
    add("seed", payload.seed)
    add("frame", payload.frame)
    add("stage", payload.stage)
    add("stageType", payload.stageType)
    add("listIndex", payload.listIndex)
    add("savedAt", payload.savedAt)
    add("slots", joinIntList(payload.slots or {}))

    local history = payload.history or {}
    local parts = {}
    for i = 1, #history do
        local entry = history[i]
        if type(entry) == "table" and type(entry.frame) == "number" then
            parts[#parts + 1] = tostring(entry.frame) .. ":" .. joinIntList(entry.slots or {})
        end
    end
    if #parts > 0 then
        add("hist", table.concat(parts, ";"))
    end

    add("seen", table.concat(payload.seen or {}, ";"))
    add("crafted", table.concat(payload.crafted or {}, ";"))
    return table.concat(fields, "|")
end

-- 紧凑文本 → payload；返回 payload, err（err 用于日志：no data / corrupt / version N）
function Persist.Decode(text)
    if type(text) ~= "string" or text == "" then
        return nil, "no data"
    end

    local prefix = nil
    local map = {}
    for part in string.gmatch(text, "([^|]+)") do
        if prefix == nil then
            prefix = part
        else
            local key, value = string.match(part, "^([%w_]+)=(.*)$")
            if key ~= nil then
                map[key] = value
            end
        end
    end
    if prefix ~= PREFIX then
        return nil, "corrupt"
    end
    local version = tonumber(map.v)
    if version == nil then
        return nil, "corrupt"
    end
    if version ~= VERSION then
        return nil, "version " .. tostring(version)
    end

    local slots = parseIntList(map.slots, BAG_SIZE)
    if slots == nil then
        return nil, "corrupt"
    end

    local history = {}
    if map.hist ~= nil and map.hist ~= "" then
        for part in string.gmatch(map.hist, "([^;]+)") do
            local frameText, slotsText = string.match(part, "^(-?%d+):(.*)$")
            if frameText ~= nil then
                local frame = tonumber(frameText)
                local list = parseIntList(slotsText, BAG_SIZE)
                if frame ~= nil and list ~= nil then
                    history[#history + 1] = { frame = frame, slots = list }
                end
            end
            if #history >= MAX_HISTORY then
                break
            end
        end
    end

    local seed = tonumber(map.seed)
    if seed == nil then
        return nil, "corrupt"
    end

    return {
        v = version,
        seed = seed,
        frame = tonumber(map.frame),
        stage = tonumber(map.stage),
        stageType = tonumber(map.stageType),
        listIndex = tonumber(map.listIndex),
        savedAt = tonumber(map.savedAt),
        slots = slots,
        history = history,
        seen = splitRecipes(map.seen),
        crafted = splitRecipes(map.crafted),
    }
end

-- 按恢复帧挑快照：frame <= 目标帧的最新一份；
-- 目标帧早于所有记录时退回最早一份（最接近本房入口），第二个返回值 = true 表示用了退路。
function Persist.SelectSnapshot(payload, frame)
    local history = payload ~= nil and payload.history or nil
    if type(history) ~= "table" then
        return nil, false
    end
    local target = tonumber(frame)
    local latest, earliest = nil, nil
    for i = 1, #history do
        local entry = history[i]
        if type(entry) == "table" and type(entry.frame) == "number" and type(entry.slots) == "table" then
            if earliest == nil or entry.frame < earliest.frame then
                earliest = entry
            end
            if target ~= nil and entry.frame <= target
                and (latest == nil or entry.frame > latest.frame) then
                latest = entry
            end
        end
    end
    if latest ~= nil then
        return latest, false
    end
    if earliest ~= nil then
        return earliest, true
    end
    return nil, false
end

-- ------------------------------------------------------------
-- 模组数据读写（全部 pcall；失败只降级，不影响游戏）
-- ------------------------------------------------------------

function Persist.Save(modObject, payload)
    if modObject == nil then
        return false, "no mod"
    end
    local text = Persist.Encode(payload)
    if text == nil then
        return false, "encode"
    end
    local ok = pcall(function()
        Isaac.SaveModData(modObject, text)
    end)
    if not ok then
        return false, "save failed"
    end
    return true
end

function Persist.Load(modObject)
    if modObject == nil then
        return nil, "no mod"
    end
    local ok, text = pcall(function()
        if Isaac.HasModData ~= nil and Isaac.HasModData(modObject) == false then
            return nil
        end
        return Isaac.LoadModData(modObject)
    end)
    if not ok then
        return nil, "load failed"
    end
    if type(text) ~= "string" or text == "" then
        return nil, "no data"
    end
    return Persist.Decode(text)
end

function Persist.Clear(modObject)
    if modObject == nil then
        return false
    end
    local ok = pcall(function()
        if Isaac.RemoveModData ~= nil then
            Isaac.RemoveModData(modObject)
        else
            Isaac.SaveModData(modObject, "")
        end
    end)
    return ok
end

return Persist


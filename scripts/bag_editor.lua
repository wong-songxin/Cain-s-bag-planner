-- ============================================================
-- 袋内容校正编辑器（状态机，不含任何绘制代码）
-- 交互：F9 进入/退出，←/→ 选格，↑/↓ 换素材，Enter 写入袋模拟
-- 说明：草稿在退出 / 关面板后仍保留，便于继续修改；确认后才会写回 BagTracker
-- ============================================================

local config = require("scripts.config")
local Log = require("scripts.log")
local Ingredients = require("scripts.data.ingredients")
local BagTracker = require("scripts.bag_tracker")

local BagEditor = {}

local BAG_SIZE = 8

local active = false
local cursor = 1
local draft = nil              -- 8 格草稿；0 = 空位（保存时会压缩掉）
local draftBagKey = nil        -- 草稿创建时的袋内容；袋变了说明草稿已过期
local candidates = { 0 }       -- 候选素材 id（0 = 空）
local candidatePos = { [0] = 1 }

local function copySlots(source)
    local result = {}
    for i = 1, BAG_SIZE do
        result[i] = (source ~= nil and source[i]) or 0
    end
    return result
end

local function ensureDraft()
    if draft == nil then
        draft = copySlots(BagTracker.GetSlots())
        draftBagKey = BagTracker.GetKey()
    end
end

-- 候选优先级：0（空） → 本房间已扫描到的素材 → 本层 + 背包 → 全量 1..MAX_ID
local function buildCandidates(counts, roomCounts)
    candidates = { 0 }
    local seen = { [0] = true }

    local function addCounts(map)
        if type(map) ~= "table" then
            return
        end
        local keys = {}
        for id in pairs(map) do
            if type(id) == "number" then
                keys[#keys + 1] = id
            end
        end
        table.sort(keys)
        for _, id in ipairs(keys) do
            if id >= 1 and id <= Ingredients.MAX_ID and not seen[id] then
                seen[id] = true
                candidates[#candidates + 1] = id
            end
        end
    end

    addCounts(roomCounts)
    addCounts(counts)
    for id = 1, Ingredients.MAX_ID do
        if not seen[id] then
            candidates[#candidates + 1] = id
        end
    end

    candidatePos = {}
    for i, id in ipairs(candidates) do
        candidatePos[id] = i
    end
end

function BagEditor.Open(options)
    options = options or {}
    -- 草稿期间袋内容若被拾取 / 丢弃改动过，草稿已过期 → 以当前袋为准重建
    if draft ~= nil and draftBagKey ~= BagTracker.GetKey() then
        if config.Debug then
            Log.Write("[CainsBag] bag editor draft expired: " .. tostring(draftBagKey)
                .. " -> " .. BagTracker.GetKey())
        end
        draft = nil
        draftBagKey = nil
    end
    ensureDraft()
    if not active then
        cursor = 1
    end
    active = true
    buildCandidates(options.counts, options.roomCounts)
    -- 草稿里的值不在候选表里时（理论上不会发生）补进去，保证 ↑/↓ 一定能选中
    for i = 1, BAG_SIZE do
        local id = draft[i] or 0
        if candidatePos[id] == nil then
            candidates[#candidates + 1] = id
            candidatePos[id] = #candidates
        end
    end
    if config.Debug then
        Log.Write("[CainsBag] bag editor opened: " .. BagTracker.GetDebugText())
    end
end

-- 退出编辑：keepDraft = true 时保留草稿（F9 / F5 的行为）
function BagEditor.Close(keepDraft)
    active = false
    if keepDraft ~= true then
        draft = nil
        draftBagKey = nil
    end
    if config.Debug then
        Log.Write("[CainsBag] bag editor closed: keepDraft=" .. tostring(keepDraft == true))
    end
end

function BagEditor.Reset()
    active = false
    cursor = 1
    draft = nil
    draftBagKey = nil
    candidates = { 0 }
    candidatePos = { [0] = 1 }
end

function BagEditor.IsActive()
    return active
end

-- 左移 / 右移光标；返回光标是否真的移动了
function BagEditor.MoveCursor(delta)
    if not active then
        return false
    end
    local target = cursor + (delta or 0)
    if target < 1 then
        target = 1
    elseif target > BAG_SIZE then
        target = BAG_SIZE
    end
    if target == cursor then
        return false
    end
    cursor = target
    return true
end

function BagEditor.SetCursor(index)
    if not active or type(index) ~= "number" or index % 1 ~= 0 then
        return false
    end
    index = math.max(1, math.min(BAG_SIZE, index))
    cursor = index
    return true
end

-- 当前格切换到上/下一个候选素材（循环，含 0 = 空）
function BagEditor.CycleValue(delta)
    if not active then
        return false
    end
    ensureDraft()
    local id = draft[cursor] or 0
    local position = candidatePos[id] or 1
    local total = #candidates
    if total <= 0 then
        return false
    end
    position = ((position - 1 + (delta or 1)) % total) + 1
    draft[cursor] = candidates[position]
    return true
end

-- 确认：压缩掉空位后写入 BagTracker（成功则关闭编辑模式）
function BagEditor.Confirm()
    if not active then
        return false, nil
    end
    ensureDraft()
    local list = {}
    for i = 1, BAG_SIZE do
        local id = draft[i] or 0
        if id ~= 0 then
            list[#list + 1] = id
        end
    end
    local ok = BagTracker.SetSlots(list)
    if ok then
        active = false
        draft = nil
        draftBagKey = nil
        if config.Debug then
            Log.Write("[CainsBag] bag editor confirm: " .. BagTracker.GetDebugText())
        end
    end
    return ok, list
end

-- 只读快照（UI / BagTracker.GetEditState 使用）
function BagEditor.GetState()
    if not active then
        return { active = false, cursor = cursor, slots = {} }
    end
    ensureDraft()
    return {
        active = true,
        cursor = cursor,
        slots = copySlots(draft),
        candidates = candidates,
    }
end

-- 供测试 / 调试：当前完整候选表（含 0）
function BagEditor.GetCandidates()
    local copy = {}
    for i = 1, #candidates do
        copy[i] = candidates[i]
    end
    return copy
end

BagTracker.RegisterEditor(BagEditor)

return BagEditor

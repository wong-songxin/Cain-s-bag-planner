-- ============================================================
-- 入口：堕化该隐合成袋「最优放置链」规划器
-- 依赖：仅原生 Repentance API（不依赖 REPENTOGON / EID / MCM）
-- ============================================================

local mod = RegisterMod("CainsBag", 1)

local config = require("scripts.config")
local Ingredients = require("scripts.data.ingredients")
local Log = require("scripts.log")
local Scan = require("scripts.scan")
local BagTracker = require("scripts.bag_tracker")
local BagEditor = require("scripts.bag_editor")
local Chain = require("scripts.chain")
local UI = require("scripts.ui")

local BAG_SIZE = 8

local state = {
    visible = config.PanelVisibleByDefault,
    slots = {},
    atoms = {},
    counts = {},
    roomCounts = {},
    available = 0,
    signature = "",
    windows = 0,
    job = nil,
    result = nil,
    chainKey = nil,
    scroll = 0,
    message = "",
    messageUntil = 0,
    frame = 0,
    lastScanFrame = -100,
    lastLoggedSignature = nil,
    diagDone = false,
    notEnough = false,
    unknownBag = true,
    uncertainBag = false,
    directBag = false,
    bagState = { confidence = "unknown", reason = "" },
    notCain = false,
    lowVariety = false,
    searching = false,
    progress = 0,
    editor = { active = false, cursor = 1, slots = {} },
}

local function log(text)
    if not config.Debug then
        return
    end
    Log.Write("[CainsBag] " .. text)
end

local function setMessage(text)
    state.message = text
    state.messageUntil = Isaac.GetTime() + 3000
end

local function getBagPlayer()
    local fallback = nil
    local taintedFallback = nil
    local count = 1
    local ok, n = pcall(function()
        return Game():GetNumPlayers()
    end)
    if ok and type(n) == "number" then
        count = n
    end
    for i = 0, count - 1 do
        local okPlayer, player = pcall(function()
            return Isaac.GetPlayer(i)
        end)
        if okPlayer and player ~= nil then
            local hasBag = false
            pcall(function()
                hasBag = player:HasCollectible(CollectibleType.COLLECTIBLE_BAG_OF_CRAFTING)
            end)
            if hasBag then
                return player
            end
            local isTaintedCain = false
            pcall(function()
                isTaintedCain = (player:GetPlayerType() == 23)
            end)
            if isTaintedCain then
                taintedFallback = taintedFallback or player
            end
            fallback = fallback or player
        end
    end
    if taintedFallback ~= nil then
        return taintedFallback
    end
    if fallback ~= nil then
        return fallback
    end
    local okPlayer, player = pcall(function()
        return Isaac.GetPlayer(0)
    end)
    if okPlayer then
        return player
    end
    return nil
end

-- 本层（已探索房间）+ 背包 → 可用素材（统计范围固定为本层，见 step5）
local function refreshScan(player)
    local room = Scan.ScanRoom()
    BagTracker.SetCollectors(room.collectors)
    BagTracker.OnRoomScan(room.entries)

    -- roomCounts 仍要保留：F9 校正的候选列表优先列「本房间已扫描到的素材」
    local roomDesc = Scan.Describe(room.atoms)
    state.roomCounts = roomDesc.counts

    local atoms = Scan.Merge(Scan.GetFloorAtoms(), Scan.GetInventoryAtoms(player))

    local desc = Scan.Describe(atoms)
    state.atoms = desc.atoms
    state.counts = desc.counts
    state.available = desc.available
    state.signature = desc.signature

    if state.signature ~= state.lastLoggedSignature then
        state.lastLoggedSignature = state.signature
        local parts = {}
        local keys = {}
        for id in pairs(desc.counts) do
            keys[#keys + 1] = id
        end
        table.sort(keys)
        for _, id in ipairs(keys) do
            parts[#parts + 1] = Ingredients.Name(id, "zh") .. "(" .. id .. ")x" .. desc.counts[id]
        end
        log("counts: " .. table.concat(parts, ", ") .. " | available=" .. desc.available
            .. " | rooms=" .. Scan.GetFloorRoomCount())
    end
end

-- 理论窗口数：需要先补满袋，之后每放 1 个素材产生 1 个窗口（含当前袋）
local function estimateWindows(slotCount, available)
    local fillNeed = math.max(0, BAG_SIZE - slotCount)
    if available < fillNeed then
        return 0
    end
    return available - fillNeed + 1
end

local function buildChainKey()
    local seed = 0
    pcall(function()
        seed = Game():GetSeeds():GetStartSeed()
    end)
    -- 配方史一有变化（登记 / 撤销 / 清空）revision 就会变 → 保证一定会重算
    return tostring(seed) .. "|" .. BagTracker.GetKey() .. "|" .. state.signature
        .. "|r" .. tostring(BagTracker.GetCraftedRevision())
end

local function finishChain()
    if state.job == nil then
        return
    end
    state.result = state.job.result
    state.searching = false
    if state.result == nil then
        return
    end
    state.scroll = 0
    if config.Debug then
        local stats = state.result.stats or {}
        log(string.format("chain: distinct=%s crafted=%s windows=%s steps=%s waste=%s ms=%.2f",
            tostring(stats.distinct), tostring(stats.craftedHits or 0), tostring(stats.windows),
            tostring(#state.result.steps), tostring(stats.waste), stats.searchMs or 0))
        for i, step in ipairs(state.result.steps) do
            if step.kind == "current" then
                local label = "当前配方"
                if step.isCrafted then
                    label = step.wasCrafted and "当前配方(已合成)" or "当前配方(已出现)"
                end
                log(string.format("  #%s %s -> %s", tostring(step.recipeIndex or "-"), label,
                    table.concat(step.bag, ",")))
            else
                local stateText = "(袋未满)"
                if step.isCrafted then
                    stateText = step.wasCrafted and "(已合成)" or "(已出现)"
                elseif step.recipeIndex ~= nil then
                    stateText = step.isNew and "(新配方)" or "(重复配方)"
                end
                -- 一次拾取可能顶掉 1~2 格（双素材掉落物一次拿完）
                local evictedText = "不顶"
                local evictedList = step.evicted
                if type(evictedList) == "table" then
                    local parts = {}
                    for k = 1, #evictedList do
                        if evictedList[k] ~= false and evictedList[k] ~= nil then
                            parts[#parts + 1] = tostring(evictedList[k])
                        end
                    end
                    if #parts > 0 then
                        evictedText = table.concat(parts, "/")
                    end
                elseif evictedList ~= nil and evictedList ~= false then
                    evictedText = tostring(evictedList)
                end
                log(string.format("  %d. 放 [%s] 顶=%s -> #%s %s %s",
                    i, table.concat(step.atom.ids, ","), evictedText,
                    tostring(step.recipeIndex or "-"), stateText,
                    table.concat(step.bag or {}, ",")))
            end
        end
    end
end

local function ensureChain()
    local key = buildChainKey()
    if state.job ~= nil and state.chainKey == key then
        return
    end

    state.chainKey = key
    state.job = nil
    state.result = nil
    state.searching = false
    state.progress = 0

    local slotCount = BagTracker.Count()
    state.windows = estimateWindows(slotCount, state.available)
    state.notEnough = (slotCount + state.available) < BAG_SIZE
    if state.notEnough then
        return
    end

    state.job = Chain.CreateJob({
        slots = BagTracker.GetSlots(),
        atoms = state.atoms,
        -- 袋里出现过的配方（口径②）不再编号 / 不计分 / 不作目标
        crafted = BagTracker.GetSeenRecipes(),
        craftedConfirmed = BagTracker.GetCraftedRecipes(),
        beamWidth = config.BeamWidth,
        maxSteps = config.MaxSteps,
        preferLessWaste = config.PreferLessWaste,
        maxCountPerType = config.MaxCountPerType,
        stats = { available = state.available, windows = state.windows },
    })
    state.searching = true
    log("search started: slots=" .. BagTracker.GetDebugText() .. " atoms=" .. tostring(#state.atoms))
end

-- ------------------------------------------------------------
-- 输入：自己求边沿
-- Repentance+ 的 Input.IsButtonTriggered 有两个坑：
--   1) 触发状态会保留到被读取，未读取时会一直留着（漏读会变成"迟到触发"）；
--   2) 同一次按键可能连续两帧都读到（一次按键被处理两次：F9 开→立刻关、丢弃键转两格）。
-- 因此改为每帧轮询全部热键的 IsButtonPressed（按住状态），由本模组自己产生边沿，
-- 保证一次物理按键只产生一次事件。键码 %32 的二次判断沿用 ModConfigMenu-CN 的规避方法，
-- 避免手柄按键与键盘键码串扰。
-- ------------------------------------------------------------
local INPUT_KEYS = {
    toggle = config.HotkeyToggle,
    calibrate = config.HotkeyCalibrate,
    recalc = config.HotkeyRecalc,
    language = config.HotkeyLanguage,
    editBag = config.HotkeyEditBag,
    editConfirm = config.HotkeyEditConfirm,
    cursorLeft = config.HotkeyCursorLeft,
    cursorRight = config.HotkeyCursorRight,
    scrollUp = config.HotkeyScrollUp,
    scrollDown = config.HotkeyScrollDown,
    pageUp = config.HotkeyPageUp,
    pageDown = config.HotkeyPageDown,
}

local keyHeld = {}
local keyEdge = {}

local function isKeyHeld(key)
    if key == nil then
        return false
    end
    local ok, held = pcall(function()
        return Input.IsButtonPressed(key, 0)
    end)
    if not ok or held ~= true then
        return false
    end
    -- 手柄按键与键盘键码可能串扰（key%32 是手柄键码）
    local okCtrl, controllerHeld = pcall(function()
        return Input.IsButtonPressed(key % 32, 0)
    end)
    if okCtrl and controllerHeld == true then
        return false
    end
    return true
end

-- 每帧调用：轮询所有热键，产生"本帧刚按下"的边沿
local function pollInput()
    for name, key in pairs(INPUT_KEYS) do
        local held = isKeyHeld(key)
        keyEdge[name] = held and not keyHeld[name]
        keyHeld[name] = held
    end
end

local function pressed(name)
    return keyEdge[name] == true
end

-- 当前面板实际能显示的行数（由 UI 按字体度量算出来的），用于翻页
local function visibleRowCount()
    if UI.LastLayout ~= nil and UI.LastLayout.rows ~= nil then
        return math.max(1, UI.LastLayout.rows)
    end
    return config.MaxVisibleRows or 12
end

local function toggleBagEditor()
    if BagTracker.HasDirectRead() then
        setMessage("已启用 REPENTOGON 直接读取，袋内容无需校正")
        return
    end
    if BagEditor.IsActive() then
        BagEditor.Close(true)   -- 保留草稿，再按 F9 可继续
        setMessage("已退出校正（修改未保存）")
        return
    end
    BagEditor.Open({ counts = state.counts, roomCounts = state.roomCounts })
    state.visible = true
    setMessage("校正袋内容：←/→ 选格  ↑/↓ 换素材  Enter 确认  F9 退出")
end

local function handleEditorHotkeys()
    if pressed("cursorLeft") then
        BagEditor.MoveCursor(-1)
    end
    if pressed("cursorRight") then
        BagEditor.MoveCursor(1)
    end
    if pressed("scrollUp") then
        BagEditor.CycleValue(-1)
    end
    if pressed("scrollDown") then
        BagEditor.CycleValue(1)
    end
    if pressed("editConfirm") then
        local ok = BagEditor.Confirm()
        if ok then
            state.chainKey = nil
            setMessage("袋内容已校正")
        else
            setMessage("校正失败：素材 ID 非法")
        end
    end
end

local function handleHotkeys()
    if pressed("toggle") then
        state.visible = not state.visible
        log("panel visible=" .. tostring(state.visible))
        setMessage(state.visible and "面板已开启" or "面板已关闭")
    end

    if pressed("editBag") then
        toggleBagEditor()
    end

    -- 编辑模式：方向键 / 回车专用于校正，不再滚动列表
    if BagEditor.IsActive() then
        handleEditorHotkeys()
        return
    end

    if pressed("calibrate") then
        if BagTracker.HasDirectRead() then
            setMessage("直接读取模式：袋内容自动同步，无需校准")
        else
            BagTracker.Calibrate()
            BagEditor.Reset()
            state.chainKey = nil
            setMessage("已校准为空袋")
        end
    end

    if pressed("recalc") then
        state.chainKey = nil
        setMessage("重新计算中…")
    end

    if pressed("language") then
        local newLang = UI.ToggleLanguage()
        setMessage(newLang == "zh" and "语言：中文" or "语言：English")
    end

    if pressed("scrollUp") then
        state.scroll = math.max(0, (state.scroll or 0) - 1)
    end
    if pressed("scrollDown") then
        state.scroll = (state.scroll or 0) + 1
    end
    if pressed("pageUp") then
        state.scroll = math.max(0, (state.scroll or 0) - visibleRowCount())
    end
    if pressed("pageDown") then
        state.scroll = (state.scroll or 0) + visibleRowCount()
    end
end

local function updateState()
    state.frame = state.frame + 1
    pollInput()

    local player = getBagPlayer()
    if player == nil then
        return
    end

    BagTracker.Update(player)

    if state.lastScanFrame < 0 or state.frame - state.lastScanFrame >= 2 then
        state.lastScanFrame = state.frame
        refreshScan(player)
    end

    -- 每局第一次更新时打印一次环境诊断，便于从 log.txt 定位问题
    if config.Debug and not state.diagDone then
        state.diagDone = true
        local playerType = -1
        pcall(function()
            playerType = player:GetPlayerType()
        end)
        local screenW, screenH = 0, 0
        pcall(function()
            screenW = Isaac.GetScreenWidth()
            screenH = Isaac.GetScreenHeight()
        end)
        log(string.format("diag: playerType=%s cain=%s bag=%s bagSource=%s recipes=%d screen=%dx%d rect=%s renderText=%s lang=%s",
            tostring(playerType), tostring(BagTracker.IsTracking()), BagTracker.GetDebugText(),
            BagTracker.HasDirectRead() and "direct" or "events",
            BagTracker.GetCraftedCount(), screenW, screenH,
            tostring(Isaac.RenderRect ~= nil), tostring(Isaac.RenderText ~= nil), UI.GetLanguage()))
        log("render: " .. UI.GetRenderInfo())
    end

    handleHotkeys()

    state.slots = BagTracker.GetSlots()
    state.bagState = BagTracker.GetState()
    state.unknownBag = (state.bagState.confidence == "unknown")
    state.uncertainBag = (state.bagState.confidence == "uncertain")
    state.directBag = BagTracker.HasDirectRead()
    state.notCain = not BagTracker.IsTracking()
    state.editor = BagEditor.GetState()

    if state.visible then
        ensureChain()
        if state.job ~= nil and not state.job.done then
            Chain.Step(state.job, config.SearchBudgetMs)
            state.searching = not state.job.done
            state.progress = state.job.progress or 0
            if state.job.done then
                finishChain()
            end
        end
    end

    if state.result ~= nil and state.result.stats ~= nil then
        state.lowVariety = (state.result.stats.distinct or 0) <= 1 and (state.windows or 0) > 1
    else
        state.lowVariety = false
    end

    if state.messageUntil > 0 and Isaac.GetTime() > state.messageUntil then
        state.message = ""
        state.messageUntil = 0
    end
end

-- ------------------------------------------------------------
-- 回调注册
-- ------------------------------------------------------------

-- 新的一局 / 续档：清空所有状态（续档时袋内容未知，需要 F9 校正）
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, isContinued)
    Scan.ResetFloor()
    BagTracker.OnGameStarted(isContinued)
    BagEditor.Reset()
    state.job = nil
    state.result = nil
    state.chainKey = nil
    state.slots = {}
    state.scroll = 0
    state.signature = ""
    state.lastLoggedSignature = nil
    state.lastScanFrame = -100
    state.diagDone = false
    state.frame = 0
    state.editor = { active = false, cursor = 1, slots = {} }
    UI.Init()
    log("game started (continued=" .. tostring(isContinued) .. "), bag="
        .. BagTracker.GetConfidence() .. ", recipes=" .. tostring(BagTracker.GetCraftedCount()))
end)

-- 换层：清空本层掉落物记录
mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
    Scan.ResetFloor()
    state.chainKey = nil
    state.lastLoggedSignature = nil
    log("new level")
end)

-- 换房间：掉落物索引会重置，重新开始检测入袋
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    BagTracker.OnNewRoom()
    BagEditor.Close(true)
    state.chainKey = nil
end)

-- 复活 / 中途加入：袋内容模拟可能已经和真实脱节（E6）
mod:AddCallback(ModCallbacks.MC_POST_PLAYER_INIT, function(_, player)
    if player == nil then
        return
    end
    -- 开局第一秒内的初始化属于正常开局（新局已对齐、续档已置为 unknown）
    if state.frame < 90 or BagTracker.IsUnknown() then
        return
    end
    BagTracker.MarkUnknown("player-init")
    setMessage("角色重新初始化，请按 F9 校正袋内容")
end)

-- 取用合成袋（袋满才会真正合成 → 清空袋内 8 格）
mod:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, function(_, collectible, rng, player, useFlags, slot)
    if collectible ~= CollectibleType.COLLECTIBLE_BAG_OF_CRAFTING then
        return
    end
    if slot ~= nil and slot ~= 0 then
        return
    end
    if not BagTracker.IsFull() then
        -- 袋未满时使用不会合成；若出现这种情况，说明模拟与真实可能已经偏差
        log("bag used but simulation is not full -> ask for calibration")
        BagTracker.MarkUncertain("use-item-not-full")
        setMessage("袋内容可能不同步，请按 F9 校正")
        return
    end
    BagTracker.Clear("use-item")
    BagEditor.Reset()
    state.chainKey = nil
    setMessage("合成完成，袋已清空")
end)

-- 记录“谁碰过这个掉落物”：玩家 / 使魔 / Bumbino / Ultra Greed 精确区分（E3）
mod:AddCallback(ModCallbacks.MC_PRE_PICKUP_COLLISION, function(_, pickup, collider, low)
    if pickup == nil or collider == nil then
        return
    end
    BagTracker.NoteCollision(pickup, collider)
end)

-- 逐帧捕获 Collect 动画首帧（E2：不再依赖每 2 帧轮询）
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_UPDATE, function(_, pickup)
    BagTracker.OnPickupUpdate(pickup)
end)

mod:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    updateState()
end)

mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
    UI.Render(state)
end)

UI.Init()

log("loaded (Debug=" .. tostring(config.Debug) .. ", beam=" .. tostring(config.BeamWidth) .. ")")

-- 供离线测试 / 控制台诊断读取（不写全局变量；游戏加载时会忽略返回值）
return { mod = mod, state = state, BagEditor = BagEditor, BagTracker = BagTracker }



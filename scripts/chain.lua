-- ============================================================
-- 最优放置链搜索（Beam Search + 协程分帧）
--
-- 状态：(袋内序列, 剩余素材计数, 已见配方集合, 浪费值)
-- 动作：拾取一个“原子”（1 或 2 个素材）；袋满时先选定顶掉哪一格
--       —— 2 素材掉落物必须连续放入，第二次顶掉的格子由队列顺序决定
-- 目标：链上出现过的不同配方（8 素材多重集）数量最多
--      opts.crafted（袋里出现过的配方）不计分：不编号、不计入 distinct、不作为目标，
--      只允许当中间态；整条链末尾若只是在命中它们，会被裁掉（避免浪费素材）
-- ============================================================

local config = require("scripts.config")
local Ingredients = require("scripts.data.ingredients")
local Recipe = require("scripts.recipe")
local Log = require("scripts.log")

local Chain = {}

local BAG_SIZE = 8

local ALL_INDICES = { 1, 2, 3, 4, 5, 6, 7, 8 }
local FIRST_INDEX = { 1 }

-- 满袋只放 1 个素材时，顶掉“同一种素材”的任意一格会得到同样的多重集，
-- 因此每种素材只保留一次枚举（减少无效分支）
local function distinctVictimIndices(bag)
    local seenValue = {}
    local indices = {}
    for i = 1, #bag do
        local value = bag[i]
        if seenValue[value] == nil then
            seenValue[value] = true
            indices[#indices + 1] = i
        end
    end
    return indices
end

local function nowMs()
    if Isaac ~= nil and Isaac.GetTime ~= nil then
        return Isaac.GetTime()
    end
    return os.clock() * 1000
end

local function copyList(list)
    local out = {}
    if list ~= nil then
        for i = 1, #list do
            out[i] = list[i]
        end
    end
    return out
end

-- 多重集 key：配方与袋内顺序无关（口径在 scripts/recipe.lua，与配方史共用一份实现）
local function multisetKey(bag)
    return Recipe.Key(bag), Recipe.Sorted(bag)
end

local function hashKey(key)
    local h = 5381
    for i = 1, #key do
        h = (h * 33 + key:byte(i)) & 0x7FFFFFFF
    end
    return h
end

-- 沿父链判断某配方是否已经出现过
local function isSeenInChain(node, key)
    local cursor = node
    while cursor ~= nil do
        local added = cursor.addedKeys
        if added ~= nil then
            for i = 1, #added do
                if added[i] == key then
                    return true
                end
            end
        end
        cursor = cursor.parent
    end
    return false
end

local function betterNode(a, b)
    if b == nil then
        return true
    end
    if a.score ~= b.score then
        return a.score > b.score
    end
    if a.seen ~= b.seen then
        return a.seen > b.seen
    end
    if a.waste ~= b.waste then
        return a.waste < b.waste
    end
    if a.depth ~= b.depth then
        return a.depth < b.depth
    end
    return a.bagKey < b.bagKey
end

-- 生成子状态
-- pushes: { { part = 1|2, evicted = 素材ID 或 false, windowKey = 配方key 或 nil, windowBag = 排序后的袋 } }
local function createChild(ctx, parent, atomIndex, bag, pushes, waste)
    local bagKey, sortedBag = multisetKey(bag)

    local seen = parent.seen
    local sig = parent.sig
    local added = nil
    local pushInfo = {}

    for i = 1, #pushes do
        local p = pushes[i]
        local isNew = nil
        local isCrafted = false
        if p.windowKey ~= nil then
            -- 袋里出现过的配方（口径②，见 bag_tracker）等价于“已经见过了”：
            -- 不加分、不进 addedKeys、不参与 sig —— 但允许它当中间态继续往后走
            isCrafted = (ctx.crafted[p.windowKey] == true)
            if isCrafted then
                isNew = false
            else
                local duplicate = isSeenInChain(parent, p.windowKey)
                if not duplicate and added ~= nil then
                    for j = 1, #added do
                        if added[j] == p.windowKey then
                            duplicate = true
                            break
                        end
                    end
                end
                if not duplicate then
                    seen = seen + 1
                    sig = sig ~ hashKey(p.windowKey)
                    added = added or {}
                    added[#added + 1] = p.windowKey
                end
                isNew = not duplicate
            end
        end
        pushInfo[i] = {
            part = p.part,
            evicted = p.evicted,
            at = p.at,
            windowKey = p.windowKey,
            windowBag = p.windowBag,
            isNew = isNew,
            isCrafted = isCrafted,
        }
    end

    -- 剪枝：既没有新配方，袋的多重集也没有变化 → 纯浪费动作
    if added == nil and bagKey == parent.bagKey then
        return
    end

    local inv = {}
    for i = 1, #parent.inv do
        inv[i] = parent.inv[i]
    end
    inv[atomIndex] = inv[atomIndex] - 1

    local totalWaste = parent.waste + waste
    local depth = parent.depth + 1
    local invSig = parent.invSig - ctx.atomHash[atomIndex]
    local node = {
        bag = bag,
        bagKey = bagKey,
        sortedBag = sortedBag,
        inv = inv,
        invSig = invSig,
        seen = seen,
        sig = sig,
        addedKeys = added,
        waste = totalWaste,
        depth = depth,
        parent = parent,
        atomIndex = atomIndex,
        pushes = pushInfo,
        score = seen * 1000 - totalWaste * ctx.wastePenalty - depth * 0.01,
    }

    -- 去重：同一（袋 + 剩余计数 + 已见配方集合）只保留最优
    local stateKey = bagKey .. "|" .. tostring(invSig) .. "|" .. tostring(seen) .. "|" .. tostring(sig)
    local existing = ctx.states[stateKey]
    if existing == nil then
        ctx.states[stateKey] = node
        ctx.stateOrder[#ctx.stateOrder + 1] = stateKey
    elseif betterNode(node, existing) then
        ctx.states[stateKey] = node
    end
end

-- 展开一个原子（一次拾取：1 或 2 个素材，必须一次拿完，不能只拾取其中一个）
--   · 只有「最后一个素材」才形成配方窗口：中间状态在游戏里不可达（两个素材是一次吸进去的）
--   · 袋满时：第 1 个素材靠「丢弃键轮转」选择顶掉哪一格；
--            后续素材只能顶掉轮转后的队首（FIFO），因此两次顶掉必然是队列上相邻的两格
local function expandAtom(ctx, node, atomIndex)
    local atom = ctx.atoms[atomIndex]
    local ids = atom.ids
    local parts = #ids

    local function step(bag, pos, pushes, waste)
        if pos > parts then
            createChild(ctx, node, atomIndex, bag, pushes, waste)
            return
        end
        local id = ids[pos]
        local isLast = (pos == parts)
        if #bag < BAG_SIZE then
            local newBag = copyList(bag)
            newBag[#newBag + 1] = id
            local windowKey, windowBag = nil, nil
            if isLast and #newBag == BAG_SIZE then
                windowKey, windowBag = multisetKey(newBag)
            end
            local newPushes = copyList(pushes)
            newPushes[#newPushes + 1] = {
                part = pos,
                evicted = false,
                at = false,
                windowKey = windowKey,
                windowBag = windowBag,
            }
            step(newBag, pos + 1, newPushes, waste)
            return
        end

        local indices
        if pos == 1 then
            if parts == 1 then
                indices = distinctVictimIndices(bag)
            else
                indices = ALL_INDICES
            end
        else
            indices = FIRST_INDEX   -- 第 2 个素材：只能顶掉轮转后的队首
        end
        for ii = 1, #indices do
            local k = indices[ii]
            local victim = bag[k]
            local newBag = {}
            for i = k + 1, BAG_SIZE do
                newBag[#newBag + 1] = bag[i]
            end
            for i = 1, k - 1 do
                newBag[#newBag + 1] = bag[i]
            end
            newBag[#newBag + 1] = id
            local windowKey, windowBag = nil, nil
            if isLast then
                windowKey, windowBag = multisetKey(newBag)
            end
            local newPushes = copyList(pushes)
            newPushes[#newPushes + 1] = {
                part = pos,
                evicted = victim,
                at = k,          -- 顶掉的下标（同值格子有多个时，测试重放要靠它保持队列顺序一致）
                windowKey = windowKey,
                windowBag = windowBag,
            }
            step(newBag, pos + 1, newPushes, waste + Ingredients.Value(victim))
        end
    end

    step(node.bag, 1, {}, 0)
end

-- ------------------------------------------------------------
-- 结果整理：沿最优节点的父链还原完整动作链
-- ------------------------------------------------------------
local function buildResult(job, best)
    local path = {}
    local cursor = best
    while cursor ~= nil do
        table.insert(path, 1, cursor)
        cursor = cursor.parent
    end

    local crafted = job.crafted or {}
    local craftedConfirmed = job.craftedConfirmed or {}
    local recipeIndex = {}
    local nextIndex = 0
    local steps = {}

    local function isCraftedKey(key)
        return key ~= nil and crafted[key] == true
    end

    local function indexOf(key)
        -- 已出现过的配方不编号（口径②）：既不算新配方，也不占「配方#n」的号
        if key == nil or isCraftedKey(key) then
            return nil, false
        end
        local idx = recipeIndex[key]
        if idx ~= nil then
            return idx, false
        end
        nextIndex = nextIndex + 1
        recipeIndex[key] = nextIndex
        return nextIndex, true
    end

    for pi = 1, #path do
        local node = path[pi]
        if node.parent == nil then
            -- 起始袋：袋满时本身就是一个配方窗口（已出现过时只显示袋内容，不编号）
            if node.seen > 0 or node.isCraftedStart then
                local idx, isNew = indexOf(node.bagKey)
                steps[#steps + 1] = {
                    kind = "current",
                    bag = node.sortedBag,
                    recipeIndex = idx,
                    isNew = isNew,
                    isCrafted = isCraftedKey(node.bagKey),
                    wasCrafted = craftedConfirmed[node.bagKey] == true,
                }
            end
        else
            -- 一次拾取 = 一个动作：2 素材掉落物也是「一次拿完」，所以只输出一行，
            -- 落点取最后一个素材形成的窗口（中间状态不可达）
            local atom = job.atoms[node.atomIndex]
            local pushes = node.pushes
            local evicted = {}
            local evictedAt = {}
            for k = 1, #pushes do
                local victim = pushes[k].evicted
                evicted[k] = (victim == false or victim == nil) and false or victim
                evictedAt[k] = pushes[k].at or false
            end
            local lastPush = pushes[#pushes]
            local idx, isNew = indexOf(lastPush.windowKey)
            steps[#steps + 1] = {
                kind = "push",
                atom = atom,
                ids = atom.ids,
                evicted = evicted,        -- 与 atom.ids 一一对应（false = 没顶掉）
                evictedAt = evictedAt,    -- 同上，记录袋内下标（供测试精确重放）
                bag = lastPush.windowBag,
                slotsAfter = lastPush.windowBag,
                recipeIndex = idx,
                isNew = isNew,
                isCrafted = lastPush.isCrafted == true,
                wasCrafted = craftedConfirmed[lastPush.windowKey] == true,
                waste = node.waste,
            }
        end
    end

    -- 末尾裁剪：最后几步只是把袋填回“已出现过”的组合、没有产出任何新配方 → 删掉，
    -- 避免让玩家白放（链条是连续动作，只裁末尾；中间步骤保留，否则照着做会对不上）
    local trimFrom = #steps + 1
    while trimFrom > 1 do
        local step = steps[trimFrom - 1]
        if step.kind == "push" and step.isCrafted == true then
            trimFrom = trimFrom - 1
        else
            break
        end
    end
    if trimFrom <= #steps then
        for i = trimFrom, #steps do
            if steps[i].isNew == true then
                trimFrom = #steps + 1
                break
            end
        end
    end
    for i = #steps, trimFrom, -1 do
        steps[i] = nil
    end

    local pushCount = 0
    local craftedHits = 0
    local lastWaste = 0
    for _, step in ipairs(steps) do
        if step.kind == "push" then
            pushCount = pushCount + #step.atom.ids
            lastWaste = step.waste or lastWaste
            if step.isCrafted then
                craftedHits = craftedHits + 1
            end
        end
    end

    local stats = job.stats
    stats.distinct = best.seen
    stats.recipeCount = nextIndex
    stats.pushes = pushCount
    stats.waste = lastWaste
    stats.depth = best.depth
    stats.craftedHits = craftedHits
    stats.searchMs = math.floor((job.cpuMs or 0) * 100) / 100

    return {
        steps = steps,
        stats = stats,
        atoms = job.atoms,
        bag = best.sortedBag,
    }
end

-- ------------------------------------------------------------
-- 搜索主体（协程内运行）
-- ------------------------------------------------------------
local function runSearch(job)
    local opts = job.options
    local beamWidth = opts.beamWidth or config.BeamWidth
    local maxSteps = opts.maxSteps or config.MaxSteps
    local wastePenalty = ((opts.preferLessWaste == nil) or opts.preferLessWaste) and 3 or 1
    local maxCountPerType = opts.maxCountPerType or config.MaxCountPerType

    local ctx = {
        atoms = job.atoms,
        wastePenalty = wastePenalty,
        crafted = job.crafted or {},
        states = {},
        stateOrder = {},
        atomHash = {},
    }

    local bag = copyList(opts.slots)
    local bagKey, sortedBag = multisetKey(bag)
    local inv = {}
    local invSig = 0
    for i = 1, #ctx.atoms do
        local count = ctx.atoms[i].count or 0
        if count > maxCountPerType then
            count = maxCountPerType
        end
        inv[i] = count
        local h = (hashKey(tostring(ctx.atoms[i].kind)) * 2654435761) & 0x3FFFFFFFFFFFFFFF
        ctx.atomHash[i] = h
        invSig = invSig + h * count
    end

    local start = {
        bag = bag,
        bagKey = bagKey,
        sortedBag = sortedBag,
        inv = inv,
        invSig = invSig,
        seen = 0,
        sig = 0,
        addedKeys = nil,
        waste = 0,
        depth = 0,
        parent = nil,
        atomIndex = nil,
        pushes = nil,
        score = 0,
    }
    if #bag == BAG_SIZE then
        if ctx.crafted[bagKey] == true then
            -- 起始袋的配方已经出现过（口径②）：不计分、不进 addedKeys，只用来显示袋内容
            start.isCraftedStart = true
        else
            start.seen = 1
            start.sig = hashKey(bagKey)
            start.addedKeys = { bagKey }
            start.score = 1000
        end
    end

    local beam = { start }
    local best = start
    local stepIndex = 0

    while stepIndex < maxSteps do
        stepIndex = stepIndex + 1
        ctx.states = {}
        ctx.stateOrder = {}

        for bi = 1, #beam do
            local node = beam[bi]
            for ai = 1, #ctx.atoms do
                if node.inv[ai] ~= nil and node.inv[ai] > 0 then
                    expandAtom(ctx, node, ai)
                end
            end
            coroutine.yield()
        end

        if #ctx.stateOrder == 0 then
            break
        end

        local candidates = {}
        for i = 1, #ctx.stateOrder do
            candidates[i] = ctx.states[ctx.stateOrder[i]]
        end
        table.sort(candidates, betterNode)

        local width = math.min(beamWidth, #candidates)
        local nextBeam = {}
        for i = 1, width do
            nextBeam[i] = candidates[i]
        end
        beam = nextBeam

        if betterNode(beam[1], best) then
            best = beam[1]
        end
        job.progress = stepIndex / maxSteps
        coroutine.yield()
    end

    job.progress = 1
    local result = buildResult(job, best)
    job.result = result
    return result
end

-- ------------------------------------------------------------
-- 对外接口
-- ------------------------------------------------------------

-- opts:
--   slots              = { 素材ID... } 袋内现状（有序，1 = 最旧）
--   atoms              = { atom... }    可用素材来源
--   crafted            = { [配方key] = true } 袋里出现过的配方（不再编号 / 不计分 / 不作目标）
--   craftedConfirmed   = { [配方key] = true } 其中真的合成过的（只用于 UI 文案区分）
--   beamWidth / maxSteps / preferLessWaste / maxCountPerType
--   stats              = { available = .., windows = .. } 统计信息（会被补全）
function Chain.CreateJob(opts)
    local atoms = {}
    local byKey = {}
    for _, atom in ipairs(opts.atoms or {}) do
        if atom.ids ~= nil and #atom.ids > 0 and (atom.count or 0) > 0 then
            -- 贡献相同素材序列、且来源性质相同（地上 / 背包）的掉落物可合并
            local key = table.concat(atom.ids, ",") .. "|" .. tostring(atom.fromInventory == true)
            local merged = byKey[key]
            if merged == nil then
                merged = {
                    kind = atom.kind,
                    ids = atom.ids,
                    count = 0,
                    fromInventory = atom.fromInventory == true,
                    ingredientId = atom.ingredientId,
                    variant = atom.variant,
                    subtype = atom.subtype,
                }
                byKey[key] = merged
                atoms[#atoms + 1] = merged
            end
            merged.count = merged.count + atom.count
        end
    end
    -- 按 kind 排序，保证每次结果顺序稳定
    table.sort(atoms, function(a, b)
        return tostring(a.kind) < tostring(b.kind)
    end)

    local job = {
        options = opts,
        atoms = atoms,
        stats = opts.stats or {},
        crafted = opts.crafted or {},
        craftedConfirmed = opts.craftedConfirmed or {},
        done = false,
        progress = 0,
        cpuMs = 0,
        error = nil,
        result = nil,
    }
    job.co = coroutine.create(function()
        return runSearch(job)
    end)
    return job
end

-- 推进搜索，最多消耗 budgetMs 毫秒；返回是否已完成
function Chain.Step(job, budgetMs)
    if job == nil or job.done then
        return true
    end
    local t0 = nowMs()
    local budget = budgetMs or config.SearchBudgetMs
    while not job.done do
        local ok, err = coroutine.resume(job.co)
        if not ok then
            job.error = tostring(err)
            job.done = true
            Log.Write("[CainsBag] chain search error: " .. job.error)
            break
        end
        if coroutine.status(job.co) == "dead" then
            job.done = true
            break
        end
        if (nowMs() - t0) >= budget then
            break
        end
    end
    job.cpuMs = (job.cpuMs or 0) + (nowMs() - t0)
    return job.done
end

-- 同步计算（测试 / 控制台调试用）
function Chain.ComputeSync(opts, budgetMs)
    local job = Chain.CreateJob(opts)
    local guard = 0
    while not job.done do
        Chain.Step(job, budgetMs or 1e9)
        guard = guard + 1
        if guard > 1000000 then
            break
        end
    end
    return job.result, job
end

return Chain




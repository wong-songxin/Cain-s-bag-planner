-- ============================================================
-- 合成袋模拟（原生 API 读不到袋内真实内容，只能本地模拟）
-- 规则：8 格 FIFO，第 1 格最旧；第 9 个素材入袋时最旧的一格被销毁
--       堕化该隐袋满时按 ACTION_DROP 可轮转（第 1 格移到队尾）
-- 识别：逐帧 Collect 动画 + 碰撞回调区分「普通拾取 / 袋吸收」+ 计数器否决
--       关键事实（与 EID 的 eid_bagofcrafting.lua 一致）：
--         · MC_PRE_PICKUP_COLLISION = 玩家/使魔“走上去碰到”＝普通拾取 → 不进袋
--         · 挥袋 / 吸取进袋不触发该回调 → Collect 动画且“没被碰过”才是入袋
-- 可信度：unknown / known / tracking / uncertain（面板只读展示）
-- ============================================================

local config = require("scripts.config")
local Log = require("scripts.log")
local Ingredients = require("scripts.data.ingredients")
local Recipe = require("scripts.recipe")

local BagTracker = {}

local BAG_SIZE = 8
local NEAR_DISTANCE = 60      -- 判定“玩家在掉落物旁边”的距离（内部坐标，1 格 = 40）
local TOUCH_TTL = 60          -- 触碰标记的存活帧数（仅用于清理）
local TOUCH_FRESH = 3         -- 碰撞记录的新鲜帧数（默认值，可被 config.TouchFreshFrames 覆盖）
local VETO_GRACE = 6          -- 计数器否决观察窗口默认值（可被 config.CounterVetoFrames 覆盖）
local COUNTER_GRACE = 60      -- 计数器核对最多等多少帧（拾取动画 / 结算可能比事件晚 1 秒）
local COUNTER_LOOKBACK = 4    -- 取“事件发生前”的计数快照要往回看几帧

local slots = {}              -- 有序数组，1 = 最旧（下一个被顶掉的格子）
local confidence = "unknown"  -- unknown | known | tracking | uncertain
local confidenceReason = ""
local tracking = false        -- 当前角色是否能被精确跟踪（堕化该隐）
local bagPlayerIndex = nil
local known = {}              -- key -> entry（上一次扫描到的掉落物）
local touched = {}            -- key -> { player, bagPlayer, frame, colliderType, colliderIndex }（谁碰过它）
local pushed = {}             -- key -> true，避免同一掉落物被重复记入
local skipLog = {}            -- key -> reason，避免同一掉落物重复刷日志
local attrLogged = {}         -- key -> true，每个掉落物只打一条归属证据日志
local pendingVeto = {}        -- key -> { entry, evicted, groups, before, frame }（计数器否决观察）
local pendingChecks = {}      -- 背包计数器二次确认队列（仅 config.CounterCheck 调试用）
local counterHistory = {}     -- 最近若干帧的背包计数快照（用于“事件发生前”的对比）
local lastCharge = nil        -- 上一帧读到的主道具充能（袋容量探针）
local lastChargeMax = nil
local chargeWatch = nil       -- { charge, frame, reason }：被跳过之后观察袋容量有没有涨（自检）
local cardSignature = nil     -- 卡牌/药丸槽签名（每 10 帧刷新）：变化说明这次拾取进了背包，不是进袋
local cardSignatureTick = -100
local dropHeldByController = {} -- 丢弃键的按住状态（ACTION_DROP 也要自己求边沿）
local collectors = {}         -- 非玩家收集者（使魔 / 乞丐 / 老虎机）位置，来自每 2 帧的房间扫描
local directReadAvailable = nil -- nil = 未探测；true/false = 是否有 REPENTOGON 直读
local directReadLogged = false
local lastClearReason = ""
-- ------------------------------------------------------------
-- 配方史（step5，口径②）：袋里「出现过」的 8 格组合，之后不再作为规划目标
--   · 不要求真的合成过（只要满 8 格出现过就拉黑，避免把素材浪费在重复配方上）
--   · 只在本次运行内存里有效（模组不读写存档）；Reset() 时清空
--   · seenRecipes     = key -> true（出现过即拉黑）
--   · recipeUses      = key -> 出现次数（撤销误记时按计数回退；0 次时从黑名单删掉）
--   · seenRecipeOrder = 首次记录顺序（计数 / 日志用）
--   · craftedRecipes  = 其中「真的合成过」的那些，只用于 UI 文案区分（已合成 / 已出现）
-- ------------------------------------------------------------
local seenRecipes = {}
local recipeUses = {}
local seenRecipeOrder = {}
local craftedRecipes = {}
local recipeRevision = 0      -- 变更版本号：main 的链缓存 key 用它感知“配方史变了”
local lastCollectibleCount = nil   -- 上一帧的道具数（合成检测：道具数增加 = 合成完成）
local craftHoldFrames = 0          -- 长按合成键的帧数（仅调试打点用）
-- 两个主动道具槽的上一帧快照：合成出的主动道具可能顶掉「另一个主动槽」（书包等双主动槽），
-- 此时道具总数不变、袋子也还在 ⇒ 只能靠槽位 itemID 变化识别合成
local activeSnapshot = nil         -- { player = ControllerIndex, a = item0, b = item1 }
local playerX = nil
local playerY = nil
local bagPlayer = nil          -- 当前追踪的玩家（计数器二次确认要用）
local ignoreTicks = 0         -- 换房后的保护帧：掉落物 Index 可能残留
local swipeUntil = -1000      -- “举起合成袋（Q）”窗口：到这一刻之前都算袋吸收（bug4）
local pushedInfo = {}         -- key -> { entry, evicted, recipeKey, frame, reason }（碰撞证据迟到时撤销）
local collideLogged = {}      -- key -> true，每个掉落物只打一条碰撞证据日志
local vanishedLogged = {}     -- key -> true，“两帧扫描之间消失且从未见过 Collect”的诊断（只记录，不判定）
local roomEntryLogged = {}    -- key -> true，换房保护帧内被吸收的掉落物诊断（当前不判定）
local editorRef = nil         -- scripts.bag_editor 注册进来，供 GetEditState() 只读查询

-- ------------------------------------------------------------
-- 回退（控制台 rewind / 时间回溯）恢复
-- rewind 会把整局状态倒回到若干帧前（start seed 不变、帧号变小），并向模组重新发
-- POST_PLAYER_INIT / POST_GAME_STARTED(continued=true)。如果照常 Reset()，面板上的
-- 袋内容与本层掉落物就全丢了。这里按「游戏帧号」保留最近一段快照，回退后恢复到
-- 目标帧的状态（袋吸收是确定性的：同一帧在两条时间线上袋内容相同）。
-- ------------------------------------------------------------
local gameFrame = 0           -- Game():GetFrameCount()（整局帧号，不会因换房归零）
local bagHistory = {}         -- { { frame = n, slots = {...} }, ... }（帧号递增）
local rewindCount = 0         -- 已恢复的回退次数（日志 / 测试用）

-- 单调帧计时：Room:GetFrameCount() 换房会归零，会把“之前的快照”变成“未来时间”，
-- 导致计数器否决永远取不到正确的前置值（这是金币被误记的根因之一）
local tick = 0

-- 背包计数器分组：用于“事件识别是否真的发生了”的二次确认
-- 只覆盖计数稳定、不会被“满值浪费”吞掉的类型；卡牌 / 药丸 / 电池等没有对应计数器，跳过核对
local COUNTER_GROUP = {
    [8] = "coin", [9] = "coin", [10] = "coin", [11] = "coin", [26] = "coin",
    [12] = "key", [13] = "key", [14] = "key",
    [15] = "bomb", [16] = "bomb", [17] = "bomb",
    [1] = "redHeart",
}

local COUNTER_GETTER = {
    coin = "GetNumCoins",
    key = "GetNumKeys",
    bomb = "GetNumBombs",
    redHeart = "GetHearts",
}

-- 满值后拾取不会再增加计数，不能用来判定“没入袋”
local COUNTER_CAP = { coin = 99, key = 99, bomb = 99 }

-- 进「卡牌/药丸槽」的素材：用槽位签名变化来判断“这次是普通拾取，没进袋”
local CARD_LIKE_IDS = { [21] = true, [22] = true, [23] = true, [24] = true, [25] = true }

local COUNTER_ALL_GROUPS = { coin = true, key = true, bomb = true, redHeart = true }
local COUNTER_HISTORY_MAX = 12

-- ------------------------------------------------------------
-- 小工具
-- ------------------------------------------------------------

local function nowFrame()
    return tick
end

-- 整局帧号（换房不归零）；1.9 原生 API 就有，取不到时返回 nil（回退到 tick）
local function readGameFrame()
    local value = nil
    pcall(function()
        value = Game():GetFrameCount()
    end)
    if type(value) == "number" then
        return value
    end
    return nil
end

local function copyList(list)
    local copy = {}
    for i = 1, #list do
        copy[i] = list[i]
    end
    return copy
end

-- 历史保留窗口（帧）；config.RewindFrames = 0 表示不保留（回退后只能按未知处理）
local function historyWindow()
    local value = config.RewindFrames
    if type(value) ~= "number" then
        return 10800
    end
    return value
end

-- 袋内容快照：只在袋发生变化时调用（入袋 / 清空 / 校正 / 撤销）
-- 同一帧内多次变化只保留最后一次；超出窗口的旧快照会被裁掉
local function noteBagSnapshot()
    if historyWindow() <= 0 then
        return
    end
    local frame = readGameFrame()
    if frame == nil then
        frame = gameFrame
    end
    local last = bagHistory[#bagHistory]
    local snapshot = copyList(slots)
    if last ~= nil and last.frame == frame then
        last.slots = snapshot
    else
        bagHistory[#bagHistory + 1] = { frame = frame, slots = snapshot }
    end
    local cutoff = frame - historyWindow()
    local keepFrom = nil
    for i = 1, #bagHistory do
        if bagHistory[i].frame >= cutoff then
            keepFrom = i
            break
        end
    end
    if keepFrom ~= nil and keepFrom > 1 then
        for i = keepFrom - 1, 1, -1 do
            table.remove(bagHistory, i)
        end
    end
end

-- 目标帧（含）之前最近的袋快照；目标帧早于所有记录时返回 nil（不知道就按未知处理）
-- 帧号 ≤ 0 的快照是“刚开局的基线”，不能代表真值（回退到 0 时一律按未知处理）
local function findBagSnapshot(frame)
    for i = #bagHistory, 1, -1 do
        local snapshot = bagHistory[i]
        if snapshot.frame <= frame and snapshot.frame > 0 then
            return snapshot
        end
    end
    return nil
end

local function entityField(entity, field)
    local value = nil
    pcall(function()
        value = entity[field]
    end)
    return value
end

-- 逐帧热路径用：避免每次调用都新建闭包
local function getEntityAnimation(entity)
    return entity:GetSprite():GetAnimation()
end

-- 掉落物去重 key：InitSeed 在同一局内唯一（换房后 Index 会复用）；取不到时退回 Index
local function keyFrom(seed, index)
    if type(seed) == "number" and seed ~= 0 then
        return "s" .. tostring(seed)
    end
    if index ~= nil then
        return "i" .. tostring(index)
    end
    return nil
end

local function entryKey(entry)
    if entry == nil then
        return nil
    end
    return keyFrom(entry.seed, entry.index)
end

local function pickupKey(pickup)
    if pickup == nil then
        return nil
    end
    return keyFrom(entityField(pickup, "InitSeed"), entityField(pickup, "Index"))
end

local function entryFromPickup(pickup)
    local entry = {
        index = entityField(pickup, "Index"),
        seed = entityField(pickup, "InitSeed"),
        variant = entityField(pickup, "Variant"),
        subtype = entityField(pickup, "SubType"),
        ids = nil,
        shop = false,
        collecting = true,
        x = nil,
        y = nil,
    }
    pcall(function()
        entry.x = pickup.Position.X
        entry.y = pickup.Position.Y
    end)
    pcall(function()
        entry.shop = pickup:ToPickup():IsShopItem() == true
    end)
    if entry.variant ~= nil and entry.subtype ~= nil then
        entry.ids = Ingredients.FromPickup(entry.variant, entry.subtype)
    end
    return entry
end

local function isNearPlayer(entry)
    if entry == nil or entry.x == nil or entry.y == nil or playerX == nil or playerY == nil then
        return false
    end
    local dx = entry.x - playerX
    local dy = entry.y - playerY
    return (dx * dx + dy * dy) <= (NEAR_DISTANCE * NEAR_DISTANCE)
end

-- 兼容两种写法：新接口用掉落物对象，旧接口 / 测试用 Index 数字
local function touchRecord(entry)
    local record = touched[entryKey(entry)]
    if record == nil and entry ~= nil and entry.index ~= nil then
        record = touched[keyFrom(nil, entry.index)]
    end
    return record
end

local function touchFreshFrames()
    local value = config.TouchFreshFrames
    if type(value) == "number" and value > 0 then
        return value
    end
    return TOUCH_FRESH
end

-- 最近的碰撞记录（只在“新鲜窗口”内有效）
-- 语义：碰撞 = 拾取者“走上去碰到”掉落物 = 普通拾取（进钱/钥匙/炸弹/红心/卡槽），不进袋
local function recentTouch(entry)
    local record = touchRecord(entry)
    if record == nil then
        return nil
    end
    local age = nowFrame() - (record.frame or 0)
    if age < 0 or age > touchFreshFrames() then
        return nil
    end
    return record, age
end

-- 碰撞者类别（日志 / 判定共用）
local function touchLabel(record)
    if record == nil then
        return "none"
    end
    if record.bagPlayer then
        return "player"
    end
    if record.player then
        return "other-player"
    end
    if record.colliderType == EntityType.ENTITY_FAMILIAR then
        return "familiar"
    end
    if record.colliderType == EntityType.ENTITY_SLOT then
        return "slot"
    end
    return "other"
end

-- ------------------------------------------------------------
-- 非玩家收集者（使魔 / Bumbino / Ultra Greed / 老虎机、乞丐）
-- 事件模拟时用来判断“这个掉落物不是玩家拿的”
-- ------------------------------------------------------------

function BagTracker.SetCollectors(list)
    collectors = list or {}
end

-- 最近的收集者（使魔 / 乞丐 / 老虎机 / Bumbino / Ultra Greed）与平方距离
local function nearestCollector(entry)
    if entry == nil or entry.x == nil or entry.y == nil then
        return nil, nil
    end
    local best = nil
    local bestDist = nil
    for _, collector in ipairs(collectors) do
        local dx = collector.x - entry.x
        local dy = collector.y - entry.y
        local dist = dx * dx + dy * dy
        if bestDist == nil or dist < bestDist then
            best = collector
            bestDist = dist
        end
    end
    return best, bestDist
end

-- 收集者类型标签（日志用）：只有官方 5 个吃掉落物的跟班会出现在这里
local function collectorLabel(collector)
    if collector == nil then
        return "-"
    end
    local entityType = collector.type
    if entityType == EntityType.ENTITY_FAMILIAR then
        if collector.name ~= nil then
            return "familiar:" .. tostring(collector.variant or "?") .. "(" .. tostring(collector.name) .. ")"
        end
        return "familiar"
    end
    return tostring(entityType or "?")
end

local function collectorNear(entry)
    if config.CollectorSkip == false then
        return false
    end
    local _, dist = nearestCollector(entry)
    if dist == nil then
        return false
    end
    local radius = config.CollectorRadius or 28
    return dist <= radius * radius
end

-- 收集者比持袋玩家更靠近这个掉落物？（用于“没有碰撞回调”时的防御性判断）
-- 口径：官方只有 Bum Friend / Dark Bum / Bumbo / Key Bum / Super Bum 会吃地上掉落物，
-- 其它实体（捐款机等 slot、Bumbino、Ultra Greed）都不算收集者（scan.lua 负责过滤）。
local function collectorCloserThanPlayer(entry)
    if config.CollectorSkip == false then
        return nil
    end
    local collector, dist = nearestCollector(entry)
    if collector == nil then
        return nil
    end
    local radius = config.CollectorRadius or 28
    if dist > radius * radius then
        return nil
    end
    if playerX ~= nil and playerY ~= nil then
        local dx = entry.x - playerX
        local dy = entry.y - playerY
        if (dx * dx + dy * dy) <= dist then
            return nil   -- 玩家更近：更像“挥袋吸收”
        end
    end
    return collector
end

-- ------------------------------------------------------------
-- REPENTOGON 直读（可选）：GetBagOfCraftingContent() → BagOfCraftingPickup[8]
-- 枚举值与本模组素材 ID 完全一致（0 = 空）。没装 REPENTOGON 时自动退回事件模拟。
-- ------------------------------------------------------------

local function detectDirectRead(player)
    if directReadAvailable ~= nil then
        return directReadAvailable
    end
    if config.DirectRead == false or player == nil then
        directReadAvailable = false
        return false
    end
    local method = nil
    pcall(function()
        method = player.GetBagOfCraftingContent
    end)
    directReadAvailable = (method ~= nil)
    if config.Debug and not directReadLogged then
        directReadLogged = true
        Log.Write("[CainsBag] bag source: "
            .. (directReadAvailable and "direct read (REPENTOGON)" or "event simulation (vanilla API)"))
    end
    return directReadAvailable
end

-- 返回紧凑列表（去掉 0 = 空）；形状不认识时返回 nil（退回事件模拟）
local function readDirectBag(player)
    local ok, content = pcall(function()
        return player:GetBagOfCraftingContent()
    end)
    if not ok or type(content) ~= "table" then
        return nil
    end
    -- REPENTOGON 一般返回 1-based 的 Lua 表；同时兼容 0-based
    local base = 1
    if content[1] == nil then
        if content[0] ~= nil then
            base = 0
        else
            return nil
        end
    end
    local list = {}
    local foundNumber = false
    for i = 1, BAG_SIZE do
        local value = content[base + i - 1]
        if value == nil then
            value = 0           -- 只要有一个数字就认这张表；缺失的格子按空处理
        elseif type(value) ~= "number" then
            return nil
        else
            foundNumber = true
        end
        if value < 0 then
            value = 0
        end
        if value > Ingredients.MAX_ID then
            return nil
        end
        if value ~= 0 then
            list[#list + 1] = value
        end
    end
    if not foundNumber then
        return nil
    end
    return list
end

function BagTracker.HasDirectRead()
    return directReadAvailable == true
end

local function setConfidence(state, reason)
    if confidence ~= state then
        if config.Debug then
            Log.Write("[CainsBag] bag state: " .. tostring(confidence) .. " -> " .. tostring(state)
                .. ((reason ~= nil and reason ~= "") and (" (" .. reason .. ")") or ""))
        end
        confidence = state
        confidenceReason = reason or ""
    elseif reason ~= nil and reason ~= "" then
        confidenceReason = reason
    end
end

-- ------------------------------------------------------------
-- 背包计数器二次确认（M1.4）
-- ------------------------------------------------------------

local function counterGroupsForIds(ids)
    local groups = {}
    local hasGroup = false
    local pureRedHeart = true
    for _, id in ipairs(ids or {}) do
        if id ~= 1 then
            pureRedHeart = false
        end
        local group = COUNTER_GROUP[id]
        if group ~= nil then
            groups[group] = true
            hasGroup = true
        end
    end
    -- 混合心（红 + 魂）在满红血时可能只加魂心，不能用红心计数器判定
    if groups.redHeart ~= nil and not pureRedHeart then
        groups.redHeart = nil
        hasGroup = false
        for _ in pairs(groups) do
            hasGroup = true
            break
        end
    end
    return hasGroup and groups or nil
end

local function readCounters(player, groups)
    local values = {}
    if player == nil then
        return values
    end
    for group in pairs(groups or {}) do
        local getter = COUNTER_GETTER[group]
        if getter ~= nil then
            local ok, value = pcall(function()
                return player[getter](player)
            end)
            if ok and type(value) == "number" then
                values[group] = value
            end
        end
    end
    return values
end

-- 记录最近若干帧的背包计数（每帧一次），用于取“事件发生前”的快照
-- 关键：拾取结算往往和 Collect 动画同帧（甚至更早），必须在事件发生前就留好快照
local function recordCounterHistory(player)
    if player == nil then
        return
    end
    local values = readCounters(player, COUNTER_ALL_GROUPS)
    local readable = false
    for _ in pairs(values) do
        readable = true
        break
    end
    if not readable then
        return
    end
    counterHistory[#counterHistory + 1] = { frame = nowFrame(), values = values }
    while #counterHistory > COUNTER_HISTORY_MAX do
        table.remove(counterHistory, 1)
    end
end

-- 卡牌 / 药丸槽签名：普通拾取会把它塞进背包（槽位变化），进袋则不会
local function readCardSignature(player)
    if player == nil then
        return nil
    end
    local parts = {}
    for i = 0, 3 do
        local card, pill = 0, 0
        pcall(function()
            card = player:GetCard(i) or 0
        end)
        pcall(function()
            pill = player:GetPill(i) or 0
        end)
        parts[#parts + 1] = tostring(card) .. "." .. tostring(pill)
    end
    return table.concat(parts, ",")
end

local function isCardLike(ids)
    for _, id in ipairs(ids or {}) do
        if CARD_LIKE_IDS[id] == true then
            return true
        end
    end
    return false
end

-- 取“frame 之前至少 COUNTER_LOOKBACK 帧”的最近一份快照
local function counterSnapshotBefore(frame, player, groups)
    local snapshot = nil
    for _, entry in ipairs(counterHistory) do
        if entry.frame <= frame - COUNTER_LOOKBACK then
            if snapshot == nil or entry.frame > snapshot.frame then
                snapshot = entry
            end
        end
    end
    local values = {}
    local current = nil
    for group in pairs(groups) do
        local value = nil
        if snapshot ~= nil then
            value = snapshot.values[group]
        end
        if value == nil then
            if current == nil then
                current = readCounters(player, groups)
            end
            value = current[group]
        end
        if value ~= nil then
            values[group] = value
        end
    end
    return values
end

local function scheduleCounterCheck(player, ids)
    if config.CounterCheck ~= true then
        return
    end
    local groups = counterGroupsForIds(ids)
    if groups == nil then
        return
    end
    local frame = nowFrame()
    local before = counterSnapshotBefore(frame, player, groups)
    local readable = false
    for _ in pairs(before) do
        readable = true
        break
    end
    if not readable then
        return
    end
    pendingChecks[#pendingChecks + 1] = {
        before = before,
        groups = groups,
        frame = frame,
        deadline = frame + COUNTER_GRACE,
    }
end

local function keysOfGroups(groups)
    local list = {}
    for group in pairs(groups) do
        list[#list + 1] = group
    end
    table.sort(list)
    return table.concat(list, ",")
end

local function formatCounterValues(groups, values)
    local parts = {}
    for group in pairs(groups) do
        local value = "?"
        if values ~= nil and values[group] ~= nil then
            value = tostring(values[group])
        end
        parts[#parts + 1] = tostring(group) .. "=" .. value
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function updateCounterChecks(player)
    if #pendingChecks == 0 or player == nil then
        return
    end
    local frame = nowFrame()
    local remaining = {}
    for _, check in ipairs(pendingChecks) do
        local after = readCounters(player, check.groups)
        local changed = false
        local capped = false
        local readable = false
        for group in pairs(check.groups) do
            local before = check.before[group]
            local value = after[group]
            if before ~= nil and value ~= nil then
                readable = true
                if value ~= before then
                    changed = true
                end
                local cap = COUNTER_CAP[group]
                if cap ~= nil and before >= cap then
                    capped = true
                end
            end
        end

        if changed then
            if config.Debug then
                Log.Write("[CainsBag] counter check ok: " .. keysOfGroups(check.groups)
                    .. " (" .. formatCounterValues(check.groups, check.before) .. " -> "
                    .. formatCounterValues(check.groups, after) .. ")")
            end
        elseif (not readable) or capped then
            -- 无法用计数器验证（接口缺失 / 已满值）：不判定
        elseif frame >= check.deadline then
            Log.Write("[CainsBag] counter mismatch: " .. keysOfGroups(check.groups)
                .. " (" .. formatCounterValues(check.groups, check.before) .. " -> "
                .. formatCounterValues(check.groups, after) .. ")"
                .. "（拾取事件没有反映到背包计数器上）")
            BagTracker.MarkUncertain("counter-mismatch")
        else
            remaining[#remaining + 1] = check
        end
    end
    pendingChecks = remaining
end

-- ------------------------------------------------------------
-- 归属证据日志（step4 / M1）
-- 每个掉落物只打一条，格式可 grep：attr seed=.. index=.. ids=.. touch=.. verdict=.. reason=..
-- ------------------------------------------------------------

local function currentCharge(player)
    if player == nil then
        return nil, nil
    end
    local charge, maxCharge = nil, nil
    pcall(function()
        charge = player:GetActiveCharge()
    end)
    pcall(function()
        maxCharge = player:GetActiveMaxCharge()
    end)
    if type(charge) ~= "number" then
        charge = nil
    end
    if type(maxCharge) ~= "number" then
        maxCharge = nil
    end
    return charge, maxCharge
end

-- 自检：如果“判成普通拾取而跳过”之后袋容量（主道具充能）反而涨了，
-- 说明本机版本的归属语义与预期相反（袋其实是靠碰撞吸收的）→ 打一条 WARN 方便定位
local function noteChargeWatch(key, reason)
    if config.ChargeProbe ~= true or lastCharge == nil then
        return
    end
    if reason ~= "player-pickup" and reason ~= "other-player" and reason ~= "not-player"
        and reason ~= "collector-near" and reason ~= "player-pickup-near" then
        return
    end
    chargeWatch = { charge = lastCharge, frame = nowFrame(), reason = reason, key = key }
end

local function updateChargeProbe(player)
    if config.ChargeProbe ~= true then
        return
    end
    local charge, maxCharge = currentCharge(player)
    if charge == nil then
        return
    end
    if chargeWatch ~= nil then
        local grace = config.CounterVetoFrames
        if type(grace) ~= "number" or grace <= 0 then
            grace = VETO_GRACE
        end
        local age = nowFrame() - chargeWatch.frame
        if charge > chargeWatch.charge and age <= grace + 4 then
            Log.Write("[CainsBag] WARN: bag charge rose after skip (reason=" .. tostring(chargeWatch.reason)
                .. ") " .. tostring(chargeWatch.charge) .. " -> " .. tostring(charge)
                .. "/" .. tostring(maxCharge or "?")
                .. " —— 归属判定可能反向，可用 config.Attribution = \"legacy\" 对比")
            chargeWatch = nil
        elseif age > 20 then
            chargeWatch = nil
        end
    end
    lastCharge = charge
    lastChargeMax = maxCharge
end

local function playerDistance(entry)
    if entry == nil or entry.x == nil or entry.y == nil or playerX == nil or playerY == nil then
        return nil
    end
    local dx = entry.x - playerX
    local dy = entry.y - playerY
    return math.sqrt(dx * dx + dy * dy)
end

-- ------------------------------------------------------------
-- 普通拾取 vs 袋吸收（bug4）
-- 事实：袋子只有「举起 / 使用」时才会吸取掉落物（Q = ACTION_PILLCARD，与长按合成同一个键）。
-- 而 MC_PRE_PICKUP_COLLISION 在堕化该隐身上基本拿不到有效记录，于是：
--   · 举起袋子（BagSwipeFrames 窗口内）→ 一律按袋吸收
--   · 没举起袋子 + 与玩家位置重叠（≤ PickupOverlapDistance）→ 走上去的普通拾取（任何类型）
-- 依据实测日志：普通拾取 playerDist ≤ 23，袋吸收 ≥ 30（挥袋半径明显更大）。
-- ------------------------------------------------------------
local function overlapDistance()
    local value = config.PickupOverlapDistance
    if type(value) == "number" and value > 0 then
        return value
    end
    return 26
end

local function bagSwipeFrames()
    local value = config.BagSwipeFrames
    if type(value) == "number" and value > 0 then
        return value
    end
    return 40
end

-- 袋子此刻是否处于“举起/吸取”状态（最近 BagSwipeFrames 帧内按过 Q）
local function bagInUse()
    return tick <= swipeUntil
end

-- 记一次“举起袋子”（由 Update 每帧读取输入）
local function noteBagUse()
    swipeUntil = tick + bagSwipeFrames()
end

-- 读一次“举起袋子”的输入；Update 与每次判定前都同步一次，
-- 避免 MC_POST_PICKUP_UPDATE 早于 POST_UPDATE 造成的 1 帧误差
local function syncBagUse()
    if bagPlayerIndex == nil then
        return
    end
    local held = false
    pcall(function()
        held = Input.IsActionPressed(ButtonAction.ACTION_PILLCARD, bagPlayerIndex) == true
    end)
    if held then
        noteBagUse()
    end
end

-- 计数器快照文本（写进 attr 日志，便于对照“钱到底涨没涨”）
local function counterText(player)
    local values = readCounters(player, COUNTER_ALL_GROUPS)
    local names = { "coin", "key", "bomb", "redHeart" }
    local parts = {}
    for _, group in ipairs(names) do
        local value = values[group]
        parts[#parts + 1] = group .. "=" .. ((value ~= nil) and tostring(value) or "?")
    end
    return table.concat(parts, ",")
end

local function logAttr(key, entry, verdict, reason, touch, age)
    if not (config.DebugAttribution or config.Debug) then
        return
    end
    if key ~= nil then
        if attrLogged[key] then
            return
        end
        attrLogged[key] = true
    end
    local ids = (entry ~= nil and entry.ids ~= nil) and table.concat(entry.ids, ",") or "-"
    local nearest, collectorDist = nearestCollector(entry)
    local dist = playerDistance(entry)
    local charge, maxCharge = lastCharge, lastChargeMax
    local touchAge = "-"
    if touch ~= nil then
        touchAge = tostring(age or (nowFrame() - (touch.frame or 0)))
    end
    local parts = {
        "attr",
        "seed=" .. tostring(entry ~= nil and entry.seed or "-"),
        "index=" .. tostring(entry ~= nil and entry.index or "-"),
        "ids=" .. ids,
        "collecting=" .. tostring(entry ~= nil and entry.collecting == true),
        "touch=" .. touchLabel(touch),
        "touchAge=" .. touchAge,
        "playerDist=" .. (dist ~= nil and tostring(math.floor(dist + 0.5)) or "-"),
        "playerNear=" .. tostring(isNearPlayer(entry)),
        "nearest=" .. (collectorDist ~= nil and tostring(math.floor(math.sqrt(collectorDist) + 0.5)) or "-"),
        "nearestType=" .. collectorLabel(nearest),
        "nearestVar=" .. tostring(nearest ~= nil and nearest.variant or "-"),
        "nearestIdx=" .. tostring(nearest ~= nil and nearest.index or "-"),
        "charge=" .. ((charge ~= nil) and (tostring(charge) .. "/" .. tostring(maxCharge or "?")) or "-"),
        "counters=" .. counterText(bagPlayer),
        "bag=" .. tostring(#slots) .. "/" .. tostring(BAG_SIZE),
        "verdict=" .. tostring(verdict),
        "reason=" .. tostring(reason),
    }
    Log.Write("[CainsBag] " .. table.concat(parts, " "))
end

-- ------------------------------------------------------------
-- 配方史登记（step5）
-- 口径②：只要袋里满 8 格的组合出现过就记下来（不要求真的合成过）。
-- 记录是幂等的：同一组合重复出现只累加计数（撤销误记时按计数回退）。
-- ------------------------------------------------------------

local function bumpRecipeRevision()
    recipeRevision = recipeRevision + 1
end

local function isCraftReason(reason)
    return reason == "craft" or reason == "craft-bag-lost" or reason == "craft-active"
        or reason == "use-item"
end

-- 返回本次登记的组合 key（不足 8 格返回 nil）
local function noteRecipeAppeared(list, reason)
    if list == nil or #list ~= BAG_SIZE then
        return nil
    end
    local key = Recipe.Key(list)
    local uses = recipeUses[key] or 0
    recipeUses[key] = uses + 1
    if uses == 0 then
        seenRecipes[key] = true
        seenRecipeOrder[#seenRecipeOrder + 1] = key
        bumpRecipeRevision()
        if config.Debug then
            Log.Write("[CainsBag] crafted recipe recorded: [" .. key .. "] (total="
                .. tostring(#seenRecipeOrder) .. " reason=" .. tostring(reason) .. ")")
        end
    end
    if isCraftReason(reason) then
        craftedRecipes[key] = true
    end
    return key
end

-- 撤销一次误记（计数器 / 卡牌槽否决证明这次拾取并没有进袋）
local function releaseRecipe(key)
    if key == nil then
        return
    end
    local uses = recipeUses[key] or 0
    if uses == 0 then
        return
    end
    if uses > 1 then
        recipeUses[key] = uses - 1
        return
    end
    recipeUses[key] = nil
    seenRecipes[key] = nil
    craftedRecipes[key] = nil
    for i = #seenRecipeOrder, 1, -1 do
        if seenRecipeOrder[i] == key then
            table.remove(seenRecipeOrder, i)
            break
        end
    end
    bumpRecipeRevision()
    if config.Debug then
        Log.Write("[CainsBag] crafted recipe unrecorded (pickup was not absorbed): [" .. key .. "]")
    end
end

-- ------------------------------------------------------------
-- 计数器否决（step4 / D）：玩家本人“拿到手但没进袋”的兜底证据
-- 钱 / 钥匙 / 炸弹 / 红心变多 ⇒ 这次是普通拾取 ⇒ 撤销刚才乐观写入的素材
-- ------------------------------------------------------------

local function vetoGraceFrames()
    local value = config.CounterVetoFrames
    if type(value) == "number" and value > 0 then
        return value
    end
    return VETO_GRACE
end

-- 撤销一次入袋：按 id 逆序从队尾删掉本次加入的素材，再把被顶掉的按原顺序插回队首
local function revertPush(pending)
    if pending == nil or pending.entry == nil or pending.entry.ids == nil then
        return false
    end
    local removed = 0
    for i = #pending.entry.ids, 1, -1 do
        local id = pending.entry.ids[i]
        for j = #slots, 1, -1 do
            if slots[j] == id then
                table.remove(slots, j)
                removed = removed + 1
                break
            end
        end
    end
    local evicted = pending.evicted or {}
    for i = #evicted, 1, -1 do
        table.insert(slots, 1, evicted[i])
    end
    return removed > 0
end

local function scheduleCounterVeto(key, entry, evicted, player, recipeKey)
    if config.CounterVeto ~= true or key == nil or entry == nil or entry.ids == nil then
        return
    end
    local groups = counterGroupsForIds(entry.ids)
    local checkCards = isCardLike(entry.ids)
    if groups == nil and not checkCards then
        return
    end
    local frame = nowFrame()
    -- 取“事件发生前至少 COUNTER_LOOKBACK 帧”的快照：
    -- 拾取结算可能比可见的 Collect 帧早/晚 1~2 帧，留 4 帧余量才不会漏判
    local before = counterSnapshotBefore(frame, player, groups or {})
    local readable = false
    for _ in pairs(before) do
        readable = true
        break
    end
    if groups ~= nil and not readable then
        return
    end
    pendingVeto[key] = {
        entry = entry,
        evicted = evicted or {},
        groups = groups or {},
        before = before,
        frame = frame,
        checkCards = checkCards,
        cardBefore = cardSignature,
        recipeKey = recipeKey,   -- 这次拾取让袋变满时登记的配方（否决时撤销）
    }
end

local function updateCounterVeto(player)
    if next(pendingVeto) == nil then
        return
    end
    local frame = nowFrame()
    local grace = vetoGraceFrames()
    local expired = {}
    for key, pending in pairs(pendingVeto) do
        local after = readCounters(player, pending.groups)
        local rose = false
        local capped = false
        for group in pairs(pending.groups) do
            local before = pending.before[group]
            local value = after[group]
            if before ~= nil and value ~= nil then
                local cap = COUNTER_CAP[group]
                if cap ~= nil and before >= cap then
                    capped = true
                end
                if value > before then
                    rose = true
                end
            end
        end
        local cardChanged = false
        if pending.checkCards and pending.cardBefore ~= nil and cardSignature ~= nil then
            cardChanged = (cardSignature ~= pending.cardBefore)
        end

        if (rose and not capped) or cardChanged then
            revertPush(pending)
            releaseRecipe(pending.recipeKey)   -- 这次拾取并没有进袋 ⇒ 撤销刚登记的配方
            pushed[key] = nil
            pushedInfo[key] = nil
            skipLog[key] = cardChanged and "card" or "counter"
            noteBagSnapshot()
            local detail = ""
            if cardChanged then
                detail = " 卡牌/药丸槽变化：" .. tostring(pending.cardBefore) .. " -> " .. tostring(cardSignature)
            else
                detail = " 普通拾取：" .. formatCounterValues(pending.groups, pending.before)
                    .. " -> " .. formatCounterValues(pending.groups, after)
            end
            Log.Write("[CainsBag] skip collect seed=" .. tostring(pending.entry.seed or "-")
                .. " index=" .. tostring(pending.entry.index or "-")
                .. " ids=" .. table.concat(pending.entry.ids, ",")
                .. " reason=" .. (skipLog[key]) .. detail)
            Log.Write("[CainsBag] bag reverted after counter veto: " .. BagTracker.GetKey())
            expired[#expired + 1] = key
        elseif frame - pending.frame >= grace or capped then
            if config.Debug then
                Log.Write("[CainsBag] veto passed (没看到普通拾取的迹象 → 认定已入袋) seed="
                    .. tostring(pending.entry.seed or "-")
                    .. " ids=" .. table.concat(pending.entry.ids, ",")
                    .. " now=" .. formatCounterValues(pending.groups, after)
                    .. " before=" .. formatCounterValues(pending.groups, pending.before))
            end
            expired[#expired + 1] = key
        end
    end
    for _, key in ipairs(expired) do
        pendingVeto[key] = nil
    end
end

-- ------------------------------------------------------------
-- 入袋 / 跳过
-- ------------------------------------------------------------

local function pushPickup(entry)
    local evicted = {}
    if entry == nil or entry.ids == nil then
        return evicted
    end
    for _, id in ipairs(entry.ids) do
        if #slots >= BAG_SIZE then
            evicted[#evicted + 1] = table.remove(slots, 1)
        end
        slots[#slots + 1] = id
    end
    -- 袋刚满 8 格 ⇒ 这个组合“出现过” ⇒ 之后不再作为规划目标（口径②）
    local recipeKey = nil
    if #slots == BAG_SIZE then
        recipeKey = noteRecipeAppeared(slots, "collect")
    end
    if confidence == "known" then
        setConfidence("tracking", "collect")
    end
    noteBagSnapshot()
    return evicted, recipeKey
end

local function skipCollect(key, entry, reason, touch, age)
    if pushed[key] or skipLog[key] then
        return
    end
    skipLog[key] = reason
    logAttr(key, entry, "skip", reason, touch, age)
    noteChargeWatch(key, reason)
    if config.Debug then
        local ids = (entry ~= nil and entry.ids ~= nil) and table.concat(entry.ids, ",") or "-"
        Log.Write("[CainsBag] skip collect seed=" .. tostring(entry ~= nil and entry.seed or "-")
            .. " index=" .. tostring(entry ~= nil and entry.index or "-")
            .. " ids=" .. ids .. " reason=" .. tostring(reason))
    end
end

local function confirmCollect(key, entry, reason, touch, age)
    if entry == nil or entry.ids == nil or pushed[key] or skipLog[key] then
        return
    end
    pushed[key] = true
    logAttr(key, entry, "confirm", reason, touch, age)
    if config.Debug then
        Log.Write("[CainsBag] collect seed=" .. tostring(entry.seed or "-")
            .. " index=" .. tostring(entry.index or "-")
            .. " ids=" .. table.concat(entry.ids, ",")
            .. " src=player reason=" .. tostring(reason))
    end
    local evicted, recipeKey = pushPickup(entry)
    pushedInfo[key] = {
        entry = entry,
        evicted = evicted or {},
        recipeKey = recipeKey,
        frame = nowFrame(),
        reason = reason,
    }
    scheduleCounterCheck(bagPlayer, entry.ids)
    scheduleCounterVeto(key, entry, evicted, bagPlayer, recipeKey)
end

-- 持袋玩家是否真的有合成袋（堕化该隐 / 身上有 710）
-- 不确定时按“有”处理，避免因为接口异常漏记
local function bagPlayerHasBag()
    if bagPlayer == nil then
        return true
    end
    local playerType = nil
    pcall(function()
        playerType = bagPlayer:GetPlayerType()
    end)
    if playerType == 23 then
        return true
    end
    local ok, value = pcall(function()
        return bagPlayer:HasCollectible(CollectibleType.COLLECTIBLE_BAG_OF_CRAFTING)
    end)
    if ok and value ~= nil then
        return value == true
    end
    return true
end

-- ------------------------------------------------------------
-- 归属判定（step4 / M2）
-- 返回 verdict("confirm"|"skip"), reason, touch, touchAge
--
-- collision（新默认，与 EID 一致）：
--   · 新鲜碰撞 = 拾取者“走上去碰到” → 普通拾取（钱/钥匙/炸弹/红心/卡槽）→ skip
--   · 没有碰撞的 Collect 动画 = 挥袋 / 吸取进袋 → confirm
--   · 例外：附近有比玩家更近的使魔/乞丐 → skip（某些使魔不触发碰撞回调，防御）
-- legacy（旧行为，仅对比用）：
--   · 持袋玩家新鲜碰撞 → confirm；其它碰撞者 → skip；无碰撞且附近无收集者 → confirm
-- ------------------------------------------------------------

local function attributePickup(entry)
    local touch, age = recentTouch(entry)
    -- 不做“没有袋也往模拟里记”的事：没有合成袋的玩家，拾取一律不进袋
    if not bagPlayerHasBag() then
        return "skip", "no-bag", touch, age
    end
    if config.Attribution == "legacy" then
        if touch ~= nil then
            if touch.bagPlayer then
                return "confirm", "player-touch", touch, age
            end
            return "skip", "not-player", touch, age
        end
        if entry ~= nil and entry.shop then
            return "skip", "shop", nil, nil
        end
        if collectorNear(entry) then
            return "skip", "not-player", nil, nil
        end
        return "confirm", "anim", nil, nil
    end

    -- collision 模式
    if touch ~= nil then
        if touch.bagPlayer then
            return "skip", "player-pickup", touch, age
        elseif touch.player then
            return "skip", "other-player", touch, age
        end
        return "skip", "not-player", touch, age
    end
    if entry ~= nil and entry.shop then
        return "skip", "shop", nil, nil
    end
    if collectorCloserThanPlayer(entry) ~= nil then
        return "skip", "collector-near", nil, nil
    end
    -- 没有碰撞记录时的兜底（bug4）：
    -- 袋子只有“举起（Q）”时才会吸取 ⇒ 没举起 + 位置与玩家重叠 = 走上去的普通拾取。
    -- 与掉落物类型无关，因此魂心/黑心/电池/卡牌…都不再误记（也不再依赖计数器）。
    if not bagInUse() then
        local dist = playerDistance(entry)
        if dist ~= nil and dist <= overlapDistance() then
            return "skip", "player-pickup-near", nil, nil
        end
    end
    return "confirm", "bag-swipe", nil, nil
end

-- 判定并执行（confirmCollect / skipCollect 是唯一出口）
local function resolvePickup(key, entry, source)
    if entry == nil or entry.ids == nil then
        if key ~= nil then
            skipLog[key] = "ignored"
        end
        return
    end
    syncBagUse()   -- 判定前再读一次输入（回调顺序可能早于 POST_UPDATE）
    local verdict, reason, touch, age = attributePickup(entry)
    if verdict == "confirm" then
        confirmCollect(key, entry, reason or source, touch, age)
    else
        skipCollect(key, entry, reason or source, touch, age)
    end
end

-- ------------------------------------------------------------
-- 公开接口：袋内容
-- ------------------------------------------------------------

function BagTracker.GetSlots()
    local copy = {}
    for i = 1, #slots do
        copy[i] = slots[i]
    end
    return copy
end

function BagTracker.Count()
    return #slots
end

function BagTracker.IsFull()
    return #slots >= BAG_SIZE
end

-- 返回排序后的多重集
function BagTracker.GetMultiset()
    local copy = BagTracker.GetSlots()
    table.sort(copy)
    return copy
end

function BagTracker.GetKey()
    return table.concat(slots, ",")
end

function BagTracker.PushIds(ids)
    if ids == nil then
        return
    end
    pushPickup({ ids = ids })
end

-- 轮转：第 1 格移到队尾
function BagTracker.Rotate()
    if #slots == 0 then
        return
    end
    local first = table.remove(slots, 1)
    slots[#slots + 1] = first
    noteBagSnapshot()   -- 顺序变了，rewind 恢复也要跟着变
end

-- 合成清空 / 手动校准
-- 口径②：清空前的 8 格组合先登记进配方史。同一个组合在袋满时就已经登记过，
-- 这里额外把它标成「真的合成过」——只影响 UI 文案（已合成 / 已出现），不影响拉黑口径。
-- 不足 8 格却带着合成 reason 清空 = 模拟不同步 ⇒ 不记录，只打一条排查日志。
function BagTracker.Clear(reason)
    local label = reason or ""
    if #slots == BAG_SIZE then
        noteRecipeAppeared(slots, label)
    elseif isCraftReason(label) then
        Log.Write("[CainsBag] crafted recipe skipped: bag=" .. tostring(#slots) .. "/8 reason=" .. label)
    end
    slots = {}
    pendingChecks = {}
    pendingVeto = {}
    counterHistory = {}
    pushedInfo = {}
    lastClearReason = label
    setConfidence("known", "clear:" .. lastClearReason)
    noteBagSnapshot()
    if config.Debug then
        Log.Write("[CainsBag] bag cleared: " .. lastClearReason)
    end
end

-- reason 只用于日志（new-run / continued / test ...）
function BagTracker.Reset(reason)
    -- 配方史只在本次运行内有效：新开一局 / 续档 / 复活都清空
    local hadRecipes = (#seenRecipeOrder > 0)
    for key in pairs(seenRecipes) do
        seenRecipes[key] = nil
    end
    for key in pairs(recipeUses) do
        recipeUses[key] = nil
    end
    for key in pairs(craftedRecipes) do
        craftedRecipes[key] = nil
    end
    for i = #seenRecipeOrder, 1, -1 do
        seenRecipeOrder[i] = nil
    end
    if hadRecipes then
        bumpRecipeRevision()
        Log.Write("[CainsBag] crafted history reset: " .. tostring(reason or "reset"))
    end
    slots = {}
    tick = 0
    confidence = "unknown"
    confidenceReason = ""
    tracking = false
    bagPlayerIndex = nil
    known = {}
    touched = {}
    pushed = {}
    skipLog = {}
    attrLogged = {}
    pendingVeto = {}
    pendingChecks = {}
    counterHistory = {}
    lastCharge = nil
    lastChargeMax = nil
    chargeWatch = nil
    cardSignature = nil
    cardSignatureTick = -100
    dropHeldByController = {}
    collectors = {}
    directReadAvailable = nil
    lastCollectibleCount = nil
    craftHoldFrames = 0
    activeSnapshot = nil
    lastClearReason = ""
    playerX = nil
    playerY = nil
    bagPlayer = nil
    ignoreTicks = 0
    swipeUntil = -1000
    pushedInfo = {}
    collideLogged = {}
    vanishedLogged = {}
    roomEntryLogged = {}
    -- 新的一局：帧号从头开始，旧的历史快照不能再用来恢复
    bagHistory = {}
    gameFrame = 0
    noteBagSnapshot()
end

-- 手动校准（F6）：清空模拟并标记已对齐
function BagTracker.Calibrate()
    slots = {}
    pendingChecks = {}
    pendingVeto = {}
    craftHoldFrames = 0
    setConfidence("known", "manual-empty")
    noteBagSnapshot()
    Log.Write("[CainsBag] bag calibrated (empty)")
end

-- 中途启用 / 续档 / 复活：真实袋内容未知
function BagTracker.MarkUnknown(reason)
    setConfidence("unknown", reason)
    if config.Debug then
        Log.Write("[CainsBag] bag unknown: " .. tostring(reason))
    end
end

-- 新局 / 续档入口（main.lua 的 MC_POST_GAME_STARTED 调用）
function BagTracker.OnGameStarted(isContinued)
    BagTracker.Reset(isContinued and "continued" or "new-run")
    if isContinued then
        BagTracker.MarkUnknown("continued")
    else
        BagTracker.Calibrate()
    end
end

-- ------------------------------------------------------------
-- 回退（控制台 rewind / 时间回溯）恢复：main.lua 检测到同一局帧号倒退时调用
-- 把袋恢复到目标帧的状态，并清掉逐帧缓存（目标帧之后被吸收的掉落物已经回到地上）
-- 说明：配方史（已出现 / 已合成）不回退——它只影响推荐，不会因为回退而“多推荐”错配方
-- 返回 true = 成功恢复；false = 没有可用快照（只能按未知处理）
-- ------------------------------------------------------------
function BagTracker.OnRewind(frame)
    local target = frame
    if type(target) ~= "number" then
        target = readGameFrame()
    end
    if type(target) ~= "number" then
        target = gameFrame
    end
    gameFrame = target
    -- 目标帧之后的快照属于「被回退掉的时间线」，已失效（玩家可能换了操作）→ 裁掉
    for i = #bagHistory, 1, -1 do
        if bagHistory[i].frame > target then
            table.remove(bagHistory, i)
        end
    end
    local snapshot = findBagSnapshot(target)

    known = {}
    touched = {}
    pushed = {}
    skipLog = {}
    attrLogged = {}
    pushedInfo = {}
    collideLogged = {}
    vanishedLogged = {}
    roomEntryLogged = {}
    pendingVeto = {}
    pendingChecks = {}
    counterHistory = {}
    chargeWatch = nil
    lastCollectibleCount = nil
    activeSnapshot = nil
    craftHoldFrames = 0
    ignoreTicks = 2

    if snapshot == nil then
        slots = {}
        setConfidence("unknown", "rewind-no-history")
        Log.Write("[CainsBag] rewind: no bag history at frame=" .. tostring(target)
            .. ", bag becomes unknown")
        return false
    end

    slots = copyList(snapshot.slots)
    rewindCount = rewindCount + 1
    setConfidence("known", "rewind")
    noteBagSnapshot()
    Log.Write("[CainsBag] rewind: bag restored at frame=" .. tostring(target)
        .. " (snapshot frame=" .. tostring(snapshot.frame) .. ") -> " .. BagTracker.GetDebugText())
    return true
end

-- 已恢复的回退次数（日志 / 离线测试用）
function BagTracker.GetRewindCount()
    return rewindCount
end

-- 当前整局帧号（测试 / 日志用）
function BagTracker.GetGameFrame()
    return readGameFrame() or gameFrame
end

function BagTracker.IsTracking()
    return tracking
end

-- 是否“袋内容完全未知”（中途启用模组、续档且未校正）
function BagTracker.IsUnknown()
    return confidence == "unknown"
end

function BagTracker.IsUncertain()
    return confidence == "uncertain"
end

function BagTracker.GetConfidence()
    return confidence
end

function BagTracker.GetConfidenceReason()
    return confidenceReason
end

-- 只读状态快照（供 UI / 日志）
function BagTracker.GetState()
    return {
        confidence = confidence,
        reason = confidenceReason,
        count = #slots,
        full = (#slots >= BAG_SIZE),
        tracking = tracking,
        playerIndex = bagPlayerIndex,
    }
end

function BagTracker.GetLastClearReason()
    return lastClearReason
end

-- ------------------------------------------------------------
-- 公开接口：配方史（step5）
-- 出现的 8 格组合 → 之后不再编号、不计入 distinct、不作为链条目标
-- ------------------------------------------------------------

-- key -> true（袋里出现过即拉黑；只读，不要就地修改）
function BagTracker.GetSeenRecipes()
    return seenRecipes
end

-- key -> true：其中「真的合成过」的那些（只用于 UI 文案区分，只读）
function BagTracker.GetCraftedRecipes()
    return craftedRecipes
end

function BagTracker.GetCraftedCount()
    return #seenRecipeOrder
end

-- 变更版本号：任何登记 / 撤销 / 清空都会 +1，供 main 的链缓存 key 感知变化
function BagTracker.GetCraftedRevision()
    return recipeRevision
end

-- 当前袋的配方 key（不足 8 格返回 nil，和链搜索口径一致）
function BagTracker.GetRecipeKey()
    if #slots ~= BAG_SIZE then
        return nil
    end
    return Recipe.Key(slots)
end

function BagTracker.IsCraftedRecipe(key)
    return key ~= nil and craftedRecipes[key] == true
end

-- 标记“模拟可能不可信”（例如袋未满却被使用、计数器对不上）
function BagTracker.MarkUncertain(reason)
    local label = reason or "unknown"
    local already = (confidence == "uncertain" and confidenceReason == label)
    setConfidence("uncertain", label)
    if not already then
        Log.Write("[CainsBag] uncertain: " .. tostring(label))
    end
end

-- ------------------------------------------------------------
-- 公开接口：人工校正（M2）
-- ------------------------------------------------------------

local function validateId(id)
    return type(id) == "number" and id >= 0 and id <= Ingredients.MAX_ID and id % 1 == 0
end

-- 写入完整袋内容；元素 ∈ 0..29，0 视为空位（会被忽略），末尾 nil 视为未满
function BagTracker.SetSlots(list)
    if type(list) ~= "table" then
        if config.Debug then
            Log.Write("[CainsBag] bag edit rejected: not a table")
        end
        return false
    end
    local clean = {}
    for position, id in ipairs(list) do
        if not validateId(id) then
            if config.Debug then
                Log.Write("[CainsBag] bag edit rejected: invalid id #" .. tostring(position)
                    .. " = " .. tostring(id))
            end
            return false
        end
        if id ~= 0 then
            if #clean >= BAG_SIZE then
                if config.Debug then
                    Log.Write("[CainsBag] bag edit rejected: more than " .. tostring(BAG_SIZE) .. " slots")
                end
                return false
            end
            clean[#clean + 1] = id
        end
    end
    slots = clean
    pendingVeto = {}
    -- F9 校正出满 8 格 ⇒ 这个组合也算“出现过”（口径②）
    if #slots == BAG_SIZE then
        noteRecipeAppeared(slots, "edit")
    end
    setConfidence("known", "edit")
    noteBagSnapshot()
    if config.Debug then
        Log.Write("[CainsBag] bag edited: " .. BagTracker.GetDebugText())
    end
    return true
end

-- 单格设置：id = nil / 0 表示清空该格；不允许留空洞
function BagTracker.SetSlot(index, id)
    if type(index) ~= "number" or index < 1 or index > BAG_SIZE or index % 1 ~= 0 then
        return false
    end
    if id ~= nil then
        if not validateId(id) then
            return false
        end
        if id == 0 then
            id = nil
        end
    end
    if id == nil then
        if index <= #slots then
            table.remove(slots, index)
        end
    else
        if index > #slots + 1 then
            return false
        end
        slots[index] = id
    end
    pendingVeto = {}
    if #slots == BAG_SIZE then
        noteRecipeAppeared(slots, "edit")
    end
    setConfidence("known", "edit")
    noteBagSnapshot()
    if config.Debug then
        Log.Write("[CainsBag] bag edited: " .. BagTracker.GetDebugText())
    end
    return true
end

-- 由 scripts.bag_editor 注册（避免模块之间循环 require）
function BagTracker.RegisterEditor(editor)
    editorRef = editor
end

-- 编辑器只读快照：{ active = bool, cursor = 1..8, slots = {1..8} }
function BagTracker.GetEditState()
    if editorRef ~= nil and editorRef.GetState ~= nil then
        return editorRef.GetState()
    end
    return { active = false, cursor = 1, slots = {} }
end

-- ------------------------------------------------------------
-- 入袋检测（M1）
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- 碰撞证据迟到（bug3）
-- MC_POST_PICKUP_UPDATE（抓 Collect 首帧）通常早于碰撞结算 ⇒ “走上去捡”的掉落物
-- 会先被乐观记入袋，MC_PRE_PICKUP_COLLISION 的碰撞记录随后才到。这里按「先记后撤」
-- 撤销那次入袋（与计数器否决同口径），不再依赖钱/钥匙计数器兜底。
-- ------------------------------------------------------------
local function lateTouchFrames()
    local value = config.LateTouchFrames
    if type(value) == "number" and value > 0 then
        return value
    end
    return 8
end

local function revertLateTouch(key)
    local info = pushedInfo[key]
    if info == nil or info.reason ~= "bag-swipe" then
        return false
    end
    if info.entry == nil or info.entry.ids == nil then
        return false
    end
    if nowFrame() - (info.frame or 0) > lateTouchFrames() + touchFreshFrames() then
        return false
    end
    if not revertPush(info) then
        return false
    end
    pushed[key] = nil
    pushedInfo[key] = nil
    pendingVeto[key] = nil
    releaseRecipe(info.recipeKey)
    skipLog[key] = "player-pickup-late"
    noteBagSnapshot()
    Log.Write("[CainsBag] late touch: bag entry reverted seed=" .. tostring(info.entry.seed or "-")
        .. " index=" .. tostring(info.entry.index or "-")
        .. " ids=" .. table.concat(info.entry.ids, ",") .. " reason=player-pickup-late")
    return true
end

-- 由 MC_PRE_PICKUP_COLLISION 调用：记录“谁碰过这个掉落物”
-- target 可以是 EntityPickup（新）或 Index 数字（兼容旧调用）
function BagTracker.MarkTouched(target, collider)
    local key = nil
    if type(target) == "number" then
        key = keyFrom(nil, target)
    elseif type(target) == "table" then
        key = keyFrom(entityField(target, "InitSeed"), entityField(target, "Index"))
    end
    if key == nil then
        return
    end

    local isPlayer = false
    local isBagPlayer = false
    local colliderType = nil
    local colliderIndex = nil
    if collider ~= nil then
        colliderType = entityField(collider, "Type")
        local ok, player = pcall(function()
            return collider:ToPlayer()
        end)
        if ok and player ~= nil then
            isPlayer = true
            pcall(function()
                colliderIndex = player.ControllerIndex
            end)
            if bagPlayerIndex == nil then
                bagPlayerIndex = colliderIndex
            end
            isBagPlayer = (bagPlayerIndex == colliderIndex)
        end
    else
        -- 旧接口 / 未知碰撞者：按持袋玩家处理（保持原有行为）
        isPlayer = true
        isBagPlayer = true
    end

    touched[key] = {
        player = isPlayer,
        bagPlayer = isBagPlayer,
        frame = nowFrame(),
        colliderType = colliderType,
        colliderIndex = colliderIndex,
    }
    -- 碰撞证据日志：用于核对“碰撞回调到底有没有触发 / 比 Collect 晚几帧”
    if config.Debug and not collideLogged[key] then
        collideLogged[key] = true
        local seedText, indexText = "-", "-"
        if type(target) == "table" then
            seedText = tostring(target.seed or entityField(target, "InitSeed") or "-")
            indexText = tostring(target.index or entityField(target, "Index") or "-")
        else
            indexText = tostring(target)
        end
        Log.Write("[CainsBag] collide seed=" .. seedText .. " index=" .. indexText
            .. " colliderType=" .. tostring(colliderType or "-")
            .. " colliderIndex=" .. tostring(colliderIndex or "-")
            .. " bagPlayer=" .. tostring(isBagPlayer))
    end
    -- 碰撞记录晚于 Collect 首帧时，撤销刚才的乐观入袋（先记后撤）
    revertLateTouch(key)
end

-- 语义更明确的新名字（main.lua 使用）
function BagTracker.NoteCollision(pickup, collider)
    BagTracker.MarkTouched(pickup, collider)
end

-- 换房保护帧内被吸收的掉落物：当前既不判定、也无法补判（known 已清空），
-- 先打一条只读诊断，便于量化“偶发漏记”还剩多少（启用延迟判定前要有数据）
local function logRoomEntryPending(key, entry, source)
    if not config.Debug or key == nil or roomEntryLogged[key] then
        return
    end
    roomEntryLogged[key] = true
    local dist = playerDistance(entry)
    Log.Write("[CainsBag] room-entry pending: seed=" .. tostring(entry.seed or "-")
        .. " index=" .. tostring(entry.index or "-")
        .. " ids=" .. ((entry.ids ~= nil) and table.concat(entry.ids, ",") or "-")
        .. " dist=" .. (dist ~= nil and tostring(math.floor(dist + 0.5)) or "-")
        .. " swipe=" .. (bagInUse() and "1" or "0")
        .. " src=" .. tostring(source))
end

-- 由 MC_POST_PICKUP_UPDATE 调用（每个掉落物每帧）：逐帧抓 Collect 首帧
function BagTracker.OnPickupUpdate(pickup)
    if pickup == nil or directReadAvailable == true then
        return
    end
    -- 先看动画（idle 掉落物占多数，避免每帧对每个掉落物取两次字段）
    local okAnim, animation = pcall(getEntityAnimation, pickup)
    if not okAnim or animation ~= "Collect" then
        return
    end
    local key = pickupKey(pickup)
    if key == nil then
        return
    end
    if pushed[key] or skipLog[key] then
        return
    end
    if ignoreTicks > 0 then
        if config.Debug then
            logRoomEntryPending(key, entryFromPickup(pickup), "anim")
        end
        return
    end
    resolvePickup(key, entryFromPickup(pickup), "anim")
end

-- 每 2 帧调用一次（传入 Scan.ScanRoom() 的 entries）
function BagTracker.OnRoomScan(entries)
    if directReadAvailable == true then
        known = {}
        return
    end
    local current = {}
    local frame = nowFrame()
    local locked = (ignoreTicks > 0)

    for _, entry in ipairs(entries or {}) do
        local key = entryKey(entry)
        if key ~= nil then
            current[key] = entry
            if not pushed[key] and not skipLog[key] and entry.collecting then
                if locked then
                    logRoomEntryPending(key, entry, "scan")
                else
                    resolvePickup(key, entry, "scan")
                end
            end
        end
    end

    -- 上一次还在、这次消失的掉落物：只有“消失前正在 Collect”才可能是入袋
    for key, prev in pairs(known) do
        if current[key] == nil and not locked and not pushed[key] and not skipLog[key] then
            if prev.collecting then
                resolvePickup(key, prev, "scan")
            elseif config.Debug and not vanishedLogged[key] then
                -- 两帧扫描之间消失、且从未见过 Collect：当前不判定，只记录诊断
                vanishedLogged[key] = true
                local dist = playerDistance(prev)
                local nearest, collectorDist = nearestCollector(prev)
                Log.Write("[CainsBag] scan vanished: seed=" .. tostring(prev.seed or "-")
                    .. " index=" .. tostring(prev.index or "-")
                    .. " ids=" .. ((prev.ids ~= nil) and table.concat(prev.ids, ",") or "-")
                    .. " dist=" .. (dist ~= nil and tostring(math.floor(dist + 0.5)) or "-")
                    .. " swipe=" .. (bagInUse() and "1" or "0")
                    .. " nearest=" .. (collectorDist ~= nil
                        and tostring(math.floor(math.sqrt(collectorDist) + 0.5)) or "-")
                    .. " nearestType=" .. collectorLabel(nearest))
            end
        end
    end

    -- 清理过期标记
    for key, record in pairs(touched) do
        if frame - record.frame > TOUCH_TTL then
            touched[key] = nil
        end
    end

    known = current
end

function BagTracker.OnNewRoom()
    known = {}
    touched = {}
    pushed = {}
    skipLog = {}
    attrLogged = {}
    pendingVeto = {}
    pendingChecks = {}
    counterHistory = {}
    chargeWatch = nil
    collectors = {}
    directReadAvailable = nil
    pushedInfo = {}
    collideLogged = {}
    vanishedLogged = {}
    roomEntryLogged = {}
    ignoreTicks = 2   -- 换房后前 2 帧不判定（防止跨房残留）
    -- 注意：不清空 swipeUntil（玩家可能正举着袋子走过门，进房瞬间继续吸取）
end

-- 合成检测：合成成功后自动清空袋模拟（省掉手按 F6）
-- 依据（都不依赖动画名，稳）：
--   · 堕化该隐拿到收藏品的途径基本只有“合成” ⇒ 道具数增加 = 合成完成
--   · 合成出的是主动道具时会顶掉袋子本身 ⇒ HasCollectible(710) 变 false
--   · 已有另一个主动（书包等两个主动槽）时，新主动会顶掉那个槽 ⇒ 道具数不变、袋子还在，
--     只能靠「主动槽 itemID 变化」识别（bug2）
-- 另附一条「长按 Q」的调试打点，方便下次核对动画名

-- 读主动道具槽（0 = 主槽，1 = 副槽）；取不到返回 nil
local function readActiveItem(player, slot)
    local id = nil
    local ok = pcall(function()
        id = player:GetActiveItem(slot)
    end)
    if not ok or type(id) ~= "number" then
        return nil
    end
    return id
end

local function updateCraftWatch(player, playerType)
    if config.CraftFallbackHold ~= true then
        return
    end

    local count, hasBag = nil, nil
    pcall(function()
        count = player:GetCollectibleCount()
    end)
    pcall(function()
        hasBag = player:HasCollectible(CollectibleType.COLLECTIBLE_BAG_OF_CRAFTING)
    end)

    if type(count) == "number" then
        if lastCollectibleCount ~= nil and count > lastCollectibleCount then
            Log.Write("[CainsBag] craft detected: collectibles " .. tostring(lastCollectibleCount)
                .. " -> " .. tostring(count) .. ", bag was [" .. BagTracker.GetKey() .. "]")
            lastCollectibleCount = count
            craftHoldFrames = 0
            -- 已经因为 MC_PRE_USE_ITEM 清过一次时不再重复清（只保留日志）
            if BagTracker.Count() > 0 or confidence ~= "known" then
                BagTracker.Clear("craft")
            end
            return
        end
        lastCollectibleCount = count
    end

    if playerType == 23 and hasBag == false and (BagTracker.Count() > 0 or confidence ~= "known") then
        Log.Write("[CainsBag] craft detected: bag replaced by a crafted active item")
        craftHoldFrames = 0
        BagTracker.Clear("craft-bag-lost")
        return
    end

    -- 主动道具槽变化：合成出主动道具时，若玩家已有另一个主动（书包等双主动槽），
    -- 新道具会顶掉那个槽 ⇒ 道具总数不变、袋子也还在，只能靠这里识别（bug2）
    local slotA = readActiveItem(player, 0)
    local slotB = readActiveItem(player, 1)
    local playerIndex = player.ControllerIndex
    local slotChanged = nil
    if activeSnapshot ~= nil and activeSnapshot.player == playerIndex
        and slotA ~= nil and slotB ~= nil
        and activeSnapshot.a ~= nil and activeSnapshot.b ~= nil
        and (slotA ~= activeSnapshot.a or slotB ~= activeSnapshot.b) then
        slotChanged = "active slots " .. tostring(activeSnapshot.a) .. "/" .. tostring(activeSnapshot.b)
            .. " -> " .. tostring(slotA) .. "/" .. tostring(slotB)
    end
    if slotA ~= nil and slotB ~= nil then
        activeSnapshot = { player = playerIndex, a = slotA, b = slotB }
    end
    if slotChanged ~= nil and playerType == 23 and (BagTracker.Count() > 0 or confidence ~= "known") then
        Log.Write("[CainsBag] craft detected: " .. slotChanged .. ", bag was [" .. BagTracker.GetKey() .. "]")
        craftHoldFrames = 0
        BagTracker.Clear("craft-active")
        return
    end

    if playerType == 23 and config.Debug then
        local holding = false
        pcall(function()
            holding = Input.IsActionPressed(ButtonAction.ACTION_PILLCARD, player.ControllerIndex) == true
        end)
        if holding then
            craftHoldFrames = craftHoldFrames + 1
            -- 只打一条：长按到 20 帧时把动画名与袋容量记下来，便于下次核对
            if craftHoldFrames == 20 then
                local animation = "?"
                pcall(function()
                    animation = player:GetSprite():GetAnimation()
                end)
                Log.Write("[CainsBag] long hold: anim=" .. tostring(animation)
                    .. " bag=" .. BagTracker.Count() .. "/8")
            end
            return
        end
        craftHoldFrames = 0
    end
end

-- 每帧调用：更新角色状态、轮转、合成兜底、计数器二次确认
function BagTracker.Update(player)
    tick = tick + 1
    local frame = readGameFrame()
    if frame ~= nil then
        gameFrame = frame
    else
        gameFrame = gameFrame + 1
    end
    if player == nil then
        return
    end
    if ignoreTicks > 0 then
        ignoreTicks = ignoreTicks - 1
    end
    bagPlayerIndex = player.ControllerIndex
    bagPlayer = player
    pcall(function()
        playerX = player.Position.X
        playerY = player.Position.Y
    end)
    -- 举起合成袋（Q = ACTION_PILLCARD，与长按合成同一个键）→ 打开“袋吸收”窗口（bug4）
    syncBagUse()
    local playerType = -1
    pcall(function()
        playerType = player:GetPlayerType()
    end)
    tracking = (playerType == 23)

    -- REPENTOGON：逐帧直接读取真实袋内容（准确率 100%，不再依赖任何猜测）
    if detectDirectRead(player) then
        local list = readDirectBag(player)
        if list ~= nil then
            local newKey = table.concat(list, ",")
            if newKey ~= table.concat(slots, ",") then
                slots = list
                craftHoldFrames = 0
                -- 直读到的真值正好满 8 格 ⇒ 这个组合“出现过”（口径②）
                if #slots == BAG_SIZE then
                    noteRecipeAppeared(slots, "direct")
                end
                noteBagSnapshot()
                if config.Debug then
                    Log.Write("[CainsBag] bag synced (direct): " .. BagTracker.GetDebugText())
                end
            end
            setConfidence("known", "direct-read")
            return
        end
        -- 返回值形状不认识：停用直读，退回事件模拟（避免一直读到空袋）
        directReadAvailable = false
        if config.Debug then
            Log.Write("[CainsBag] direct read returned unexpected shape, fallback to event simulation")
        end
    end

    -- 卡牌 / 药丸槽签名（每 10 帧刷新一次，够用且便宜）：用于识别“卡牌被塞进背包，没进袋”
    if tick - cardSignatureTick >= 10 then
        cardSignatureTick = tick
        cardSignature = readCardSignature(player)
    end

    -- 袋容量探针（只读，用于自检归属语义是否反了）
    updateChargeProbe(player)

    -- 计数器快照 / 否决：用于识别“玩家本人拿到手但没进袋”的普通拾取
    if config.CounterCheck == true or config.CounterVeto == true then
        recordCounterHistory(player)
    end
    if config.CounterVeto == true then
        updateCounterVeto(player)
    end
    if config.CounterCheck == true then
        updateCounterChecks(player)
    end

    -- 丢弃键也自己求边沿：Repentance+ 的 IsActionTriggered 可能连续两帧为真，
    -- 直接用它会让一次按键轮转两格，整条链的袋顺序都会错位
    local controllerIndex = player.ControllerIndex
    local dropHeld = false
    local okDrop, dropValue = pcall(function()
        return Input.IsActionPressed(ButtonAction.ACTION_DROP, controllerIndex)
    end)
    if okDrop then
        dropHeld = (dropValue == true)
    end
    local dropWasHeld = dropHeldByController[controllerIndex] == true
    dropHeldByController[controllerIndex] = dropHeld

    if not tracking then
        return
    end
    if dropHeld and not dropWasHeld then
        if BagTracker.Count() > 0 then
            BagTracker.Rotate()
            if config.Debug then
                Log.Write("[CainsBag] bag rotated: " .. BagTracker.GetKey())
            end
        else
            if config.Debug then
                Log.Write("[CainsBag] drop pressed but bag is empty")
            end
        end
    end
    updateCraftWatch(player, playerType)
end

-- 日志用文本
function BagTracker.GetDebugText()
    local parts = {}
    for _, id in ipairs(slots) do
        parts[#parts + 1] = tostring(id)
    end
    return "[" .. table.concat(parts, " ") .. "]"
end

return BagTracker


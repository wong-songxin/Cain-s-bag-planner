-- ============================================================
-- HUD 面板：在 MC_POST_RENDER 里只做绘制，不做逻辑计算
-- ============================================================

local config = require("scripts.config")
local Ingredients = require("scripts.data.ingredients")
local Log = require("scripts.log")

local UI = {}

local font = nil
local lang = "zh"
local drawApi = "none"        -- utf8 | utf8-5 | scaledUtf8 | draw | draw-5 | scaled | renderScaled | renderText | none
local widthApi = "none"       -- utf8 | plain | none
local fontSource = "none"
local shadowEnabled = false
local rectChecked = false
local rectAvailable = false
local rectFilledArg = true
local renderLogged = false

-- 候选字体：游戏内置字体优先，最后尝试本机 ModConfigMenu-CN 自带的中文字体
-- （含中文字形的会被优先选中；加载失败 / 字形为空会自动跳过）
local FONT_CANDIDATES = {
    "font/teammeatfont10.fnt",
    "font/teammeatfont12.fnt",
    "font/teammeatfont16bold.fnt",
    "font/pftempestasevencondensed.fnt",
}

-- 跨 mod 借用中文字体：相对路径（1.7/1.8 可用）+ 绝对路径（1.9 实测相对路径失败）
local MCM_CN_FOLDER = "mod_config_menu_cn_2494192799"
local MCM_CN_FONT_FILES = {
    "resources/mcm_cn_font/teammeatfont12.fnt",
    "resources/mcm_cn_font/teammeatfont10.fnt",
}

-- 用 require 的报错信息推断 mods 绝对路径（EID 同款技巧）：
-- 拼出 <mods>/mod_config_menu_cn_.../resources/... 这样的绝对路径，1.9 下才加载得动
local function discoverModsDir()
    local ok, err = pcall(require, "scripts.cb_path_probe")
    if ok or type(err) ~= "string" then
        return nil
    end
    -- 报错里会列出多条候选路径，取第一条“位于 mods 目录下”的
    local candidate = nil
    for path in err:gmatch("no file '([^']+)'") do
        local normalized = path:gsub("\\", "/")
        if normalized:lower():find("/mods/", 1, true) ~= nil then
            candidate = normalized
            break
        end
    end
    if candidate == nil then
        return nil
    end
    -- <mods>/<mymod>/scripts/cb_path_probe.lua → 文件名 → <mymod>/ → <mods>/
    local dir = candidate:match("^(.*/)[^/]*$")
    if dir == nil then
        return nil
    end
    local modRoot = dir:match("^(.*/)[^/]*/$")
    if modRoot == nil then
        return nil
    end
    return modRoot:match("^(.*/)[^/]*/$")
end

local MODS_DIR = discoverModsDir()

local COLORS = {
    white = { 1.00, 1.00, 1.00, 1.00 },
    gray = { 0.68, 0.68, 0.72, 1.00 },
    dim = { 0.45, 0.45, 0.50, 1.00 },
    green = { 0.55, 1.00, 0.60, 1.00 },
    yellow = { 1.00, 0.90, 0.40, 1.00 },
    orange = { 1.00, 0.65, 0.30, 1.00 },
    red = { 1.00, 0.45, 0.45, 1.00 },
    cyan = { 0.55, 0.90, 1.00, 1.00 },
    shadow = { 0.00, 0.00, 0.00, 0.85 },
}

local TEXT = {
    zh = {
        title = "合成链",
        distinct = "不同配方",
        windows = "窗口",
        available = "可用素材",
        floor = "本层",
        bag = "袋内",
        emptyBag = "空",
        recipe = "配方#%d",
        sameAs = "（同 #%d）",
        crafted = "（已出现）",
        craftedConfirmed = "（已合成）",
        option = "放",
        evictOpen = "（顶掉",
        evictJoin = "、",
        evictClose = "）",
        arrow = "→",
        noWindow = "（袋未满，不计配方）",
        searching = "搜索中 %d%%",
        notEnough = "素材不足，无法形成配方",
        unknownBag = "袋内容未知：请按 F9 校正（或先合成一次）",
        uncertainBag = "袋内容可能不同步：请按 F9 校正",
        notCain = "非该隐：顶掉需手动丢弃顺序",
        singleType = "可看配方 %d / 窗口 %d：素材多样性不足",
        footer = "F5 显示模式  F6 校准  F7 重算  F8 语言  F9 校正袋  方向键 滚动",
        editorTitle = "校正袋内容 [%d/8]",
        editorHelp = "←/→ 选格  ↑/↓ 换素材  Enter 确认  F9 退出",
        editorHint = "（#1 = 最旧 = 下一个被顶掉的格子；空位保存时会自动压缩）",
        editorEmpty = "--",
        editorFooter = "校正模式：Enter 确认  F9 退出  F5 面板模式（修改不丢）",
        markKnown = "✓",
        markUncertain = "?",
        directBag = "直读",
        inBag = "(背包)",
        fromBag = "",
        ready = "就绪",
        current = "当前",
    },
    en = {
        title = "Craft Chain",
        distinct = "recipes",
        windows = "windows",
        available = "materials",
        floor = "floor",
        bag = "Bag",
        emptyBag = "empty",
        recipe = "#%d",
        sameAs = " (=#%d)",
        crafted = " (seen)",
        craftedConfirmed = " (crafted)",
        option = "take",
        evictOpen = " -",
        evictJoin = "/",
        evictClose = "",
        arrow = "->",
        noWindow = "(bag not full)",
        searching = "searching %d%%",
        notEnough = "Not enough materials for a recipe",
        unknownBag = "Bag contents unknown: press F9 to set them",
        uncertainBag = "Bag contents may be out of sync: press F9",
        notCain = "Not T.Cain: evict order must be done manually",
        singleType = "Only %d recipe / %d windows: low variety",
        footer = "F5 panel mode  F6 calibrate  F7 recalc  F8 lang  F9 edit bag  arrows scroll",
        editorTitle = "Edit bag [%d/8]",
        editorHelp = "left/right slot  up/down material  Enter save  F9 exit",
        editorHint = "(#1 = oldest = next evicted; gaps are compacted on save)",
        editorEmpty = "--",
        editorFooter = "Edit mode: Enter save  F9 exit  F5 panel mode (edits kept)",
        markKnown = "OK",
        markUncertain = "?",
        directBag = "Direct",
        inBag = "(bag)",
        fromBag = "",
        ready = "ready",
        current = "now",
    },
}

local function T(key)
    local table_ = TEXT[lang] or TEXT.zh
    return table_[key] or TEXT.zh[key] or key
end

-- ------------------------------------------------------------
-- 文本度量：全部走“逐字符宽度”，保证排版、裁剪、绘制的度量口径完全一致
-- （1.9 的 GetStringWidthUTF8 单位可能随版本变化，逐字符测量 + 估算兜底最稳）
-- ------------------------------------------------------------

local FALLBACK_FONT_HEIGHT = 14
local fontBaseHeight = nil
local charWidthCache = {}

-- 单字符宽度测量（scale = 1，不走缓存）：量不到返回 0
local function measureChar(ch)
    if font == nil then
        return 0
    end
    if widthApi == "utf8" and font.GetStringWidthUTF8 ~= nil then
        local ok, w = pcall(function()
            return font:GetStringWidthUTF8(ch)
        end)
        if ok and type(w) == "number" and w > 0 then
            return w
        end
    end
    if widthApi == "plain" and font.GetStringWidth ~= nil then
        local ok, w = pcall(function()
            return font:GetStringWidth(ch)
        end)
        if ok and type(w) == "number" and w > 0 then
            return w
        end
    end
    return 0
end

-- 字体在 scale = 1 时的行高：
-- 优先 Font:GetHeight()；没有就用“中文字宽”（中文是全角，宽度 ≈ 字高）；
-- 再退化为 ASCII 字宽 × 2
local function glyphHeightBase()
    if fontBaseHeight ~= nil then
        return fontBaseHeight
    end
    fontBaseHeight = FALLBACK_FONT_HEIGHT
    if font ~= nil and font.GetHeight ~= nil then
        local ok, h = pcall(function()
            return font:GetHeight()
        end)
        if ok and type(h) == "number" and h > 0 then
            fontBaseHeight = h
            return fontBaseHeight
        end
    end
    local cjkWidth = measureChar("合")
    if cjkWidth > 0 then
        fontBaseHeight = cjkWidth * 1.05
        return fontBaseHeight
    end
    local asciiWidth = measureChar("A")
    if asciiWidth > 0 then
        -- ASCII 字宽只有字高的 40%~55%，这里取偏大的系数，宁可行距松一点也不要叠字
        fontBaseHeight = asciiWidth * 2.2
    end
    return fontBaseHeight
end

-- 把一个 UTF-8 字符串切成字符（返回 { char, byteStart, byteLen } 序列）
local function utf8Chars(text)
    local chars = {}
    local i = 1
    local n = #text
    while i <= n do
        local b = text:byte(i)
        if b == nil then
            break
        end
        local len = 1
        if b >= 0xF0 then
            len = 4
        elseif b >= 0xE0 then
            len = 3
        elseif b >= 0xC0 then
            len = 2
        end
        if i + len - 1 > n then
            len = 1
        end
        chars[#chars + 1] = { text = text:sub(i, i + len - 1), bytes = len }
        i = i + len
    end
    return chars
end

-- 单字符宽度（scale = 1）：先量，量不到就用字高估算
local function charWidth(ch)
    local w = charWidthCache[ch]
    if w ~= nil then
        return w
    end
    w = 0
    if widthApi == "utf8" and font ~= nil then
        local ok, measured = pcall(function()
            return font:GetStringWidthUTF8(ch)
        end)
        if ok and type(measured) == "number" and measured > 0 then
            w = measured
        end
    elseif widthApi == "plain" and font ~= nil then
        local ok, measured = pcall(function()
            return font:GetStringWidth(ch)
        end)
        if ok and type(measured) == "number" and measured > 0 then
            w = measured
        end
    end
    if w <= 0 then
        local b = ch:byte(1) or 65
        local h = glyphHeightBase()
        if b >= 0xE0 then
            w = h          -- 中日韩 / 全角
        elseif b >= 0xC0 then
            w = h * 0.85
        else
            w = h * 0.52   -- ASCII 半角
        end
    end
    charWidthCache[ch] = w
    return w
end

local function textWidth(text, scale)
    scale = scale or 1
    if text == nil or text == "" then
        return 0
    end
    local total = 0
    for _, ch in ipairs(utf8Chars(text)) do
        total = total + charWidth(ch.text)
    end
    return total * scale
end

-- 按宽度裁剪字符串（UTF-8 安全），返回 { text = 截断结果, done = 是否完整 }
local function clipText(text, maxWidth, scale)
    if text == nil or text == "" or maxWidth <= 0 then
        return "", false
    end
    local total = textWidth(text, scale)
    if total <= maxWidth then
        return text, true
    end
    local parts = {}
    local used = 0
    for _, ch in ipairs(utf8Chars(text)) do
        local w = charWidth(ch.text) * (scale or 1)
        if used + w > maxWidth then
            break
        end
        parts[#parts + 1] = ch.text
        used = used + w
    end
    return table.concat(parts), false
end

-- 实际绘制（按探测到的 API 分支）
local function drawTextRaw(text, x, y, color, scale)
    scale = scale or 1
    if drawApi == "utf8" then
        if font == nil then
            return
        end
        font:DrawStringUTF8(text, x, y, KColor(color[1], color[2], color[3], color[4] or 1), scale, true)
    elseif drawApi == "utf8-5" then
        if font == nil then
            return
        end
        font:DrawStringUTF8(text, x, y, KColor(color[1], color[2], color[3], color[4] or 1), scale)
    elseif drawApi == "scaledUtf8" then
        if font == nil then
            return
        end
        -- 与 EID 完全一致：(str, x, y, scaleX, scaleY, color, boxWidth, renderMode)
        font:DrawStringScaledUTF8(text, x, y, scale, scale,
            KColor(color[1], color[2], color[3], color[4] or 1), 0, false)
    elseif drawApi == "draw" then
        if font == nil then
            return
        end
        font:DrawString(text, x, y, KColor(color[1], color[2], color[3], color[4] or 1), scale, true)
    elseif drawApi == "draw-5" then
        if font == nil then
            return
        end
        font:DrawString(text, x, y, KColor(color[1], color[2], color[3], color[4] or 1), scale)
    elseif drawApi == "scaled" then
        if font == nil then
            return
        end
        font:DrawStringScaled(text, x, y, scale, scale,
            KColor(color[1], color[2], color[3], color[4] or 1), 0, false)
    elseif drawApi == "renderScaled" then
        pcall(function()
            Isaac.RenderScaledText(text, x, y, x + 240, y + 12, scale, scale,
                color[1], color[2], color[3], color[4] or 1)
        end)
    elseif drawApi == "renderText" then
        pcall(function()
            Isaac.RenderText(text, x, y, color[1], color[2], color[3], color[4] or 1)
        end)
    end
end

-- 没有底板时用“四向黑色描边”保证在复杂背景上也能看清
-- （1.9 一个坐标单位 ≈ 3~4 屏幕像素，所以偏移必须按字号缩放，不能写死 1）
local function outlineOffset(scale)
    local off = glyphHeightBase() * (scale or 1) * 0.09
    if off < 0.25 then
        off = 0.25
    elseif off > 0.6 then
        off = 0.6
    end
    return off
end

local function drawText(text, x, y, color, scale)
    if text == nil or text == "" then
        return
    end
    if shadowEnabled then
        local d = outlineOffset(scale)
        drawTextRaw(text, x - d, y, COLORS.shadow, scale)
        drawTextRaw(text, x + d, y, COLORS.shadow, scale)
        drawTextRaw(text, x, y - d, COLORS.shadow, scale)
        drawTextRaw(text, x, y + d, COLORS.shadow, scale)
    end
    drawTextRaw(text, x, y, color, scale)
end

-- 探测可用于画底板的接口（Repentance+ 1.9 已移除 Isaac.RenderRect）
local function ensureRectProbe()
    if rectChecked then
        return
    end
    rectChecked = true
    rectAvailable = false
    if Isaac.RenderRect ~= nil then
        local ok = pcall(function()
            Isaac.RenderRect(0, 0, 1, 1, 0, 0, 0, 0, true)
        end)
        if ok then
            rectAvailable = true
            rectFilledArg = true
        else
            local ok2 = pcall(function()
                Isaac.RenderRect(0, 0, 1, 1, 0, 0, 0, 0)
            end)
            if ok2 then
                rectAvailable = true
                rectFilledArg = false
            end
        end
    end
    shadowEnabled = not rectAvailable
end

local function drawRect(x, y, w, h, color)
    ensureRectProbe()
    if not rectAvailable then
        return
    end
    if rectFilledArg then
        Isaac.RenderRect(x, y, w, h, color[1], color[2], color[3], color[4] or 1, true)
    else
        Isaac.RenderRect(x, y, w, h, color[1], color[2], color[3], color[4] or 1)
    end
end

-- 按段绘制：segments = { { text = "...", color = COLORS.xxx }, ... }
-- maxWidth 不为 nil 时按宽度裁剪，保证永远不会画到面板外面去
local function drawSegments(segments, x, y, scale, maxWidth)
    local cursor = x
    local limit = nil
    if maxWidth ~= nil then
        limit = x + maxWidth
    end
    for _, segment in ipairs(segments) do
        local text = segment.text
        if text ~= nil and text ~= "" then
            local color = segment.color or COLORS.white
            local width = textWidth(text, scale)
            if limit ~= nil and cursor + width > limit then
                local clipped = clipText(text, limit - cursor, scale)
                if clipped ~= "" then
                    drawText(clipped, cursor, y, color, scale)
                    cursor = cursor + textWidth(clipped, scale)
                end
                return cursor - x
            end
            drawText(text, cursor, y, color, scale)
            cursor = cursor + width
        end
    end
    return cursor - x
end

-- ------------------------------------------------------------
-- 字体与绘制 API 探测
-- ------------------------------------------------------------

-- 新建一个“空”字体对象（必须再 Load 才有字形）
local function newFont()
    local ok, obj = pcall(Font)
    if ok and obj ~= nil then
        return obj
    end
    return nil
end

-- 字体是否真的装好了字形
-- Repentance+ 1.9 实测：Font(path) 构造出来的对象 IsLoaded() == false，
-- 用它画字既不报错也不显示；未加载的字体 GetStringWidth 也会是 0。
local function fontIsLoaded(fontObject)
    if fontObject == nil then
        return false
    end
    if fontObject.IsLoaded ~= nil then
        local ok, loaded = pcall(function()
            return fontObject:IsLoaded()
        end)
        if ok and loaded == false then
            return false
        end
    end
    if fontObject.GetStringWidthUTF8 ~= nil then
        local ok, width = pcall(function()
            return fontObject:GetStringWidthUTF8("A")
        end)
        if ok and type(width) == "number" then
            return width > 0
        end
    end
    if fontObject.GetStringWidth ~= nil then
        local ok, width = pcall(function()
            return fontObject:GetStringWidth("A")
        end)
        if ok and type(width) == "number" then
            return width > 0
        end
    end
    -- 既没有 IsLoaded 也没有字宽接口：只能认为可用
    return true
end

local function fontHasChinese(fontObject)
    if fontObject == nil then
        return false
    end
    if fontObject.GetStringWidthUTF8 ~= nil then
        local ok, width = pcall(function()
            return fontObject:GetStringWidthUTF8("合成链")
        end)
        if ok and type(width) == "number" and width > 0 then
            return true
        end
    end
    return false
end

-- 探测字体自身的绘制接口
-- 返回 "scaledUtf8" / "scaled" / "utf8" / "utf8-5" / "draw" / "draw-5"；不可用返回 "none"
--
-- 顺序很关键：Repentance+ 1.9 里应优先用 DrawStringScaledUTF8 / DrawStringScaled
-- （参数是 str, x, y, scaleX, scaleY, color, boxWidth, renderMode，本机 EID 就是这么画的）；
-- 而 DrawStringUTF8 / DrawString 的第 5 个参数在 1.9 中其实是“框宽”而不是缩放，
-- 把缩放值传进去会让换行/字距完全错乱（面板糊成一团、看不出是什么）。
local function pickDrawApi(fontObject)
    if fontObject == nil or KColor == nil then
        return "none"
    end
    if fontObject.DrawStringScaledUTF8 ~= nil then
        local ok = pcall(function()
            fontObject:DrawStringScaledUTF8("A", -100, -100, 0.1, 0.1, KColor(1, 1, 1, 1), 0, false)
        end)
        if ok then
            return "scaledUtf8"
        end
    end
    if fontObject.DrawStringScaled ~= nil then
        local ok = pcall(function()
            fontObject:DrawStringScaled("A", -100, -100, 0.1, 0.1, KColor(1, 1, 1, 1), 0, false)
        end)
        if ok then
            return "scaled"
        end
    end
    if fontObject.DrawStringUTF8 ~= nil then
        local ok = pcall(function()
            fontObject:DrawStringUTF8("A", -100, -100, KColor(1, 1, 1, 1), 0.1, true)
        end)
        if ok then
            return "utf8"
        end
        local ok2 = pcall(function()
            fontObject:DrawStringUTF8("A", -100, -100, KColor(1, 1, 1, 1), 0.1)
        end)
        if ok2 then
            return "utf8-5"
        end
    end
    if fontObject.DrawString ~= nil then
        local ok = pcall(function()
            fontObject:DrawString("A", -100, -100, KColor(1, 1, 1, 1), 0.1, true)
        end)
        if ok then
            return "draw"
        end
        local ok2 = pcall(function()
            fontObject:DrawString("A", -100, -100, KColor(1, 1, 1, 1), 0.1)
        end)
        if ok2 then
            return "draw-5"
        end
    end
    return "none"
end

local function pickWidthApi(fontObject)
    if fontObject ~= nil then
        if fontObject.GetStringWidthUTF8 ~= nil then
            local ok, width = pcall(function()
                return fontObject:GetStringWidthUTF8("A")
            end)
            if ok and type(width) == "number" then
                return "utf8"
            end
        end
        if fontObject.GetStringWidth ~= nil then
            local ok, width = pcall(function()
                return fontObject:GetStringWidth("A")
            end)
            if ok and type(width) == "number" then
                return "plain"
            end
        end
    end
    return "none"
end

-- 按路径加载字体：不可用（加载失败 / 字形为空）返回 nil
-- 1.9 正确写法是 Font() + Font:Load(path)，并对 IsLoaded() 做校验；
-- Font(path) 只作为旧版本（1.7 / 1.8）的回退。
local fontCache = {}
local function loadFontByPath(path)
    if path == nil or path == "" then
        return nil
    end
    if fontCache[path] ~= nil then
        return fontCache[path] or nil
    end

    local candidate = nil

    local obj = newFont()
    if obj ~= nil and obj.Load ~= nil then
        local ok = pcall(function()
            obj:Load(path)
        end)
        if not ok or not fontIsLoaded(obj) then
            -- GoG 版本要求第二个参数，失败再试一次
            pcall(function()
                obj:Load(path, "")
            end)
        end
        if fontIsLoaded(obj) then
            candidate = obj
        end
    end

    if candidate == nil then
        local ok, legacy = pcall(Font, path)
        if ok and legacy ~= nil and fontIsLoaded(legacy) then
            candidate = legacy
        end
    end

    fontCache[path] = candidate or false
    if config.Debug then
        if candidate ~= nil then
            Log.Write(string.format("[CainsBag] font ok: %s (cjk=%s)",
                tostring(path), tostring(fontHasChinese(candidate))))
        else
            Log.Write("[CainsBag] font skip: " .. tostring(path) .. "（未加载或字形为空）")
        end
    end
    return candidate
end

local function detectLanguage()
    local forced = config.Language
    if forced == "zh" or forced == "en" then
        return forced
    end
    local utf8Capable = (drawApi == "utf8" or drawApi == "utf8-5"
        or drawApi == "scaledUtf8" or drawApi == "scaled")
    if utf8Capable and fontHasChinese(font) then
        return "zh"
    end
    return "en"
end

-- force = true 时清空字体缓存重新探测（测试 / 手动重载用）
function UI.Init(force)
    if force then
        fontCache = {}
    end

    -- 候选字体：config.FontPath 优先，其次内置字体，最后借用其它 mod 的中文字体
    local candidates = {}
    if config.FontPath ~= nil and config.FontPath ~= "" then
        candidates[#candidates + 1] = config.FontPath
    end
    for _, path in ipairs(FONT_CANDIDATES) do
        candidates[#candidates + 1] = path
    end
    if MODS_DIR ~= nil then
        for _, rel in ipairs(MCM_CN_FONT_FILES) do
            candidates[#candidates + 1] = MODS_DIR .. MCM_CN_FOLDER .. "/" .. rel
        end
    end
    for _, rel in ipairs(MCM_CN_FONT_FILES) do
        candidates[#candidates + 1] = "../mods/" .. MCM_CN_FOLDER .. "/" .. rel
    end

    -- 逐个候选评估：必须“真的加载出字形”（IsLoaded / 字宽 > 0），其中支持中文的优先
    local best = nil
    local tried = {}
    for _, path in ipairs(candidates) do
        if not tried[path] then
            tried[path] = true
            local loaded = loadFontByPath(path)
            if loaded ~= nil then
                local api = pickDrawApi(loaded)
                if api ~= "none" then
                    local chinese = fontHasChinese(loaded)
                    if best == nil or (chinese and not best.chinese) then
                        best = {
                            font = loaded,
                            source = path,
                            chinese = chinese,
                            api = api,
                            widthApi = pickWidthApi(loaded),
                        }
                    end
                end
            end
        end
    end

    -- 最后尝试无参 Font()（旧版本会直接带上默认字体）
    if best == nil then
        local defaultFont = newFont()
        if defaultFont ~= nil and fontIsLoaded(defaultFont) then
            local api = pickDrawApi(defaultFont)
            if api ~= "none" then
                best = {
                    font = defaultFont,
                    source = "Font()",
                    chinese = fontHasChinese(defaultFont),
                    api = api,
                    widthApi = pickWidthApi(defaultFont),
                }
            end
        end
    end

    if best ~= nil then
        font = best.font
        fontSource = best.source
        drawApi = best.api
        widthApi = best.widthApi
    else
        -- 字体全都不可用，退到遗留渲染接口（1.9 下多半已失效，只作兜底）
        font = nil
        fontSource = "none"
        widthApi = "none"
        if Isaac.RenderScaledText ~= nil then
            drawApi = "renderScaled"
        elseif Isaac.RenderText ~= nil then
            drawApi = "renderText"
        else
            drawApi = "none"
        end
        -- 一个都没加载成功时清掉失败缓存：可能是模组加载得太早（图形未初始化），
        -- 下次 UI.Init()（进入游戏时）再重试一遍
        fontCache = {}
    end

    -- 字体变了：清掉度量缓存（字高 / 单字宽度）
    fontBaseHeight = nil
    charWidthCache = {}

    lang = detectLanguage()
    rectChecked = false
    shadowEnabled = false
    renderLogged = false

    if config.Debug then
        Log.Write(string.format("[CainsBag] UI init: font=%s drawApi=%s widthApi=%s lang=%s rectApi=%s h=%.1f",
            tostring(fontSource), tostring(drawApi), tostring(widthApi), tostring(lang),
            tostring(Isaac.RenderRect ~= nil), glyphHeightBase()))
        if (config.Language == "zh") and lang ~= "zh" then
            Log.Write("[CainsBag] 警告：强制中文但当前字体可能不含中文字形，可修改 config.FontPath")
        end
        if drawApi == "none" or drawApi == "renderText" or drawApi == "renderScaled" then
            Log.Write("[CainsBag] 警告：没有可用的字体绘制接口（1.9 的 Isaac.RenderText 多半是空实现），"
                .. "面板将不可见；请把 config.FontPath 指向任意可用的 .fnt（例如本机 ModConfigMenu-CN 的字体）")
        end
    end
end

function UI.GetLanguage()
    return lang
end

-- 热键切换语言（zh / en），并清掉度量缓存（两种语言的示例串长度不同，缩放要重算）
function UI.ToggleLanguage()
    local nextLang = (lang == "zh") and "en" or "zh"
    config.Language = nextLang
    lang = nextLang
    charWidthCache = {}
    renderLogged = false
    Log.Write("[CainsBag] language -> " .. nextLang)
    return nextLang
end

function UI.GetRenderInfo()
    return string.format("font=%s drawApi=%s widthApi=%s lang=%s rect=%s",
        tostring(fontSource), tostring(drawApi), tostring(widthApi), tostring(lang),
        tostring(rectAvailable))
end

local function computeScale(maxTextWidth)
    local sample
    if lang == "zh" then
        sample = "88 放 双硬币（顶掉永恒心、硬币） → 配方#12 币 币 币 钥 钥 炸 炸 红"
    else
        sample = "88 take Double Penny -Eternal Heart/Penny ->#12 C C C K K B B R"
    end
    local width = textWidth(sample, 1)
    local scale = 1.0
    if width > 0 then
        scale = maxTextWidth / width
    end
    if scale > 1.0 then
        scale = 1.0
    elseif scale < 0.08 then
        scale = 0.08
    end
    return scale * (config.UiScale or 1)
end

local function ingredientSegments(ids)
    local segments = {}
    for i, id in ipairs(ids or {}) do
        if i > 1 then
            segments[#segments + 1] = { text = " ", color = COLORS.dim }
        end
        local r, g, b = Ingredients.Color(id)
        segments[#segments + 1] = { text = Ingredients.ShortName(id, lang), color = { r, g, b, 1 } }
    end
    return segments
end

local function atomLabel(atom)
    if atom.fromInventory then
        return Ingredients.Name(atom.ingredientId or atom.ids[1], lang) .. T("inBag")
    end
    return Ingredients.PickupLabel(atom.variant, atom.subtype, lang)
end

local function buildStepRow(step, index)
    local segments = {}
    segments[#segments + 1] = { text = string.format("%2d ", index), color = COLORS.dim }
    segments[#segments + 1] = { text = T("option") .. " ", color = COLORS.gray }

    local atom = step.atom
    segments[#segments + 1] = {
        text = atomLabel(atom),
        color = atom.fromInventory and COLORS.cyan or COLORS.white,
    }

    -- 一次拾取可能顶掉 1~2 格（双素材掉落物一次拿完）：逐个列出被顶掉的素材
    local evictedIds = {}
    if type(step.evicted) == "table" then
        for i = 1, #step.evicted do
            if step.evicted[i] ~= nil and step.evicted[i] ~= false then
                evictedIds[#evictedIds + 1] = step.evicted[i]
            end
        end
    elseif step.evicted ~= nil and step.evicted ~= false then
        evictedIds[1] = step.evicted
    end
    if #evictedIds > 0 then
        segments[#segments + 1] = { text = " " .. T("evictOpen"), color = COLORS.gray }
        for i = 1, #evictedIds do
            if i > 1 then
                segments[#segments + 1] = { text = T("evictJoin"), color = COLORS.gray }
            end
            local r, g, b = Ingredients.Color(evictedIds[i])
            segments[#segments + 1] = {
                text = Ingredients.Name(evictedIds[i], lang),
                color = { r, g, b, 1 },
            }
        end
        segments[#segments + 1] = { text = T("evictClose"), color = COLORS.gray }
    end

    segments[#segments + 1] = { text = " " .. T("arrow") .. " ", color = COLORS.dim }

    -- 袋里出现过的配方（口径②）：不编号，只标「已出现 / 已合成」+ 该步袋内容
    if step.isCrafted then
        segments[#segments + 1] = {
            text = (step.wasCrafted and T("craftedConfirmed") or T("crafted")) .. " ",
            color = COLORS.dim,
        }
        for _, segment in ipairs(ingredientSegments(step.bag)) do
            segments[#segments + 1] = segment
        end
        return segments
    end

    if step.recipeIndex == nil then
        segments[#segments + 1] = { text = T("noWindow"), color = COLORS.dim }
        return segments
    end

    segments[#segments + 1] = {
        text = string.format(T("recipe"), step.recipeIndex) .. " ",
        color = step.isNew and COLORS.green or COLORS.gray,
    }
    if not step.isNew then
        segments[#segments + 1] = {
            text = string.format(T("sameAs"), step.recipeIndex) .. " ",
            color = COLORS.dim,
        }
    end
    for _, segment in ipairs(ingredientSegments(step.bag)) do
        segments[#segments + 1] = segment
    end
    return segments
end

local function buildHeader(state)
    local distinct = 0
    if state.result ~= nil and state.result.stats ~= nil then
        distinct = state.result.stats.distinct or 0
    end
    local scopeText = T("floor")   -- 统计范围固定为本层（step5 去掉了 Tab 范围切换）
    local titleText = T("title")
    local titleColor = COLORS.yellow
    local confidence = state.bagState and state.bagState.confidence or nil
    if confidence == "known" then
        titleText = titleText .. " " .. T("markKnown")
    elseif confidence == "uncertain" then
        titleText = titleText .. " " .. T("markUncertain")
        titleColor = COLORS.orange
    end
    local segments = {
        { text = titleText .. " | ", color = titleColor },
        { text = string.format("%s %d / %s %d | ", T("distinct"), distinct, T("windows"), state.windows or 0),
            color = COLORS.white },
        { text = string.format("%s %d | ", T("available"), state.available or 0), color = COLORS.white },
        { text = scopeText, color = COLORS.cyan },
    }
    if state.directBag then
        segments[#segments + 1] = { text = " | " .. T("directBag"), color = COLORS.green }
    end
    return segments
end

local function buildBagLine(state)
    local segments = { { text = T("bag") .. ": ", color = COLORS.gray } }
    local currentStep = nil
    if state.result ~= nil then
        for _, step in ipairs(state.result.steps) do
            if step.kind == "current" then
                currentStep = step
                break
            end
        end
    end
    if currentStep ~= nil and currentStep.isCrafted then
        -- 袋里出现过的组合（口径②）：不编号，只标「已出现 / 已合成」，素材本身照常显示
        segments[#segments + 1] = {
            text = (currentStep.wasCrafted and T("craftedConfirmed") or T("crafted")) .. "  ",
            color = COLORS.gray,
        }
    elseif currentStep ~= nil and currentStep.recipeIndex ~= nil then
        segments[#segments + 1] = {
            text = string.format(T("recipe"), currentStep.recipeIndex) .. "  ",
            color = COLORS.yellow,
        }
    end
    if state.slots == nil or #state.slots == 0 then
        segments[#segments + 1] = { text = T("emptyBag"), color = COLORS.dim }
    else
        for _, segment in ipairs(ingredientSegments(state.slots)) do
            segments[#segments + 1] = segment
        end
    end
    return segments
end

local function buildWarnings(state)
    local list = {}
    if state.unknownBag then
        list[#list + 1] = { text = T("unknownBag"), color = COLORS.orange }
    elseif state.uncertainBag then
        list[#list + 1] = { text = T("uncertainBag"), color = COLORS.orange }
    end
    if state.notCain then
        list[#list + 1] = { text = T("notCain"), color = COLORS.gray }
    end
    if state.notEnough then
        list[#list + 1] = { text = T("notEnough"), color = COLORS.red }
    end
    if state.searching then
        list[#list + 1] = {
            text = string.format(T("searching"), math.floor((state.progress or 0) * 100)),
            color = COLORS.cyan,
        }
    end
    if state.lowVariety then
        local distinct = state.result and state.result.stats and state.result.stats.distinct or 1
        list[#list + 1] = {
            text = string.format(T("singleType"), distinct, state.windows or 0),
            color = COLORS.yellow,
        }
    end
    return list
end

-- 校正编辑器视图（只读渲染，状态机在 scripts/bag_editor.lua）
local function buildEditorRows(editor)
    local rows = {}
    local cursor = editor.cursor or 1
    local slots = editor.slots or {}

    rows[#rows + 1] = {
        { text = string.format(T("editorTitle"), cursor) .. "  ", color = COLORS.yellow },
        { text = T("editorHelp"), color = COLORS.gray },
    }

    local slotSegments = {}
    for i = 1, 8 do
        if i > 1 then
            slotSegments[#slotSegments + 1] = { text = "  ", color = COLORS.dim }
        end
        local id = slots[i] or 0
        local isCursor = (cursor == i)
        slotSegments[#slotSegments + 1] = {
            text = isCursor and ">" or " ",
            color = COLORS.yellow,
        }
        slotSegments[#slotSegments + 1] = {
            text = "#" .. i .. " ",
            color = isCursor and COLORS.yellow or COLORS.gray,
        }
        if id == 0 then
            slotSegments[#slotSegments + 1] = { text = T("editorEmpty"), color = COLORS.dim }
        else
            local r, g, b = Ingredients.Color(id)
            slotSegments[#slotSegments + 1] = {
                text = Ingredients.ShortName(id, lang),
                color = { r, g, b, 1 },
            }
        end
    end
    rows[#rows + 1] = slotSegments

    rows[#rows + 1] = { { text = T("editorHint"), color = COLORS.cyan } }
    return rows
end

-- ------------------------------------------------------------
-- 绘制入口（每帧调用，只做绘制）
-- ------------------------------------------------------------
function UI.Render(state)
    if state == nil or not state.visible or state.eligible == false then
        return
    end
    if drawApi == "none" then
        return
    end

    -- 绘制通道自检：屏幕左上角的小标记。
    -- 看到它 = 渲染通、只是面板位置/内容有问题；看不到它 = 渲染接口本身不通。
    -- 发布时把 config.DebugMarker 改成 false 即可
    if config.Debug and config.DebugMarker then
        drawText("CB " .. tostring(drawApi), 4, 3, COLORS.white, 0.5)
    end

    -- 只取“动作”行（起始袋已在袋内一行里体现）
    local rows = {}
    if state.result ~= nil and state.result.steps ~= nil then
        for _, step in ipairs(state.result.steps) do
            if step.kind == "push" then
                rows[#rows + 1] = step
            end
        end
    end

    -- 校正模式：用编辑器视图替换链条列表（状态机在 bag_editor，不在这里）
    local editing = (state.editor ~= nil and state.editor.active == true)
    local editorRows = {}
    if editing then
        editorRows = buildEditorRows(state.editor)
        rows = {}
    end
    local rowCount = editing and #editorRows or #rows

    local warnings = buildWarnings(state)

    local screenW = Isaac.GetScreenWidth()
    local screenH = Isaac.GetScreenHeight()
    -- 避开 HUD：主动道具 / 卡牌槽在左上角，血条在左下角 → 面板从 17% 高度开始往下 62%
    local panelX = math.floor(screenW * 0.012)
    local panelY = math.floor(screenH * 0.17)
    local panelW = math.floor(screenW * (config.PanelWidthRatio or 0.5))
    local panelH = math.floor(screenH * 0.62)
    local padX = math.max(3, math.floor(panelW * 0.03))
    local maxTextW = panelW - 2 * padX

    -- 排版完全由字体度量推导：行高 = 字高 × 1.30，能放几行就放几行
    local scale = computeScale(maxTextW)
    local glyphH = glyphHeightBase() * scale
    local lineH = math.max(glyphH * 1.30, 7)
    local fixedLines = #warnings + 5   -- 标题 + 袋 + 分隔 + 页脚分隔 + 页脚
    local rowsByHeight = math.floor((panelH - lineH * fixedLines) / lineH)
    local visibleRows = math.max(1, math.min(config.MaxVisibleRows or 12, rowsByHeight))

    local maxScroll = math.max(0, rowCount - visibleRows)
    state.scroll = math.max(0, math.min(state.scroll or 0, maxScroll))
    if editing then
        state.scroll = 0
    end

    -- 暴露最近一次的排版结果（调试 / 离线测试用：验证不越界、行高不叠字）
    UI.LastLayout = {
        screenW = screenW, screenH = screenH,
        panelX = panelX, panelY = panelY, panelW = panelW, panelH = panelH,
        scale = scale, glyphH = glyphH, lineH = lineH, rows = visibleRows,
    }

    -- 坐标 / 缩放自检：每次初始化后打印一次实际几何，便于判断“是不是画到屏幕外了”
    if config.Debug and not renderLogged then
        renderLogged = true
        Log.Write(string.format(
            "[CainsBag] render geom: screen=%dx%d panel=%d,%d %dx%d scale=%.2f glyphH=%.1f lineH=%.1f rows=%d api=%s",
            screenW, screenH, panelX, panelY, panelW, panelH, scale, glyphH, lineH, visibleRows,
            tostring(drawApi)))
    end

    drawRect(panelX, panelY, panelW, panelH, { 0, 0, 0, 0.72 })

    local x = panelX + padX
    local bottom = panelY + panelH
    local y = panelY + math.floor(lineH * 0.30)

    drawSegments(buildHeader(state), x, y, scale, maxTextW)
    y = y + lineH
    drawSegments(buildBagLine(state), x, y, scale, maxTextW)
    y = y + lineH

    for _, warning in ipairs(warnings) do
        drawText(clipText(warning.text, maxTextW, scale), x, y, warning.color, scale)
        y = y + lineH
    end

    local dashWidth = textWidth("-", scale)
    if dashWidth <= 0 then
        dashWidth = 6 * scale
    end
    local dashCount = math.max(6, math.floor(maxTextW / dashWidth))
    local separator = string.rep("-", dashCount)

    drawText(separator, x, y, COLORS.dim, scale)
    y = y + lineH

    local footerTextY = bottom - lineH * 1.15
    local footerSepY = footerTextY - lineH * 0.85
    local rowY = y
    if editing then
        for i = 1, rowCount do
            if (rowY + lineH) > footerSepY then
                break
            end
            drawSegments(editorRows[i], x, rowY, scale, maxTextW)
            rowY = rowY + lineH
        end
    else
        local i = 0
        while i < visibleRows and (rowY + lineH) <= footerSepY do
            local step = rows[(state.scroll or 0) + i + 1]
            if step == nil then
                break
            end
            drawSegments(buildStepRow(step, (state.scroll or 0) + i + 1), x, rowY, scale, maxTextW)
            i = i + 1
            rowY = rowY + lineH
        end
    end

    drawText(separator, x, footerSepY, COLORS.dim, scale)
    drawText(clipText(editing and T("editorFooter") or T("footer"), maxTextW, scale),
        x, footerTextY, COLORS.gray, scale)

    if state.message ~= nil and state.message ~= "" then
        drawText(clipText(state.message, maxTextW * 1.6, scale), x, bottom + lineH * 0.15,
            COLORS.yellow, scale)
    end
end

return UI



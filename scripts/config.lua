-- ============================================================
-- 《以撒的结合：忏悔+》Mod —— 堕化该隐合成袋「最优放置链」规划器
-- 全局配置（修改后需重载模组：主菜单退出重进 / 重新载入模组）
-- ============================================================

local config = {
    -- 调试：把素材计数、链条结果、耗时写入 log.txt（不向控制台打印）
    Debug = true,

    -- 左上角画一个自检标记（"CB <drawApi>"）：看得到 = 渲染通道通；发布时可改 false
    DebugMarker = true,

    -- 进入一局后是否默认显示面板
    PanelVisibleByDefault = true,

    -- 热键（键码见 resources/scripts/enums.lua 的 Keyboard 枚举）
    HotkeyToggle = Keyboard.KEY_F5,        -- 开/关面板
    HotkeyCalibrate = Keyboard.KEY_F6,     -- 把本地模拟校准为空袋（想录入真实袋内容请用 F9）
    HotkeyRecalc = Keyboard.KEY_F7,        -- 强制重算
    HotkeyLanguage = Keyboard.KEY_F8,      -- 切换中文 / 英文（字体不含中文字形时很有用）
    HotkeyEditBag = Keyboard.KEY_F9,       -- 进入/退出“手工校正袋内容”编辑模式
    HotkeyEditConfirm = Keyboard.KEY_ENTER, -- 编辑模式：确认并写入袋模拟
    HotkeyCursorLeft = Keyboard.KEY_LEFT,  -- 编辑模式：光标左移一格
    HotkeyCursorRight = Keyboard.KEY_RIGHT, -- 编辑模式：光标右移一格
    HotkeyScrollUp = Keyboard.KEY_UP,      -- 上滚一行 / 编辑模式：切到上一个素材
    HotkeyScrollDown = Keyboard.KEY_DOWN,  -- 下滚一行 / 编辑模式：切到下一个素材
    HotkeyPageUp = Keyboard.KEY_PAGE_UP,   -- 上翻一页
    HotkeyPageDown = Keyboard.KEY_PAGE_DOWN, -- 下翻一页

    -- 搜索参数
    BeamWidth = 80,                -- Beam Search 束宽
    MaxSteps = 40,                 -- 链最大动作数（防御性上限）
    MaxCountPerType = 24,          -- 单一素材种类参与的推入次数上限（防御，避免计数异常导致搜索爆炸）
    SearchBudgetMs = 4,            -- 每帧允许的搜索耗时（毫秒）；超出则留到下一帧继续

    -- 范围与素材来源
    -- 统计范围固定为「本层已探索房间」（Tab 范围切换已在 step5 移除，按 Tab 不再有任何行为）
    IncludeInventory = true,       -- 是否把玩家背包里的卡牌/药丸算作可用素材

    -- 偏好
    PreferLessWaste = true,        -- 平手时优先少销毁（waste 权重 3，否则 1）

    -- 面板
    Language = "auto",             -- "auto" | "zh" | "en"；auto 时自动探测默认字体是否支持中文
    FontPath = nil,                -- 自定义字体路径（如 "font/teammeatfont10.fnt"），nil 表示用默认 Font()
    UiScale = 1.0,                 -- 面板整体缩放
    PanelWidthRatio = 0.50,        -- 面板宽度占屏幕宽度比例
    MaxVisibleRows = 12,           -- 链条最多显示行数

    -- 合成后自动清空（不用再按 F6）：道具数 +1（合成出被动道具）或袋子被合成出的主动道具顶掉 ⇒ 清空
    -- 另在长按合成键 20 帧时打一条 `long hold: anim=.. bag=n/8` 调试日志（判定不依赖动画名）
    CraftFallbackHold = true,

    -- 控制台 rewind / 时间回溯：按游戏帧号保留最近的袋内容与掉落物扫描快照，
    -- 回退（同一局 + 帧号倒退）后恢复到目标帧的状态，而不是把面板信息清空。
    RewindFrames = 10800,          -- 最多保留多少帧历史（60fps ≈ 3 分钟）；0 = 关闭（回退后按未知处理）

    -- 袋内容来源
    DirectRead = true,             -- 检测到 REPENTOGON 时直接读取袋内容（不可用时自动退回事件模拟）
    -- 收集者（会吃掉场上掉落物的实体）启发式：
    -- 官方只有 5 个跟班：3.24.0 Bum Friend / 3.64.0 Dark Bum / 3.88.0 Bumbo /
    -- 3.90.0 Key Bum / 3.102.0 Super Bum；其它实体（含捐款机等 slot、Bumbino、Ultra Greed）都不吃掉落物。
    CollectorSkip = true,          -- 总开关：false 时完全不使用“附近有收集者 ⇒ 不计入”的判定
    CollectorRadius = 28,          -- 判定半径（内部坐标，1 格 = 40）：跟班要贴到掉落物上才会吃
    ExtraCollectorFamiliars = {},  -- mod 跟班白名单：{ [variant] = true } 或 { [variant] = "名字" }
    CounterCheck = false,          -- 背包计数器二次确认（仅调试用；真实归属判定改用下面的 CounterVeto）

    -- 归属判定（step4）
    -- 事实：堕化该隐的合成袋“吸收”（挥袋 / 吸取）不会触发 MC_PRE_PICKUP_COLLISION；
    --       而玩家/使魔走上去“碰到”掉落物属于普通拾取（进钱/钥匙/炸弹/红心/卡槽，不进袋）。
    -- "collision" = 新默认：有碰撞 = 普通拾取 → 不计入；没有碰撞的 Collect = 袋吸收 → 计入
    -- "legacy"    = 旧行为（玩家触碰就计入；附近没有收集者也算玩家），仅用于对比/回退
    Attribution = "collision",
    TouchFreshFrames = 3,          -- 碰撞记录的“新鲜”帧数（普通拾取结算窗口，超出即视为旧触碰）
    LateTouchFrames = 8,           -- 碰撞证据迟到：Collect 之后这么多帧内才收到碰撞 ⇒ 撤销刚才的入袋
    -- 举起合成袋（Q = ACTION_PILLCARD）才会吸取掉落物：按下后这段时间内仍算“袋吸收窗口”
    -- （按住期间每帧刷新；这里控制松手后还继续算吸取的宽限帧数）
    BagSwipeFrames = 30,
    -- 没举起袋子时：与玩家位置重叠的 Collect 一律按“走上去的普通拾取”处理（bug4）
    -- 距离取两个碰撞半径之和 ≈ 26（内部坐标；实测普通拾取 ≤23、袋吸收 ≥30）
    PickupOverlapDistance = 26,
    CounterVeto = true,            -- 计数器否决：钱/钥匙/炸弹/红心变多 ⇒ 说明这次是普通拾取 → 回滚入袋
    CounterVetoFrames = 20,        -- 计数器否决的观察窗口（帧）：拾取结算可能晚于 Collect 动画，别设太小
    ChargeProbe = true,            -- 袋容量探针：只读 GetActiveCharge()，用于自检“归属判定是否反了”（不改判定）
    DebugAttribution = true,       -- 打印每条拾取的归属证据（[CainsBag] attr 单行日志）
}

return config

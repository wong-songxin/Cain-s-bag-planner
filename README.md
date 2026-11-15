# Cain's Bag Planner（合成袋最优放置链规划器）

为《以撒的结合：忏悔+》的**堕化该隐**（Tainted Cain）合成袋计算一条**操作链**：
按顺序拾取哪些掉落物、每次顶掉袋内哪一格，使链上出现过的**不同配方（8 个素材的多重集）数量最多**。

- 不预测、不显示合成出的道具；链条中不包含合成动作，何时合成完全由玩家决定。
- 不依赖 REPENTOGON / EID / ModConfigMenu（MCM 也无需安装），只用原生 Repentance API。
- 装了 REPENTOGON 时自动改用**直读真值**；没装时用事件模拟（逐帧 Collect + 归属判定 + 计数器/槽位否决）。

> **交接文档索引**（`prompts/`）
> - `step1.md` 原始需求（勿改）
> - `step2_debug.md` 实机排错记录（勿改）
> - `step3_bag_state.md` 袋状态识别：逐帧入袋 + F9 校正 + 可信度（勿改）
> - `step4_pickup_attribution.md` 拾取归属：玩家自己捡的不计入袋（**已实现**，见 §3.2 / §5 / §8）
> - `step5_crafted_recipes_and_scope.md` 袋里出现过的配方不再展示 + 去掉 Tab 范围切换（**已实现**，口径见 §9）

## 0. 当前进度（里程碑）

| 里程碑 | 状态 | 位置 |
| --- | --- | --- |
| 素材映射（含双素材掉落物 / 卡牌符文药丸兜底） | ✅ 实机 | `scripts/data/ingredients.lua` |
| 房间 / 本层掉落物扫描 + 背包卡牌药丸聚合 | ✅ 实机 | `scripts/scan.lua` |
| 8 格 FIFO 袋模拟 + 轮转 + 双素材一次顶 2 格 + 合成清空 | ✅ 实机 | `scripts/bag_tracker.lua` |
| Beam Search 链搜索（协程分帧 / 缓存 / 逐步可执行性重放校验） | ✅ 离线 + 实机 | `scripts/chain.lua`、`tests/test_logic.lua` |
| HUD 面板（1.9 渲染适配、字体探测、自动排版、中英切换、`✓`/`?`、`直读` 标记） | ✅ 实机 | `scripts/ui.lua` |
| 逐帧入袋识别（`Collect` 首帧 / `InitSeed` 去重 / 换房保护帧） | ✅ 实机 | `scripts/bag_tracker.lua` |
| **拾取归属（step4）**：碰撞=普通拾取 / 无碰撞=袋吸收 / 2P·使魔·无袋玩家不计入 | ✅ 实机 | `bag_tracker.attributePickup` |
| **计数器 / 卡牌槽否决**：钱·钥匙·炸弹·红心变多 或 卡牌槽变化 ⇒ 撤销误记 | ✅ 实机 | `bag_tracker.updateCounterVeto` |
| **合成后自动清空**：道具数 +1 / 袋子被合成出的主动道具顶掉 ⇒ 清空（不用按 F6） | ✅ 离线（待实机复验） | `bag_tracker.updateCraftWatch` |
| F9 手工校正袋内 8 格（候选素材、草稿保留、过期草稿重建） | ✅ 实机 | `scripts/bag_editor.lua`、`main.lua` |
| 可信度四态 `unknown / known / tracking / uncertain`（续档、复活、使用未满降级） | ✅ 实机 | `bag_tracker.lua`、`ui.lua` |
| 输入层：`IsButtonPressed` + 自求边沿（一次按键只触发一次） | ✅ 实机 | `main.lua`（`pollInput`） |
| 归属证据日志 `[CainsBag] attr ...` + 袋容量探针 `WARN` 自检 | ✅ 实机 | `bag_tracker.lua` |
| **step5：出现过的配方去重 + 去掉 Tab 范围切换**（满 8 格出现过即拉黑，见 §9） | ✅ 离线 | `scripts/recipe.lua`、`chain.lua`、`bag_tracker.lua`、`main.lua`、`ui.lua` |
| **bug 修复（step6）**：双素材掉落物按「一次拾取 = 一个动作」建模；已有另一个主动道具时合成主动也会清空 | ✅ 离线 | `chain.lua`、`ui.lua`、`bag_tracker.lua` |
| REPENTOGON 直读（可选、自动探测、异常回退事件模拟） | ⚠️ 代码就绪，本机未装未实测 | `bag_tracker.detectDirectRead / readDirectBag` |
| 离线测试 | ✅ 267 条断言全绿 | `python tests/run_tests.py`、`python tests/check_encoding.py` |

**待验证 / 待办（按优先级）**

1. **REPENTOGON 直读**：装一次跑一局，确认 `bag source: direct read (REPENTOGON)` / `bag synced (direct): [...]`，并核对 0/1-based 与内容顺序；
2. 合成自动清空的**实机复验**：合成后应出现 `craft detected` + `bag cleared: craft`，面板自动清空（见 §5 第 1 条）；
3. 袋**未满**时 `ACTION_DROP` 的真实行为（轮转 / 无效 / 丢弃）——当前按"轮转"建模；
4. `pickup.InitSeed` 跨房间唯一性（当前 key 优先用 seed，取不到退回 index）；
5. 电池类（无计数器 / 无槽位信号）的归属边界：观察是否仍会多记一次；
6. **偶发漏记（已知未修）**：连续快速吸取多个掉落物时，个别掉落物可能没被识别入袋
   （挥袋动画同帧重叠 + 归属证据缺失）。当前用 `F9` 手工补正；后续排查可对比 `attr` 与 `skip collect` 日志的时间戳。

## 1. 安装

1. 把本目录挂到游戏的 mods 目录（管理员 PowerShell）：

   ```powershell
   New-Item -ItemType Junction `
       -Path "E:\Steam\steamapps\common\The Binding of Isaac Rebirth\mods\CainsBag" `
       -Target "E:\Code\MOD\Cain's-bag"
   ```

2. 启动游戏 → `Mods` 菜单 → 启用 **Cain's Bag Planner**（Private 模组需要在 `Mods` 里手动开启）。
3. 进一局后默认自动显示面板；`F5` 可以关闭/打开。

卸载：关闭游戏后删除 junction（`Remove-Item "…\mods\CainsBag"`）即可，不会动到源码目录。

### 1.1 从 GitHub 安装 / 更新

仓库根目录就是模组根目录（`metadata.xml`、`main.lua` 在最外层），所以**克隆到的文件夹名要与 `metadata.xml` 的 `<directory>` 一致**（`CainsBag`）：

```powershell
cd "E:\Steam\steamapps\common\The Binding of Isaac Rebirth\mods"
git clone https://github.com/<你的用户名>/CainsBag.git CainsBag
```

- 更新：`cd mods\CainsBag; git pull`，再在游戏里重载模组（或重启游戏）；
- 不想用 git：下载 GitHub Release 里的 `CainsBag.zip` 解压到 `mods\` 下即可（zip 里只有 `metadata.xml` / `main.lua` / `scripts/`）；
- 源码自带的 `tests/`（离线测试）与 `prompts/`（开发交接文档）不参与模组运行，保留无副作用。

> **可选（推荐）**：安装 [REPENTOGON](https://repentogon.com/) 后，模组会**逐帧直接读取袋内真实内容**
> （`GetBagOfCraftingContent()`，100% 准确，不再需要 `F9` 手工校正）；没装时自动退回事件模拟，功能不受影响。

## 2. 热键

| 按键 | 作用 |
| --- | --- |
| `F5` | 开/关面板（校正过程中关面板不会丢修改） |
| `F6` | 把袋模拟校准为空袋（**合成后已自动清空**，只在"想手动重新同步一次"时才需要；替换袋内容请用 `F9`；直读模式下无需校准） |
| `F7` | 强制重算 |
| `F8` | 切换中文 / 英文（字体不含中文字形时用它切到英文） |
| `F9` | 进入 / 退出「校正袋内容」编辑模式（已启用 REPENTOGON 直读时不可用） |
| `←` / `→` | 编辑模式：选择格子 |
| `↑` / `↓` | 编辑模式：切换素材（循环）；非编辑模式：链条滚动 |
| `Enter` | 编辑模式：确认并写入袋模拟（立即重算） |
| `PageUp` / `PageDown` | 上 / 下翻一页 |

> 统计范围**固定为本层已探索房间**（`Scan.GetFloorAtoms()`）。`Tab` 已于 step5 移除，按下去不会有任何行为。

热键都能在 `scripts/config.lua` 里改。热键使用「按住状态 + 自己求边沿」实现（每帧轮询全部按键），
规避了 Repentance+ `Input.IsButtonTriggered` 的两个坑：一次按键可能连续两帧可读（会导致 F9 开了又关、
丢弃键一次轮转两格）、未读取的触发会一直保留（会导致之后突然"补触发"）。因此**一次按键只生效一次**。

## 3. 面板读法

```
合成链 | 不同配方 7 / 窗口 9 | 可用素材 18 | 本层
袋内: （已出现）  币 币 币 钥 钥 炸 炸 红
----------------------------------------
 1 放 硬币 → 配方#1 币 币 币 币 币 币 红 红
 2 放 钥匙（顶掉红心）→ （已出现） 币 币 币 币 币 红 红 钥
 3 放 双硬币（顶掉硬币、钥匙）→ 配方#2 币 币 币 币 红 红 钥 钥
 4 放 幸运币（顶掉硬币）→ 配方#3（同 #2） …
----------------------------------------
F5 关闭  F6 校准  F7 重算  F8 语言  F9 校正袋  方向键 滚动
```

- **不同配方**：链上出现过的互不相同的 8 素材多重集数量（**不含**袋里已经出现过的组合，见下一条）。
- **`（已出现）` / `（已合成）`**：这个 8 格组合在合成袋里出现过（`（已合成）` = 真正合成过的那一次）。
  此后它**不再编号、不计入「不同配方」、不再作为链条目标**，避免把素材又摆回同一个组合白合一次；
  若链条必须经过它，该行只显示动作 + `（已出现）` + 该步袋内容（素材照常显示，因为规划还要用）。
- **窗口**：理论上最多能看到的配方数 = 可用素材数 −（补满袋所需）+ 1；素材种类极单一（例如全是硬币）时窗口很多但配方只有 1 个，会额外提示「素材多样性不足」。
- **双素材掉落物（双硬币、钥匙圈、双炸弹、混合心…）**：一次拾取同时进 2 格，**不能只拾取其中一个**，
  所以面板只占一行；袋满时会列出被顶掉的 2 个素材（第 2 个只能是队列上紧跟第 1 个的那一格，FIFO）。
- **`(同 #n)`**：这一步落地的配方和之前第 n 个配方相同（灰字），不算新配方。
- **`(背包)`**：素材来自玩家背包里的卡牌/药丸，需要先丢到地上才能放进袋子。
- **`放` = 挥袋吸入**：堕化该隐要把掉落物放进袋子，得用**挥袋（攻击/吸取）**，不是走上去捡——
  走上去碰到的掉落物属于普通拾取（进钱 / 钥匙 / 炸弹 / 红心 / 卡槽），**不会进袋**（见 §5 的归属判定）。
- 标题后的标记表示袋内容可信度：`✓` = 已确认（新开一局 / 刚合成 / 刚用 `F9` 校正）；无标记 = 正在连续跟踪；
  `?` = 可能不同步（中途续档、复活、计数器对不上…），底部会提示「按 F9 校正」。
- 面板底部出现的警告：`袋内容未知 / 可能不同步：请按 F9 校正`、`素材不足`、`非该隐`。

### 3.1 校正袋内容（`F9`）

```
校正袋内容 [3/8]  ←/→ 选格  ↑/↓ 换素材  Enter 确认  F9 退出
>#1 币   #2 币   #3 钥   #4 炸   #5 红   #6 --   #7 --   #8 --
（#1 = 最旧 = 下一个被顶掉的格子；空位保存时会自动压缩）
```

- `#1` 是最旧的一格（下一个被顶掉的格子）；只填前 N 格表示袋未满，后续拾取会继续追加。
- 候选顺序：`--`（空）→ 本房间已扫描到的素材 → 本层 / 背包里的卡牌药丸 → 全部 0..29 素材。
- `Enter` 写入后立即重算链条；`F9` 退出时草稿会保留（再按 `F9` 可继续），`F5` 关面板也不会丢。

### 3.2 袋内内容是怎么来的（识别链路概要）

```
REPENTOGON 可用？
 ├─ 是 → 每帧 GetBagOfCraftingContent() 覆盖模拟（✓ … | 直读），事件模拟不参与
 └─ 否 → 事件模拟
      ① 逐帧看掉落物 Collect 首帧（InitSeed 去重；换房前 2 帧不判定）
      ② 归属判定（step4）
          · 新鲜碰撞(≤3 帧) = 玩家/使魔"走上去捡" → 普通拾取，不计入
          · 没有碰撞的 Collect = 挥袋 / 吸取进袋 → 计入
          · 附近有更近的使魔/乞丐/老虎机 → 不计入；没有合成袋的玩家 → 不计入
      ③ 否决（只在"计入"之后复核，20 帧窗口）
          · 钱/钥匙/炸弹/纯红心变多 ⇒ 这是普通拾取 ⇒ 回滚这次入袋
          · 卡牌 / 药丸槽签名变化 ⇒ 卡牌进了背包 ⇒ 回滚
      ④ 合成检测：道具数 +1 或 袋子被合成出的主动道具顶掉 ⇒ 袋模拟清空（known）
```

- 每一步都会写日志（`attr` / `skip collect` / `veto passed` / `craft detected` / `bag cleared`），排查见 §8。
- 可信度：新局或 `F6`/`F9`/合成清空 → `known`；连续入袋 → `tracking`；`use-item` 未满 / 计数器核对异常 → `uncertain`；续档 / 复活 → `unknown`。

## 4. 配置（`scripts/config.lua`）

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `PanelVisibleByDefault` | `true` | 进局后默认显示面板（热键见 §2） |
| `Debug` | `true` | 把素材计数、链条结果、耗时写入 `log.txt`（**不向控制台打印**，避免刷屏） |
| `DebugMarker` | `true` | 在屏幕左上角画自检标记 `CB <drawApi>`：**看得到标记 = 渲染通道是通的**；发布时可改 `false` |
| `BeamWidth` | `80` | Beam Search 束宽，越大越准、越慢 |
| `MaxSteps` | `40` | 链最多动作数 |
| `MaxCountPerType` | `24` | 同一种素材最多参与多少次放入（防御计数异常） |
| `SearchBudgetMs` | `4` | 每帧允许的搜索耗时，超出后下一帧续算 |
| `IncludeInventory` | `true` | 是否把背包里的卡牌/药丸算进可用素材 |
| `PreferLessWaste` | `true` | 分数相同时优先少销毁高价值素材（权重 3，否则 1） |
| `Language` | `"auto"` | `"zh"` / `"en"` / `"auto"`（自动探测字体是否有中文字形） |
| `FontPath` | `nil` | 自定义字体路径，例如 `"font/teammeatfont10.fnt"` |
| `UiScale` | `1.0` | 面板整体缩放 |
| `PanelWidthRatio` | `0.50` | 面板宽度占屏幕宽度比例 |
| `MaxVisibleRows` | `12` | 链条最多显示行数 |
| `CraftFallbackHold` | `true` | **合成后自动清空袋模拟**（不用再按 F6）：① 道具数增加（合成出被动道具）② 袋子被合成出的主动道具顶掉 ③ 已有另一个主动道具时主动槽 itemID 变化（`craft-active`）——任一命中即判定合成完成；另在长按合成键 20 帧时打一条 `long hold: anim=.. bag=n/8` 调试日志 |
| `DirectRead` | `true` | 检测到 REPENTOGON 时逐帧直接读取真实袋内容；不可用时自动退回事件模拟 |
| `CollectorRadius` | `40` | 事件模拟时，判定「掉落物被使魔 / 乞丐 / 老虎机拿走」的半径（无碰撞回调时的防御判断） |
| `Attribution` | `"collision"` | 归属判定：`"collision"` = 新语义（碰撞=普通拾取→不计入；无碰撞的 Collect=袋吸收→计入）；`"legacy"` = 旧行为（玩家碰过就计入），仅对比/回退用 |
| `TouchFreshFrames` | `3` | 碰撞记录的「新鲜」帧数：超出后视为旧触碰（碰过但没拿走），不再阻止入袋 |
| `CounterVeto` | `true` | 计数器/槽位否决：钱 / 钥匙 / 炸弹 / 红心变多，或卡牌 / 药丸槽变化 ⇒ 这次是普通拾取 ⇒ 撤销刚才的入袋（回滚并重算） |
| `CounterVetoFrames` | `20` | 否决观察窗口（帧）：拾取结算可能晚于 `Collect` 动画，别设太小 |
| `ChargeProbe` | `true` | 袋容量探针：只读 `GetActiveCharge()/GetActiveMaxCharge()`。**不参与判定**，只在「跳过之后袋容量反而涨了」时打 `WARN`（说明归属判定可能反了） |
| `DebugAttribution` | `true` | 每条拾取打一行归属证据日志 `[CainsBag] attr ...`（排查归属时用） |
| `CounterCheck` | `false` | 背包计数器二次确认（**仅调试用**；真实归属判定请用上面的 `CounterVeto`） |

## 5. 已知限制

1. **袋内容来源**（原生 API 读不到袋内容：官方 `EntityPlayer` 文档里没有任何 Bag 相关函数）
   - **装了 REPENTOGON 时（推荐）**：自动检测 `EntityPlayer:GetBagOfCraftingContent()`，逐帧直接读取真实 8 格
     （返回的 `BagOfCraftingPickup` 枚举值与素材 ID 完全一致，0 = 空）。面板标题显示 `✓ … | 直读`，
     此时 `F6` / `F9` 不需要，也不会再改动袋内容；日志：`[CainsBag] bag source: direct read (REPENTOGON)`、
     `[CainsBag] bag synced (direct): [...]`。
   - **没装 REPENTOGON 时**：退回事件模拟（日志：`bag source: event simulation (vanilla API)`）：
     - **归属语义（step4，与本机 EID 的 `eid_bagofcrafting.lua` 一致）**：
       `MC_PRE_PICKUP_COLLISION` 只代表「拾取者走上去碰到掉落物」= **普通拾取**（钱 / 钥匙 / 炸弹 / 红心 / 卡槽 / 饰品），
       **不进袋**；堕化该隐**挥袋 / 吸取**把掉落物收进袋子时**不触发**该回调，
       所以「`Collect` 首帧 + 没有新鲜碰撞」才是入袋（`reason=bag-swipe`）。
     - 碰撞记录只在 `TouchFreshFrames`（默认 3 帧）内有效：玩家碰过但没拿走（满血红心、卡槽满的卡牌等）
       随后被袋子吸收，仍会正确计入；其它玩家（2P）/ 使魔 / Bumbino / Ultra Greed 碰到 → 不计入；
       没有合成袋的玩家 → 一律不计入（`no-bag`）。
     - 无碰撞、但附近有比玩家更近的使魔 / 乞丐 / 老虎机（`CollectorRadius`）→ 判为 `collector-near` 跳过
       （防御：个别使魔可能不触发碰撞回调）。
     - **计数器 / 槽位否决（`CounterVeto`）**：钱 / 钥匙 / 炸弹 / 纯红心变多，或卡牌 / 药丸槽签名变化 ⇒
       这次确实是普通拾取 ⇒ 撤销刚才乐观写入的素材并重算（日志 `skip collect ... reason=counter|card`、
       `bag reverted after counter veto: [...]`；没被撤销的会打 `veto passed ...`）。
       这样即使某些拾取没有碰撞回调（实测 T.Cain 走路捡东西也不触发），也不会把玩家自己吃掉的东西记进袋子。
       计数器快照用**单调帧**计时（房间帧号换房会归零，取“事件发生前”的快照会失效——这是金币被误记的根因）。
     - 去重 key 用 `InitSeed`；换房后清表 + 前 2 帧不判定；
     - 每条拾取都会打一行归属证据日志（`DebugAttribution`）：
       `attr seed=.. index=.. ids=.. touch=player|other-player|familiar|slot|none touchAge=.. playerDist=.. nearest=.. nearestType=.. charge=.. counters=coin=..,key=..,bomb=..,redHeart=.. bag=n/8 verdict=confirm|skip reason=..`
       （`charge=` 是 `GetActiveCharge()/GetActiveMaxCharge()` 探针，只记录不参与判定，便于核对袋内容量）；
       若「判成普通拾取而跳过」之后袋容量反而上涨，会额外打一条
       `WARN: bag charge rose after skip (reason=...)`，说明本机版本的归属语义可能与预期相反，
       把 `config.Attribution` 改成 `"legacy"` 即可对比。
     - 中途启用模组、继续存档、复活（`player init`）都会把状态置为「未知」，按 `F9` 照游戏内实际 8 格录入即可。
     - **合成后自动清空（不用按 `F6`）**：三个信号取并集，任一命中就清空袋模拟并把可信度置为 `known`：
       1. **道具数 +1**（合成出被动道具）：`craft detected: collectibles X -> Y, bag was [...]` + `bag cleared: craft`；
       2. **袋子被顶掉**（合成出主动道具、且没有第二个主动槽）：`HasCollectible(710)` 变 false
          → `bag cleared: craft-bag-lost`；
       3. **主动道具槽的 itemID 变化**（玩家已经有另一个主动道具，例如书包的两个主动槽：
          新主动会顶掉那个槽，道具总数不变、袋子也还在）：`craft detected: active slots 710/105 -> 710/400, bag was [...]`
          → `bag cleared: craft-active`。
       只有在袋模拟的格子用完时才需要 `F6`（例如中途启用模组、续档后想同步一次）。
     - 残留边界：站在「拿不起来的掉落物」上（满血红心等）挥袋时，碰撞每帧刷新会把这次吸收判成普通拾取；
       货币类由计数器否决兜住，卡牌 / 药丸由槽位否决兜住；电池没有可读信号，仍可能多记一次（与 EID 行为一致）。
     - **已知未修（偶发）**：连续快速吸取多个掉落物时，极少数情况下会漏记其中一两个（挥袋动画同帧重叠 +
       归属证据缺失）。可用 `F9` 手工补正；排查方向见 §8 的 `attr` / `skip collect` 日志。
   > 实机已确认的事实（2026-11）：`MC_PRE_PICKUP_COLLISION` 在 T.Cain **走路捡东西时也不触发**（日志 `touch=none`），
   > 所以归属主要靠"计数器/槽位否决"兜底；`GetActiveCharge()` 不等于袋内素材数（本机恒为 0，`GetActiveMaxCharge()` 取不到），
   > 容量探针只能当参考。仍需验证：`pickup.InitSeed` 的稳定性、袋**未满**时 `ACTION_DROP` 的真实行为（轮转 / 无效 / 丢弃）。
2. **渲染 API 随版本变化**（本机实测为 Repentance+ 1.9.7，`Isaac.RenderRect` 已被移除）：
   - **字体必须先 `Font()` 再 `Font:Load(path)`**：1.9 下用 `Font(path)` 构造出来的是一个「未加载」的空字体，
     `IsLoaded()` 为 `false`，用它画字**既不报错也什么都不显示**。
     现在每个候选字体都用 `IsLoaded()` / 字宽是否大于 0 校验，校验不过就跳过，并逐条打印到 `log.txt`：
     `[CainsBag] font ok: ...` / `[CainsBag] font skip: ...`；
   - **画字优先用 `DrawStringScaledUTF8`（`str, x, y, scaleX, scaleY, color, boxWidth, renderMode`）**。
     这是本机 EID 的写法；`DrawStringUTF8` 的第 5 个参数在 1.9 里其实是「框宽」而不是缩放，
     把缩放值传进去会让换行/字距错乱（面板糊成一团、看不出是什么），所以只作旧版本回退；
   - **排版完全由字体度量推导**：`行高 = 字高 × 1.30`，能放几行就放几行，每行按宽度裁剪，
     因此「字叠在一起」或「文字溢出面板」在结构上不会发生；`Font:GetHeight()` 拿不到时用
     「中文字宽」或「ASCII 字宽 × 2.2」估算；
   - 没有矩形接口时自动降级为「文字 + 四向黑色描边」（偏移按字号缩放，不是写死 1px）；
   - 面板从屏幕高度 17% 处开始，避开左上角主动道具/卡牌槽与左下角血条；
   - 具体探测结果会打印在 `log.txt`：
     `[CainsBag] UI init: font=... drawApi=... lang=... rectApi=... h=...` 与
     `[CainsBag] render geom: screen=512x288 panel=6,48 256x178 scale=0.65 glyphH=... lineH=... rows=...`；
   - 若日志里出现多行 `font skip:` 且 `drawApi=renderText`，说明所有字体都没加载成功（1.9 的 `Isaac.RenderText`
     是空实现，面板此时不可见），请用 `config.FontPath` 指定一个确定存在的 `.fnt`。
3. **中文显示**依赖字体是否含中文字形（`Language = "auto"` 会自动探测，`F8` 可随时切换中/英）：
   - 默认按顺序尝试 `font/teammeatfont10.fnt`、`font/teammeatfont12.fnt` …，再尝试本机 ModConfigMenu-CN 自带的中文字体
     （用 require 的报错信息推算 mods 目录，拼出绝对路径 `<mods>/mod_config_menu_cn_2494192799/resources/mcm_cn_font/teammeatfont12.fnt`，
     失败再退回相对路径；都失败就自动跳过）；
   - 若面板显示为方块，按 `F8` 切到英文，或用 `FontPath` 指定任意含中文字形的 `.fnt`。
4. 掉落物 → 素材映射（`scripts/data/ingredients.lua`）来自社区逆向，个别条目可能有偏差；
   本模组只用它做素材组合与「浪费」评分，不参与任何配方结果计算。
5. 搜索是 **Beam Search（启发式）**，不保证全局最优；束宽调大可以更接近最优。
6. 非堕化该隐也能用面板，但无法轮转袋内顺序，面板提示「非该隐：顶掉需手动丢弃顺序」。
7. 商店里**未购买**的商品不计入可用素材；**购买属于普通拾取**（扣钱、进背包），按 step4 的归属语义**不计入**袋；
   只有挥袋收进袋子的掉落物才计入。入袋事件逐帧识别，扫描列表（本层素材统计）每 2 帧刷新一次。

## 6. 目录结构与上传范围

**上传用的核心代码 = `metadata.xml` + `main.lua` + `scripts/**/*.lua`**（共 11 个文件）。
公开仓库 / 发布包里也只有这 11 个文件 + `README.md` / `.gitignore` / `.gitattributes` / `tools/package.ps1`；
其余目录**只留在本地开发环境**，既不进公开仓库、也不进 zip。

```
# ---- 核心代码（会打进模组 / zip） ----
metadata.xml                -- 模组元数据
main.lua                    -- 入口：RegisterMod + 回调装配 + 输入 / 状态管理
scripts/
  config.lua                -- 热键 / 搜索参数 / 归属判定 / 显示选项
  log.lua                   -- 统一日志：**只写 log.txt**（Isaac.DebugString），不向控制台打印
  recipe.lua                -- 配方 key（8 素材多重集）唯一口径：链搜索与配方史共用
  data/ingredients.lua      -- 素材表、估值、颜色、掉落物映射
  scan.lua                  -- 扫描房间/本层掉落物 + 背包卡牌药丸 → 素材计数
  bag_tracker.lua           -- 模拟袋内 8 格（入袋归属 / 轮转 / 合成清空 / 配方史 / 校正 / 可信度）
  bag_editor.lua            -- F9 校正编辑器的状态机（不含绘制）
  chain.lua                 -- 最优放置链搜索（Beam Search + 协程分帧）
  ui.lua                    -- HUD 面板绘制（字体与渲染接口自适应）

# ---- 只留在本地（不在公开仓库里，也不上传） ----
README.md                   -- 本开发文档（工坊页面另填）
prompts/                    -- step1~5 交接文档（step1~3 勿改）
tests/                      -- 离线测试（stub + 断言 + 模糊测试 + explore_reachable_bags.py 穷举参考）
tools/package.ps1           -- 打包脚本（白名单 → dist\CainsBag + zip；文件带 UTF-8 BOM，兼容 PowerShell 5.1 的中文）
```

`tests/` 里各文件：`stub_isaac.lua`（原生 API 桩）、`test_logic.lua`（映射 / 袋模拟 / 归属语义 / 否决 /
合成清空 / 配方史 / 链搜索）、`test_bag_edit.lua`（F9 编辑器）、`test_fuzz.lua`（100 组随机场景）、
`test_main.lua`（加载 main.lua 的集成测试）、`test_ui.lua`（字体与渲染探测）、`run_tests.py` / `run_one.py` /
`check_encoding.py`（测试入口与编码检查）、`perf.lua`（最坏情况性能参考）、
`explore_reachable_bags.py`（早期穷举参考脚本，不参与自动测试）。

## 7. 开发自测

> `tests/` 与 `prompts/` 只在本地开发环境保留（`.gitignore` 已排除，公开仓库不含测试代码）。
> 需要在公开仓库里带测试时，把 `.gitignore` 里的 `tests/`、`.github/` 去掉再提交即可。

```powershell
pip install lupa          # 一次性
python tests/run_tests.py # 逻辑 + 编辑器 + 模糊 + 集成 + UI 探测
python tests/check_encoding.py  # UTF-8 无 BOM / 行尾检查
python tests/run_one.py tests.perf   # 最坏情况性能参考
```

当前结果：`run_tests.py` → **267 条断言全绿（0 失败）**；`check_encoding.py` → 28 个文件无问题。

> GitHub Actions 工作流（`.github/workflows/tests.yml`，Windows + Python 3.11/3.12）在本地保留，
> 与 `tests/` 一样不随公开仓库上传；要启用 CI 就把 `.gitignore` 里的 `tests/`、`.github/` 去掉再提交。

`tests/` 用 Lua 桩模拟原生 API，覆盖：

- 掉落物/卡牌/药丸 → 素材映射（含双素材掉落物、符文/药丸兜底）
- 袋模拟的 FIFO、轮转、双素材一次顶 2 格、合成清空
- 逐帧入袋识别（step4 归属语义）：袋吸收计入 / 玩家本人碰到不计入 / 其它玩家不计入 / 使魔不计入 / 收集者更近不计入 /
  无袋玩家不计入 / 旧触碰不阻止入袋 / 商店跳过 / `InitSeed` 去重 / 换房保护帧 / 计数器否决与回滚 / `legacy` 模式（M1）
- 归属证据日志（`attr` 单行）与袋容量探针的 `WARN` 自检（测试里临时替换 `Log.Write` 捕获断言）
- 合成自动清空：道具数增加 / 袋子被合成出的主动道具顶掉 → 清空；道具数不变 → 不清理
- 合成主动道具（bug2）：已有另一个主动槽时替换该槽（道具总数不变、袋子还在）→ 按主动槽 itemID 变化
  识别并清空（`craft-active`）；袋已空时不再反复触发；袋子被顶掉仍走 `craft-bag-lost`
- 一次拾取 = 一个动作（bug1）：7 格 + 双素材只算 1 个配方、双素材只占 1 个动作、
  袋满时两次顶掉必须 FIFO 连续（重放校验会拒绝"任选两格"）
- REPENTOGON 直读：能力探测、0/1-based 兼容、直读模式下不叠加事件模拟、逐帧同步、不可用时退回事件模拟
- F9 编辑器状态机：光标边界、候选循环、确认、草稿保留 / 丢弃、`SetSlots` / `SetSlot` 全部校验分支（M2）
- 可信度四态转换：unknown / known / tracking / uncertain（含续档与复活降级）（M3）
- 扫描聚合（商店排除、拾取中排除、背包卡牌药丸）
- 链搜索：**逐步重放校验**（顶掉的素材必须真在袋里、配方统计与 `isNew` 标记一致、素材用量不超限），
  小规模与穷举最优值对比
- 100 组随机场景的模糊测试
- 配方史（step5）：`Recipe.Key` 与链搜索 / 袋模拟三处 key 口径一致；起始袋与中间落点「已出现」时不计分、不编号、
  `distinct` 不增加；浪费剪枝与末尾裁剪；空配方史时结果与改动前完全一致；
  F9 校正 / 合成清空 / `use-item` 都会记录且幂等、`Reset` 清空、按 `Tab` 不改变任何状态
- 加载 `main.lua` 后连续 400 帧 update + render 的集成冒烟测试
- 字体探测：模拟 1.9 的「`Font(path)` 返回空字体」「`DrawStringUTF8` 第 5 参是框宽」两处坑，
  校验代码只接受真正加载出字形的字体、优先用 `DrawStringScaledUTF8`，并检查实机 512×288 坐标系下
  面板不越界、行高不小于字高（不会叠字）、不压住左上角道具槽，以及面板隐藏时不绘制

## 8. 日志速查（`log.txt` 里 grep `[CainsBag]`）

| 日志行 | 含义 / 怎么用 |
| --- | --- |
| `bag source: direct read (REPENTOGON)` / `bag source: event simulation (vanilla API)` | 当前袋内容来源（装没装 REPENTOGON） |
| `bag state: known -> tracking (collect)` | 可信度流转（`unknown/known/tracking/uncertain`） |
| `attr seed=.. index=.. ids=.. touch=.. verdict=.. reason=..` | **每条拾取的归属证据**（一次一条）。`touch` 看是谁碰的，`verdict=confirm/skip` + `reason` 看结论；带 `counters=` 与 `bag=n/8` 便于对照游戏内 HUD |
| `collect seed=.. ids=.. src=player reason=bag-swipe` | 计入袋内（`bag-swipe` = 挥袋/吸取吸收） |
| `skip collect ... reason=player-pickup|other-player|not-player|collector-near|shop|no-bag` | 未计入及原因 |
| `veto passed ... now=coin=X before=coin=X` | 20 帧内没看到"普通拾取"的迹象 → 认定已入袋 |
| `skip collect ... reason=counter 普通拾取：coin=0 -> coin=1` + `bag reverted after counter veto: [...]` | 计数器否决：先记后撤（这次其实是普通拾取） |
| `skip collect ... reason=card 卡牌/药丸槽变化：...` | 卡牌/药丸进了背包而不是袋子 |
| `craft detected: collectibles X -> Y, bag was [...]` + `bag cleared: craft` | **合成完成 → 袋模拟自动清空**（不用按 F6） |
| `craft detected: bag replaced by a crafted active item` | 合成出主动道具，袋子被顶掉 → 同样自动清空 |
| `craft detected: active slots 710/105 -> 710/400, bag was [...]` + `bag cleared: craft-active` | **已有另一个主动道具**（书包等双主动槽）时合成主动：道具总数不变、袋子还在，靠主动槽 itemID 变化识别 → 自动清空 |
| `crafted recipe recorded: [..] (total=N reason=..)` | 袋里满 8 格的组合第一次出现 ⇒ 进配方史（口径②：不要求真的合成过）；此后不再编号 / 不计入「不同配方」 |
| `crafted recipe skipped: bag=N/8 reason=..` | 清空袋时不足 8 格（F6 / F9 / 模拟不同步）⇒ 不记录，便于排查不同步 |
| `crafted recipe unrecorded (pickup was not absorbed): [..]` | 计数器 / 卡牌槽否决撤销了这次入袋 ⇒ 同时撤销刚登记的配方 |
| `crafted history reset: ..` | 新开一局 / 续档 / 复活 ⇒ 配方史清空（不写存档） |
| `long hold: anim=<动画名> bag=n/8` | 长按合成键 20 帧的调试打点（仅记录，判定不依赖它） |
| `WARN: bag charge rose after skip (reason=...)` | 袋容量探针自检：被判成普通拾取后容量反而上涨 ⇒ 归属语义可能反了，可用 `config.Attribution = "legacy"` 对比 |
| `bag rotated: ...` / `drop pressed but bag is empty` | 丢弃键轮转（一次按键只转一格） |
| `font ok/skip`、`UI init:`、`render geom:` | 字体与渲染探测（见 §5 第 2 条） |
| `chain: distinct=.. crafted=.. windows=.. steps=.. waste=.. ms=..` | 链搜索结果与耗时（`SearchBudgetMs` 超出会分帧续算）；`crafted` = 本次链条命中「已出现过配方」的次数 |

## 9. 与 `prompts/step1.md` 的差异说明

- **配方史口径（step5）改成「出现过即拉黑」**：`prompts/step5_crafted_recipes_and_scope.md` 原文只要求在
  「真正合成（袋被清空）」时记录；实测需求是「只要在合成袋里满 8 格出现过，之后就别再推荐」——因此实现为：
  袋满 8 格的每一种来源（袋吸收 / REPENTOGON 直读 / F9 校正）都立即登记该多重集，`Clear()` 时再补登记一次
  并把「真的合成过」标出来（UI 因此分成 `（已出现）` 与 `（已合成）`）。计数器 / 卡牌槽否决回滚入袋时会撤销
  那次登记。配方史只在本局内存里有效（不读写存档），`F6` / `F9` 不清空，新局 / 续档 / 复活清空。
- 剪枝：除了「无新配方且袋多重集不变」的纯浪费动作外，不丢弃「重复配方但改变袋内容」的动作。
  原因是这类动作有时是结构调整的必经之路（先换成已见过的袋，再走向新配方），丢掉会漏掉更优链。
- 素材计数上限用 `MaxCountPerType`（默认 24）代替「单个种类最多 8」：一次袋只有 8 格，
  但整条链可以反复放入同一种素材，卡在 8 会浪费掉长链。
- 提供 `Language = "auto"` 的字体探测，避免默认字体不含中文时满屏方块。
- 2 素材掉落物按「一次拾取 = 一个动作」建模：两个素材同时进袋，**不能只拾取其中一个**，
  所以中间状态不可达 —— 只有最后一个素材才形成配方窗口，面板也只显示一行；
  袋满时两次顶掉必须是队列上相邻的两格（第 2 个只能顶掉轮转后的队首，FIFO），不允许任意挑两格。
- **拾取归属语义（step4）**：原文档假设「持袋玩家本人的拾取才进袋」，与实测相反——T.Cain 的袋子靠**挥袋 / 吸取**吸收，
  走上去捡属于普通拾取，且 `MC_PRE_PICKUP_COLLISION` 对 T.Cain **不触发**。因此实现为：
  「有新鲜碰撞 = 普通拾取 → 不计入；无碰撞的 `Collect` = 袋吸收 → 计入」，再用「计数器 / 卡牌槽否决」兜住无信号的漏判；
  `config.Attribution = "legacy"` 可切回旧行为做对照。
- **合成清空**不再依赖动画名（`PickupWalk`）与松手时序，改为「道具数 +1」或「袋子被合成出的主动道具顶掉」判定（见 §5 第 1 条），
  失败一次也不会让面板一直记着旧的 8 格。

## 10. 发布 / 上传

### 10.1 首次上传到 GitHub（已完成，留作参考）

当前远端：`https://github.com/wong-songxin/Cain-s-bag-planner`（分支 `main`，只含核心代码）。
本地的完整开发历史保存在分支 `dev-history`（含 `prompts/`、`tests/`、CI 工作流，**未推送**）。

```powershell
cd "E:\Code\MOD\Cain's-bag"          # 目录名带单引号，PowerShell 用双引号包住
git init -b main
git add .gitattributes .gitignore README.md main.lua metadata.xml scripts tools
git commit -m "Cain's Bag Planner 0.7.0：合成袋最优放置链 + 拾取归属 + 配方史（仅核心代码）"
git remote add origin https://github.com/wong-songxin/Cain-s-bag-planner.git
git push -u origin main
```

- 仓库名建议 `CainsBag`：GitHub 仓库名不接受 `'`（`Cain's-bag` 会被改成 `Cain-s-bag`），而模组目录名本来就该是 `CainsBag`；
- 仓库描述 / Topics 建议：`isaac`、`repentance`、`mod`、`tainted-cain`、`bag-of-crafting`；
- 仓库里已经有 `.gitignore`（忽略 `prompts/`、`tests/`、`.github/`、`__pycache__`、`dist/`、`*.zip` 等）——
  公开仓库只含核心代码（§6），开发用的交接文档 / 离线测试 / CI 工作流都留在本地；
- **许可证**：不写 `LICENSE` 等于"保留所有权利"，别人不能合法复用代码。要在 GitHub 上被放心使用，推荐加一份
  MIT（宽松、模组常见）或 GPL-3.0；需要的话告诉我，我把 `LICENSE` 与 README 的许可声明一起补上。

### 10.2 发布 Release（给不想用 git 的玩家）

```powershell
cd "E:\Code\MOD\Cain's-bag"
powershell -ExecutionPolicy Bypass -File tools\package.ps1
```

脚本按 **白名单** 组装核心代码（`metadata.xml` + `main.lua` + `scripts/**/*.lua`），并在打包前校验
「上传目录里不能出现非 `.lua` 文件」，把 `prompts/`、`tests/`、`tools/`、`README.md` 全部挡在外面：

```
dist\CainsBag\main.lua
dist\CainsBag\metadata.xml
dist\CainsBag\scripts\{config,log,recipe,scan,bag_tracker,bag_editor,chain,ui}.lua
dist\CainsBag\scripts\data\ingredients.lua
dist\CainsBag.zip            ← 解压后得到 mods\CainsBag\...
```

把 `dist\CainsBag.zip` 作为 Release 资产上传即可（`dist/` 已在 `.gitignore` 里，不会进仓库）。
玩家解压后应得到 `mods\CainsBag\{metadata.xml, main.lua, scripts\...}`。

### 10.3 Steam 创意工坊（可选，二选一即可）

- 游戏内 `Mods` → 选中本模组 → `Upload`，游戏会读取 `metadata.xml`；
- 上传前把 `<visibility>` 从 `Private` 改成 `Public`（**只影响工坊可见性，不影响 GitHub**）；
- `<id>` 目前是占位值，只在工坊上传流程里才需要唯一 id，纯 GitHub 分发可以不管；
- 每次发版同步改 `metadata.xml` 的 `<version>`（当前 `0.7.0`），工坊端才能正确提示更新。

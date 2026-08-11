# 瑟尔基尔 pilot_003 五问题修复 — 下一 session 接力提示词

## 背景

pilot_003 瑟尔基尔 effect_01-03 + deck UI + 2金币抽牌已落码（494 测试 PASS）。实机 UI 验证发现 5 个问题，本提示词逐一给出**根因 + 日志证据 + 代码位置 + 修复方案**。

参考日志：`battle_logs/session_log_20260808_003645.txt`（单机 PvE 教学战斗，player 装了瑟尔基尔，埋了正面牌）。

**先读 [pilot-003-selkill-effect01-2026-08-07.md 记忆](../../C:/Users/m1396/.claude/projects/f--Battle-GEAR-S/memory/pilot-003-selkill-effect01-2026-08-07.md) 了解 effect_01-03 事后语义全貌。**

---

## 问题1：维修/掩护正面牌被强制使用，应弃置抽1

### 现象
维修正面牌触发 effect_02 时，状态满（无合法维修目标）却走 force_use 让玩家使用它；掩护同理。应走 unusable_discard（弃置+瑟尔基尔抽1）。

### 根因
`ActionService._pilot_003_can_use_card`（scripts/action_core/ActionService.gd 约 936-979）对非攻击牌直接 `return true`，没检查效果 conditions / target 可用性：
```gdscript
# 攻击牌：需武器+范围 (959-978)
if String(card.def.action_type) == "攻击":
    ... 检查武器范围 ...
    return false / true
return true   # ← 辅助牌（维修/掩护/回忆/防御/反击）一律 true，太宽松
```
- 维修需"我方或相邻机甲存在未满状态"——状态满时条件不满足，应 false。
- 掩护/防御/反击是"响应窗口专用"牌（被攻击时用），主动凭空使用无意义，应 false。

### 日志证据
- 行 605-612：维修 `action_013_维修` force_use → `repair_direct checking_conditions` → **行 612 `挂起目标选择 rule=repair_target_select`**（状态满无目标却挂起等输入，动作一直卡到回合末 turn_cleanup 弃置，行 638-654）。
- 行 98-110：掩护 `action_016_掩护` force_use → `cover_effect1_direct` 执行 `extra_might -5`（无攻击上下文，-5 无意义）。

### 附带严重问题：force_use 挂起导致 PvP 不同步（问题2 根因之一）
force_use 创建的 `use_action_card` 子动作需 need_input（选武器/目标）。在**回合开始自动抽牌流程**中触发时（enemy/AI 回合或对手回合），无人响应输入，动作挂起。PvP 两端若因前置状态不同走 force_use vs unusable_discard 分支，牌堆数量/状态分歧。

### 修复方案
`_pilot_003_can_use_card` 增加对辅助牌的严格预检，**任何无法在不需人类输入下完整合法执行的牌返回 false → unusable_discard**：
1. **ConditionChecker 检查**：对该牌所有 DIRECT effect 调 `ConditionChecker.check_conditions(eff, bind_ctx, payload)`，任一不满足 → false（维修状态满时条件 fail）。
2. **target_rules 检查**：任一 effect 的 target_rules 非 `NO_TARGET`（如维修 `repair_target_select`）→ false（需选目标，自动回合无法选）。
3. **攻击上下文依赖检查**：effect 的 actions 含 `MODIFY_ATTACK_MIGHT` / `MODIFY_ATTACK_MARKERS` / `MODIFY_ATTACK_DAMAGE` 等攻击类原子，且当前无进行中 attack_action（payload 无 attack_action_id）→ false（掩护/防御凭空用无意义）。
4. **响应窗口牌黑名单**（兜底）：防御 `action_009`、掩护 `action_016`、反击 `action_010`、识破、预判等 AVAILABILITY/响应类牌——AVAILABILITY 已被现有逻辑排除（955 行 has_availability → false），但纯 DIRECT 的掩护需靠上面 (3) 拦。

**判定原则（用户口述）**：正面牌离堆时，只有"无需特定时机、无需选目标、conditions 全满足"的牌才 force_use；否则一律 unusable_discard（弃置+瑟尔基尔抽1）。这同时消除 force_use 挂起问题。

### 测试
- `test_pilot_003_selkill.gd::test_effect02_self_draw_usable` 用的是 action_001_进攻（攻击牌有目标），仍应 force_use——确保攻击牌路径不被误伤。
- 新增：维修正面牌 + 状态满 → unusable_discard；掩护正面牌非响应窗口 → unusable_discard。

---

## 问题2+3：effect_03 跳过不生效；PvP 牌堆不同步（同一根因）

### 现象
- 问题3：用复选框勾选让另一玩家跳过正面牌，但他抽牌时仍抽到正面牌（被 effect_02 拦截处理），跳过无效。"先弃置顶牌之后再抽2张"。
- 问题2：PvP 两端行动牌堆数量、牌序不一致。

### 根因（核心）
`TurnService.start_turn`（scripts/services/TurnService.gd 约 94-114）回合开始抽牌用 **`deck_service.draw_from_deck(&"action_deck", 2)`**，**绕过了 `game_actions.draw_action_cards`**：
```gdscript
# ── 5. 抽2张行动牌 ── (96-114)
var drawn_actions: Array[StringName] = []
if context.deck_service != null:
    drawn_actions = context.deck_service.draw_from_deck(&"action_deck", 2)  # ← 绕过 skip
    for card_id in drawn_actions:
        player.action_hand.append(card_id)
        ... 设 owner / zone=action_hand（触发 effect_02）...
```
`draw_from_deck` 是底层方法，**不走 `_draw_one_action_card` 的 effect_03 skip 逻辑**（GameActions.gd 约 617-672）。所以：
- **skip 不生效**（问题3）：正面牌被当普通牌抽走，zone 变 action_hand 触发 effect_02。effect_03 的 `_pilot_003_skip` / `is_pilot_003_skip_active` 完全没被查询。
- **effect_02 在自动抽牌时触发** force_use/unusable_discard 副作用（改牌堆数量、挂起子动作），PvP 两端可能分歧（问题2）。

### 日志证据
- 行 28：复选框提交跳过 `["player","enemy"]`。
- 行 88-94：enemy 回合1 TURN_START → `CARD_LEAVE_ACTION_DECK_BEFORE card_326（掩护）from action_deck to action_hand` → effect_02 force_use。**card_326（顶牌正面）被抽进 enemy 手牌，skip 没跳过它**。
- 行 595：`我方 抽 2 张行动牌: 强袭、破甲 (来源:pilot_003_unusable_compensation)`——unusable_discard 补偿抽牌改了牌堆数量。
- 行 612：维修 force_use 挂起选目标（问题2 分歧源）。

### 修复方案
1. **TurnService.start_turn 抽行动牌改用 `draw_action_cards`**（统一走 skip + effect_02 事后处理）：
   ```gdscript
   # 替换 96-114 的 draw_from_deck + 手动 append/owner/zone：
   if context.game_actions:
       context.game_actions.draw_action_cards({
           "player_id": String(player_id), "count": 2, "reason": &"turn_start"
       })
   # draw_action_cards 内部已 append + 设 owner + 设 zone=action_hand（触发 effect_02）+
   # 注册 AVAILABILITY + fire ON_CARD_DRAWN，且走 _draw_one_action_card 的 effect_03 skip。
   ```
   删掉手动 `drawn_actions`/`append`/`owner`/`zone`/`register_hand_card_availability`（draw_action_cards 都包了）。注意日志记录（137 `write_log turn_draw`）的 `drawn_actions` 需从 draw_action_cards 返回或改用 reason 跟踪——draw_action_cards 当前 fire ON_CARD_DRAWN 时点可拿抽到的牌，或让 draw_action_cards 返回 drawn 列表（看 GameActions.draw_action_cards 签名，567 行，确认是否返回）。

2. **装备牌抽牌保留 `draw_from_deck`**（119 行，装备牌无 skip/effect_02，不变）。

3. **配合问题1修复**（_pilot_003_can_use_card 严格预检），消除 effect_02 在自动抽牌时的 force_use 挂起，两端确定性一致。

4. **PvP 同步验证**：改后两端 start_turn 都走 draw_action_cards，skip + effect_02 副作用两端一致（前提：effect_01 埋牌走 _net_exec 已锁步、RNG 种子同步）。effect_01 的 `pilot_003_insert_face_up_random` 用 `context.rng.randf()`（GameActions 约 2733）——确认走 _net_exec 锁步且两端 RNG 调用次数一致（机师效果按钮走 `_net_exec("equipment_active")` → `_net_equipment_active` → effect_fire，已是锁步，见 app_root.gd 2231/1204/1415）。

### 测试
- 现有 `test_pilot_003_insert_and_skip`（test_pilot_system.gd 1049）用 `ga.draw_action_cards` 测 skip，会继续过。新增：模拟 TurnService.start_turn 抽牌 + skip 开启 → 顶牌正面被跳过留牌堆、不触发 effect_02。

---

## 问题4：效果按钮合并为2个 + effect_03 随时可点提交生效

### 现状
`equipment_panel.gd`（约 290-342）为机师的每个 effect 建一个圆形按钮（编号 1/2/3）：
- effect_01（公开埋牌，DIRECT）→ 可点按钮
- effect_02（离堆强制使用，LISTEN 被动）→ 置灰按钮（`is_passive=true`，只悬停描述）
- effect_03（跳过公开牌，DIRECT）→ 可点按钮

### 用户要求
- **effect_02 是被动效果，做成描述说明，不要按钮**（现在那个置灰按钮多余）。
- **一共2个可点按钮**：按钮1=effect_01（埋牌），按钮2=effect_03（跳过复选框）。
- **effect_03 任何时候都能点，但需要提交（复选框确认）才更新生效**（去掉每回合1次 + 主阶段限制）。

### 修复方案
1. **equipment_panel 渲染机师效果按钮时跳过 LISTEN 被动 effect**（effect_02 mode=LISTEN）：不生成按钮，其描述合并到 effect_01 按钮的悬停浮框，或单独描述区。改 equipment_panel.gd 约 290-342 的循环：`if eff.mode == _TC.MODE_LISTEN: continue`（不建按钮），描述可加到面板的机师信息区。

2. **effect_03 去掉限制**（ActionPilotEffects.gd 931-951）：
   - 删 `p003e3.once_per_turn_key = &"pilot_003_effect_03"`（942）和 `once_per_turn_max`。
   - 删 `set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}])`（943-945）→ 改 `set_conditions([])`（任何时候可点）。
   - effect_03 的 actions 是 `[CHOOSE_MANY_PLAYERS]`（949），点按钮 → 弹复选框 → 提交 → `set_pilot_003_skip_players` 整组覆盖（已是"提交才生效"语义，无需改）。

3. **按钮编号**：effect_01 显示"1"，effect_03 显示"2"（去掉 effect_02 后重新编号，或直接用 effect 序号 1/3 但跳过 2 显示——用户要"2按钮"，建议显示 1/2）。

### 注意
- effect_01 保留 `once_per_turn_key` + `IS_OWNER_MAIN_PHASE`（每我方回合1次、主阶段，不变）。
- effect_02 的置灰按钮去掉后，确保 effect_02 的 LISTEN 监听器仍正常注册（按钮只是 UI，不影响 effect 注册，注册走 `_register_pilot_effects`）。

---

## 问题5：进游戏第一回合 UI 不刷新，要点地图才显示

### 现象
每次进游戏后的第一回合，回合开始抽的新行动牌、获得的2金币不显示，得等一会、点击地图后才刷新出真实状态。

### 根因
`_start_tutorial_battle`（scripts/app/app_root.gd 354-378）中 **`start_turn("player")`（375）在 `_show_battle()`（378）之前调用**：
```gdscript
var start_result = battle.start_tutorial(registry)   # 371
var turn_result = battle.start_turn("player")         # 375 ← 先 start_turn
_show_battle()                                         # 378 ← 后建面板
```
start_turn 内 fire 的时点（TURN_START/TURN_AFTER_START，TurnService 85/148）在**面板未建、UI 信号未连接**时触发，UI 刷新丢失。`_show_battle` 末尾虽调 `_refresh_battle()`（1900），但 start_turn 期间 deferred 操作（call_deferred resume 等）未跑完，首帧显示不完整，要点地图（`_on_battle_hex_clicked` 触发刷新）才补齐。

**对比 PvP 流程顺序正确**（app_root.gd 596-598）：
```gdscript
_show_battle()                              # 597 先建面板连信号
var turn_result = battle.start_turn("player")  # 598 后 start_turn（timing 信号能正常触发 UI 刷新）
```
注释还写"先刷新一遍让 set_pilot 数值生效"。

### 修复方案
调换 PvE `_start_tutorial_battle` 的顺序，与 PvP 一致：
```gdscript
var start_result = battle.start_tutorial(registry)
if not _status_ok(start_result):
    _show_status("战斗启动失败: %s" % _status_message(start_result))
    return
_show_battle()                                    # 先建面板连信号
var turn_result = battle.start_turn("player")     # 后 start_turn
if not _status_ok(turn_result):
    battle.log.append({"message": "玩家回合启动失败", ...})
```
若调换后仍有 deferred 时序残留，在 start_turn 后加一次 `call_deferred("_refresh_battle")` 或 `await get_tree().process_frame` 后刷新。参考 PvP 流程验证无回归。

### 验证
启动教学战斗，第一回合进入即显示新抽行动牌 + 2金币，无需点击地图。

---

## 约束（用户口述，必须遵守）

1. **不要用 Agent（subagent）**。不要用 python3，用 python。自己用 Read/Grep/Edit/Bash 干活。
2. **所有面向用户回复用中文**（用户看不懂英文）。
3. **要保证先前测试全部通过无引入回归**（当前基线 494 PASS）。改完跑：
   ```bash
   timeout 150 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd 2>&1 | grep -iE "FAIL|TESTS (PASSED|FAILED)|Parse Error"
   ```
   每次测试后 timeout 即时关闭防爆内存。
4. **操作中不懂不确定就问**（过程中商量，不要停了再问），多问少错。
5. **不要质疑用户列出的问题，问题都存在。**
6. Godot 在 `F:\Godot_4.6\Godot_v4.6-stable_win64.exe`。
7. **坑提醒**（上 session 踩过）：
   - Edit tool 在 CRLF+中文大文件（ActionService.gd / app_root.gd）匹配常失败（box-drawing 字符 ── + 中文 + CRLF + em-dash ——），**用 python 按函数签名锚点/行级切片替换整块**，不要硬匹配中文注释。
   - action_003 是"猛击"非"闪击"（闪击=action_006）。action_009=防御、action_010=反击、action_013=维修、action_016=掩护。
   - 注释里的 `--` 常是两个 em-dash（U+2014）非 ASCII 连字符，contains 匹配用纯 ASCII token。

## 建议执行顺序

1. **问题5**（最简单，调换2行顺序，立即改善体验）→ 跑测试。
2. **问题2+3**（TurnService 改 draw_action_cards）→ 跑测试 + 新增 start_turn skip 测试。
3. **问题1**（_pilot_003_can_use_card 严格预检，消除 force_use 挂起）→ 跑测试 + 新增维修/掩护 unusable 测试。
4. **问题4**（按钮合并 + effect_03 去限制）→ 实机 UI 验证。
5. 全量回归 494+ → 实机 PvP 双窗口验证牌堆同步。
6. 更新记忆 [pilot-003-selkill-effect01-2026-08-07.md](../../C:/Users/m1396/.claude/projects/f--Battle-GEAR-S/memory/pilot-003-selkill-effect01-2026-08-07.md)。

## 关键代码位置索引

| 位置 | 文件 | 说明 |
|------|------|------|
| `_pilot_003_can_use_card` | scripts/action_core/ActionService.gd ~936-979 | 问题1 修复点（预检过宽） |
| `_handle_pilot_003_immediately_use` | scripts/action_core/ActionService.gd ~910-930 | effect_02 入口（移标签→can_use?force:discard） |
| `TurnService.start_turn` 抽牌 | scripts/services/TurnService.gd ~94-114 | 问题2+3 修复点（draw_from_deck→draw_action_cards） |
| `draw_action_cards` | scripts/effect_core/GameActions.gd ~567 | 含 skip + effect_02 的统一抽牌入口 |
| `_draw_one_action_card` | scripts/effect_core/GameActions.gd ~617-672 | effect_03 skip 逻辑（找首张非正面牌） |
| `pilot_003_effect_03` 定义 | scripts/generated_database/ActionPilotEffects.gd ~931-951 | 问题4 修复点（去 once_per_turn/phase） |
| `pilot_003_effect_01` 定义 | scripts/generated_database/ActionPilotEffects.gd ~881-905 | 保留 once_per_turn 不变 |
| 机师效果按钮渲染 | scripts/ui/equipment_panel.gd ~290-342 | 问题4 修复点（跳过 LISTEN 被动建按钮） |
| `_start_tutorial_battle` | scripts/app/app_root.gd ~354-378 | 问题5 修复点（start_turn/_show_battle 顺序） |
| `_show_battle` | scripts/app/app_root.gd ~1644-1900 | 末尾 _refresh_battle（1900） |
| PvP 启动顺序（参考） | scripts/app/app_root.gd ~596-598 | _show_battle 先、start_turn 后（正确） |
| `_on_equipment_active_clicked` | scripts/app/app_root.gd ~2228-2231 | 机师效果按钮→_net_exec("equipment_active") 锁步 |
| `is_pilot_003_skip_active` | scripts/generated_database/ActionPilotEffects.gd ~383-387 | skip 查询（遍历所有 source） |

# 瑟尔基尔 pilot_003 — effect_02 事后重写 · 下一 session 接力提示词

> 上一 session 上下文耗尽，effect_02「事后语义」重写进行到一半。本文件是接力交接，读完即可动手。
> 本 session 已完成的代码改动全部保留在磁盘上（未提交）。下文「已完成」「待做」清单核对磁盘实际状态即可。

---

## 0. 任务总览

实现 **瑟尔基尔 pilot_003**（联邦 SSR，cost 15, attack_limit 1, action_card_limit 5）三个效果。权威文档三份（冲突以文档为准）：
- `new_logic/机斗战甲规则书.txt`
- `new_logic/行动牌的效果与逻辑.txt`
- `new_logic/各动作的生命周期与时点.txt`

**三效果：**
1. **effect_01 公开埋牌**（active+passive 同一按钮）：我方回合1次，选任意张行动牌正面朝上随机插入行动牌堆，可选1张置顶。被埋的牌（face_up_bury 标签，打在牌本身上，按 owner_pid 区分多瑟尔基尔）在牌堆中显示牌名。
2. **effect_02 离堆强制使用**（passive）：face_up_bury 牌离开 action_deck（被任意玩家抽走 / 从牌堆弃置）时，瑟尔基尔立即使用它；不可用则弃置 + 瑟尔基尔抽1（即使牌已在弃牌堆也抽）。
3. **effect_03 跳过公开牌**（DIRECT 复选框）：勾选的玩家（含自己）抽牌时跳过正面牌；瑟尔基尔自己勾选且本次将抽到正面牌时抽牌数+1（按"次"计：一次抽 N 张只 +1 -> N+1）。

**Plus：** 牌堆 UI 重做（默认显"未知牌"+序号，tagged face-up 显牌名）+ 新增"2金币抽牌"按钮（付费抽牌，每我方回合1次，与 sell 按钮并排，所有玩家都有此基础效果）。

---

## 1. effect_02 事后语义（核心，上一 session 中途被用户纠正过，别再搞错）

**卡片先进抽牌者手牌，再被瑟尔基尔拿走。抽牌者不补抽。**

- 抽牌路径（`draw_action_cards` / `TurnService`）正常把牌 append 进抽牌者 action_hand + 设 owner=抽牌者，**然后**设 zone=action_hand。
- 设 zone 时 `CardInstance.zone` setter 检测到 `old==action_deck && new!=action_deck && has_tag(face_up_bury)` -> emit `left_action_deck` 信号。
- 信号 -> `DeckService._fire_pilot_003_card_leave_deck` -> fire `CARD_LEAVE_ACTION_DECK_BEFORE` 时点。
- effect_02（LISTEN，listen_timing=CARD_LEAVE_ACTION_DECK_BEFORE, listen_action_type=card_zone_change）监听器执行 actions -> `IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK` 原子 -> `_handle_pilot_003_immediately_use`：
  - 可用 -> `_pilot_003_force_use`：从抽牌者手牌移除 + 改 owner=瑟尔基尔（"牌归瑟尔基尔先用"，owner==执行者根本不进 pilot_009 受控校验分支，**与 009 无关，不是"绕过 009"**）+ 直接调 use_action_card（**不手动设 temp_zone**，由 use_action_card 动作的 _step_card_to_temp_zone 把牌放入瑟尔基尔临时区使用；passive，source_action_id 非空不消耗攻击数）。"不拿走"=不把牌加进瑟尔基尔 action_hand，直接进使用流程。
  - 不可用（迎击牌无响应窗口 / 攻击牌无合法武器目标 / 机甲 destroyed）-> `_pilot_003_unusable_discard`：discard_card（已在弃牌堆则跳过）+ 瑟尔基尔抽1。
- **抽牌者不补抽**（"当然不补抽，这是瑟尔基尔的核心玩法"）。
- zone setter 监控覆盖**所有**离堆路径（draw / 直接 pop / 从牌堆弃置），pilot_006/007/觉醒的直接 pop 也自动触发。用户已确认先不管 006/007 旧的错，靠这套机制保证未来正确。

---

## 2. 已完成代码改动（磁盘上已改，别重改）

### `scripts/runtime/CardInstance.gd`
- tags 系统：`tags` 字典 + `_tag_key()` + `add_tag/has_tag/get_tag/get_tag_owners/remove_tag`（按 `tag@owner_pid` 键，多瑟尔基尔去歧义）+ `is_face_up_in_deck()` + `get_face_up_tag_owner()`。
- **zone setter 监控**（effect_02 关键）：
  ```gdscript
  var _zone: StringName = &""
  var zone: StringName:
      get:
          return _zone
      set(value):
          if value == _zone:
              return
          var old := _zone
          _zone = value
          if old == &"action_deck" and value != &"action_deck" and has_tag(&"face_up_bury"):
              left_action_deck.emit(self)
  signal left_action_deck(card: CardInstance)
  ```

### `scripts/effect_core/GameActions.gd`
- `pilot_003_insert_face_up_random`（~2675）：已迁移到 face_up_bury 标签 + `deck_top_card_id` 置顶参数。非顶随机插入先，顶牌插 index0 最后。
- `_p003_mark_face_up`（~2707）：add_tag(face_up_bury, owner_pid, {source, mech_id, face_up:true}) + connect `left_action_deck` -> `DeckService._fire_pilot_003_card_leave_deck` + 设 zone=action_deck。
- `draw_action_cards`（~567）：已重排为「append+owner 后设 zone=action_hand」触发 effect_02 事后处理；只对仍留在 action_hand 的牌注册 AVAILABILITY / fire ON_CARD_DRAWN。skip 判定已用 `is_face_up_in_deck()`。
- effect_03 skip 逻辑（~582-601）已在：`is_pilot_003_skip_active` / `is_pilot_003_self_skip_active` / `_pilot_003_skip` 字典。

### `scripts/services/DeckService.gd`
- `draw_from_deck`（22）：已删 predict-intercept while 循环 + counters 检查。action_deck 的 zone 不在此设（由调用方 append+owner 后设）。
- `_fire_pilot_003_card_leave_deck`（57）：已重写为信号 handler（接 CardInstance，建虚拟 action_type=card_zone_change，record.player_id=card.owner_player_id=当前持有者，fire CARD_LEAVE_ACTION_DECK_BEFORE）。

### `scripts/services/TurnService.gd`
- action_deck 抽牌路径已同样重排（append+owner 后设 zone=action_hand 触发 effect_02）。

### `scripts/action_core/ConditionChecker.gd`
- `PAYLOAD_CARD_HAS_RUNTIME_TAG`（121）：已改 `card.has_tag(rt_tag)`。

### `scripts/action_core/ActionUIBridge.gd`
- 已加 `&"select_pilot_003_choose_top"` case -> request_ui_popup.emit（effect_01 phase 链置顶窗）。

### `scripts/action_core/TimingEngine.gd`
- CHOOSE_MANY resume store_next_phase 分支：存 pending_effect phase=pilot_003_choose_top，弹 select_pilot_003_choose_top 窗。
- `pilot_003_choose_top` resume：存 payload["pilot_003_top_card_id"]，mark once_per_turn/once_per_game，续跑 _seq INSERT。
- 已删 dead `CHOOSE_ONE_INSERTED_CARD_TO_DECK_TOP` handler。

### `scripts/ui/unite_attack_select_panel.gd`
- 已通用化：configure(game_context, card_ids, label, card_suffix, confirm_verb, cancel_label)。effect_01 复用为置顶选择窗。

### `scripts/app/app_root.gd`
- 已加第二 UniteAttackSelectPanel 实例 + `pilot_003_choose_top_panel` + routing case + completed/cancelled handlers + popup 栈/owner 列表。

### `scripts/generated_database/ActionPilotEffects.gd`
- effect_01（~884）：phase 链 [CHOOSE_MANY(store_next_phase=pilot_003_choose_top) + INSERT(deck_top_card_id=$runtime.pilot_003_top_card_id)]。
- effect_02（~912）：mode LISTEN, listen_timing=CARD_LEAVE_ACTION_DECK_BEFORE, listen_action_type=card_zone_change, 条件 PAYLOAD_CARD_HAS_RUNTIME_TAG(face_up_bury) + PAYLOAD_FROM_ZONE_IS(action_deck), actions=[CANCEL_PARENT_CARD_TRANSFER, IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK]。**CANCEL 现已是 no-op**（写 pilot_003_intercepted counter 无人读，见待做#3）。
- effect_03（~935）：CHOOSE_MANY_PLAYERS + SET_PILOT_003_SKIP_PLAYERS。

---

## 3. 待做 #1（核心）：重写 ActionService effect_02 三 handler（事后语义）

文件：`scripts/action_core/ActionService.gd`。三 handler 当前还是 **predict-intercept 旧逻辑**（假设牌被 draw_from_deck 弹出、不在任何区域数组、force_use 直接设 temp_zone、unusable_discard 假设牌浮空）。要改成事后语义（牌在抽牌者手牌）。

**坑（重要）：Edit 工具在这个 CRLF+中文大文件上经常匹配失败（box drawing 字符 ── U+2500 + 中文 + CRLF 混合）。上一 session 的 python 替换脚本 old1 也因编码匹配失败没跑通。建议下个 session 用 python 按函数签名锚点切片替换整块（避免匹配中文注释）：用 `t.find("func _handle_pilot_003_immediately_use")` 定位起始，用下一个函数签名 `func _pilot_003_can_use_card` 定位结束，切片替换。force_use 用 `func _pilot_003_force_use` 到 `func _pilot_003_unusable_discard`，unusable_discard 用 `func _pilot_003_unusable_discard` 到 `func _build_source_info_from_parent`。**

### 目标代码 1：`_handle_pilot_003_immediately_use`（含其上方注释）
```gdscript
## ── pilot_003 effect_02 离堆强制使用 helper（事后语义）──
## IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK：face_up_bury 牌 zone 从 action_deck 变走时
## （CardInstance.zone setter emit left_action_deck -> _fire_pilot_003_card_leave_deck
##  fire CARD_LEAVE_ACTION_DECK_BEFORE -> effect_02 监听器执行本原子）事后处理。
## 牌此时已进入抽牌者手牌（被抽走，zone=action_hand，owner=抽牌者）或弃牌堆（从牌堆弃置）。
## 流程：移除 face_up_bury 标签 + disconnect 离堆信号 -> 判断对瑟尔基尔是否可用 ->
##   可用：从抽牌者手牌移除 + 重指向 owner=瑟尔基尔 + 进临时区 + use_action_card；
##   不可用：discard_card（已在弃牌堆则跳过）+ 瑟尔基尔抽1。
## 抽牌者不补抽（瑟尔基尔核心玩法）。
func _handle_pilot_003_immediately_use(params: Dictionary) -> void:
	if context == null or context.game_state == null or context.game_actions == null:
		return
	var card_id: StringName = params.get("card_instance_id", &"")
	if card_id == &"":
		return
	var card = context.game_state.get_card(card_id)
	if card == null:
		return
	# 使用者 = 埋牌者（移标签前从 face_up_bury 标签读 owner_pid/mech_id）
	var face_tag: Dictionary = card.get_tag(&"face_up_bury")
	var owner_pid: StringName = StringName(face_tag.get("owner_pid", &""))
	var owner_mech_id: StringName = StringName(face_tag.get("mech_id", &""))
	# 移除标签（防后续 zone 变化再触发）+ disconnect 离堆信号（_p003_mark_face_up 时 connect 的）
	card.remove_tag(&"face_up_bury")
	if context.deck_service != null and card.left_action_deck.is_connected(Callable(context.deck_service, &"_fire_pilot_003_card_leave_deck")):
		card.left_action_deck.disconnect(Callable(context.deck_service, &"_fire_pilot_003_card_leave_deck"))
	if owner_pid == &"" or owner_mech_id == &"":
		_pilot_003_unusable_discard(card_id, &"", &"")
		return
	var owner_mech = context.game_state.mechs.get(owner_mech_id)
	if _pilot_003_can_use_card(card, owner_mech):
		_pilot_003_force_use(card_id, owner_pid, owner_mech_id)
	else:
		_pilot_003_unusable_discard(card_id, owner_pid, owner_mech_id)
```
> 关键变化：移标签 + disconnect **上移到判断之前**（原来在 force_use/unusable_discard 里移）。这样 force_use 设 temp_zone 时 setter 不再 emit（标签已无），避免重复触发。`_pilot_003_can_use_card` 不读标签（看 card.def/owner_mech），移标签不影响判断。

### 目标代码 2：`_pilot_003_force_use`
```gdscript
## 强制使用：牌归瑟尔基尔先用，直接走 use_action_card 动作（主动使用），由动作把牌放入瑟尔基尔临时区使用。
## 事后语义：牌在抽牌者手牌（owner=抽牌者）。force_use 先从抽牌者手牌移除 + 改 owner=瑟尔基尔
## （"这个牌就该他先用"；owner==执行者，根本不涉及 pilot_009 受控使用校验），然后直接调
## use_action_card——**不手动设 temp_zone**，由 use_action_card 的 _step_card_to_temp_zone 把牌移入瑟尔基尔临时区。
## passive 攻击，source_action_id 非空跳过攻击数消耗/校验。
## face_up_bury 标签已由 _handle_pilot_003_immediately_use 移除。
## "不拿走"=不把牌加进瑟尔基尔 action_hand，而是直接进使用流程（临时区->使用->结算弃）。
func _pilot_003_force_use(card_id: StringName, owner_pid: StringName, owner_mech_id: StringName) -> void:
	if context == null or context.action_service == null:
		return
	var card = context.game_state.get_card(card_id)
	if card != null:
		# 从抽牌者手牌移除（owner=抽牌者 != 瑟尔基尔 时）；瑟尔基尔自己抽到自己埋的牌则无需移
		var drawer_pid: StringName = card.owner_player_id
		if drawer_pid != &"" and drawer_pid != owner_pid:
			var drawer = context.game_state.players.get(drawer_pid)
			if drawer != null:
				drawer.action_hand.erase(card_id)
		# 牌归瑟尔基尔先用（owner==执行者，不进 pilot_009 受控使用校验分支，与 009 无关）
		card.owner_player_id = owner_pid
		# 不设 temp_zone：由 use_action_card 的 _step_card_to_temp_zone 放入瑟尔基尔临时区
	context.game_state.write_log(&"pilot_003_force_use", {
		"card_id": String(card_id),
		"player_id": String(owner_pid),
	})
	context.action_service.execute(&"use_action_card", {
		"card_instance_id": card_id,
		"player_id": owner_pid,
		"mech_id": owner_mech_id,
		"source_action_id": &"pilot_003_force_use",
		"reason": &"pilot_003_force_use",
		"executor": &"pilot_003_force_use",
	})
```
> 关键变化 vs 旧 predict-intercept 逻辑：①从抽牌者 action_hand erase（牌物理在抽牌者手牌）；②改 owner_player_id=瑟尔基尔（牌归瑟尔基尔先用，owner==执行者不触发 009 校验，**不要理解成"绕过 009"**——是根本不进那个分支）；③**不手动设 temp_zone**，让 use_action_card 动作的 step ②`_step_card_to_temp_zone` 把牌移入瑟尔基尔临时区（"直接走使用行动牌动作，把该牌放入瑟尔基尔临时区去使用"）。erase 是必须的（牌要从抽牌者手牌消失），否则改 owner 后牌脏留在抽牌者手牌数组 + 临时区重复存在。

### 目标代码 3：`_pilot_003_unusable_discard`
```gdscript
## 无法使用回退：公开弃置该正面牌 + 瑟尔基尔拥有者抽1。
## 事后语义：牌在抽牌者手牌（被抽走）或弃牌堆（从牌堆弃置）。discard_card 经
## remove_card_from_all_zones 自动从抽牌者手牌移除入弃牌堆；已在弃牌堆则跳过（不重复弃置
## 致离场效果二次触发）。瑟尔基尔抽1（即使牌已在弃牌堆也抽）。face_up_bury 标签已由
## _handle_pilot_003_immediately_use 移除。
func _pilot_003_unusable_discard(card_id: StringName, owner_pid: StringName, _owner_mech_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	var card = context.game_state.get_card(card_id)
	var already_discarded: bool = card != null and card.zone == &"discard"
	context.game_state.write_log(&"pilot_003_unusable", {
		"card_id": String(card_id),
		"player_id": String(owner_pid),
	})
	if not already_discarded and context.deck_service != null:
		context.deck_service.discard_card(card_id, &"pilot_003_unusable_face_up_card")
	if owner_pid != &"":
		context.game_actions.draw_action_cards({"player_id": owner_pid, "count": 1, "reason": &"pilot_003_unusable_compensation"})
```
> 关键变化：加 already_discarded 守卫（牌可能从牌堆直接弃置触发 effect_02，此时 zone 已是 discard，不再重复 discard_card 致离场效果二次触发）。discard_card 内部 remove_card_from_all_zones 自动从抽牌者手牌移除，无需手动 erase。

---

## 4. 待做 #2：跑全量测试 + 修 test27/30/31 语义

测试命令（Windows，headless，用 timeout 即时关 Godot 防爆内存）：
```bash
timeout 120 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd
```
当前全量基线约 485 PASS（step1 完成时全过）。改完 handler 后跑全量。

`tests/test_pilot_system.gd`：
- test27（~1049）：已改 `is_face_up_in_deck()`，可能 OK，跑测试看。
- **test30（~1164）/ test31（~1220）**：原基于 predict-intercept 旧语义（抽牌者补抽 / 牌不入手 / 直接调 pilot_003_move_to_deck_top）。要改事后语义断言：牌进抽牌者手牌 -> 被 effect_02 移走 -> 抽牌者手牌少这张且不补抽 -> 瑟尔基尔得到（force_use）或弃牌堆+瑟尔基尔抽1（unusable）。**先读 test30/31 实际代码再改断言**，别凭记忆。

---

## 5. 待做 #3（可选清理）：effect_02 ActionPilotEffects 的 CANCEL_PARENT_CARD_TRANSFER

CANCEL_PARENT_CARD_TRANSFER 现在 no-op（写 counters["pilot_003_intercepted"]=true，draw_from_deck 已删读它的 predict-intercept 循环）。最小改动：**保留**作 no-op（actions 序列兼容，无害）。若要清理：从 effect_02 set_actions 删 CANCEL 行 + 从 ActionService._is_atomic_action 表（~210）删 `&"CANCEL_PARENT_CARD_TRANSFER"` + 删 _dispatch_atomic_action 的 CANCEL 分支（~418-426）。**非必须，建议先保留，全量过测后再清理。**

---

## 6. 待做 #4：step3 验证 effect_03 跳过完整

effect_03 skip 逻辑已在 GameActions.draw_action_cards（~582-601）：
- `is_pilot_003_skip_active(player_id)`：勾选玩家抽牌时找第一张非 face_up 牌抽。
- `is_pilot_003_self_skip_active(player_id)`：瑟尔基尔自己勾选且将抽到正面牌时 count+1。
- `_pilot_003_skip` 字典 `{source_pilot: {player_id: true}}`，toggle_pilot_003_skip / set_pilot_003_skip_players 已就位。
- 验证：跳过是否正确跳过 face_up 牌、+1 是否按"次"计（一次抽 N 张只 +1）。注意 skip 跳过的 face_up 牌仍在牌堆（没被抽走），不触发 effect_02（effect_02 只在 zone 变化时触发，skip 不改 zone）。

---

## 7. 待做 #5：step4 牌堆 UI 重做 + 2金币抽牌按钮

1. **牌堆显示**（`scripts/ui/` 找牌堆信息相关 panel，可能是 deck_info_popup 或 hand_panel 旁）：默认每张牌显示"未知牌"+序号；带 face_up_bury 标签的牌（`card.is_face_up_in_deck()`）显示 XXX 牌名。
2. **2金币抽牌按钮**：与 sell_equipment 按钮并排，所有玩家都有此基础效果。每我方回合1次，花2金币抽1张行动牌（参考 GameConfig.paid_draw_cost=2）。PvP 人类玩家可点。sell 按钮在 `sell_equipment_panel` / `hand_panel` 附近，找现有 sell 按钮位置加并排。

---

## 8. 待做 #6：step5 pilot_003 专项测试 + 全量回归

写 `tests/test_pilot_003_selkill.gd`（参考已有 tests/test_pilot_001_*.gd / test_pilot_002_rabil.gd 风格），覆盖：
- effect_01：选牌埋入 + 置顶 + face_up_bury 标签 + 牌堆显示牌名。
- effect_02 事后：敌方抽到 face_up 牌 -> 进敌方手牌 -> 瑟尔基尔拿走使用（可用）+ 抽牌者不补抽；不可用 -> 弃牌堆 + 瑟尔基尔抽1。
- effect_03：跳过 face_up 牌 + 自跳 +1。
记得在 `tests/run_tests.gd` 的测试列表里注册新文件。全量过测无回归。

---

## 9. 已验证无回归的路径（不用重测，仅作参考）

- step1 effect_01 phase 链 + choose-top UI：已实机验证 + 全量过测。
- zone setter + DeckService 信号 handler + draw_from_deck/draw_action_cards/TurnService 重排：基础设施已就位，但 effect_02 handler 还是旧逻辑，**全量测试在 handler 重写前会因 test30/31 旧语义失败或通过（取决于旧 handler 行为）**，以 handler 重写后为准。

---

## 10. 约束（用户原话，必须遵守）

- 先做 PvP 人类玩家的逻辑和 UI（要通用，无数个人类玩家也能复用）。AI 逻辑先不管。
- 不要做多余的阅读和动作，有记忆就用记忆，立即开始。
- 操作中不懂不确定就问（过程中商量，不要停了再问），多问少错。
- **不要用 Agent（subagent）。不要用 python3，用 python。**
- 要保证先前测试全部通过无引入回归。
- Godot 在 `F:\Godot_4.6\Godot_v4.6-stable_win64.exe`，每次测试后用 timeout 即时关闭防爆内存。
- 不要质疑用户列出的问题，问题都存在。
- 所有面向用户回复用中文。
- 用户看不懂英文。

---

## 11. 接力起点（建议执行顺序）

1. 读本文件 + 三份权威文档相关段。
2. **待做 #1**：用 python 按函数签名锚点切片替换 ActionService 三 handler（目标代码见上文）。先 Read 确认三 handler 当前磁盘内容，再写 python 脚本切片替换。
3. 跑全量测试（timeout 120），看 test27/30/31 结果。
4. **待做 #2**：改 test30/31 事后语义断言，再跑全量直到全过。
5. **待做 #3**（可选）：清理 CANCEL no-op。
6. **待做 #4-6**：effect_03 验证 -> deck UI + 2金币抽牌 -> 专项测试。
7. 完成后更新 memory `pilot-003-selkill-effect01-2026-08-07.md`。

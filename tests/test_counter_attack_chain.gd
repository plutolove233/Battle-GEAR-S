## test_counter_attack_chain.gd — 反击多轮连锁完整流程测试
##
## 还原并验证规则文档「反击」(第10张) 的完整场景：
##   1. 玩家A 发动攻击1 打 玩家B
##   2. 玩家B 用反击响应攻击1，执行效果1（半动力移动，跳出/未跳出攻击1范围）
##   3. 攻击1 结算
##   4. 攻击1 的「攻击结算」时点触发反击效果2，B 选择1把武器发动攻击2
##      （攻击2 目标在 B 所选武器的攻击范围内任选，不限定原攻击者A——可打 C 或 A）
##   5. 攻击2 命中 C（或 A）→ C 可用自己的迎击牌（含反击）响应攻击2
##   6. 攻击2 结算 → 若 C 用反击响应，则触发攻击3 ……（以此类推）
##
## 走完整 ActionService.execute 路径 + 输入回调（select_weapon / select_attack_target /
## select_move_target / 响应窗口），不直接构造动作对象。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const SLog = preload("res://scripts/services/slog.gd")
const _ThrustHelper = preload("res://tests/thrust_test_helper.gd")


## 等一帧，flush call_deferred 排入的动作恢复（-s 模式靠 SceneTree 主循环）。
func _frame() -> void:
	var ml = Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


## ── 测试夹具：创建带3机甲(A/B/C)的战斗 ──

func _new_battle_with_three_mechs() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_ThrustHelper.clear_thrust_from_hand(battle)
	return battle


## 新建第三个机甲 C（克隆 frame_001 结构，近战武器范围2，确保能与 B 互相攻击）
func _add_third_mech(battle: BattleState) -> _MechState:
	var gs = battle.context.game_state
	var c_player := _PlayerState.new()
	c_player.player_id = &"player_c"
	c_player.gold = 15
	gs.players[c_player.player_id] = c_player

	var mech := _MechState.new()
	mech.mech_id = &"mech_c"
	mech.owner_player_id = &"player_c"
	mech.max_hp = 25
	mech.current_hp = 25
	# 6 部件槽
	var body_slots: Array[StringName] = [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]
	for slot_id: StringName in body_slots:
		var slot = battle.context.game_state.mechs.get(&"enemy_mech").slots.get(slot_id)
		var s = _new_part_slot(slot)
		mech.slots[slot_id] = s
	# 2 武器槽
	for i: int in range(2):
		var wsid: StringName = StringName("weapon_%d" % [i + 1])
		var ws = _new_weapon_slot()
		mech.slots[wsid] = ws
	# 基础武器：近战 威力10 范围2
	mech.set_base_weapons([{
		"name": "C近战",
		"might": 10,
		"range_value": 2,
		"weapon_kind": &"近战",
	}])
	mech.max_power = 10
	mech.power = 10
	gs.mechs[mech.mech_id] = mech
	return mech


func _new_part_slot(src) -> RefCounted:
	# 复用 enemy_mech 槽位的基础数值（不引用同一对象）
	var MechSlotState = load("res://scripts/runtime/MechSlotState.gd")
	var s = MechSlotState.new()
	s.slot_id = src.slot_id
	s.slot_kind = src.slot_kind
	s.base_armor = src.base_armor
	s.base_power = src.base_power
	s.base_durability = src.base_durability
	return s


func _new_weapon_slot() -> RefCounted:
	var MechSlotState = load("res://scripts/runtime/MechSlotState.gd")
	var s = MechSlotState.new()
	s.slot_id = &"weapon_1"
	s.slot_kind = &"WEAPON"
	return s


## 把指定机甲放到指定 hex（须是地图内 normal 格子）
func _place_mech(battle: BattleState, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	mech.position = {"q": q, "r": r}


## 从牌堆/弃牌堆确保某张行动牌在指定玩家手里
func _ensure_card_in_player_hand(battle: BattleState, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	# 从牌堆找
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = player_id
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	# 从弃牌堆找
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = player_id
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## ── 输入驱动器：收集 action_needs_input 信号，按 input_type 自动回填 ──

class InputDriver:
	var context = null
	var pending: Dictionary = {}  # action_id -> {input_type, input_params}
	# 策略：weapon_id / target_id / move_cell / response 的自动选择回调
	var weapon_for: Callable = Callable()       # (action_id) -> StringName
	var target_for: Callable = Callable()       # (action_id, input_params) -> StringName
	var move_cell_for: Callable = Callable()    # (action_id, input_params) -> StringName  ("q,r")，空=取消移动
	var response_for: Callable = Callable()    # (action_id) -> Array[Dictionary]  选中的迎击牌条目；空数组=不响应
	var damage_for: Callable = Callable()       # (action_id, input_params) -> Dictionary  放置损伤回填

	func attach(ctx) -> void:
		context = ctx
		# 断开 ActionUIBridge 的信号连接：测试环境由 InputDriver 全权驱动输入回调，
		# 否则 ActionUIBridge._on_action_needs_input 会对 AI（enemy/player_c）自动响应/自动放损伤，
		# 抢先处理 respond_attack（自动选 evade 等非反击牌）并同步完成动作，导致 driver 看到的是已完成动作。
		if context.action_ui_bridge != null:
			if context.action_engine != null:
				context.action_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
			if context.timing_engine != null:
				context.timing_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
		# ActionEngine 的 input 信号：step handler 返回 need_input 时 emit（select_weapon / select_attack_target / select_move_target / place_damage_tokens 等）
		context.action_engine.action_needs_input.connect(_on_need)
		# TimingEngine 的 input 信号：响应窗口 respond_attack 由 TimingEngine._handle_response_window emit
		# （ActionEngine 不转发此信号，故必须单独连 TimingEngine 的）
		if context.timing_engine != null:
			context.timing_engine.action_needs_input.connect(_on_need)

	func _on_need(action_id: StringName, input_type: StringName, input_params: Dictionary) -> void:
		pending[action_id] = {"input_type": input_type, "input_params": input_params}

	## 推进一步：若有 pending 输入，按策略回填并 continue_action。
	## 返回 true 表示推进了至少一处；false 表示当前无待处理输入。
	func pump() -> bool:
		if pending.is_empty():
			return false
		var action_id: StringName = pending.keys()[0]
		var entry: Dictionary = pending[action_id]
		var input_type: StringName = entry["input_type"]
		var input_params: Dictionary = entry["input_params"]
		pending.erase(action_id)
		var input_data = _resolve(action_id, input_type, input_params)
		if input_data == null:
			return true  # 已由 _resolve 内部直接处理（如响应窗口走 handle_response_selection）
		context.action_service.continue_action(action_id, input_data)
		return true

	func _resolve(action_id: StringName, input_type: StringName, input_params: Dictionary):
		match input_type:
			&"select_weapon":
				return {"weapon_id": weapon_for.call(action_id)}
			&"select_attack_target":
				return {"target_id": target_for.call(action_id, input_params)}
			&"select_move_target":
				var cell: StringName = move_cell_for.call(action_id, input_params)
				if cell == &"":
					# 取消移动 → cancel 该 single_move 效果动作
					context.action_service.cancel_action(action_id)
					return null
				return {"target_cell": cell}
			&"respond_attack":
				var sel: Array[Dictionary] = response_for.call(action_id)
				context.timing_engine.handle_response_selection(action_id, sel)
				return null
			&"place_damage_tokens":
				var d: Dictionary = damage_for.call(action_id, input_params)
				if d.is_empty():
					return {"auto_placed": true}
				return d
			_:
				return {"auto": true}

	## 一直 pump 直到无 pending 且无动作在等待输入（或达到 max_iters 防死循环）。
	## 每轮 pump 后 await 一帧，flush call_deferred 排入的父动作恢复
	## （效果动作完成通知父动作是 deferred 的，同步循环无法 flush）。
	var frame_cb: Callable = Callable()  # () -> void (async, awaits a process_frame)

	func drain(max_iters: int = 400) -> void:
		var it := 0
		while it < max_iters:
			it += 1
			var progressed: bool = pump()
			if frame_cb.is_valid():
				await frame_cb.call()
			# flush deferred 后可能产生新的 pending（父动作恢复→继续→新的 need_input）
			if not pump():
				if not progressed and pending.is_empty():
					# 无 pending 且无进展——检查是否仍有动作卡在等待态
					if not _has_waiting_actions():
						break
			if pending.is_empty() and not _has_waiting_actions():
				break

	func _has_waiting_actions() -> bool:
		if context == null or context.action_registry == null:
			return false
		for aid: StringName in context.action_registry.get_active_ids():
			var a = context.action_registry.get_action(aid)
			if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
				return true
		return false


## ── 辅助：判断某机甲当前是否在另一机甲的武器范围内 ──

func _in_range(battle: BattleState, attacker_id: StringName, target_id: StringName, rng: int) -> bool:
	var gs = battle.context.game_state
	var a = gs.mechs.get(attacker_id)
	var t = gs.mechs.get(target_id)
	var _RangeCalc = load("res://scripts/battle/RangeCalculator.gd")
	return _RangeCalc.is_in_weapon_range(a.position, t.position, rng, gs.map_state.cells)


## ════════════════════════════════════════════════════════════
## 测试1：完整多轮连锁
##   A(近战r2) 打 B；B 反击响应；B 动力0→效果1移动立即结束；攻击1结算；
##   B 反击效果2 发动攻击2，B 选近战武器打 C（非原攻击者A，验证目标不锁定）；
##   攻击2 的 ATTACK_AT → C 用反击响应；攻击2结算；C 反击效果2 发动攻击3 打 A；
##   攻击3 的 ATTACK_AT → A 无迎击牌，不响应；攻击3结算。
## ════════════════════════════════════════════════════════════
func test_counter_attack_full_chain():
	var battle := _new_battle_with_three_mechs()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")   # A
	var mech_b = gs.get_mech_for_player(&"enemy")    # B
	var mech_c := _add_third_mech(battle)             # C

	# 布局：A(10,0)  B(11,0)  C(12,0) —— 三者沿 q 轴相邻，近战范围2可互打
	_place_mech(battle, mech_a.mech_id, 10, 0)
	_place_mech(battle, mech_b.mech_id, 11, 0)
	_place_mech(battle, mech_c.mech_id, 12, 0)

	# A、B 用 frame 基础武器：近战 范围2。C 近战 范围2。
	# 距离：A-B=1, B-C=1, A-C=2 —— 均在范围2内
	mech_a.power = 10
	mech_b.power = 0   # B 动力0 → 反击效果1 半动力移动立即结束，专注连锁
	mech_c.power = 0   # C 动力0 → 反击效果1 半动力移动立即结束（避免 deferred 取消移动在同步 drain 内不 flush）

	# 确保 B、C 手里各有反击牌
	var b_counter := _ensure_card_in_player_hand(battle, &"enemy", "action_010_反击")
	if b_counter == &"":
		return "B 手牌未找到反击牌"
	var c_counter := _ensure_card_in_player_hand(battle, &"player_c", "action_010_反击")
	if c_counter == &"":
		return "C 手牌未找到反击牌"

	# 记录初始 HP（用于事后验证攻击确实结算）
	var a_hp0: int = mech_a.current_hp
	var b_hp0: int = mech_b.current_hp
	var c_hp0: int = mech_c.current_hp

	# ── 构造输入驱动器 ──
	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.frame_cb = _frame

	# 武器选择：一律用第1把基础武器（frame_base_weapon_1）
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"

	# 攻击目标选择：根据当前等待的 attacker 决定
	#   - 攻击1（A发起）→ 打 B
	#   - 攻击2（B反击发起）→ 打 C（验证不锁定原攻击者A）
	#   - 攻击3（C反击发起）→ 打 A
	driver.target_for = func(aid: StringName, _params: Dictionary) -> StringName:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return &""
		var attacker_id: StringName = act.record.get("attacker_id", &"")
		match attacker_id:
			mech_a.mech_id:
				return mech_b.mech_id   # 攻击1：A 打 B
			mech_b.mech_id:
				return mech_c.mech_id   # 攻击2：B 反击 打 C
			mech_c.mech_id:
				return mech_a.mech_id   # 攻击3：C 反击 打 A
		return &""

	# 移动：反击效果1 因 B 动力0 不会请求选格；若被请求则取消（不移动）
	driver.move_cell_for = func(_aid: StringName, _params: Dictionary) -> StringName:
		return &""  # 取消移动

	# 响应窗口：
	#   - 攻击1 的窗口（被攻击方=B）→ B 用反击响应
	#   - 攻击2 的窗口（被攻击方=C）→ C 用反击响应
	#   - 攻击3 的窗口（被攻击方=A）→ A 无迎击牌，不响应
	driver.response_for = func(aid: StringName) -> Array[Dictionary]:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return []
		var target_id: StringName = act.record.get("target_id", &"")
		match target_id:
			mech_b.mech_id:
				return [{"effect_id": &"counter_availability", "card_instance_id": b_counter, "availability_priority": 5}]
			mech_c.mech_id:
				return [{"effect_id": &"counter_availability", "card_instance_id": c_counter, "availability_priority": 5}]
		# 攻击3 打 A：A 无迎击牌 → 不响应
		return []

	# 损伤放置：AI 自动（executor 非 player 时 ActionUIBridge 自动放，但测试不走 UI bridge；
	# place_damage_tokens 输入回填 auto_placed 即可让 damage_change 继续）
	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	# ── 发起攻击1：A 打 B ──
	# 直接通过 action_service.execute 发起 attack 动作（A 主动攻击，非效果触发）
	var atk1_result: Dictionary = battle.context.action_service.execute(&"attack", {
		"attacker_id": mech_a.mech_id,
		"target_id": &"",          # 走选目标流程
		"weapon_id": &"",          # 走选武器流程
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"player", "mech_id": mech_a.mech_id},
	})
	if atk1_result.get("state", &"") == &"error":
		return "攻击1 发起失败: %s" % str(atk1_result)

	# 驱动整个连锁直到全部完成
	await driver.drain(500)
	# 多 flush 几帧，确保 damage_change / hp_change 等 deferred 效果动作全部落地
	for _i in range(5):
		await _frame()

	# ── 验证 ──
	# 1) 攻击1 命中 B（B 动力0 未移动，仍在 A 范围内）→ B 受到伤害
	if mech_b.current_hp >= b_hp0:
		return "攻击1 未对 B 造成伤害（b_hp %d→%d），反击效果1/攻击1结算异常" % [b_hp0, mech_b.current_hp]

	# 2) 攻击2（B反击打C）应已发生 → C 受到伤害
	if mech_c.current_hp >= c_hp0:
		return "攻击2（B反击打C）未对 C 造成伤害（c_hp %d→%d），反击效果2未触发或目标选择失败" % [c_hp0, mech_c.current_hp]

	# 3) 攻击3（C反击打A）应已发生 → A 受到伤害
	if mech_a.current_hp >= a_hp0:
		return "攻击3（C反击打A）未对 A 造成伤害（a_hp %d→%d），C的反击效果2未触发" % [a_hp0, mech_a.current_hp]

	# 4) 所有动作应已结算（无残留 waiting 动作）
	var active_ids: Array = battle.context.action_registry.get_active_ids()
	var waiting: Array = []
	for aid: StringName in active_ids:
		var a = battle.context.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	if not waiting.is_empty():
		return "连锁结束后仍有动作处于等待态: %s" % str(waiting)

	return true


## ════════════════════════════════════════════════════════════
## 测试2：反击效果2 的目标不锁定原攻击者——显式验证「可打范围内任意机甲」
##   A(近战r2) 打 B；B 反击响应（动力0 不移动）；攻击1结算；
##   B 反击效果2 发动攻击2，B 的目标选择窗口应同时列出 A 与 C（均在 B 范围2内），
##   测试选择 C（非原攻击者 A）并命中。
## ════════════════════════════════════════════════════════════
func test_counter_effect2_target_not_locked_to_attacker():
	var battle := _new_battle_with_three_mechs()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")
	var mech_b = gs.get_mech_for_player(&"enemy")
	var mech_c := _add_third_mech(battle)

	# 布局：B(10,0) 居中，A(9,0)、C(11,0) 分列两侧——A、C 距 B 均1，在 B 范围2内
	_place_mech(battle, mech_b.mech_id, 10, 0)
	_place_mech(battle, mech_a.mech_id, 9, 0)
	_place_mech(battle, mech_c.mech_id, 11, 0)

	mech_a.power = 10
	mech_b.power = 0   # 反击效果1 移动立即结束
	mech_c.power = 10

	var b_counter := _ensure_card_in_player_hand(battle, &"enemy", "action_010_反击")
	if b_counter == &"":
		return "B 手牌未找到反击牌"

	var c_hp0: int = mech_c.current_hp
	var observed_target_window: Dictionary = {}  # 记录攻击2的目标选择 input_params

	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.frame_cb = _frame
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"
	driver.target_for = func(aid: StringName, params: Dictionary) -> StringName:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return &""
		var attacker_id: StringName = act.record.get("attacker_id", &"")
		# 攻击1（A发起）→ 打 B
		if attacker_id == mech_a.mech_id:
			return mech_b.mech_id
		# 攻击2（B反击发起）：记录目标选择窗口参数，并选 C（非原攻击者A）
		if attacker_id == mech_b.mech_id:
			observed_target_window["params"] = params
			observed_target_window["attacker"] = attacker_id
			return mech_c.mech_id
		return &""
	driver.move_cell_for = func(_aid: StringName, _params: Dictionary) -> StringName:
		return &""  # 取消移动
	driver.response_for = func(aid: StringName) -> Array[Dictionary]:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return []
		var target_id: StringName = act.record.get("target_id", &"")
		# 仅攻击1（打B）时 B 用反击响应；攻击2 打 C 时 C 不响应（本测试只验证目标选择，不展开连锁）
		if target_id == mech_b.mech_id:
			return [{"effect_id": &"counter_availability", "card_instance_id": b_counter, "availability_priority": 5}]
		return []
	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	# 发起攻击1：A 打 B
	var atk1: Dictionary = battle.context.action_service.execute(&"attack", {
		"attacker_id": mech_a.mech_id,
		"target_id": &"",
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"player", "mech_id": mech_a.mech_id},
	})
	if atk1.get("state", &"") == &"error":
		return "攻击1 发起失败: %s" % str(atk1)

	await driver.drain(500)

	# 验证1：攻击2 的目标选择窗口确实出现（B 作为攻击2 发动方）
	if observed_target_window.is_empty():
		return "反击效果2 发动的攻击2 未触发目标选择窗口（可能仍被锁定为原攻击者）"
	if observed_target_window.get("attacker", &"") != mech_b.mech_id:
		return "攻击2 发动方应为 B(反击方)，实际: %s" % str(observed_target_window.get("attacker"))

	# 验证2：C 受到伤害（攻击2 打 C 命中）
	if mech_c.current_hp >= c_hp0:
		return "攻击2 选 C 为目标但未造成伤害（c_hp %d→%d），目标选择或命中异常" % [c_hp0, mech_c.current_hp]

	return true


## ════════════════════════════════════════════════════════════
## 测试3：反击效果1 移动跳出攻击1范围 —— 攻击1未命中 + 反击效果2仍触发
##   A(近战r2, pos 10,0) 打 B(pos 11,0，距离1在范围内)；B 反击响应；
##   B 反击效果1 用半动力移动跳出 A 范围（移到 14,0，距离4>2）；
##   攻击1结算时 _step_check_hit 用实时位置算范围 → hit=false（B 不受伤害）；
##   ATTACK_SETTLE 仍触发反击效果2 → B 发动攻击2 打 C。
##   验证规则文档「攻击结算前目标仍在范围内则命中，否则未命中」+ 反击效果2不依赖命中。
## ════════════════════════════════════════════════════════════
func test_counter_effect1_moves_out_of_range_attack_misses():
	var battle := _new_battle_with_three_mechs()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var mech_a = gs.get_mech_for_player(&"player")   # A
	var mech_b = gs.get_mech_for_player(&"enemy")    # B
	var mech_c := _add_third_mech(battle)             # C

	# 布局：A(10,0) r2 打 B(11,0)（距离1在范围）；B 移动到 14,0（距离4 跳出范围2）
	# B 移动路径 (11,0)→(12,0)→(13,0)→(14,0) 均为 normal 直路。
	# C 放在 B 移动后位置(14,0) 的武器范围2内、且不挡 B 路径（r=0 上 q=11~14）的格。
	_place_mech(battle, mech_a.mech_id, 10, 0)
	_place_mech(battle, mech_b.mech_id, 11, 0)
	# 扫描地图找 C 的合法落点：距 (14,0) 范围2内、非 B 路径格、非 A 位置
	var b_final := {"q": 14, "r": 0}
	var b_path_cells := {"11,0": true, "12,0": true, "13,0": true, "14,0": true, "10,0": true}
	var c_pos: Dictionary = {}
	for cell_key: String in battle.context.game_state.map_state.cells.keys():
		var parts := cell_key.split(",")
		var cq: int = int(parts[0])
		var cr: int = int(parts[1])
		if b_path_cells.has(cell_key):
			continue
		var cell = battle.context.game_state.map_state.get_cell({"q": cq, "r": cr})
		if cell == null or cell.terrain == &"RED":
			continue
		# 用 RangeCalculator 直接算 (14,0)->候选格 距离≤2
		var _RangeCalc = load("res://scripts/battle/RangeCalculator.gd")
		if _RangeCalc.is_in_weapon_range(b_final, {"q": cq, "r": cr}, 2, battle.context.game_state.map_state.cells):
			c_pos = {"q": cq, "r": cr}
			break
	if c_pos.is_empty():
		return "找不到 C 的合法落点（B(14,0) 范围2内且不挡 B 路径）"
	_place_mech(battle, mech_c.mech_id, int(c_pos["q"]), int(c_pos["r"]))

	# B 动力6 → 半动力 X=3，正好够移3格到 14,0（耗3，X=0），
	# loop 因剩余动力为0不再请求选格，移动自然结束（无需 driver 处理"取消移动"）。
	mech_a.power = 10
	mech_b.power = 6
	mech_c.power = 10

	var b_counter := _ensure_card_in_player_hand(battle, &"enemy", "action_010_反击")
	if b_counter == &"":
		return "B 手牌未找到反击牌"

	var a_hp0: int = mech_a.current_hp
	var b_hp0: int = mech_b.current_hp
	var c_hp0: int = mech_c.current_hp

	var driver := InputDriver.new()
	driver.attach(battle.context)
	driver.frame_cb = _frame

	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"

	# 攻击目标：攻击1(A发起)→B；攻击2(B反击发起)→C
	driver.target_for = func(aid: StringName, _params: Dictionary) -> StringName:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return &""
		var attacker_id: StringName = act.record.get("attacker_id", &"")
		if attacker_id == mech_a.mech_id:
			return mech_b.mech_id   # 攻击1：A 打 B
		if attacker_id == mech_b.mech_id:
			return mech_c.mech_id   # 攻击2：B 反击 打 C
		return &""

	# 反击效果1 移动：B 从 11,0 移到 14,0（跳出 A 范围2）。
	# single_move 用 find_optimal_path 一次算出整条路径(12,0)(13,0)(14,0)逐格走，
	# 走完 path 后 loop_until_cancel 再请求下一格；第2次请求返回空=取消结束循环移动。
	var move_call_count := 0
	driver.move_cell_for = func(_aid: StringName, _params: Dictionary) -> StringName:
		move_call_count += 1
		if move_call_count == 1:
			return &"14,0"   # 第1次：给最终目标格，path 算出逐格路径走完
		return &""          # 第2次：取消，结束半动力循环移动

	# 响应窗口：攻击1（打B）→ B 用反击响应；攻击2（打C）→ C 不响应
	driver.response_for = func(aid: StringName) -> Array[Dictionary]:
		var act = battle.context.action_registry.get_action(aid)
		if act == null:
			return []
		var target_id: StringName = act.record.get("target_id", &"")
		if target_id == mech_b.mech_id:
			return [{"effect_id": &"counter_availability", "card_instance_id": b_counter, "availability_priority": 5}]
		return []

	driver.damage_for = func(_aid: StringName, _params: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	# 发起攻击1：A 打 B
	var atk1: Dictionary = battle.context.action_service.execute(&"attack", {
		"attacker_id": mech_a.mech_id,
		"target_id": &"",
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"player", "mech_id": mech_a.mech_id},
	})
	if atk1.get("state", &"") == &"error":
		return "攻击1 发起失败: %s" % str(atk1)

	await driver.drain(500)
	for _i in range(5):
		await _frame()

	# 验证1：B 移动后跳出 A 范围 → 攻击1未命中 B → B 不受伤害
	if mech_b.current_hp != b_hp0:
		return "攻击1 应未命中 B（B 已移出范围），但 B HP 变化 %d→%d" % [b_hp0, mech_b.current_hp]

	# 验证2：B 实际移到了 14,0（跳出范围）
	var b_pos = mech_b.position
	if int(b_pos.get("q", -1)) != 14 or int(b_pos.get("r", -1)) != 0:
		return "B 应移动到 (14,0) 跳出 A 范围，实际位置: %s" % str(b_pos)

	# 验证3：反击效果2 仍触发 → 攻击2 打 C，C 受到伤害
	if mech_c.current_hp >= c_hp0:
		return "反击效果2 应触发攻击2 打 C（c_hp %d→%d），跳出范围后反击效果2未触发或攻击2未命中" % [c_hp0, mech_c.current_hp]

	# 验证4：A 未受攻击（攻击2 打的是 C）
	if mech_a.current_hp != a_hp0:
		return "攻击2 目标应为 C，A HP 不应变化 %d→%d" % [a_hp0, mech_a.current_hp]

	# 验证5：无残留等待动作
	var active_ids: Array = battle.context.action_registry.get_active_ids()
	var waiting: Array = []
	for aid: StringName in active_ids:
		var a = battle.context.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	if not waiting.is_empty():
		return "连锁结束后仍有动作处于等待态: %s" % str(waiting)

	return true

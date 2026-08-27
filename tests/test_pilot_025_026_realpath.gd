## test_pilot_025_026_realpath.gd - 真实路径复现（伊万026/约书亚025 卡死排查）
##
## 现有 test_pilot_025/026 用假 _Action 直接 fire_timing，不覆盖真实 AttackAction 的
## resume/续跑链；伊万测试也带了顶层 mech_id（生产 `_net_equipment_active` 没有）。
## 本文件走与生产一致的完整路径：
##   1. 伊万 effect_01：用 `_net_equipment_active` 同款 payload（无顶层 mech_id，只有
##      source_mech_id）execute effect_fire → 验证完成后无残留等待动作（生产"发动后动不了"
##      即表现为 effect_fire 或某子动作停在 waiting_* 态，UI 被锁）。
##   2. 约书亚 effect_02 1b：真实 AttackAction 驱动到 ATTACK_PRE → 弹 CHOOSE_ONE → 1b
##      reserve_select → slot_select → _seq 子动作(set_equipment+gain_card) → 攻击动作
##      必须能 resume 并走完 damage/settle（生产"设置装备后阻塞"即攻击卡在 waiting_* 态）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")


func _frame() -> void:
	var ml := Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 900252
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


func _setup_pilot(battle, pilot_def_id: String, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, pilot_def_id, owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb, "enemy_mech": gs.get_mech_for_player(&"enemy")}


func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 在 mech 的 reserve_1 放一张装备牌（face_down）。返回 instance_id；失败返回 ""。
func _put_card_in_reserve(gs, cdb, mech, card_def_id: String) -> StringName:
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return &""
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = mech.owner_player_id
	card.mech_id = mech.mech_id
	card.zone = &"equipment_slot"
	card.slot_id = &"reserve_1"
	card.face_down = true
	gs.cards[inst_id] = card
	var slot = mech.slots.get(&"reserve_1")
	if slot == null:
		slot = _MechSlotState.new()
		slot.slot_id = &"reserve_1"
		mech.slots[&"reserve_1"] = slot
	slot.equipped_card = card
	return inst_id


## 收集所有残留的 waiting 动作（卡死判定）
func _waiting_actions(ctx) -> Array:
	var waiting: Array = []
	for aid: StringName in ctx.action_registry.get_active_ids():
		var a = ctx.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	return waiting


# ═══════════════════════════════════════════
# 输入驱动器：标准输入自动回填，pilot 弹窗捕获不自动答
# ═══════════════════════════════════════════

const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class Driver:
	var context = null
	var pending: Dictionary = {}   # action_id -> {input_type, input_params}
	var popups: Array = []         # {"action_id", "type", "params"}  (pilot 弹窗)
	var weapon_for: Callable = Callable()
	var target_for: Callable = Callable()
	var response_for: Callable = Callable()
	var damage_for: Callable = Callable()

	func attach(ctx) -> void:
		context = ctx
		# 断开 ActionUIBridge（测试由本驱动器全权接管输入）
		if context.action_ui_bridge != null:
			if context.action_engine != null:
				context.action_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
			if context.timing_engine != null:
				context.timing_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
		if context.action_engine != null:
			context.action_engine.action_needs_input.connect(_on_need)
		if context.timing_engine != null:
			context.timing_engine.action_needs_input.connect(_on_need)

	func _on_need(action_id: StringName, input_type: StringName, input_params: Dictionary) -> void:
		if _STD_INPUTS.has(input_type):
			pending[action_id] = {"input_type": input_type, "input_params": input_params}
		else:
			popups.append({"action_id": action_id, "type": String(input_type), "params": input_params})

	## 推进一处标准输入。返回 true 表示推进了；false 表示无标准输入待处理。
	func pump() -> bool:
		if pending.is_empty():
			return false
		var action_id: StringName = pending.keys()[0]
		var entry: Dictionary = pending[action_id]
		var input_type: StringName = entry["input_type"]
		var input_params: Dictionary = entry["input_params"]
		pending.erase(action_id)
		match input_type:
			&"select_weapon":
				context.action_service.continue_action(action_id, {"weapon_id": weapon_for.call(action_id)})
			&"select_attack_target":
				context.action_service.continue_action(action_id, {"target_id": target_for.call(action_id, input_params)})
			&"select_move_target":
				context.action_service.cancel_action(action_id)  # 测试不移动
			&"respond_attack":
				context.timing_engine.handle_response_selection(action_id, response_for.call(action_id))
			&"place_damage_tokens":
				var d: Dictionary = damage_for.call(action_id, input_params)
				context.action_service.continue_action(action_id, d if not d.is_empty() else {"auto_placed": true})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true


# ═══════════════════════════════════════════
# 测试1：伊万 effect_01 生产同款 payload（无顶层 mech_id）
# ═══════════════════════════════════════════

func test_ivan_effect1_production_payload_no_block() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ctx = battle.context
	var s = _setup_pilot(battle, "pilot_026_伊万", &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var mech = s.mech
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	if int(mech.attack_count_this_turn) != 0:
		return "初始攻击计数应0"
	# 与 _net_equipment_active 完全一致的 payload（无顶层 mech_id）
	var src: Dictionary = {
		"card_instance_id": s.card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": &"player",
		"effect_id": &"pilot_026_effect_01",
	}
	var payload: Dictionary = {
		"effect_id": &"pilot_026_effect_01",
		"player_id": &"player",
		"source_mech_id": mech.mech_id,
		"card_instance_id": s.card.instance_id,
		"phase": &"MAIN",
		"source": src,
	}
	ctx.action_service.execute(&"effect_fire", payload)
	for _i in range(5):
		await _frame()
	# 效果落地
	if int(mech.attack_count_this_turn) != 1:
		return "效果1应消耗1点攻击数，实=%d" % int(mech.attack_count_this_turn)
	var st: Dictionary = mech.get_status(&"SET_TRAP")
	if int(st.get("stacks", 0)) != 4:
		return "SET_TRAP 应4层（伊万effect2覆盖），实=%d" % int(st.get("stacks", 0))
	# 无残留等待动作（卡死判定）
	var waiting := _waiting_actions(ctx)
	if not waiting.is_empty():
		return "效果后仍有动作等待: %s" % str(waiting)
	return true


# ═══════════════════════════════════════════
# 测试2：约书亚 1b 真实 AttackAction 全流程（设置装备后攻击必须 resume）
# ═══════════════════════════════════════════

func test_joshua_1b_real_attack_resumes() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ctx = battle.context
	var s = _setup_pilot(battle, "pilot_025_约书亚", &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	# 相邻布局（frame_base_weapon_1 范围内）
	_place_mech(battle, player_mech.mech_id, 10, 0)
	_place_mech(battle, enemy_mech.mech_id, 11, 0)
	player_mech.power = 10
	# reserve_1 放头部部件
	var reserve_id := _put_card_in_reserve(gs, cdb, player_mech, "part_001_量产装_头部")
	if reserve_id == &"":
		return "缺 part_001_量产装_头部"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var player = s.gs.players.get(&"player")
	var action_before: int = player.action_hand.size()
	var enemy_hp_before: int = enemy_mech.current_hp

	var driver := Driver.new()
	driver.attach(ctx)
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"
	driver.target_for = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]:
		return []
	driver.damage_for = func(_aid: StringName, _p: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	# 发起真实攻击（走选武器→选目标→ATTACK_PRE）
	var atk: Dictionary = ctx.action_service.execute(&"attack", {
		"attacker_id": player_mech.mech_id,
		"target_id": &"",
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"player", "mech_id": player_mech.mech_id},
	})
	if atk.get("state", &"") == &"error":
		return "攻击发起失败: %s" % str(atk)

	# 逐步推进：标准输入 pump + pilot 弹窗手动答
	var steps: int = 0
	var attack_id: StringName = atk.get("action_id", &"")
	while steps < 200:
		steps += 1
		if not driver.popups.is_empty():
			var p: Dictionary = driver.popups.pop_front()
			match p.get("type", ""):
				"choose_one_effect":
					ctx.timing_engine.resume_pending_effect(p["action_id"], {"chosen_option_index": 1})  # 1b
				"pilot_025_reserve_select":
					ctx.timing_engine.resume_pending_effect(p["action_id"], {"selected_card_id": reserve_id})
				"pilot_025_slot_select":
					ctx.timing_engine.resume_pending_effect(p["action_id"], {"chosen_slot_id": &"头部"})
				"immediate_set_equipment":
					ctx.timing_engine.resume_pending_effect(p["action_id"], {"cancelled": true})
				_:
					return "出现未预期的弹窗类型: %s (params=%s)" % [p.get("type", ""), str(p.get("params", {}))]
			await _frame()
			continue
		var progressed: bool = driver.pump()
		await _frame()
		if not progressed and driver.popups.is_empty() and _waiting_actions(ctx).is_empty():
			break

	var waiting := _waiting_actions(ctx)
	if not waiting.is_empty():
		return "约书亚1b后仍有动作等待（卡死）: %s" % str(waiting)

	# 1b 已抽2张行动牌
	if player.action_hand.size() - action_before != 2:
		return "1b 应抽2张行动牌 实=%d（前=%d）" % [player.action_hand.size(), action_before]
	# 攻击动作应已完全结算：攻击动作已从 registry 清理（complete 后移除=null），且敌方确实受到伤害
	var atk_act = ctx.action_registry.get_action(attack_id)
	if atk_act != null and atk_act.state != &"completed":
		return "攻击动作应 completed（或已完成被清理），实=%s" % String(atk_act.state)
	if enemy_mech.current_hp >= enemy_hp_before:
		return "约书亚1b后攻击应命中敌方造成伤害（HP %d→%d），攻击未完整结算" % [enemy_hp_before, enemy_mech.current_hp]
	return true


# ═══════════════════════════════════════════
# 测试3：resume_effect 锁清理回归（pilot_025 效果弹窗经 bridge.resolve_effect_input 确认）
# ═══════════════════════════════════════════
#
# 背景（2026-08-14 实机 bug）：pilot_025/003/018/choose_one_effect 等效果弹窗确认走
# _net_exec("resume_effect") → 曾直连 timing_engine.resume_pending_effect，绕过
# ActionUIBridge，导致 _waiting_action_id（共享等待锁）残留 -> 主动效果按钮全灰 + 地图点击
# 被拦截（"发动后动不了"）。本测试不断开 bridge，用真实 AttackAction 驱动到 pilot_025
# reserve_select 弹窗，验证：弹窗期间锁非空；经 resolve_effect_input 确认后锁清空且攻击
# 完整结算。此路径即 app_root resume_effect op 修复后的行为。

func test_resume_effect_clears_lock() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ctx = battle.context
	var s = _setup_pilot(battle, "pilot_025_约书亚", &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player_mech = s.mech
	var enemy_mech = s.enemy_mech
	_place_mech(battle, player_mech.mech_id, 10, 0)
	_place_mech(battle, enemy_mech.mech_id, 11, 0)
	player_mech.power = 10
	var reserve_id := _put_card_in_reserve(gs, cdb, player_mech, "part_001_量产装_头部")
	if reserve_id == &"":
		return "缺 part_001_量产装_头部"
	gs.active_player_id = &"player"
	gs.phase = &"MAIN"
	var player = s.gs.players.get(&"player")
	var action_before: int = player.action_hand.size()
	var enemy_hp_before: int = enemy_mech.current_hp

	# 不断开 bridge：本测试专测 bridge 锁路径（bridge 仍连接着两个信号源并设锁）。
	# 标准输入用 Driver 的 _on_need 收集，但用独立连接，避免 attach() 断开 bridge。
	var driver := Driver.new()
	driver.context = ctx
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"
	driver.target_for = func(_aid: StringName, _p: Dictionary) -> StringName:
		return enemy_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]:
		return []
	driver.damage_for = func(_aid: StringName, _p: Dictionary) -> Dictionary:
		return {"auto_placed": true}
	ctx.action_engine.action_needs_input.connect(driver._on_need)
	ctx.timing_engine.action_needs_input.connect(driver._on_need)

	var atk: Dictionary = ctx.action_service.execute(&"attack", {
		"attacker_id": player_mech.mech_id,
		"target_id": &"",
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"player", "mech_id": player_mech.mech_id},
	})
	if atk.get("state", &"") == &"error":
		return "攻击发起失败: %s" % str(atk)
	var attack_id: StringName = atk.get("action_id", &"")

	var saw_reserve_lock: bool = false
	var saw_resume_clear: bool = false
	var steps: int = 0
	while steps < 200:
		steps += 1
		if not driver.popups.is_empty():
			var p: Dictionary = driver.popups.pop_front()
			match p.get("type", ""):
				"choose_one_effect":
					ctx.action_ui_bridge.resolve_effect_input(p["action_id"], {"chosen_option_index": 1})
				"pilot_025_reserve_select":
					# 弹窗期间共享等待锁应非空（bridge 已捕获）
					if ctx.action_ui_bridge.get_waiting_action_info().is_empty():
						return "reserve_select 弹窗期间 bridge 等待锁应为非空"
					saw_reserve_lock = true
					# app_root resume_effect op 修复后走 bridge.resolve_effect_input
					ctx.action_ui_bridge.resolve_effect_input(p["action_id"], {"selected_card_id": reserve_id})
					# 确认后，reserve_select 弹窗不应仍占用共享锁（残留=卡死根因）。
					# 注意：同一 effect 链的后续弹窗（slot_select）与 reserve_select 共享 action_id，
					# 但 input_type 不同——锁被合法覆盖时 input_type 会变。残留判定用 input_type。
					var lock_after: Dictionary = ctx.action_ui_bridge.get_waiting_action_info()
					if not lock_after.is_empty() and String(lock_after.get("input_type", &"")) == String(p["type"]):
						return "resume_effect 后 %s 仍占用共享等待锁（残留）" % String(p["type"])
					saw_resume_clear = true
				"pilot_025_slot_select":
					ctx.action_ui_bridge.resolve_effect_input(p["action_id"], {"chosen_slot_id": &"头部"})
				"immediate_set_equipment":
					ctx.action_ui_bridge.resolve_effect_input(p["action_id"], {"cancelled": true})
				_:
					return "出现未预期的弹窗类型: %s (params=%s)" % [p.get("type", ""), str(p.get("params", {}))]
			await _frame()
			continue
		var progressed: bool = driver.pump()
		await _frame()
		if not progressed and driver.popups.is_empty() and _waiting_actions(ctx).is_empty():
			break

	if not saw_reserve_lock or not saw_resume_clear:
		return "应经过 reserve_select 弹窗并验证锁清空 (lock=%s, clear=%s)" % [saw_reserve_lock, saw_resume_clear]
	var waiting := _waiting_actions(ctx)
	if not waiting.is_empty():
		return "resume_effect 路径后仍有动作等待（卡死）: %s" % str(waiting)
	if player.action_hand.size() - action_before != 2:
		return "1b 应抽2张行动牌 实=%d（前=%d）" % [player.action_hand.size(), action_before]
	if enemy_mech.current_hp >= enemy_hp_before:
		return "攻击应命中敌方造成伤害（HP %d→%d），攻击未完整结算" % [enemy_hp_before, enemy_mech.current_hp]
	return true

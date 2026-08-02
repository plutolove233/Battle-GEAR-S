## test_unicorn_repeat_loop.gd - P2: effect_084「可继续发动」循环验证
##
## 119 联邦的一角兽·右腿：响应对我方的攻击，可置2损伤到此牌并立即移动2格，发动后可继续发动。
## 原实现 REPEAT_SELF_DAMAGE_AND_FREE_MOVE 单轮（"循环待补"）。本测试验证循环：
##   敌方攻击 player -> player 用 119 响应 -> 自损2+移动2 -> 弹"是否继续？" ->
##   继续 -> 再自损2+移动2 -> 弹"是否继续？" -> 停止 -> 攻击继续结算（移出范围未命中）。
## 验证：119 上损伤=4（2轮×2），player 移动两次（位置变化），循环正常停止。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")


func _frame() -> void:
	var ml = Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


func _ensure_equipment_in_hand(battle: BattleState, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.equipment_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.equipment_deck.size()):
		var cid: StringName = gs.deck_state.equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			return cid
	for i in range(gs.deck_state.advanced_equipment_deck.size()):
		var cid: StringName = gs.deck_state.advanced_equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.advanced_equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			return cid
	return &""


func _ensure_attack_card_in_enemy_hand(battle: BattleState) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.action_type == &"攻击":
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


func _clear_player_hand(battle: BattleState) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	if player == null:
		return
	for cid: StringName in player.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	player.action_hand.clear()


## 驱动器：拦截 action_needs_input，按类型回填
class Driver:
	var context = null
	var pending: Dictionary = {}
	var leg_id: StringName = &""          # 119 装备实例 id（响应选择用）
	var move_cells: Array = []            # 依次的移动目标
	var choose_indices: Array = []        # 依次的"是否继续"选择（0继续/1停止）
	var frame_cb: Callable = Callable()
	var respond_called: int = 0
	var move_called: int = 0
	var choose_called: int = 0
	var avail_check: String = ""    # Fix A: get_available_cards 须含 effect_084
	var counter_check: String = ""  # Fix D: effect_084 响应不应设 counter_attacked

	func attach(ctx) -> void:
		context = ctx
		if context.action_ui_bridge != null:
			if context.action_engine != null:
				context.action_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
			if context.timing_engine != null:
				context.timing_engine.action_needs_input.disconnect(context.action_ui_bridge._on_action_needs_input)
		context.action_engine.action_needs_input.connect(_on_need)
		if context.timing_engine != null:
			context.timing_engine.action_needs_input.connect(_on_need)

	func _on_need(action_id: StringName, input_type: StringName, input_params: Dictionary) -> void:
		pending[action_id] = {"input_type": input_type, "input_params": input_params}

	func pump() -> bool:
		if pending.is_empty():
			return false
		var action_id: StringName = pending.keys()[0]
		var entry: Dictionary = pending[action_id]
		var input_type: StringName = entry["input_type"]
		var input_params: Dictionary = entry["input_params"]
		pending.erase(action_id)
		var handled = _resolve(action_id, input_type, input_params)
		if handled == null:
			return true
		context.action_service.continue_action(action_id, handled)
		return true

	func _resolve(action_id: StringName, input_type: StringName, _params: Dictionary):
		match input_type:
			&"respond_attack":
				respond_called += 1
				# Fix A 验证：get_available_cards 须遍历 permanent_listeners，含装备 AVAILABILITY 效果 effect_084
				var _TC = preload("res://scripts/action_core/TimingConst.gd")
				var atk = context.action_registry.get_action(action_id)
				if atk != null:
					var avail = context.timing_engine.get_available_cards(_TC.ATTACK_AT, atk)
					var _found084 := false
					for _c in avail:
						if String(_c.get("effect_id", &"")) == "equipment_effect_084":
							_found084 = true
							break
					if not _found084:
						avail_check = "响应窗口未列出 effect_084（get_available_cards 漏 permanent），实际 %d 项" % avail.size()
				var sel: Array[Dictionary] = [{
					"effect_id": &"equipment_effect_084",
					"card_instance_id": leg_id,
					"availability_priority": 10,
				}]
				context.timing_engine.handle_response_selection(action_id, sel)
				# Fix D 验证：effect_084 is_counter_card=false，响应后不应设 counter_attacked（损伤由攻击方放置）
				var atk2 = context.action_registry.get_action(action_id)
				if atk2 != null and bool(atk2.record.get("counter_attacked", false)):
					counter_check = "effect_084 响应不应设 counter_attacked（is_counter_card=false）"
				return null
			&"select_move_target":
				move_called += 1
				if move_cells.is_empty():
					context.action_service.cancel_action(action_id)
					return null
				return {"target_cell": move_cells.pop_front()}
			&"choose_one_effect":
				choose_called += 1
				var idx: int = 1
				if not choose_indices.is_empty():
					idx = choose_indices.pop_front()
				context.timing_engine.resume_pending_effect(action_id, {"chosen_option_index": idx})
				return null
			&"place_damage_tokens":
				return {"auto_placed": true}
			_:
				return {"auto": true}

	func drain(max_iters: int = 600) -> void:
		var it := 0
		while it < max_iters:
			it += 1
			var progressed: bool = pump()
			if frame_cb.is_valid():
				await frame_cb.call()
			if not pump():
				if not progressed and pending.is_empty():
					if not _has_waiting():
						break
			if pending.is_empty() and not _has_waiting():
				break

	func _has_waiting() -> bool:
		if context == null or context.action_registry == null:
			return false
		for aid: StringName in context.action_registry.get_active_ids():
			var a = context.action_registry.get_action(aid)
			if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
				return true
		return false


func test_unicorn_rleg_repeat_loop():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.players.get(&"player").is_human = true
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"

	# 装备 119 一角兽右腿（durability=5，自损2/轮，2轮=4<5 不破）
	var leg_id: StringName = _ensure_equipment_in_hand(battle, "part_119_联邦的一角兽_右腿")
	if leg_id == &"":
		return "找不到一角兽右腿"
	battle.context.card_set_service.set_equipment(&"player", leg_id, &"右腿")
	for _i in range(5):
		await _frame()

	# 敌我相邻，敌方武器 range=1（player 移动后超出范围 -> 攻击未命中，无需驱动损伤放置）
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	if not enemy_mech.base_weapons.is_empty():
		enemy_mech.base_weapons[0]["might"] = 10
		enemy_mech.base_weapons[0]["range_value"] = 1
	_clear_player_hand(battle)
	var attack_card_id: StringName = _ensure_attack_card_in_enemy_hand(battle)
	if attack_card_id == &"":
		return "敌方无攻击牌"
	var weapon_id: StringName = enemy_mech.get_weapon_ids()[0]

	var driver := Driver.new()
	driver.context = battle.context
	driver.leg_id = leg_id
	driver.move_cells = [&"7,0", &"9,0"]      # 2 轮移动目标（各 2 格）
	driver.choose_indices = [0, 1]            # 第1次继续，第2次停止
	driver.frame_cb = _frame
	driver.attach(battle.context)

	battle.context.action_ui_bridge.context = battle.context
	var atk_result: Dictionary = battle.execute_attack_action(&"enemy", &"player", weapon_id, attack_card_id)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return "攻击未发起: %s" % str(atk_result)

	await driver.drain(600)
	for _i in range(5):
		await _frame()

	# Fix A：响应窗口应列出 effect_084（get_available_cards 遍历 permanent_listeners）
	if driver.avail_check != "":
		return driver.avail_check
	# Fix D：effect_084 响应(is_counter_card=false)不应设 counter_attacked
	if driver.counter_check != "":
		return driver.counter_check

	# ① 119 上损伤 = 4（2 轮 × 自损2）
	var leg_card = gs.get_card(leg_id)
	if leg_card == null:
		return "119 装备牌实例丢失"
	var tokens: int = int(leg_card.damage_tokens) if leg_card.get("damage_tokens") else 0
	if tokens != 4:
		return "119 应有 4 损伤（2轮×2），实际 %d" % tokens

	# ② player 移动两次到 (9,0)
	var pq: int = int(player_mech.position.get("q", -1))
	var pr: int = int(player_mech.position.get("r", -1))
	if pq != 9 or pr != 0:
		return "player 应移动两次到 (9,0)，实际 (%d,%d)" % [pq, pr]

	# ③ 攻击动作已完成（循环正常停止，无残留）
	if battle.context.action_registry.get_action(attack_id) != null:
		var leftover = battle.context.action_registry.get_action(attack_id)
		return "攻击动作未完成，state=%s" % String(leftover.state)
	return true

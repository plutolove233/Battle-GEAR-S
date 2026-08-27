## test_pilot_062_realpath.gd - 洛尔恩（pilot_062）真实攻击路径复现
##
## 现有 test_pilot_062_luoern.gd 用假 _Action 直接 fire_timing + 手动注册 cover_effect1，
## 不覆盖真实 AttackAction 驱动链与真实手牌注册路径。本文件走与实机一致的完整路径：
##   1. 真实 attack 动作（execute attack -> select_weapon -> select_attack_target -> ATTACK_PRE），
##      洛尔恩玩家手牌有行动牌但【无真实掩护牌】-> 掩护窗口（select_thrust_cards）是否弹出
##      洛尔恩转化选项（实机"完全不生效"怀疑点：窗口由 cover_effect1（掩护牌手牌监听器）触发，
##      无掩护牌则窗口根本不打开，COVER_WINDOW_EXTRA 永无扫描时机）。
##   2. 同路径但手牌【有真实掩护牌】（register_hand_card_availability 注册，与抽牌路径一致）
##      -> 窗口应弹且 extra_options 含「洛尔恩--掩护」复选框（引擎层正确性对照）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


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
	battle.rng_seed = 90062
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)
	return battle


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


func _clear_hands(battle) -> void:
	var gs = battle.context.game_state
	for pid: StringName in [&"player", &"enemy"]:
		var p = gs.players.get(pid)
		if p == null:
			continue
		for cid: StringName in p.action_hand.duplicate():
			battle.context.timing_engine.unregister_listeners_for_card(cid)
			p.action_hand.erase(cid)


## 把行动牌放入玩家手牌并走真实注册路径（register_hand_card_availability，
## 与 DeckService 抽牌一致：注册 AVAILABILITY + permanent_while_in_hand LISTEN）。
func _put_card_in_hand_realpath(battle, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, player_id)
	if card == null:
		return &""
	var player = gs.players.get(player_id)
	player.action_hand.append(card.instance_id)
	card.zone = &"action_hand"
	card.mech_id = &""
	battle.context.register_hand_card_availability(card.instance_id)
	return card.instance_id


## 洛尔恩标准布局：玩家带洛尔恩机师（set_pilot 自动注册 e1->COVER_WINDOW_EXTRA
## permanent listener + e2），双方相邻，清空双方手牌。返回布局字典。
func _setup_luoern(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	_clear_hands(battle)
	var pilot_card = _make_instance(gs, cdb, "pilot_062_洛尔恩", &"player")
	if pilot_card == null:
		return {}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	battle.context.action_ui_bridge.context = battle.context
	return {"gs": gs, "player_mech": player_mech, "enemy_mech": enemy_mech}


func _waiting_actions(ctx) -> Array:
	var waiting: Array = []
	for aid: StringName in ctx.action_registry.get_active_ids():
		var a = ctx.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	return waiting


const _STD_INPUTS: Array[StringName] = [
	&"select_weapon", &"select_attack_target", &"select_move_target",
	&"respond_attack", &"place_damage_tokens",
]


class Driver:
	var context = null
	var pending: Dictionary = {}
	var popups: Array = []
	var weapon_for: Callable = Callable()
	var target_for: Callable = Callable()
	var response_for: Callable = Callable()
	var damage_for: Callable = Callable()

	func attach(ctx) -> void:
		context = ctx
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
				context.action_service.cancel_action(action_id)
			&"respond_attack":
				context.timing_engine.handle_response_selection(action_id, response_for.call(action_id))
			&"place_damage_tokens":
				# 仿 ActionUIBridge._auto_place_damage_tokens：真实放置损伤标记后回填动作
				var dp_mechs: Array = input_params.get("mech_ids", [])
				var dp_amount: int = int(input_params.get("amount", 0))
				if not bool(input_params.get("removal_mode", false)) and not dp_mechs.is_empty():
					context.damage_token_service.place_damage_tokens({
						"mech_id": dp_mechs[0],
						"count": dp_amount,
					})
				context.action_service.continue_action(action_id, {"auto_placed": true})
			_:
				context.action_service.continue_action(action_id, {"auto": true})
		return true


## 发起真实 enemy->player 攻击并推进到流程结束或首个弹窗返回。
## 返回首个非标准输入弹窗（Dictionary）或空 Dictionary。
func _run_real_attack_until_popup(battle, ctx, driver, target_mech) -> Dictionary:
	gs_set_phase(battle)
	var atk: Dictionary = ctx.action_service.execute(&"attack", {
		"attacker_id": (battle.context.game_state.get_mech_for_player(&"enemy")).mech_id,
		"target_id": &"",
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"enemy", "mech_id": (battle.context.game_state.get_mech_for_player(&"enemy")).mech_id},
	})
	if atk.get("state", &"") == &"error":
		return {"type": "EXEC_ERROR", "params": atk}
	var steps: int = 0
	while steps < 200:
		steps += 1
		if not driver.popups.is_empty():
			return driver.popups.pop_front()
		var progressed: bool = driver.pump()
		await _frame()
		if not progressed and driver.popups.is_empty() and _waiting_actions(ctx).is_empty():
			break
	return {}


func gs_set_phase(battle) -> void:
	var gs = battle.context.game_state
	gs.active_player_id = &"enemy"
	gs.phase = &"MAIN"


## 测试1：手牌无真实掩护牌（有行动牌燃料）-> 真实攻击路径下掩护窗口是否弹出。
## 设计意图（复选框「洛尔恩--掩护」条件满足：次数可用+手牌≥1行动牌）应弹出；
## 若未弹出即确认根因：窗口宿主 cover_effect1 是掩护牌的手牌监听器，无掩护牌则
## COVER_WINDOW_EXTRA 永无扫描时机（实机"完全不生效"）。
func test_no_cover_card_no_window() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ctx = battle.context
	var s := _setup_luoern(battle)
	if s.is_empty():
		return "洛尔恩布局失败"
	# 玩家手牌：1张进攻牌（燃料），无掩护牌
	var fuel_cid: StringName = _put_card_in_hand_realpath(battle, &"player", "action_001_进攻")
	if fuel_cid == &"":
		return "找不到 action_001_进攻"

	var driver := Driver.new()
	driver.attach(ctx)
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"
	driver.target_for = func(_aid: StringName, _p: Dictionary) -> StringName:
		return s.player_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]:
		return []
	driver.damage_for = func(_aid: StringName, _p: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	var popup: Dictionary = await _run_real_attack_until_popup(battle, ctx, driver, s.player_mech)
	if popup.is_empty():
		return "无掩护牌时掩护窗口未弹出（洛尔恩转化掩护不可达，实机复现）"
	if String(popup.get("type", "")) != "select_thrust_cards":
		return "期望 select_thrust_cards 掩护窗口，实际弹窗: %s" % String(popup.get("type", ""))
	var extras: Array = popup.get("params", {}).get("extra_options", [])
	var found: bool = false
	for e in extras:
		if String(e.get("effect_id", "")) == "pilot_062_effect_01":
			found = true
	if not found:
		return "掩护窗口弹出但 extra_options 无 pilot_062_effect_01: %s" % str(extras)
	return true


## 测试2：手牌有真实掩护牌 -> 窗口应弹且 extra_options 含「洛尔恩--掩护」（引擎层对照）。
func test_with_cover_card_window_has_extra() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ctx = battle.context
	var s := _setup_luoern(battle)
	if s.is_empty():
		return "洛尔恩布局失败"
	# 玩家手牌：1张进攻牌（燃料）+ 1张真实掩护牌（真实注册路径）
	var fuel_cid: StringName = _put_card_in_hand_realpath(battle, &"player", "action_001_进攻")
	if fuel_cid == &"":
		return "找不到 action_001_进攻"
	var cover_cid: StringName = _put_card_in_hand_realpath(battle, &"player", "action_016_掩护")
	if cover_cid == &"":
		return "找不到 action_016_掩护"

	var driver := Driver.new()
	driver.attach(ctx)
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"
	driver.target_for = func(_aid: StringName, _p: Dictionary) -> StringName:
		return s.player_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]:
		return []
	driver.damage_for = func(_aid: StringName, _p: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	var popup: Dictionary = await _run_real_attack_until_popup(battle, ctx, driver, s.player_mech)
	if popup.is_empty():
		return "有掩护牌时掩护窗口未弹出（cover_effect1 注册或 ATTACK_PRE 触发失败）"
	if String(popup.get("type", "")) != "select_thrust_cards":
		return "期望 select_thrust_cards 掩护窗口，实际弹窗: %s" % String(popup.get("type", ""))
	var params: Dictionary = popup.get("params", {})
	var card_ids: Array = params.get("card_ids", [])
	var found_cover: bool = false
	for cid in card_ids:
		if StringName(cid) == cover_cid:
			found_cover = true
	if not found_cover:
		return "掩护窗口候选不含真实掩护牌: %s" % str(card_ids)
	var extras: Array = params.get("extra_options", [])
	var found: bool = false
	for e in extras:
		if String(e.get("effect_id", "")) == "pilot_062_effect_01":
			found = true
	if not found:
		return "extra_options 无 pilot_062_effect_01: %s" % str(extras)
	return true


## 测试3：完整链路（实机bug复现）——真实攻击 + 确认掩护窗口打出真实掩护牌
## + 洛尔恩效果2 CHOOSE_ONE 弹窗选「该攻击不能被响应」(option_1) -> 攻击应继续推进到
## ATTACK_AT（响应窗口被 no_response 抑制）-> 伤害结算 -> 动作完成。
## 实机症状：选完「不能响应」后攻击卡住、响应窗口卡住、三方失步。
## 断言：攻击动作 completed、防御方掉血、respond_attack 从未触发（no_response 生效）、
## 无孤儿挂起动作。防御方手牌带迎击牌（若无抑制本会弹响应窗口，使抑制可观测）。
func test_full_chain_cover_then_no_response() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ctx = battle.context
	var s := _setup_luoern(battle)
	if s.is_empty():
		return "洛尔恩布局失败"
	# 防御方（player=洛尔恩持有者/掩护方）手牌：1张真实掩护牌 + 1张迎击牌
	var cover_cid: StringName = _put_card_in_hand_realpath(battle, &"player", "action_016_掩护")
	if cover_cid == &"":
		return "找不到 action_016_掩护"
	var counter_cid: StringName = _put_card_in_hand_realpath(battle, &"player", "action_008_回避")
	if counter_cid == &"":
		return "找不到 action_008_回避"

	var respond_seen: Array = []
	var driver := Driver.new()
	driver.attach(ctx)
	driver.weapon_for = func(_aid: StringName) -> StringName:
		return &"frame_base_weapon_1"
	driver.target_for = func(_aid: StringName, _p: Dictionary) -> StringName:
		return s.player_mech.mech_id
	driver.response_for = func(_aid: StringName) -> Array[Dictionary]:
		respond_seen.append(String(_aid))
		return []
	driver.damage_for = func(_aid: StringName, _p: Dictionary) -> Dictionary:
		return {"auto_placed": true}

	gs_set_phase(battle)
	var atk: Dictionary = ctx.action_service.execute(&"attack", {
		"attacker_id": s.enemy_mech.mech_id,
		"target_id": &"",
		"weapon_id": &"",
		"attack_card_id": &"",
		"target_count": 1,
		"source": {"player_id": &"enemy", "mech_id": s.enemy_mech.mech_id},
	})
	if atk.get("state", &"") == &"error":
		return "attack 执行失败: %s" % str(atk)
	var attack_action = null
	for a in ctx.action_registry.get_actions_by_type(&"attack"):
		attack_action = a
	if attack_action == null:
		return "attack 动作未注册"
	var hp_before: int = int(s.player_mech.current_hp)
	var tokens_before: int = 0
	for slot in s.player_mech.slots.values():
		tokens_before += int(slot.region_damage_tokens)
		if slot.equipped_card != null:
			tokens_before += int(slot.equipped_card.damage_tokens)

	var saw_thrust_window: bool = false
	var saw_effect2_popup: bool = false
	var steps: int = 0
	while steps < 400:
		steps += 1
		if not driver.popups.is_empty():
			var popup: Dictionary = driver.popups.pop_front()
			var ptype: String = String(popup.get("type", ""))
			var pparams: Dictionary = popup.get("params", {})
			if ptype == "select_thrust_cards":
				# 掩护多选窗确认：打出真实掩护牌（UI 走 _on_thrust_selection_completed ->
				# resume_effect {selected_card_ids, selected_extra_ids}）
				saw_thrust_window = true
				ctx.timing_engine.resume_pending_effect(pparams.get("action_id", &""), {
					"selected_card_ids": [cover_cid],
					"selected_extra_ids": [],
				})
			elif ptype == "choose_one_effect":
				var eff_id: String = String(pparams.get("effect_id", ""))
				if eff_id != "pilot_062_effect_02":
					return "期望 pilot_062_effect_02 二选一弹窗，实际: %s" % eff_id
				saw_effect2_popup = true
				ctx.timing_engine.resume_pending_effect(pparams.get("action_id", &""), {
					"chosen_option_index": 1,
					"chosen_effect_id": &"option_1",
					"confirmed": true,
				})
			else:
				return "意外弹窗类型: %s params=%s" % [ptype, str(pparams).substr(0, 200)]
			await _frame()
			continue
		var progressed: bool = driver.pump()
		await _frame()
		if attack_action.state == &"completed":
			break
		if not progressed and driver.popups.is_empty() and _waiting_actions(ctx).is_empty():
			break
	if not saw_thrust_window:
		return "掩护多选窗未弹出（链路未到 ATTACK_PRE 掩护窗口）"
	if not saw_effect2_popup:
		return "洛尔恩效果2二选一弹窗未弹出（掩护 use_action_card 的 USE_ACTION_AFTER 未触发效果2）"
	if attack_action.state != &"completed":
		var diag: Array = []
		for sid: StringName in attack_action.pending_effect_action_ids:
			var sub = ctx.action_registry.get_action(sid)
			if sub != null:
				diag.append("%s(%s) state=%s step=%d" % [String(sid), String(sub.action_type), String(sub.state), sub.current_step_index])
			else:
				diag.append("%s(不在registry)" % String(sid))
		return "选「不能响应」后攻击卡住：state=%s 等待中=%s 子动作=%s" % [String(attack_action.state), str(_waiting_actions(ctx)), str(diag)]
	if not bool(attack_action.record.get("no_response", false)):
		return "attack record.no_response 应为 true"
	if not respond_seen.is_empty():
		return "no_response=true 时不应触发响应窗口（respond_attack 触发 %d 次）" % respond_seen.size()
	# 攻击造成了 1 个损伤标记（威力11-掩护5-护甲 -> damage 0 / markers 1）：
	# 伤进槽位损伤标记而非直接扣血，断言防御方总损伤标记增加
	var tokens_after: int = 0
	for slot in s.player_mech.slots.values():
		tokens_after += int(slot.region_damage_tokens)
		if slot.equipped_card != null:
			tokens_after += int(slot.equipped_card.damage_tokens)
	if tokens_after <= tokens_before:
		return "攻击完成后防御方应获得损伤标记（%d -> %d）" % [tokens_before, tokens_after]
	# 掩护牌应已被 use_action_card settle 弃置
	var cover_card = ctx.game_state.get_card(cover_cid)
	if cover_card != null and String(cover_card.zone) != "discard":
		return "掩护牌打出后应进弃牌堆，实际 zone=%s" % String(cover_card.zone)
	return true

## test_pilot_062_luoern.gd - 洛尔恩（pilot_062，联邦 N）效果测试
##
## 洛尔恩 2 个效果（被动 LISTEN，无按钮）：
##   effect_01「转化掩护」（LISTEN COVER_WINDOW_EXTRA，每任意玩家回合1次）：掩护多选窗
##     显示「洛尔恩--掩护」复选框（条件：次数可用 + 手牌≥1行动牌）。选中后真实掩护先按顺序执行，
##     然后洛尔恩转化：弹行动牌单选窗（必须选1张，取消=不计次数）→ 选中牌移入临时区 →
##     PLAY_AS_NAMED 当作掩护（威力-5，不耗攻击数）→ 链末入弃牌堆。无行动牌则效果直接结束不计次。
##   effect_02「掩护加成」（LISTEN USE_ACTION_AFTER）：我方使用掩护（转化或原版，不含进攻）后
##     立即弹二选一（可取消）：该攻击损伤-1（MODIFY_ATTACK_MARKERS fork_persist 写 fork_extra_markers，
##     双连 fork 深拷贝保留）/ 该攻击不能被响应（SET_ATTACK_NO_RESPONSE 写 attack record.no_response，
##     ATTACK_AT 响应窗口直接跳过，任何响应包括识破都不弹）。
##
## 关键覆盖点：
##   1. 效果定义（e1 LISTEN COVER_WINDOW_EXTRA + 条件；e2 LISTEN USE_ACTION_AFTER + 条件+二选一）。
##   2. e1 掩护窗口 extra 选项：勾选洛尔恩转化 -> 选燃料行动牌 -> 转化掩护威力-5 -> 燃料进弃牌堆。
##   3. e1 额度消耗（store_result_key 确认路径自动 mark once_per_turn）。
##   4. e1 无行动牌：extra 不显示（不弹窗），不计次。
##   5. e1 取消：不计次（额度仍可用）。
##   6. e2 损伤-1：掩护后 fork_extra_markers=-1（双连复制攻击继承减损）。
##   7. e2 不可响应：掩护后 attack record.no_response=true，ATTACK_AT 不弹响应窗口。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90064
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
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


func _make_attack(battle: BattleState, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_attack_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": extra.get("weapon_id", &""),
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 确保某张行动牌在指定玩家手里（无 availability 注册——燃料牌当作掩护无需响应能力）。
func _put_card_in_hand(battle, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, player_id)
	if card == null:
		return &""
	var player = gs.players.get(player_id)
	player.action_hand.append(card.instance_id)
	card.zone = &"action_hand"
	card.mech_id = &""
	return card.instance_id


## 确保某张行动牌在指定玩家手里并注册 AVAILABILITY（迎击牌响应窗口用）。
func _ensure_card_in_enemy_hand(battle, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	for cid: StringName in enemy.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and String(c.def.card_id) == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and String(c.def.card_id) == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			enemy.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &"enemy"
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 标准布局：player(10,0) enemy(11,0)，玩家带洛尔恩，注册 cover_effect1（掩护窗口），
## 双方行动手牌清空。返回 {battle, pilot_card, player_mech, enemy_mech, gs, player, cover_e1}。
func _setup(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	for cid: StringName in player.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
	for cid: StringName in enemy.action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		enemy.action_hand.erase(cid)
	# 洛尔恩 -> player_mech（自动注册 e1->COVER_WINDOW_EXTRA、e2->USE_ACTION_AFTER permanent listener）
	var pilot_card = _make_instance(gs, cdb, "pilot_062_洛尔恩", &"player")
	if pilot_card == null:
		return {}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, pilot_card)
	# 注册 cover_effect1（掩护多选窗，collect_cover_window_extras=true）。
	# 须用真实掩护牌实例注册：cover_effect1.permanent_while_in_hand=true，
	# _listener_card_still_active 会按 source_card_id 查牌并要求其 zone==action_hand，
	# 用假 id 会被跳过（监听器永不激活）。
	var cover_card = _make_instance(gs, cdb, "action_016_掩护", &"player")
	if cover_card == null:
		return {}
	cover_card.mech_id = player_mech.mech_id
	player.action_hand.append(cover_card.instance_id)
	cover_card.zone = &"action_hand"
	var cover_e1 = _GeneratedActionEffects.build_all_effects().get(&"cover_effect1")
	if cover_e1 == null:
		return {}
	battle.context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_PRE, cover_e1, {
		"card_instance_id": cover_card.instance_id,
		"player_id": &"player",
		"mech_id": player_mech.mech_id,
		"card_def_id": &"action_016_掩护",
		"slot_id": &"action_hand",
	})
	battle.context.action_ui_bridge.context = battle.context
	return {"battle": battle, "pilot_card": pilot_card, "player_mech": player_mech, "enemy_mech": enemy_mech, "gs": gs, "player": player, "cover_e1": cover_e1}


## 洛尔恩 once_per_turn 已用计数（timing_engine._once_per_turn_used）
func _opt_used(te, pilot_card) -> int:
	var key: String = "%s:%s" % [String(pilot_card.instance_id), "pilot_062_effect_01"]
	var used_map: Dictionary = te._once_per_turn_used.get(key, {})
	if used_map.is_empty():
		return 0
	var total: int = 0
	for k in used_map:
		total += int(used_map[k])
	return total


# ═══════════════════════════════════════════
# 测试
# ═══════════════════════════════════════════

## 测试1：effect_01 / effect_02 定义正确
func test_luoern_effect_definition() -> Variant:
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_062_effect_01")
	if e1 == null:
		return "缺 pilot_062_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.COVER_WINDOW_EXTRA:
		return "effect_01 listen_timing 应 COVER_WINDOW_EXTRA 实=%s" % String(e1.listen_timing)
	if e1.display_name != "洛尔恩--掩护":
		return "effect_01 display_name 应「洛尔恩--掩护」实=%s" % e1.display_name
	var conds: Array = e1.conditions
	var has_opt: bool = false
	var has_card: bool = false
	for c in conds:
		if String(c.get("op", &"")) == &"EFFECT_ONCE_PER_TURN_AVAILABLE":
			has_opt = true
		if String(c.get("op", &"")) == &"HAS_ACTION_CARD_IN_HAND":
			has_card = true
	if not has_opt or not has_card:
		return "effect_01 应含 EFFECT_ONCE_PER_TURN_AVAILABLE + HAS_ACTION_CARD_IN_HAND 条件"
	var acts: Array = e1.actions
	if acts.is_empty() or String(acts[0].get("type", &"")) != &"CHOOSE_MANY_CARDS":
		return "effect_01 actions[0] 应 CHOOSE_MANY_CARDS"
	if String(acts[0].get("params", {}).get("store_result_key", &"")) != &"pilot_062_fuel_ids":
		return "effect_01 应 store_result_key=pilot_062_fuel_ids"
	var e2 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_062_effect_02")
	if e2 == null:
		return "缺 pilot_062_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 MODE_LISTEN 实=%s" % String(e2.mode)
	if e2.listen_timing != _TimingConst.USE_ACTION_AFTER:
		return "effect_02 listen_timing 应 USE_ACTION_AFTER 实=%s" % String(e2.listen_timing)
	if e2.listen_action_type != &"use_action_card":
		return "effect_02 listen_action_type 应 use_action_card"
	var e2_conds: Array = e2.conditions
	var has_cover: bool = false
	var has_self: bool = false
	for c in e2_conds:
		if String(c.get("op", &"")) == &"USED_CARD_IS_COVER":
			has_cover = true
		if String(c.get("op", &"")) == &"USED_CARD_EXECUTOR_IS_SELF":
			has_self = true
	if not has_cover or not has_self:
		return "effect_02 应含 USED_CARD_IS_COVER + USED_CARD_EXECUTOR_IS_SELF 条件"
	var e2_acts: Array = e2.actions
	if e2_acts.is_empty() or String(e2_acts[0].get("type", &"")) != &"CHOOSE_ONE":
		return "effect_02 actions[0] 应 CHOOSE_ONE"
	var opts: Array = e2_acts[0].get("params", {}).get("options", [])
	if opts.size() != 2:
		return "effect_02 应 2 个选项，实=%d" % opts.size()
	var opt_types: Array = []
	for o in opts:
		opt_types.append(String(o.get("actions", [{}])[0].get("type", &"")))
	if not opt_types.has("MODIFY_ATTACK_MARKERS") or not opt_types.has("SET_ATTACK_NO_RESPONSE"):
		return "effect_02 选项应含 MODIFY_ATTACK_MARKERS + SET_ATTACK_NO_RESPONSE，实=%s" % str(opt_types)
	return true


## 测试2：转化掩护全流程——掩护窗口勾选洛尔恩 -> 选燃料行动牌 -> 威力-5 -> 燃料进弃牌堆；
## USE_ACTION_AFTER 弹效果2 -> 选「损伤-1」-> fork_extra_markers=-1；额度消耗。
func test_luoern_cover_convert_full_flow() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup(battle)
	if s.is_empty():
		return "标准布局失败"
	var gs = s.gs
	var player_mech = s.player_mech
	var enemy_mech = s.enemy_mech
	var player = s.player
	var pilot_card = s.pilot_card
	# 燃料行动牌（普通攻击牌当作掩护）
	var fuel_cid: StringName = _put_card_in_hand(battle, &"player", "action_001_进攻")
	if fuel_cid == &"":
		return "找不到燃料行动牌"
	# enemy 攻击 player（holder 自身被攻击 -> cover_effect1 触发）
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# ① 掩护窗口弹 select_thrust_cards
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards(掩护窗口)，实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")
	# ② 勾选洛尔恩转化（不选真实掩护）
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {
		"selected_card_ids": [],
		"selected_extra_ids": ["pilot_062_effect_01"],
	})
	await _pump_frames(3)
	# ③ 洛尔恩转化：弹行动牌单选窗 select_thrust_cards（燃料牌）
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_thrust_cards":
		return "洛尔恩转化应弹 select_thrust_cards(选行动牌)，实际: %s" % String(wait2.get("input_type", &""))
	var convert_action_id: StringName = wait2.get("action_id", &"")
	# ④ 选燃料牌确认 -> 转化掩护 use_action_card（-5）-> USE_ACTION_AFTER 弹效果2
	battle.context.timing_engine.resume_pending_effect(convert_action_id, {"selected_card_ids": [fuel_cid]})
	await _pump_frames(6)
	var wait3: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait3.get("input_type", &"")) != &"choose_one_effect":
		return "掩护后应弹 choose_one_effect(效果2)，实际: %s" % String(wait3.get("input_type", &""))
	var e2_action_id: StringName = wait3.get("action_id", &"")
	# ⑤ 选「该攻击损伤-1」(option 0)
	battle.context.timing_engine.resume_pending_effect(e2_action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	# ⑥ 验证：威力-5 + fork_extra_markers=-1（双连 fork 深拷贝保留）
	if int(attack.record.get("extra_might", 0)) != -5:
		return "转化掩护威力应-5，实际: %d" % int(attack.record.get("extra_might", 0))
	if int(attack.record.get("fork_extra_markers", 0)) != -1:
		return "效果2损伤-1 fork_extra_markers 应=-1，实际: %d" % int(attack.record.get("fork_extra_markers", 0))
	# ⑦ 燃料牌进弃牌堆
	var fuel_card = gs.get_card(fuel_cid)
	if fuel_card == null or String(fuel_card.zone) != &"discard":
		return "燃料牌应进弃牌堆，zone=%s" % String(fuel_card.zone if fuel_card else "null")
	# ⑧ 洛尔恩每回合1次额度已消耗
	if _opt_used(battle.context.timing_engine, pilot_card) < 1:
		return "洛尔恩转化额度应已消耗"
	# ⑨ 确认无残留挂起动作
	var waiting: Array = []
	for aid: StringName in battle.context.action_registry.get_active_ids():
		var a = battle.context.action_registry.get_action(aid)
		if a and (a.state == &"waiting_input" or a.state == &"waiting_timing" or a.state == &"waiting_effect_action"):
			waiting.append("%s:%s" % [String(aid), String(a.state)])
	if not waiting.is_empty():
		return "转化流程后残留挂起动作: %s" % str(waiting)
	return true


## 测试3：无行动牌 -> 洛尔恩 extra 不显示（掩护窗口不弹），不计次
func test_luoern_no_action_card_no_extra() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup(battle)
	if s.is_empty():
		return "标准布局失败"
	var player_mech = s.player_mech
	var enemy_mech = s.enemy_mech
	var pilot_card = s.pilot_card
	# 清空玩家手牌（含 _setup 放入的掩护牌离手 -> cover_e1 不激活、洛尔恩无行动牌）
	var gs3 = s.gs
	var player3 = s.player
	for cid3: StringName in player3.action_hand.duplicate():
		var c3 = gs3.get_card(cid3)
		player3.action_hand.erase(cid3)
		if c3:
			c3.zone = &""
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# 无真实掩护 + 无 extra -> 不应弹 select_thrust_cards
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) == &"select_thrust_cards":
		return "无行动牌时不应弹掩护窗口，实际弹了 select_thrust_cards"
	# 不计次
	if _opt_used(battle.context.timing_engine, pilot_card) != 0:
		return "无行动牌应不计次，实际已用 %d" % _opt_used(battle.context.timing_engine, pilot_card)
	return true


## 测试4：洛尔恩转化选择取消 -> 不计次（额度仍可用）
func test_luoern_convert_cancel_no_count() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup(battle)
	if s.is_empty():
		return "标准布局失败"
	var player_mech = s.player_mech
	var enemy_mech = s.enemy_mech
	var pilot_card = s.pilot_card
	var fuel_cid: StringName = _put_card_in_hand(battle, &"player", "action_001_进攻")
	if fuel_cid == &"":
		return "找不到燃料行动牌"
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards(掩护窗口)，实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {
		"selected_card_ids": [],
		"selected_extra_ids": ["pilot_062_effect_01"],
	})
	await _pump_frames(3)
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_thrust_cards":
		return "洛尔恩转化应弹 select_thrust_cards(选行动牌)，实际: %s" % String(wait2.get("input_type", &""))
	var convert_action_id: StringName = wait2.get("action_id", &"")
	# 取消选牌 -> 不计次
	battle.context.timing_engine.resume_pending_effect(convert_action_id, {"cancelled": true})
	await _pump_frames(5)
	if _opt_used(battle.context.timing_engine, pilot_card) != 0:
		return "洛尔恩转化取消应不计次，实际已用 %d" % _opt_used(battle.context.timing_engine, pilot_card)
	# 燃料牌仍在手牌（未弃）
	var fuel_card = battle.context.game_state.get_card(fuel_cid)
	if fuel_card == null or String(fuel_card.zone) != &"action_hand":
		return "取消后燃料牌应仍在手牌，zone=%s" % String(fuel_card.zone if fuel_card else "null")
	return true


## 测试5：效果2「该攻击不能被响应」——掩护后 SET_ATTACK_NO_RESPONSE 写 no_response，
## ATTACK_AT 即使目标有迎击牌也不弹响应窗口。
func test_luoern_cover_no_response() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s := _setup(battle)
	if s.is_empty():
		return "标准布局失败"
	var gs = s.gs
	var player_mech = s.player_mech
	var enemy_mech = s.enemy_mech
	var fuel_cid: StringName = _put_card_in_hand(battle, &"player", "action_001_进攻")
	if fuel_cid == &"":
		return "找不到燃料行动牌"
	# enemy 持迎击牌（注册 AVAILABILITY，若弹响应窗口则可选）——数据中无「action_002_迎击」，
	# 迎击牌为 action_008_回避/009_防御/010_反击/011_疾行/012_识破；防御牌含 defend_availability。
	var intercept_cid: StringName = _ensure_card_in_enemy_hand(battle, "action_009_防御")
	if intercept_cid == &"":
		return "找不到敌方迎击牌"
	# enemy 攻击 player
	var attack := _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards(掩护窗口)，实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {
		"selected_card_ids": [],
		"selected_extra_ids": ["pilot_062_effect_01"],
	})
	await _pump_frames(3)
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_thrust_cards":
		return "洛尔恩转化应弹 select_thrust_cards(选行动牌)，实际: %s" % String(wait2.get("input_type", &""))
	var convert_action_id: StringName = wait2.get("action_id", &"")
	battle.context.timing_engine.resume_pending_effect(convert_action_id, {"selected_card_ids": [fuel_cid]})
	await _pump_frames(6)
	var wait3: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait3.get("input_type", &"")) != &"choose_one_effect":
		return "掩护后应弹 choose_one_effect(效果2)，实际: %s" % String(wait3.get("input_type", &""))
	var e2_action_id: StringName = wait3.get("action_id", &"")
	# 选「该攻击不能被响应」(option 1)
	battle.context.timing_engine.resume_pending_effect(e2_action_id, {"chosen_option_index": 1})
	await _pump_frames(6)
	# 验证 attack record.no_response=true
	if not bool(attack.record.get("no_response", false)):
		return "效果2选不可响应后 attack.no_response 应=true"
	# ATTACK_AT fire：即使 enemy 有迎击牌（AVAILABILITY），no_response 抑制响应窗口 -> 不弹 respond_attack
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AT, attack)
	await _pump_frames(3)
	var wait4: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait4.get("input_type", &"")) == &"respond_attack":
		return "no_response 攻击不应弹响应窗口，实际弹了 respond_attack"
	return true

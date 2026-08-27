## test_pilot_066_hacker.gd - 骇客（pilot_066，联邦 N，cost 3, attack_limit 1, action_card_limit 4）
##
## 骇客效果（运行时机师效果走 ActionPilotEffects 新体系，通用模块 VIEW_RANDOM_OTHER_HAND_CARDS）：
##   effect_01（DIRECT 显示按钮，开关）：随时按弹"启用/禁用骇客技能"二选一（可取消）。
##     flag 存 card.counters["pilot_066_hack_switch"]（默认启用=true）。CHOOSE_ONE 两选项各带
##     CARD_COUNTER_IS 条件过滤——仅当前状态对应的"翻转"选项可见；选中即 SET_CARD_COUNTER 翻转。
##   effect_02（LISTEN BASIC_MOVE_AFTER 隐藏，merge_desc_into_index=1，priority 10）：
##     我方回合2次，我方机甲基础移动后，若3格范围内有持行动牌的其他机甲，直接弹目标选择
##     （valid_mech_ids 只高亮可选；取消不消耗次数），选定后随机查看其2张行动牌
##     （context.synced_shuffle 洗牌保证 PvP 双端同步；不足2张看全部），非阻塞浮窗只给查看方本人看。
##     类型加成（各计一次可叠加）：含攻击 -> 本回合攻击次数+1（MODIFY_ATTACK_COUNT THIS_TURN）；
##     含迎击 -> 本回合行动牌上限+1（MODIFY_ACTION_HAND_LIMIT THIS_TURN）；含辅助 -> 回复3动力
##     （RESTORE_POWER）。确认选目标才 MARK_EFFECT_ONCE_PER_TURN_USED（取消不计次）。
##   组件全通用：SET_CARD_COUNTER/CARD_COUNTER_IS（开关）+ OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE
##   （3格内持牌候选）+ EFFECT_ONCE_PER_TURN_AVAILABLE（每回合2次）+ VIEW_RANDOM_OTHER_HAND_CARDS（模块）。
##
## 覆盖：定义结构 / 开关翻转 / 攻击+辅助双加成 / 迎击加成（不足2张看全部）/ 取消不消耗次数 /
##       每回合2次用满停触发 / 越程不触发 / 无持牌候选不触发 / 开关禁用不触发 /
##       TurnService 回合末清理 action_hand_limit_modifier（含攻击数还原）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GeneratedPilotEffects = preload("res://scripts/generated_database/GeneratedPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90066
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	# 骇客窥牌选目标/浮窗需人类玩家路径（AI 自动跳过不挂起）；双方都设人类
	for pid in [&"player", &"enemy"]:
		var p = battle.context.game_state.players.get(pid)
		if p != null:
			p.is_human = true
	return battle


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 设骇客为 owner_id 机甲的机师（set_pilot 注册 DIRECT 开关 + LISTEN 监听器）；返回字典
func _setup_hacker(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_066_骇客", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {
		"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb,
		"te": battle.context.timing_engine,
		"enemy_mech": gs.get_mech_for_player(&"enemy"),
		"enemy_player": gs.players.get(&"enemy"),
		"player": gs.players.get(&"player"),
	}


## 构造 basic_move 动作（fire BASIC_MOVE_AFTER 用），已注册进 action_registry。
func _make_move(battle, mover_mech_id: StringName) -> _Action:
	var mv := _Action.new()
	mv.action_id = &"test_p066_mv_%d" % [randi() % 1000000]
	mv.action_type = &"basic_move"
	mv.record = {"mech_id": mover_mech_id, "power_cost": 1, "free_move": false}
	mv.state = &"running"
	mv.context = battle.context
	battle.context.action_registry.register(mv)
	return mv


## 在 _pending_effect 中找 phase 匹配的挂起 effect 动作 id；无返回 &""。
func _find_pending_action(battle, phase: String) -> StringName:
	var pending: Dictionary = battle.context.timing_engine._pending_effect
	for aid: StringName in pending:
		if String(pending[aid].get("phase", &"")) == phase:
			return aid
	return &""


## 找一张指定 action_type 的行动牌 def_id（cdb 已加载全部行动牌）。
func _find_action_def_id(cdb, want_type: String) -> String:
	for def in cdb.list_cards_by_kind(&"action"):
		if String(def.action_type) == want_type:
			return String(def.card_id)
	return ""


## 清空 action_hand 后，给 pid 玩家放 types（"攻击"/"迎击"/"辅助"数组）对应的行动牌实例；返回实例 id 数组
func _set_hand_types(s, pid: StringName, types: Array) -> Array:
	var p = s.gs.players.get(pid)
	if p == null:
		return []
	p.action_hand.clear()
	var ids: Array = []
	for t: String in types:
		var def_id := _find_action_def_id(s.cdb, t)
		if def_id == "":
			return []
		var c = _make_instance(s.gs, s.cdb, def_id, pid)
		if c == null:
			return []
		p.action_hand.append(c.instance_id)
		ids.append(c.instance_id)
	return ids


## 触发骇客 effect_01（DIRECT 开关按钮），返回挂起的 effect_fire action（或 null）
func _fire_pilot_066_toggle(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_066_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_066_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## 读取机师牌 counters["pilot_066_hack_switch"]（不存在按默认 true）
func _hack_flag(pilot_card) -> bool:
	if pilot_card == null:
		return true
	if not "counters" in pilot_card:
		return true
	return bool(pilot_card.counters.get("pilot_066_hack_switch", true))


## 连接 action_needs_input 捕获展示浮窗参数（存 Array 防 lambda 捕获坑）。
## out_arr 存 {"type": input_type, "params": input_params}；若传 target_arr，则单独收 select_mech_target 参数。
func _capture_display(battle, out_arr: Array, target_arr: Array = []) -> void:
	if battle.context.timing_engine.action_needs_input.is_connected(_on_display_input):
		battle.context.timing_engine.action_needs_input.disconnect(_on_display_input)
	battle.context.timing_engine.action_needs_input.connect(_on_display_input.bind(out_arr, target_arr))


func _on_display_input(action_id: StringName, input_type: StringName, input_params: Dictionary, out_arr: Array, target_arr: Array) -> void:
	if String(input_type) == "view_random_other_hand_show_display":
		out_arr.append(input_params)
	elif String(input_type) == "select_mech_target":
		target_arr.append(input_params)


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：2 效果定义正确（e1 DIRECT 开关 CHOOSE_ONE / e2 隐藏 LISTEN BASIC_MOVE_AFTER 窥牌）
func test_p066_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()

	var e1 = effs.get(&"pilot_066_effect_01")
	if e1 == null:
		return "缺 pilot_066_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 DIRECT"
	if not e1.hide_button == false:
		return "effect_01 应是可见按钮"
	if e1.actions.is_empty() or String(e1.actions[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 actions[0] 应 CHOOSE_ONE"
	var p1: Dictionary = e1.actions[0].get("params", {})
	if not p1.get("optional", false):
		return "effect_01 CHOOSE_ONE 应 optional（可取消）"
	var opts1: Array = p1.get("options", [])
	if opts1.size() != 2:
		return "effect_01 应有 2 个开关选项 实=%d" % opts1.size()
	# 选项0=禁用（条件 flag==true，动作为 SET_CARD_COUNTER value=false）
	var o0: Dictionary = opts1[0] if opts1[0] is Dictionary else {}
	var o0_acts: Array = o0.get("actions", [])
	if o0_acts.is_empty() or String(o0_acts[0].get("type", &"")) != "SET_CARD_COUNTER":
		return "选项0 动作应 SET_CARD_COUNTER"
	var o0_p: Dictionary = o0_acts[0].get("params", {}) if o0_acts[0] is Dictionary else {}
	if String(o0_p.get("key", &"")) != "pilot_066_hack_switch" or bool(o0_p.get("value", true)) != false:
		return "选项0 SET_CARD_COUNTER 应 value=false（禁用）"
	# 选项1=启用（条件 flag==false，动作为 SET_CARD_COUNTER value=true）
	var o1: Dictionary = opts1[1] if opts1[1] is Dictionary else {}
	var o1_acts: Array = o1.get("actions", [])
	if o1_acts.is_empty() or String(o1_acts[0].get("type", &"")) != "SET_CARD_COUNTER":
		return "选项1 动作应 SET_CARD_COUNTER"
	var o1_p: Dictionary = o1_acts[0].get("params", {}) if o1_acts[0] is Dictionary else {}
	if String(o1_p.get("key", &"")) != "pilot_066_hack_switch" or bool(o1_p.get("value", false)) != true:
		return "选项1 SET_CARD_COUNTER 应 value=true（启用）"

	var e2 = effs.get(&"pilot_066_effect_02")
	if e2 == null:
		return "缺 pilot_066_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN"
	if e2.listen_timing != _TimingConst.BASIC_MOVE_AFTER:
		return "effect_02 应监听 BASIC_MOVE_AFTER"
	if String(e2.listen_action_type) != "basic_move":
		return "effect_02 listen_action_type 应 basic_move"
	if not e2.hide_button:
		return "effect_02 应 hide_button"
	if int(e2.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1"
	if int(e2.priority) != 10:
		return "effect_02 priority 应 10"
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	for want in ["IS_OWNER_TURN", "SELF_MECH_IS_MOVE_SUBJECT", "CARD_COUNTER_IS", "EFFECT_ONCE_PER_TURN_AVAILABLE", "OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE"]:
		if not ops2.has(want):
			return "effect_02 缺条件 %s" % want
	# EFFECT_ONCE_PER_TURN_AVAILABLE max=2
	var eoa_max := 0
	for c in e2.conditions:
		var cop: String = String(c.get("op", &""))
		var cp: Dictionary = c.get("params", {})
		if cop == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			eoa_max = int(cp.get("once_per_turn_max", 0))
			if String(cp.get("once_per_turn_key", &"")) != "pilot_066_effect_02":
				return "EFFECT_ONCE_PER_TURN_AVAILABLE once_per_turn_key 应 pilot_066_effect_02"
		if cop == "OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE" and int(cp.get("range", 0)) != 3:
			return "OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE range 应 3"
	if eoa_max != 2:
		return "EFFECT_ONCE_PER_TURN_AVAILABLE max 应 2 实=%d" % eoa_max
	if e2.actions.is_empty() or String(e2.actions[0].get("type", &"")) != "VIEW_RANDOM_OTHER_HAND_CARDS":
		return "effect_02 actions[0] 应 VIEW_RANDOM_OTHER_HAND_CARDS"
	var p2: Dictionary = e2.actions[0].get("params", {})
	if int(p2.get("range", 0)) != 3 or int(p2.get("view_count", 0)) != 2:
		return "effect_02 params range 应 3 view_count 应 2 实=%s" % str(p2)
	if int(p2.get("attack_bonus", 0)) != 1 or int(p2.get("action_hand_bonus", 0)) != 1 or int(p2.get("support_power", 0)) != 3:
		return "effect_02 params 加成应 attack=1 hand=1 power=3 实=%s" % str(p2)
	if String(p2.get("once_per_turn_key", &"")) != "pilot_066_effect_02":
		return "effect_02 params once_per_turn_key 应 pilot_066_effect_02"
	if String(p2.get("store_target_key", &"")) != "pilot_066_target_id":
		return "effect_02 params store_target_key 应 pilot_066_target_id"

	# 旧 CardEffect 定义已删（迁移至 ActionPilotEffects）
	if _GeneratedPilotEffects.build_pilot_effects().has(&"pilot_066_effect_01"):
		return "旧 GeneratedPilotEffects 不应再有 pilot_066_effect_01"

	# set_pilot 注册监听器（DIRECT 虚拟时点 + BASIC_MOVE_AFTER LISTEN）
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_066_骇客 或 effect_ids 未更新）"
	var te = s.te
	var found_direct := false
	var found_listen := false
	for entry in te.permanent_listeners.get(&"pilot_066_effect_01", []):
		var eff = entry.get("effect", null)
		if eff != null and String(eff.effect_id) == "pilot_066_effect_01":
			found_direct = true
	for entry in te.permanent_listeners.get(_TimingConst.BASIC_MOVE_AFTER, []):
		var eff = entry.get("effect", null)
		if eff != null and String(eff.effect_id) == "pilot_066_effect_02":
			found_listen = true
	if not (found_direct and found_listen):
		return "监听器注册不全 direct=%s listen=%s" % [str(found_direct), str(found_listen)]
	return true


# ═══════════════════════════════════════════
# 开关测试
# ═══════════════════════════════════════════

## 测试2：默认启用(absent=true)->按按钮弹窗->选"禁用"(选项0)->flag=false；再按->选"启用"(选项1)->flag=true
func test_p066_toggle_off_then_on() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var pilot = s.pilot_card

	# 默认启用
	if not _hack_flag(pilot):
		return "默认 flag 应启用(true)"

	# ① 按开关：应弹 CHOOSE_ONE（pre_actions_target），仅"禁用"选项可见
	var ef1 := await _fire_pilot_066_toggle(battle, pilot, s.mech, &"player")
	if ef1 == null:
		return "effect_01 应挂起弹开关二选一窗"
	if _find_pending_action(battle, "pre_actions_target") != ef1.action_id:
		return "effect_01 应挂起 pre_actions_target（即 effect_fire 本动作）"
	# 选"禁用"（选项0）
	battle.context.timing_engine.resume_pending_effect(ef1.action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	if _hack_flag(pilot):
		return "选禁用后 flag 应 false 实=%s" % str(_hack_flag(pilot))

	# ② 再按开关：应弹窗，仅"启用"选项可见（flag==false 命中选项1）
	var ef2 := await _fire_pilot_066_toggle(battle, pilot, s.mech, &"player")
	if ef2 == null:
		return "第二次 effect_01 应挂起弹开关二选一窗"
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"chosen_option_index": 1})
	await _pump_frames(6)
	if not _hack_flag(pilot):
		return "选启用后 flag 应 true 实=%s" % str(_hack_flag(pilot))
	return true


# ═══════════════════════════════════════════
# 窥牌行为测试
# ═══════════════════════════════════════════

## 触发骇客窥牌：设敌机3格内持牌 -> fire BASIC_MOVE_AFTER -> 返回挂起的 move action
## （模块应已弹目标选择并挂起 phase=view_random_other_hand_target）
func _trigger_hack_target(battle, s) -> _Action:
	battle.context.game_state.active_player_id = &"player"
	battle.context.game_state.phase = &"MAIN"
	s.mech.position = {"q": 0, "r": 0}
	s.enemy_mech.position = {"q": 0, "r": 1}  # 距离1 <= 3
	var mv := _make_move(battle, s.mech.mech_id)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AFTER, mv)
	return mv


## 测试3：攻击+辅助双加成——敌手牌[攻击,辅助] -> 查看2张 -> 攻击次数+1 + 回复3动力，且展示浮窗2张
func test_p066_peek_attack_support() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var te = s.te
	# 敌手牌：攻击 + 辅助（2张 = view_count，全看）
	var given := _set_hand_types(s, &"enemy", ["攻击", "辅助"])
	if given.size() != 2:
		return "敌手牌构建失败：%s" % str(given)
	# 记录加成前（动力压到1，留出+3的验证空间）
	s.mech.power = 1
	var atk_before: int = s.mech.max_attacks_per_turn
	var power_before: int = s.mech.power
	# 捕获展示浮窗 + 目标选择参数（候选 valid_mech_ids 在目标选择信号里）
	var displays: Array = []
	var target_inputs: Array = []
	_capture_display(battle, displays, target_inputs)

	var mv := _trigger_hack_target(battle, s)
	if mv.state != &"waiting_timing":
		return "范围内持牌移动应弹目标选择阻塞，state=%s" % String(mv.state)
	var aid := _find_pending_action(battle, "view_random_other_hand_target")
	if aid == &"":
		return "应挂起 view_random_other_hand_target"
	# 校验候选 valid_mech_ids 只含敌机（目标选择信号参数）
	if target_inputs.size() != 1:
		return "应弹1次目标选择 实=%d" % target_inputs.size()
	var valid: Array = target_inputs[0].get("valid_mech_ids", [])
	if valid.size() != 1 or String(valid[0]) != String(s.enemy_mech.mech_id):
		return "候选应仅敌机 实=%s" % str(valid)

	# 确认选敌机 -> 查看+加成
	te.resume_pending_effect(aid, {"target_mech_id": s.enemy_mech.mech_id})
	await _pump_frames(8)
	if s.mech.max_attacks_per_turn != atk_before + 1:
		return "含攻击牌本回合攻击数应+1 实 %d -> %d" % [atk_before, s.mech.max_attacks_per_turn]
	if s.mech.power != power_before + 3:
		return "含辅助牌应回复3动力 实 %d -> %d" % [power_before, s.mech.power]
	# 展示浮窗：2张
	if displays.size() != 1:
		return "应恰好1次展示浮窗 实=%d" % displays.size()
	var disp_cards: Array = displays[0].get("display_cards", [])
	if disp_cards.size() != 2:
		return "展示应2张牌 实=%d" % disp_cards.size()
	# 标记已消耗1次（本回合剩余1次）
	if not te.is_once_per_turn_key_available(&"pilot_066_effect_02", s.pilot_card.instance_id, 2):
		return "确认后应消耗1次（剩1次可用）"
	return true


## 测试4：迎击加成——敌手牌[迎击]（1张 < view_count，看全部）-> 行动牌上限+1，无攻击/辅助加成
func test_p066_peek_counter_fewer_than_two() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var te = s.te
	var given := _set_hand_types(s, &"enemy", ["迎击"])
	if given.size() != 1:
		return "敌手牌构建失败"
	var hand_before: int = s.player.action_card_limit
	var atk_before: int = s.mech.max_attacks_per_turn
	var power_before: int = s.mech.power
	var displays: Array = []
	_capture_display(battle, displays)

	var mv := _trigger_hack_target(battle, s)
	if mv.state != &"waiting_timing":
		return "应弹目标选择阻塞"
	var aid := _find_pending_action(battle, "view_random_other_hand_target")
	if aid == &"":
		return "应挂起 view_random_other_hand_target"
	te.resume_pending_effect(aid, {"target_mech_id": s.enemy_mech.mech_id})
	await _pump_frames(8)
	if s.player.action_card_limit != hand_before + 1:
		return "含迎击牌本回合行动牌上限应+1 实 %d -> %d" % [hand_before, s.player.action_card_limit]
	if s.mech.max_attacks_per_turn != atk_before:
		return "无攻击牌攻击数不应变 实 %d" % s.mech.max_attacks_per_turn
	if s.mech.power != power_before:
		return "无辅助牌动力不应变 实 %d" % s.mech.power
	if displays.size() != 1 or (displays[0].get("display_cards", []) as Array).size() != 1:
		return "展示应1张牌（不足2张看全部）实=%s" % str(displays[0].get("display_cards", []) if displays.size() else [])
	return true


## 测试5：取消选目标 -> 不发动加成 + 不消耗次数（再移动仍可触发）
func test_p066_cancel_no_consume() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var te = s.te
	_set_hand_types(s, &"enemy", ["攻击"])
	var atk_before: int = s.mech.max_attacks_per_turn
	var power_before: int = s.mech.power

	# ① 触发 -> 取消
	var mv := _trigger_hack_target(battle, s)
	if mv.state != &"waiting_timing":
		return "应弹目标选择阻塞"
	var aid := _find_pending_action(battle, "view_random_other_hand_target")
	if aid == &"":
		return "应挂起 view_random_other_hand_target"
	te.resume_pending_effect(aid, {"cancelled": true})
	await _pump_frames(6)
	if s.mech.max_attacks_per_turn != atk_before or s.mech.power != power_before:
		return "取消不应有任何加成"
	if not te.is_once_per_turn_key_available(&"pilot_066_effect_02", s.pilot_card.instance_id, 2):
		return "取消不应消耗次数"

	# ② 再次移动仍可触发（次数未被消耗）
	var mv2 := _trigger_hack_target(battle, s)
	if mv2.state != &"waiting_timing":
		return "取消后再移动应仍能触发"
	var aid2 := _find_pending_action(battle, "view_random_other_hand_target")
	if aid2 == &"":
		return "取消后应仍挂起目标选择"
	te.resume_pending_effect(aid2, {"target_mech_id": s.enemy_mech.mech_id})
	await _pump_frames(8)
	if s.mech.max_attacks_per_turn != atk_before + 1:
		return "确认后攻击数应+1 实 %d" % s.mech.max_attacks_per_turn
	return true


## 测试6：每回合2次用满 -> 第3次移动不再触发（EFFECT_ONCE_PER_TURN_AVAILABLE 拦截）
func test_p066_two_uses_then_stops() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var te = s.te
	_set_hand_types(s, &"enemy", ["攻击"])
	var atk_before: int = s.mech.max_attacks_per_turn

	# 第1次使用
	var mv1 := _trigger_hack_target(battle, s)
	if mv1.state != &"waiting_timing":
		return "第1次移动应触发"
	var aid1 := _find_pending_action(battle, "view_random_other_hand_target")
	te.resume_pending_effect(aid1, {"target_mech_id": s.enemy_mech.mech_id})
	await _pump_frames(8)
	if s.mech.max_attacks_per_turn != atk_before + 1:
		return "第1次攻击数应+1"
	# 第2次使用
	var mv2 := _trigger_hack_target(battle, s)
	if mv2.state != &"waiting_timing":
		return "第2次移动应触发"
	var aid2 := _find_pending_action(battle, "view_random_other_hand_target")
	te.resume_pending_effect(aid2, {"target_mech_id": s.enemy_mech.mech_id})
	await _pump_frames(8)
	if s.mech.max_attacks_per_turn != atk_before + 2:
		return "第2次攻击数应再+1（共+2）实 %d" % s.mech.max_attacks_per_turn
	# 第3次移动：不应再触发（2次用满）
	var mv3 := _trigger_hack_target(battle, s)
	await _pump_frames(4)
	if mv3.state == &"waiting_timing" and _find_pending_action(battle, "view_random_other_hand_target") != &"":
		return "第3次移动不应触发窥牌（2次用满）"
	if s.mech.max_attacks_per_turn != atk_before + 2:
		return "第3次不应再加成 实 %d" % s.mech.max_attacks_per_turn
	return true


## 测试7：敌机3格外（无持牌候选）-> 不触发（OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE 排除）
func test_p066_out_of_range_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.mech.position = {"q": 0, "r": 0}
	s.enemy_mech.position = {"q": 10, "r": 0}  # 距离10 > 3
	battle.context.game_state.active_player_id = &"player"
	# 确保敌机持牌（仅 isolate 距离条件）
	if s.enemy_player.action_hand.is_empty():
		var atk_def_id := _find_action_def_id(s.cdb, "攻击")
		if atk_def_id == "":
			return "无攻击行动牌"
		s.enemy_player.action_hand.append(_make_instance(s.gs, s.cdb, atk_def_id, &"enemy").instance_id)
	var mv := _make_move(battle, s.mech.mech_id)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AFTER, mv)
	await _pump_frames(4)
	if mv.state == &"waiting_timing" and _find_pending_action(battle, "view_random_other_hand_target") != &"":
		return "3格外移动不应触发窥牌"
	return true


## 测试8：范围内无敌机持行动牌（0张）-> 不触发（OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE 要求持牌）
func test_p066_no_candidate_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	s.enemy_player.action_hand.clear()  # 敌机0张行动牌
	battle.context.game_state.active_player_id = &"player"
	s.mech.position = {"q": 0, "r": 0}
	s.enemy_mech.position = {"q": 0, "r": 1}
	var mv := _make_move(battle, s.mech.mech_id)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AFTER, mv)
	await _pump_frames(4)
	if mv.state == &"waiting_timing" and _find_pending_action(battle, "view_random_other_hand_target") != &"":
		return "无敌机持行动牌不应触发窥牌"
	return true


## 测试9：开关禁用 -> 不触发（CARD_COUNTER_IS flag=false 拦截）
func test_p066_switch_off_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	# 先禁用开关
	var ef := await _fire_pilot_066_toggle(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 应挂起"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"chosen_option_index": 0})
	await _pump_frames(6)
	if _hack_flag(s.pilot_card):
		return "禁用后 flag 应 false"
	_set_hand_types(s, &"enemy", ["攻击"])
	battle.context.game_state.active_player_id = &"player"
	s.mech.position = {"q": 0, "r": 0}
	s.enemy_mech.position = {"q": 0, "r": 1}
	var mv := _make_move(battle, s.mech.mech_id)
	s.te.fire_timing(_TimingConst.BASIC_MOVE_AFTER, mv)
	await _pump_frames(4)
	if mv.state == &"waiting_timing" and _find_pending_action(battle, "view_random_other_hand_target") != &"":
		return "开关禁用后不应触发窥牌"
	return true


## 测试10：TurnService 回合末清理——action_hand_limit_modifier(+1) 还原 action_card_limit；
## 同时攻击数修饰符也还原（modify_attack_count THIS_TURN 写入 mech.statuses）
func test_p066_turn_end_cleanup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hacker(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	# 手动构造 THIS_TURN 修饰符（骇客窥到迎击+攻击牌会各写1条）
	var hand_lim_before: int = s.player.action_card_limit
	var atk_before: int = s.mech.max_attacks_per_turn
	s.player.action_card_limit += 1
	s.player.statuses.append({"type": &"action_hand_limit_modifier", "delta": 1, "duration": &"THIS_TURN"})
	s.mech.max_attacks_per_turn += 1
	s.mech.statuses.append({"type": &"attack_count_modifier", "delta": 1, "duration": &"THIS_TURN"})
	# 回合末清理
	battle.context.turn_service._clean_this_turn_durations(&"player")
	if s.player.action_card_limit != hand_lim_before:
		return "回合末应还原 action_card_limit 实 %d -> %d" % [hand_lim_before, s.player.action_card_limit]
	if s.mech.max_attacks_per_turn != atk_before:
		return "回合末应还原攻击数 实 %d -> %d" % [atk_before, s.mech.max_attacks_per_turn]
	# 修饰符应被移除
	for st in s.player.statuses:
		if String(st.get("type", &"")) == "action_hand_limit_modifier":
			return "action_hand_limit_modifier 应已移除"
	for st in s.mech.statuses:
		if String(st.get("type", &"")) == "attack_count_modifier":
			return "attack_count_modifier 应已移除"
	return true

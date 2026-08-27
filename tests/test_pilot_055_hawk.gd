## test_pilot_055_hawk.gd - 霍克（pilot_055）效果测试
##
## 霍克 1 个被动按钮（效果1，悬框描述）：
##   我方回合1次，可以使卖出装备牌获得的金币*2，若卖出的是高级装备牌，则再获得3金币。
##
## 通用机制（后续可复用，纯通用组件组装）：
##   · LISTEN 监听通用弃置前时点 DISCARD_BEFORE（discard_card 动作第一步，handler 先建快照再 fire）。
##   · DISCARD_REASON_IS reason=[sell, sell_set_equipment]：只响应「卖出」触发的弃牌
##     （手牌卖出=sell；备用区/已设置卖出=sell_set_equipment）。非卖出弃牌不触发。
##   · DISCARD_INCLUDED_OWNER_ACTION_CARD card_kind=equipment：本次卖出的是效果持有者自己的装备牌
##     （from_mech_id==效果持有者机甲）。他人卖自己的装备不误配。
##   · DISCARD_EQUIPMENT_IS_ADVANCED：被卖装备稀有度 SR/SSR 才算高级（规则书：高级装备牌堆含 SR、SSR）。
##   · $discard_equipment_cost 通用表达式：读被弃装备牌 cost 作补发金额（=卖价，补发1倍即×2）。
##   · EFFECT_ONCE_PER_TURN_AVAILABLE(key,max1) + 发动分支显式 MARK_EFFECT_ONCE_PER_TURN_USED；
##     effect 级不设 once_per_turn_key（避免取消分支 auto-mark 误计次）。确认才计次，取消不计。
##   · CHOOSE_ONE optional:true 确认弹窗（可取消不计次）。
##   · GAIN_GOLD 统一金币动作（$binding_context.player_id 归属效果持有者）。
##
## 关键覆盖点：
##   1. 效果定义正确（LISTEN 时点/条件/额度 key/无 effect 级 key/动作链/高级奖励分支 condition）。
##   2. 卖出普通装备 -> 确认 -> 金币+2×卖价（补发1倍），不额外+3。
##   3. 卖出高级装备（SSR）-> 确认 -> 金币+2×卖价+3。
##   4. 卖出 -> 取消 -> 只获卖价（不补发不计次），可再触发。
##   5. 每回合1次用满 -> 同回合第2次卖出不弹窗、不补发。
##   6. PVP3 多人类玩家通用：third 卖出触发按玩家隔离（金币只动 third 的）。
##   7. 敌方卖出不触发（DISCARD_INCLUDED_OWNER_ACTION_CARD 归属判定）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90055
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
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


## 设霍克为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, player}
func _setup_hawk(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_055_霍克", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb, "player": gs.players.get(owner_id)}


## 创建独立玩家 third + 机甲（PVP3 多人），返回机甲；null 失败
func _create_third_player(battle) -> _MechState:
	var gs = battle.context.game_state
	var p = _PlayerState.new()
	p.player_id = &"third"
	p.gold = 15
	p.is_human = true
	gs.players[&"third"] = p
	var m := _MechState.new()
	m.mech_id = &"third_mech"
	m.owner_player_id = &"third"
	m.max_hp = 25
	m.current_hp = 25
	m.max_power = 10
	m.power = 10
	m.position = {"q": 6, "r": 2}
	for slot_id in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿", &"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2", &"event", &"pilot"]:
		var sl := _MechSlotState.new()
		sl.slot_id = slot_id
		sl.slot_kind = &"PART"
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m
	return m


## 把一张装备牌放进 pid 的装备手牌（mech_id=该玩家机甲，模拟装备归属），返回实例；null 失败
func _put_equipment_in_hand(battle, pid: StringName, def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(pid)
	if mech == null:
		return null
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return null
	card.mech_id = mech.mech_id
	card.zone = &"equipment_hand"
	gs.players.get(pid).equipment_hand.append(card.instance_id)
	return card


## 找挂起的弃牌 action（霍克 CHOOSE_ONE 确认）；无挂起返回 null。
func _find_suspended_discard_action(battle):
	for a in battle.context.action_registry.get_actions_by_type(&"discard_card"):
		if a.state == &"waiting_timing" or a.state == &"waiting_input":
			return a
	return null


## 走真实卖出（CardSetService 先 gain_gold(sell_price) 后 discard → DISCARD_BEFORE 触发霍克）。
## 返回挂起的 discard action；无挂起返回 null。
func _fire_sell(battle, pid: StringName, card) -> Variant:
	battle.context.game_state.active_player_id = pid
	# 重置卖出次数（本测试只关心霍克额度，不测卖出次数限制）
	battle.context.game_state.players.get(pid).sell_equipment_count_this_turn = 0
	battle.context.card_set_service.sell_equipment(pid, card.instance_id)
	await _pump_frames(8)
	return _find_suspended_discard_action(battle)


## resume CHOOSE_ONE 确认（chosen_option_index 0=发动 1=取消）
func _resume_choose(battle, act, option_index: int) -> void:
	battle.context.timing_engine.resume_pending_effect(act.action_id, {"chosen_option_index": option_index})
	await _pump_frames(12)


func _gold(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).gold


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：效果定义正确（LISTEN 时点/条件/额度 key/动作链/高级奖励分支 condition/无 effect 级 key）
func test_pilot_055_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_055_effect_01")
	if e1 == null:
		return "缺 pilot_055_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.DISCARD_BEFORE:
		return "effect_01 应监听 DISCARD_BEFORE 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "discard_card":
		return "effect_01 listen_action_type 应 discard_card"
	if e1.hide_button:
		return "effect_01 应是显示按钮（被动按钮+悬框描述）"
	if e1.once_per_turn_key != &"":
		return "effect_01 不应设 effect 级 once_per_turn_key（走显式 MARK 计次）"
	var e1_ops: Array = []
	var reasons_ok := false
	var owner_ok := false
	var quota_ok := false
	for c in e1.conditions:
		var op := String(c.get("op", &""))
		e1_ops.append(op)
		if op == "DISCARD_REASON_IS":
			var r_p: Array = c.get("params", {}).get("reason", [])
			if r_p.has(&"sell") and r_p.has(&"sell_set_equipment"):
				reasons_ok = true
		elif op == "DISCARD_INCLUDED_OWNER_ACTION_CARD":
			if String(c.get("params", {}).get("card_kind", &"")) == "equipment":
				owner_ok = true
		elif op == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			var c_p = c.get("params", {})
			if String(c_p.get("once_per_turn_key", &"")) == "pilot_055_effect_01" and int(c_p.get("once_per_turn_max", 0)) == 1:
				quota_ok = true
	if not reasons_ok:
		return "effect_01 DISCARD_REASON_IS 应含 reason=[sell, sell_set_equipment]"
	if not owner_ok:
		return "effect_01 应含 DISCARD_INCLUDED_OWNER_ACTION_CARD(card_kind=equipment)"
	if not quota_ok:
		return "effect_01 额度应为 pilot_055_effect_01 max=1（每回合1次）"
	if not e1_ops.has("DISCARD_EQUIPMENT_IS_ADVANCED"):
		# DISCARD_EQUIPMENT_IS_ADVANCED 应在发动分支的 +3 金币动作 condition 上（下断）
		pass
	var e1_acts = e1.actions
	if e1_acts.size() != 1 or String(e1_acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 动作0 应 CHOOSE_ONE（确认弹窗）"
	var co_params = e1_acts[0].get("params", {})
	if not bool(co_params.get("optional", false)):
		return "effect_01 CHOOSE_ONE 应 optional=true（可取消不计次）"
	var opts: Array = co_params.get("options", [])
	if opts.size() != 2:
		return "effect_01 应2个分支 实=%d" % opts.size()
	var opt0: Array = opts[0].get("actions", [])
	var opt0_types: Array = []
	for a in opt0:
		opt0_types.append(String(a.get("type", &"")))
	if opt0_types != ["MARK_EFFECT_ONCE_PER_TURN_USED", "GAIN_GOLD", "GAIN_GOLD"]:
		return "effect_01 发动分支动作应为 [MARK, GAIN_GOLD, GAIN_GOLD] 实=%s" % str(opt0_types)
	var mark_params: Dictionary = opt0[0].get("params", {})
	if String(mark_params.get("once_per_turn_key", &"")) != "pilot_055_effect_01":
		return "effect_01 MARK 额度 key 应 pilot_055_effect_01"
	var gold_p: Dictionary = opt0[1].get("params", {})
	if String(gold_p.get("amount", &"")) != "$discard_equipment_cost":
		return "effect_01 补发 GAIN_GOLD amount 应 $discard_equipment_cost"
	if String(gold_p.get("player_id", &"")) != "$binding_context.player_id":
		return "effect_01 补发 GAIN_GOLD player_id 应 $binding_context.player_id"
	var gold2: Dictionary = opt0[2]
	var gold2_p: Dictionary = gold2.get("params", {})
	if int(gold2_p.get("amount", 0)) != 3:
		return "effect_01 高级 GAIN_GOLD 应 amount=3"
	if String(gold2_p.get("player_id", &"")) != "$binding_context.player_id":
		return "effect_01 高级 GAIN_GOLD player_id 应 $binding_context.player_id"
	if not gold2.has("condition"):
		return "effect_01 高级 +3 金币动作应带 condition（仅高级装备才给）"
	var gold2_cond: Array = gold2.get("condition", [])
	var cond_ok := false
	for cc in gold2_cond:
		if String(cc.get("op", &"")) == "DISCARD_EQUIPMENT_IS_ADVANCED":
			cond_ok = true
	if not cond_ok:
		return "effect_01 高级 +3 condition 应为 DISCARD_EQUIPMENT_IS_ADVANCED"
	if String(opts[1].get("label", &"")) != "取消" or opts[1].get("actions", []) != []:
		return "effect_01 取消分支应为空（不计次）"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：卖出普通装备 -> 确认 -> 金币+2×卖价（补发1倍），不额外+3
func test_pilot_055_sell_normal_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hawk(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	var card = _put_equipment_in_hand(battle, &"player", "part_001_量产装_头部")
	if card == null:
		return "普通装备入装失败"
	var cost: int = card.def.cost
	var gold_before: int = _gold(battle, &"player")
	var sell = await _fire_sell(battle, &"player", card)
	if sell == null:
		return "卖出普通装备后应挂起（霍克弹 CHOOSE_ONE 确认）"
	await _resume_choose(battle, sell, 0)
	if _gold(battle, &"player") != gold_before + cost * 2:
		return "普通卖出确认后金币应 +2×卖价（补发1倍） 实净变=%d" % (_gold(battle, &"player") - gold_before)
	return true


## 测试3：卖出高级装备（SSR）-> 确认 -> 金币+2×卖价+3
func test_pilot_055_sell_advanced_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hawk(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	var card = _put_equipment_in_hand(battle, &"player", "part_115_联邦的一角兽_头部")
	if card == null:
		return "高级装备入装失败"
	var cost: int = card.def.cost
	var gold_before: int = _gold(battle, &"player")
	var sell = await _fire_sell(battle, &"player", card)
	if sell == null:
		return "卖出高级装备后应挂起（霍克弹 CHOOSE_ONE 确认）"
	await _resume_choose(battle, sell, 0)
	if _gold(battle, &"player") != gold_before + cost * 2 + 3:
		return "高级卖出确认后金币应 +2×卖价+3 实净变=%d" % (_gold(battle, &"player") - gold_before)
	return true


## 测试4：卖出 -> 取消 -> 只获卖价（不补发不计次），可再触发
func test_pilot_055_sell_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hawk(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	# 第1次：卖出普通装备 -> 取消
	var card = _put_equipment_in_hand(battle, &"player", "part_001_量产装_头部")
	if card == null:
		return "普通装备入装失败"
	var cost: int = card.def.cost
	var gold_before: int = _gold(battle, &"player")
	var sell = await _fire_sell(battle, &"player", card)
	if sell == null:
		return "第1次卖出应挂起"
	await _resume_choose(battle, sell, 1)
	if _gold(battle, &"player") != gold_before + cost:
		return "取消后应只获卖价（不补发）"
	# 次数未消耗：再卖出另一张普通装备 -> 仍触发
	var card2 = _put_equipment_in_hand(battle, &"player", "part_002_量产装_躯干")
	if card2 == null:
		return "第二张普通装备入装失败"
	var cost2: int = card2.def.cost
	var gold_after_first: int = _gold(battle, &"player")
	var sell2 = await _fire_sell(battle, &"player", card2)
	if sell2 == null:
		return "取消后应可再触发（次数未消耗）"
	await _resume_choose(battle, sell2, 0)
	if _gold(battle, &"player") != gold_after_first + cost2 * 2:
		return "再次确认后金币应 +2×卖价 实净变=%d" % (_gold(battle, &"player") - gold_after_first)
	return true


## 测试5：每回合1次用满 -> 同回合第2次卖出不弹窗、不补发
func test_pilot_055_once_per_turn_max_1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hawk(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	# 第1次：卖出普通装备 -> 确认（计次）
	var card1 = _put_equipment_in_hand(battle, &"player", "part_001_量产装_头部")
	if card1 == null:
		return "第1张普通装备入装失败"
	var cost1: int = card1.def.cost
	var sell1 = await _fire_sell(battle, &"player", card1)
	if sell1 == null:
		return "第1次卖出未挂起"
	await _resume_choose(battle, sell1, 0)
	# 第2次：额度用满，跳过不弹窗、不补发
	var gold_before: int = _gold(battle, &"player")
	var card2 = _put_equipment_in_hand(battle, &"player", "part_002_量产装_躯干")
	if card2 == null:
		return "第2张普通装备入装失败"
	var cost2: int = card2.def.cost
	var sell2 = await _fire_sell(battle, &"player", card2)
	if sell2 != null:
		return "第2次不应挂起（每回合1次已用满）"
	if _gold(battle, &"player") != gold_before + cost2:
		return "第2次跳过应只获卖价（不补发）"
	return true


## 测试6：PVP3 多人类玩家通用——third 卖出触发按玩家隔离（金币只动 third 的）
func test_pilot_055_owner_isolation_pvp3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_hawk(battle, &"third")
	if s.is_empty():
		return "third setup 失败（霍克设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"third").gold = 50
	gs.players.get(&"player").gold = 50
	var card = _put_equipment_in_hand(battle, &"third", "part_001_量产装_头部")
	if card == null:
		return "third 普通装备入装失败"
	var cost: int = card.def.cost
	var third_gold_before: int = _gold(battle, &"third")
	var player_gold_before: int = _gold(battle, &"player")
	var sell = await _fire_sell(battle, &"third", card)
	if sell == null:
		return "third 卖出应挂起（霍克在 third 身上）"
	await _resume_choose(battle, sell, 0)
	if _gold(battle, &"third") != third_gold_before + cost * 2:
		return "third 确认后金币应 +2×卖价"
	if _gold(battle, &"player") != player_gold_before:
		return "third 触发不应影响 player 金币"
	return true


## 测试7：敌方卖出不触发（DISCARD_INCLUDED_OWNER_ACTION_CARD 归属判定）
func test_pilot_055_other_sell_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_hawk(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	gs.players.get(&"enemy").gold = 50
	var enemy_card = _put_equipment_in_hand(battle, &"enemy", "part_001_量产装_头部")
	if enemy_card == null:
		return "敌方装备入装失败"
	var cost: int = enemy_card.def.cost
	var player_gold_before: int = _gold(battle, &"player")
	var enemy_gold_before: int = _gold(battle, &"enemy")
	var sell = await _fire_sell(battle, &"enemy", enemy_card)
	if sell != null:
		return "敌方卖出不应触发霍克（归属判定应跳过）"
	if _gold(battle, &"enemy") != enemy_gold_before + cost:
		return "敌方应只获卖价"
	if _gold(battle, &"player") != player_gold_before:
		return "敌方卖出不应让霍克获金"
	return true

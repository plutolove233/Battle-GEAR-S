## test_pilot_051_likar.gd - 莉卡尔（pilot_051，秩序 R）效果测试
##
## 莉卡尔 1 个被动按钮（效果1，悬框描述）：
##   我方回合2次，从商店购买装备牌后可以获得3金币，若购买的是高级装备牌，则可再抽2张行动牌。
##
## 通用机制（后续可复用，纯通用组件组装）：
##   · LISTEN 监听通用商店购买时点 SHOP_BUY_AFTER（ShopService 三条购买路径统一 fire）。
##   · SHOP_BUYER_IS_SELF 条件：只对效果拥有者自己的购买生效（敌方购买不触发）。
##   · EFFECT_ONCE_PER_TURN_AVAILABLE(key,max2) + 发动分支显式 MARK_EFFECT_ONCE_PER_TURN_USED；
##     effect 级不设 once_per_turn_key（避免取消分支 auto-mark 误计次）。确认才计次，取消不计。
##   · CHOOSE_ONE optional:true 确认弹窗（可取消不计次）。
##   · 分支动作 condition（PAYLOAD_BOOL_IS_TRUE key=is_advanced）：仅高级装备（SR/SSR）才抽2行动牌。
##   · GAIN_GOLD amount=3 统一金币动作（$binding_context.player_id 归属购买者）。
##
## 关键覆盖点：
##   1. 效果定义正确（LISTEN 时点/条件/共享额度 key/无 effect 级 key/动作链）。
##   2. 购买普通装备 -> 确认 -> 金币+3，不抽行动牌。
##   3. 购买高级装备（SR/SSR）-> 确认 -> 金币+3 + 抽2行动牌。
##   4. 购买 -> 取消 -> 不获金不抽牌不计次，可再触发。
##   5. 每回合2次用满 -> 第3次购买触发被跳过。
##   6. PVP3 多人类玩家通用：third 玩家购买触发按玩家隔离（金币只动 third 的）。
##   7. 敌方购买不触发（SHOP_BUYER_IS_SELF 只认效果拥有者的购买）。
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
	battle.rng_seed = 90054
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


## 设莉卡尔为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, player}
func _setup_likal(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_051_莉卡尔", owner_id)
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


## 把一张装备牌放进商店普通槽位 slot_index（默认0），返回实例 id
func _put_normal_in_shop(battle, def_id: String, slot_index: int = 0) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, &"")
	if card == null:
		return &""
	card.zone = &"shop"
	gs.shop_state.normal_slots[slot_index] = card.instance_id
	return card.instance_id


## 把一张装备牌放进商店高级槽位，返回实例 id
func _put_advanced_in_shop(battle, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, &"")
	if card == null:
		return &""
	card.zone = &"shop"
	gs.shop_state.advanced_slot = card.instance_id
	return card.instance_id


## 找挂起的商店虚拟 action（莉卡尔 CHOOSE_ONE 确认）；无挂起返回 null。
func _find_suspended_shop_action(battle):
	for a in battle.context.action_registry.get_actions_by_type(&"shop"):
		if a.state == &"waiting_timing" or a.state == &"waiting_input":
			return a
	return null


## 走真实购买普通装备（fire SHOP_BUY_AFTER 触发莉卡尔 e1）。返回挂起的 shop action；无挂起返回 null。
func _fire_buy_normal(battle, pid: StringName, slot_index: int):
	battle.context.game_state.active_player_id = pid
	battle.context.shop_service.buy_normal_equipment(pid, slot_index)
	await _pump_frames(8)
	return _find_suspended_shop_action(battle)


## 走真实购买高级装备（fire SHOP_BUY_AFTER 触发莉卡尔 e1）。返回挂起的 shop action；无挂起返回 null。
func _fire_buy_advanced(battle, pid: StringName):
	battle.context.game_state.active_player_id = pid
	battle.context.shop_service.buy_advanced_equipment(pid)
	await _pump_frames(8)
	return _find_suspended_shop_action(battle)


## resume CHOOSE_ONE 确认（chosen_option_index 0=发动 1=取消）
func _resume_choose(battle, act, option_index: int) -> void:
	battle.context.timing_engine.resume_pending_effect(act.action_id, {"chosen_option_index": option_index})
	await _pump_frames(12)


func _gold(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).gold


func _action_hand_size(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).action_hand.size()


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：效果定义正确（LISTEN 时点/条件/额度 key/动作链/无 effect 级 key）
func test_pilot_051_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_051_effect_01")
	if e1 == null:
		return "缺 pilot_051_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.SHOP_BUY_AFTER:
		return "effect_01 应监听 SHOP_BUY_AFTER 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "shop":
		return "effect_01 listen_action_type 应 shop"
	if e1.hide_button:
		return "effect_01 应是显示按钮（1显示按钮模式）"
	if e1.once_per_turn_key != &"":
		return "effect_01 不应设 effect 级 once_per_turn_key（走显式 MARK 计次）"
	var e1_ops: Array = []
	for c in e1.conditions:
		e1_ops.append(String(c.get("op", &"")))
	for need in ["SHOP_BUYER_IS_SELF", "EFFECT_ONCE_PER_TURN_AVAILABLE"]:
		if not e1_ops.has(need):
			return "effect_01 应含条件 %s" % need
	for c in e1.conditions:
		if String(c.get("op", &"")) == "EFFECT_ONCE_PER_TURN_AVAILABLE":
			var c_p = c.get("params", {})
			if String(c_p.get("once_per_turn_key", &"")) != "pilot_051_effect_01" or int(c_p.get("once_per_turn_max", 0)) != 2:
				return "effect_01 额度应为 pilot_051_effect_01 max=2（每回合2次）"
	var e1_acts = e1.actions
	if e1_acts.size() != 1 or String(e1_acts[0].get("type", &"")) != "CHOOSE_ONE":
		return "effect_01 动作0 应 CHOOSE_ONE（确认弹窗）"
	var co_params = e1_acts[0].get("params", {})
	if not bool(co_params.get("optional", false)):
		return "effect_01 CHOOSE_ONE 应 optional=true（可取消不计次）"
	var opts: Array = co_params.get("options", [])
	if opts.size() != 2:
		return "effect_01 应2个分支 实=%d" % opts.size()
	var opt0_types: Array = []
	for a in opts[0].get("actions", []):
		opt0_types.append(String(a.get("type", &"")))
	if opt0_types != ["MARK_EFFECT_ONCE_PER_TURN_USED", "GAIN_GOLD", "EXECUTE_GAIN_CARD"]:
		return "effect_01 发动分支动作应为 [MARK, GAIN_GOLD, EXECUTE_GAIN_CARD] 实=%s" % str(opt0_types)
	var mark_params: Dictionary = opts[0].get("actions", [])[0].get("params", {})
	if String(mark_params.get("once_per_turn_key", &"")) != "pilot_051_effect_01":
		return "effect_01 MARK 额度 key 应 pilot_051_effect_01"
	var gold_p: Dictionary = opts[0].get("actions", [])[1].get("params", {})
	if int(gold_p.get("amount", 0)) != 3:
		return "effect_01 GAIN_GOLD 应 amount=3"
	if String(gold_p.get("player_id", &"")) != "$binding_context.player_id":
		return "effect_01 GAIN_GOLD player_id 应 $binding_context.player_id"
	var eg: Dictionary = opts[0].get("actions", [])[2]
	var eg_p: Dictionary = eg.get("params", {})
	if String(eg_p.get("from_zone", &"")) != "action_deck" or String(eg_p.get("card_kind", &"")) != "action" or int(eg_p.get("count", 0)) != 2:
		return "effect_01 应抽2张行动牌(action_deck)"
	if not eg.has("condition"):
		return "effect_01 抽牌动作应带 condition（仅高级装备才抽）"
	var eg_cond: Array = eg.get("condition", [])
	var cond_ok := false
	for cc in eg_cond:
		if String(cc.get("op", &"")) == "PAYLOAD_BOOL_IS_TRUE" and String(cc.get("params", {}).get("key", &"")) == "is_advanced":
			cond_ok = true
	if not cond_ok:
		return "effect_01 抽牌 condition 应为 PAYLOAD_BOOL_IS_TRUE(key=is_advanced)"
	if String(opts[1].get("label", &"")) != "取消" or opts[1].get("actions", []) != []:
		return "effect_01 取消分支应为空（不计次）"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：购买普通装备 -> 确认 -> 金币+3，不抽行动牌
func test_pilot_051_buy_normal_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_likal(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	var card_id: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if card_id == &"":
		return "普通装备上架失败"
	var card = gs.get_card(card_id)
	var price: int = battle.context.shop_service._get_buy_price(card)
	var gold_before: int = _gold(battle, &"player")
	var hand_before: int = _action_hand_size(battle, &"player")
	var buy = await _fire_buy_normal(battle, &"player", 0)
	if buy == null:
		return "购买普通装备后应挂起（莉卡尔弹 CHOOSE_ONE 确认）"
	await _resume_choose(battle, buy, 0)
	if _gold(battle, &"player") != gold_before - price + 3:
		return "确认后金币应 -%d+3 实净变=%d" % [price, _gold(battle, &"player") - gold_before + price]
	if _action_hand_size(battle, &"player") != hand_before:
		return "普通装备（非高级）购买后不应抽行动牌"
	return true


## 测试3：购买高级装备（SSR）-> 确认 -> 金币+3 + 抽2张行动牌
func test_pilot_051_buy_advanced_confirm() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_likal(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	var card_id: StringName = _put_advanced_in_shop(battle, "part_115_联邦的一角兽_头部")
	if card_id == &"":
		return "高级装备上架失败"
	var card = gs.get_card(card_id)
	var price: int = battle.context.shop_service._get_buy_price(card)
	var gold_before: int = _gold(battle, &"player")
	var hand_before: int = _action_hand_size(battle, &"player")
	var buy = await _fire_buy_advanced(battle, &"player")
	if buy == null:
		return "购买高级装备后应挂起（莉卡尔弹 CHOOSE_ONE 确认）"
	await _resume_choose(battle, buy, 0)
	if _gold(battle, &"player") != gold_before - price + 3:
		return "确认后金币应 -%d+3 实净变=%d" % [price, _gold(battle, &"player") - gold_before + price]
	if _action_hand_size(battle, &"player") != hand_before + 2:
		return "高级装备确认后应抽2张行动牌 实变=%d" % (_action_hand_size(battle, &"player") - hand_before)
	return true


## 测试4：购买 -> 取消 -> 不获金不抽牌不计次，可再触发
func test_pilot_051_buy_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_likal(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	var card_id: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if card_id == &"":
		return "普通装备上架失败"
	var card = gs.get_card(card_id)
	var price1: int = battle.context.shop_service._get_buy_price(card)
	var gold_before: int = _gold(battle, &"player")
	var hand_before: int = _action_hand_size(battle, &"player")
	var buy = await _fire_buy_normal(battle, &"player", 0)
	if buy == null:
		return "购买后应挂起"
	# 取消 -> 只付购买价，不获金不抽牌不计次
	await _resume_choose(battle, buy, 1)
	if _gold(battle, &"player") != gold_before - price1:
		return "取消后应只付购买价（不获3金币）"
	if _action_hand_size(battle, &"player") != hand_before:
		return "取消不应抽行动牌"
	# 次数未消耗：再购买另一张普通装备 -> 仍触发
	var card_id2: StringName = _put_normal_in_shop(battle, "part_002_量产装_躯干")
	if card_id2 == &"":
		return "第二张普通装备上架失败"
	var card2 = gs.get_card(card_id2)
	var price2: int = battle.context.shop_service._get_buy_price(card2)
	var gold_after_first: int = _gold(battle, &"player")
	var buy2 = await _fire_buy_normal(battle, &"player", 0)
	if buy2 == null:
		return "取消后应可再触发（次数未消耗）"
	await _resume_choose(battle, buy2, 0)
	if _gold(battle, &"player") != gold_after_first - price2 + 3:
		return "再次确认后金币应 -%d+3" % price2
	if _action_hand_size(battle, &"player") != hand_before:
		return "普通装备再次确认仍不应抽牌"
	return true


## 测试5：每回合2次用满 -> 第3次购买触发被跳过
func test_pilot_051_once_per_turn_max_2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_likal(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	var price: int = 0
	# 第1次：买普通装备 -> 确认
	var c1: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	var card1 = gs.get_card(c1)
	price = battle.context.shop_service._get_buy_price(card1)
	var buy1 = await _fire_buy_normal(battle, &"player", 0)
	if buy1 == null:
		return "第1次购买未挂起"
	await _resume_choose(battle, buy1, 0)
	# 第2次：买另一张普通装备 -> 确认
	var c2: StringName = _put_normal_in_shop(battle, "part_002_量产装_躯干")
	var card2 = gs.get_card(c2)
	price = battle.context.shop_service._get_buy_price(card2)
	var buy2 = await _fire_buy_normal(battle, &"player", 0)
	if buy2 == null:
		return "第2次购买未挂起"
	await _resume_choose(battle, buy2, 0)
	# 第3次：额度用满，跳过不弹窗、不获金
	var gold_before: int = _gold(battle, &"player")
	var hand_before: int = _action_hand_size(battle, &"player")
	var c3: StringName = _put_normal_in_shop(battle, "part_003_量产装_右臂")
	var card3 = gs.get_card(c3)
	price = battle.context.shop_service._get_buy_price(card3)
	var buy3 = await _fire_buy_normal(battle, &"player", 0)
	if buy3 != null:
		return "第3次不应挂起（每回合2次已用满）"
	if _gold(battle, &"player") != gold_before - price:
		return "第3次跳过应只付购买价（不获3金币）"
	if _action_hand_size(battle, &"player") != hand_before:
		return "第3次跳过不应抽行动牌"
	return true


## 测试6：PVP3 多人类玩家通用——third 玩家购买触发按玩家隔离（金币只动 third 的）
func test_pilot_051_owner_isolation_pvp3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_likal(battle, &"third")
	if s.is_empty():
		return "third setup 失败（莉卡尔设置到 third 机甲）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"third").gold = 50
	gs.players.get(&"player").gold = 50
	var card_id: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if card_id == &"":
		return "普通装备上架失败"
	var card = gs.get_card(card_id)
	var price: int = battle.context.shop_service._get_buy_price(card)
	var third_gold_before: int = _gold(battle, &"third")
	var player_gold_before: int = _gold(battle, &"player")
	var third_hand_before: int = _action_hand_size(battle, &"third")
	var player_hand_before: int = _action_hand_size(battle, &"player")
	var buy = await _fire_buy_normal(battle, &"third", 0)
	if buy == null:
		return "third 购买应挂起（莉卡尔在 third 身上）"
	await _resume_choose(battle, buy, 0)
	if _gold(battle, &"third") != third_gold_before - price + 3:
		return "third 确认后金币应 -%d+3" % price
	if _gold(battle, &"player") != player_gold_before:
		return "third 触发不应影响 player 金币"
	if _action_hand_size(battle, &"third") != third_hand_before:
		return "third 普通购买（非高级）不应抽牌"
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "third 触发不应影响 player 行动手牌"
	return true


## 测试7：敌方购买不触发（SHOP_BUYER_IS_SELF 只认效果拥有者的购买）
func test_pilot_051_other_buy_no_trigger() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_likal(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	gs.players.get(&"enemy").gold = 50
	var card_id: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if card_id == &"":
		return "普通装备上架失败"
	var card = gs.get_card(card_id)
	var price: int = battle.context.shop_service._get_buy_price(card)
	var player_gold_before: int = _gold(battle, &"player")
	var enemy_gold_before: int = _gold(battle, &"enemy")
	var player_hand_before: int = _action_hand_size(battle, &"player")
	# 敌方购买：莉卡尔在 player 身上，SHOP_BUYER_IS_SELF 应跳过，不弹窗
	var buy = await _fire_buy_normal(battle, &"enemy", 0)
	if buy != null:
		return "敌方购买不应触发莉卡尔（SHOP_BUYER_IS_SELF 应跳过）"
	if _gold(battle, &"player") != player_gold_before:
		return "敌方购买不应让莉卡尔获金"
	if _gold(battle, &"enemy") != enemy_gold_before - price:
		return "敌方应只付购买价"
	if _action_hand_size(battle, &"player") != player_hand_before:
		return "敌方购买不应让莉卡尔抽牌"
	return true

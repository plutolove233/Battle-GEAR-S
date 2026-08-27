## test_pilot_079_linuo.gd - 莉诺（pilot_079，秩序 N）效果测试
##
## 莉诺 1 个被动按钮（效果1，置灰+悬框描述）：
##   每回合2次，可以用原价购买商店里的1张装备牌（持有者回合）。
##
## 通用机制（纯通用组件组装，不绑机师）：
##   · 被动按钮（LISTEN TURN_START，IS_OWNER_TURN 条件）：持有者回合开始把机师牌实例
##     计数器 face_value_buy_uses 重置为2（SET_CARD_COUNTER）。
##   · 商店弹窗（app_root）按 get_face_value_buy_uses 剩余次数追加独立"用X原价购买"选项；
##     ShopService 购买时用原价（_get_face_value_price）并 consume 消耗1次。
##   · 独立于折扣：不读 DISCOUNT 状态、不消耗折扣、重置不覆盖折扣。
##
## 关键覆盖点：
##   1. 效果定义正确（LISTEN TURN_START / IS_OWNER_TURN / SET_CARD_COUNTER key+value）。
##   2. 设置莉诺后 fire TURN_START（先设 active_player_id）-> 计数器=2 + 查询 helper。
##   3. buy_normal_equipment(use_pilot_original=true) 按原价（cost）购买、金币-原价、次数-1。
##   4. 2次用满 -> 第3次原价购买被拒（守卫），普通全额购买仍可（独立）。
##   5. 下一回合 TURN_START 重置回2。
##   6. 与 DISCOUNT 折扣互不影响（原价购买不耗折扣、折扣购买不耗原价次数）。
##   7. 高级装备原价购买同样适用。
##   8. PVP3 多人类玩家通用：third 玩家原价购买按玩家隔离。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _StateSnapshot = preload("res://scripts/net/state_snapshot.gd")

var _turn_seq: int = 0


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90079
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


## PVP3 真实开局：setup_pvp3_battle（含3玩家/3机甲/牌堆）。返回 battle。
func _new_pvp3_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90079
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var setup_result: Dictionary = battle.context.game_setup_service.setup_pvp3_battle(registry)
	if not bool(setup_result.get("ok", false)):
		push_error(setup_result.message)
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


## 设莉诺为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, player}
func _setup_linuo(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_079_莉诺", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb, "player": gs.players.get(owner_id)}


## 构造 turn action（fire TURN_START 用；action_type 须与 TurnService._fire_timing
## 的虚拟 action 一致 &"turn"，否则 listen_action_type 过滤跳过）
func _make_turn_action(battle, turn_owner: StringName) -> _Action:
	_turn_seq += 1
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p079_turn_%d" % _turn_seq
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": turn_owner}
	turn_action.state = &"running"
	turn_action.context = battle.context
	battle.context.action_registry.register(turn_action)
	return turn_action


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


func _gold(battle, pid: StringName) -> int:
	return battle.context.game_state.players.get(pid).gold


## 普通槽0当前牌的原价（cost）
func _slot0_face_price(battle) -> int:
	var gs = battle.context.game_state
	var cid = gs.shop_state.normal_slots[0]
	var card = gs.get_card(cid)
	return battle.context.shop_service._get_face_value_price(card)


## 普通槽0当前牌的折扣价（1.5x）
func _slot0_buy_price(battle) -> int:
	var gs = battle.context.game_state
	var cid = gs.shop_state.normal_slots[0]
	var card = gs.get_card(cid)
	return battle.context.shop_service._get_buy_price(card)


## fire TURN_START（持有者回合，重置原价购买次数）。返回莉诺牌实例。
func _fire_owner_turn_start(battle, pid: StringName, pilot_card) -> void:
	var gs = battle.context.game_state
	gs.active_player_id = pid
	var turn_action := _make_turn_action(battle, pid)
	battle.context.timing_engine.fire_timing(_TimingConst.TURN_START, turn_action)
	await _pump_frames(6)


# ═══════════════════════════════════════════
# 定义测试
# ═══════════════════════════════════════════

## 测试1：效果定义正确（LISTEN TURN_START / IS_OWNER_TURN / SET_CARD_COUNTER key+value）
func test_pilot_079_effect_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_079_effect_01")
	if e1 == null:
		return "缺 pilot_079_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 MODE_LISTEN（被动置灰按钮）实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.TURN_START:
		return "effect_01 应监听 TURN_START 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "turn":
		return "effect_01 listen_action_type 应 turn"
	var has_own := false
	for c in e1.conditions:
		if String(c.get("op", &"")) == "IS_OWNER_TURN":
			has_own = true
	if not has_own:
		return "effect_01 应含 IS_OWNER_TURN 条件（持有者回合才重置）"
	var acts: Array = e1.actions
	if acts.size() != 1:
		return "effect_01 应1个动作 实=%d" % acts.size()
	var a0: Dictionary = acts[0]
	if String(a0.get("type", &"")) != "SET_CARD_COUNTER":
		return "effect_01 动作应 SET_CARD_COUNTER 实=%s" % String(a0.get("type", &""))
	var ap: Dictionary = a0.get("params", {})
	if String(ap.get("key", &"")) != "face_value_buy_uses":
		return "counter key 应 face_value_buy_uses 实=%s" % String(ap.get("key", &""))
	if int(ap.get("value", 0)) != 2:
		return "counter value 应 2（每回合2次）实=%d" % int(ap.get("value", 0))
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：设置莉诺 -> fire TURN_START（持有者回合）-> 计数器=2 + 查询 helper
func test_pilot_079_turn_start_reset_and_query() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_linuo(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	await _fire_owner_turn_start(battle, &"player", s.pilot_card)
	var n: int = int(s.pilot_card.counters.get(&"face_value_buy_uses", 0))
	if n != 2:
		return "TURN_START 后计数器应=2 实=%d" % n
	var q: Dictionary = _ActionPilotEffects.get_face_value_buy_uses(s.gs, &"player")
	if int(q.get("uses", 0)) != 2:
		return "get_face_value_buy_uses uses 应=2 实=%s" % str(q)
	if String(q.get("source_name", "")) != "莉诺":
		return "source_name 应=莉诺 实=%s" % String(q.get("source_name", ""))
	return true


## 测试3：buy_normal_equipment(use_pilot_original=true) 按原价购买、金币-原价、次数-1
func test_pilot_079_buy_normal_original_price() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_linuo(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	await _fire_owner_turn_start(battle, &"player", s.pilot_card)
	s.player.gold = 50
	var card_id: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if card_id == &"":
		return "普通装备上架失败"
	var price: int = _slot0_face_price(battle)
	var gold_before: int = _gold(battle, &"player")
	var hand_before: int = s.player.equipment_hand.size()
	var r = battle.context.shop_service.buy_normal_equipment(&"player", 0, false, true)
	if not bool(r.get("ok", false)):
		return "原价购买失败: %s" % String(r.get("message", ""))
	if _gold(battle, &"player") != gold_before - price:
		return "金币应-原价%d 实变=%d" % [price, _gold(battle, &"player") - gold_before]
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 1:
		return "购买后次数应=1（2->1）实=%d" % int(s.pilot_card.counters.get(&"face_value_buy_uses", 0))
	if s.player.equipment_hand.size() != hand_before + 1:
		return "购买后装备手牌应+1"
	return true


## 测试4：2次用满 -> 第3次原价购买被拒；普通全额购买仍可（独立）
func test_pilot_079_uses_exhausted_rejected() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_linuo(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	await _fire_owner_turn_start(battle, &"player", s.pilot_card)
	s.player.gold = 50
	# 第1次
	var c1: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if c1 == &"":
		return "第1次上架失败"
	var p1: int = _slot0_face_price(battle)
	var r1 = battle.context.shop_service.buy_normal_equipment(&"player", 0, false, true)
	if not bool(r1.get("ok", false)):
		return "第1次原价购买失败"
	# 第2次（槽0已补牌，重新上架一张）
	var c2: StringName = _put_normal_in_shop(battle, "part_002_量产装_躯干")
	if c2 == &"":
		return "第2次上架失败"
	var p2: int = _slot0_face_price(battle)
	var r2 = battle.context.shop_service.buy_normal_equipment(&"player", 0, false, true)
	if not bool(r2.get("ok", false)):
		return "第2次原价购买失败"
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 0:
		return "2次后次数应=0 实=%d" % int(s.pilot_card.counters.get(&"face_value_buy_uses", 0))
	# 第3次：次数不足被拒
	var gold_before: int = _gold(battle, &"player")
	var c3: StringName = _put_normal_in_shop(battle, "part_003_量产装_右臂")
	if c3 == &"":
		return "第3次上架失败"
	var r3 = battle.context.shop_service.buy_normal_equipment(&"player", 0, false, true)
	if bool(r3.get("ok", false)):
		return "第3次原价购买应被拒（次数用满）"
	if String(r3.get("message", "")) != "原价购买次数不足":
		return "拒绝消息应为'原价购买次数不足' 实=%s" % String(r3.get("message", ""))
	if _gold(battle, &"player") != gold_before:
		return "被拒不应扣金币"
	# 普通全额购买（不用原价次数）仍可：独立
	var c4: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if c4 == &"":
		return "全额购买上架失败"
	var full_price: int = _slot0_buy_price(battle)
	var gold_b4: int = _gold(battle, &"player")
	var r4 = battle.context.shop_service.buy_normal_equipment(&"player", 0, false, false)
	if not bool(r4.get("ok", false)):
		return "普通全额购买应成功: %s" % String(r4.get("message", ""))
	if _gold(battle, &"player") != gold_b4 - full_price:
		return "全额购买应按1.5x价%d 实变=%d" % [full_price, _gold(battle, &"player") - gold_b4]
	return true


## 测试5：下一回合 TURN_START -> 次数重置回2
func test_pilot_079_turn_start_reset_next_round() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_linuo(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	await _fire_owner_turn_start(battle, &"player", s.pilot_card)
	# 用掉1次
	s.player.gold = 50
	var c1: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if c1 == &"":
		return "上架失败"
	var r1 = battle.context.shop_service.buy_normal_equipment(&"player", 0, false, true)
	if not bool(r1.get("ok", false)):
		return "原价购买失败"
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 1:
		return "用掉1次后应=1"
	# 下个我方回合 TURN_START -> 重置为2
	await _fire_owner_turn_start(battle, &"player", s.pilot_card)
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 2:
		return "下回合 TURN_START 后应重置回2 实=%d" % int(s.pilot_card.counters.get(&"face_value_buy_uses", 0))
	return true


## 测试6：与 DISCOUNT 折扣互不影响（原价购买不耗折扣、折扣购买不耗原价次数）
func test_pilot_079_independent_of_discount() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_linuo(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	await _fire_owner_turn_start(battle, &"player", s.pilot_card)
	s.player.gold = 50
	# 手动加 DISCOUNT 状态 stacks=2（stacks>1 消耗时不会走 remove_status 路径）
	s.mech.statuses.append({"type": &"DISCOUNT", "stacks": 2, "status_id": &"test_p079_discount"})
	if battle.context.shop_service.get_discount_uses(&"player") != 2:
		return "DISCOUNT 前置 stacks 应=2"
	# 原价购买：只耗原价次数，不耗折扣
	var c1: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if c1 == &"":
		return "上架失败"
	var p1: int = _slot0_face_price(battle)
	var gold_before: int = _gold(battle, &"player")
	var r1 = battle.context.shop_service.buy_normal_equipment(&"player", 0, false, true)
	if not bool(r1.get("ok", false)):
		return "原价购买失败"
	if _gold(battle, &"player") != gold_before - p1:
		return "原价购买应-原价%d" % p1
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 1:
		return "原价购买后次数应=1"
	if battle.context.shop_service.get_discount_uses(&"player") != 2:
		return "原价购买不应消耗折扣（应仍=2）"
	# 折扣购买（use_face_value=true）：只耗折扣，不耗原价次数
	var c2: StringName = _put_normal_in_shop(battle, "part_002_量产装_躯干")
	if c2 == &"":
		return "折扣购买上架失败"
	var p2: int = _slot0_face_price(battle)
	var gold_b2: int = _gold(battle, &"player")
	var r2 = battle.context.shop_service.buy_normal_equipment(&"player", 0, true, false)
	if not bool(r2.get("ok", false)):
		return "折扣购买失败: %s" % String(r2.get("message", ""))
	if _gold(battle, &"player") != gold_b2 - p2:
		return "折扣购买应-原价%d" % p2
	if battle.context.shop_service.get_discount_uses(&"player") != 1:
		return "折扣购买应消耗1层（2->1）实=%d" % battle.context.shop_service.get_discount_uses(&"player")
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 1:
		return "折扣购买不应消耗原价次数（应仍=1）实=%d" % int(s.pilot_card.counters.get(&"face_value_buy_uses", 0))
	return true


## 测试7：高级装备原价购买同样适用
func test_pilot_079_buy_advanced_original_price() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_linuo(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	await _fire_owner_turn_start(battle, &"player", s.pilot_card)
	s.player.gold = 50
	var card_id: StringName = _put_advanced_in_shop(battle, "part_115_联邦的一角兽_头部")
	if card_id == &"":
		return "高级装备上架失败"
	var card = s.gs.get_card(card_id)
	var price: int = battle.context.shop_service._get_face_value_price(card)
	if price != 6:
		return "前置：part_115 原价应=6 实=%d" % price
	var gold_before: int = _gold(battle, &"player")
	var r = battle.context.shop_service.buy_advanced_equipment(&"player", false, true)
	if not bool(r.get("ok", false)):
		return "高级原价购买失败: %s" % String(r.get("message", ""))
	if _gold(battle, &"player") != gold_before - price:
		return "金币应-原价%d 实变=%d" % [price, _gold(battle, &"player") - gold_before]
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 1:
		return "高级原价购买后次数应=1 实=%d" % int(s.pilot_card.counters.get(&"face_value_buy_uses", 0))
	return true


## 测试8：PVP3 多人类玩家通用——third 玩家原价购买按玩家隔离
func test_pilot_079_pvp3_third_player_generic() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var third_mech = _create_third_player(battle)
	if third_mech == null:
		return "third 玩家创建失败"
	var s = _setup_linuo(battle, &"third")
	if s.is_empty():
		return "third setup 失败（莉诺设置到 third 机甲）"
	await _fire_owner_turn_start(battle, &"third", s.pilot_card)
	s.player.gold = 50
	var gs = battle.context.game_state
	gs.players.get(&"player").gold = 50
	var card_id: StringName = _put_normal_in_shop(battle, "part_001_量产装_头部")
	if card_id == &"":
		return "普通装备上架失败"
	var price: int = _slot0_face_price(battle)
	var third_gold_before: int = _gold(battle, &"third")
	var player_gold_before: int = _gold(battle, &"player")
	var r = battle.context.shop_service.buy_normal_equipment(&"third", 0, false, true)
	if not bool(r.get("ok", false)):
		return "third 原价购买失败: %s" % String(r.get("message", ""))
	if _gold(battle, &"third") != third_gold_before - price:
		return "third 金币应-原价%d 实变=%d" % [price, _gold(battle, &"third") - third_gold_before]
	if int(s.pilot_card.counters.get(&"face_value_buy_uses", 0)) != 1:
		return "third 购买后次数应=1 实=%d" % int(s.pilot_card.counters.get(&"face_value_buy_uses", 0))
	if _gold(battle, &"player") != player_gold_before:
		return "third 购买不应影响 player 金币"
	# third 的莉诺次数与 player 隔离：player 无莉诺 -> get_face_value_buy_uses 应=0
	var pq: Dictionary = _ActionPilotEffects.get_face_value_buy_uses(gs, &"player")
	if int(pq.get("uses", 0)) != 0:
		return "player（无莉诺）应无原价购买次数 实=%s" % str(pq)
	return true


## 测试9：PVP3 真实开局（setup_pvp3_battle）+ 真实 TurnService.start_turn("player")
## -> 莉诺计数器=2 + get_face_value_buy_uses=2（接近实机锁步路径）
func test_pilot_079_pvp3_real_start_turn() -> Variant:
	var battle := _new_pvp3_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var pmech = gs.get_mech_for_player(&"player")
	if pmech == null or not ("pilot" in pmech.slots):
		return "player 机甲无 pilot 槽（setup_pvp3 应建 PILOT 槽）"
	var card = _make_instance(gs, cdb, "pilot_079_莉诺", &"player")
	battle.context.game_setup_service.set_pilot(pmech.mech_id, card)
	var r = battle.context.turn_service.start_turn(&"player")
	if not bool(r.get("ok", false)):
		return "start_turn 失败: %s" % String(r.get("message", ""))
	await _pump_frames(10)
	var n: int = int(card.counters.get(&"face_value_buy_uses", 0))
	var q: Dictionary = _ActionPilotEffects.get_face_value_buy_uses(gs, &"player")
	if n != 2:
		return "PVP3 start_turn 后计数器应=2 实=%d" % n
	if int(q.get("uses", 0)) != 2:
		return "PVP3 真实路径 uses 应=2 实=%s" % str(q)
	return true


## 测试10：PVP3 快照往返——serialize(player 视角) → 新窗口 apply_snapshot → uses 仍=2
## （验证 client 窗口快照同步后商店弹窗能读到剩余次数）
func test_pilot_079_pvp3_snapshot_roundtrip() -> Variant:
	var battle := _new_pvp3_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var pmech = gs.get_mech_for_player(&"player")
	var card = _make_instance(gs, cdb, "pilot_079_莉诺", &"player")
	battle.context.game_setup_service.set_pilot(pmech.mech_id, card)
	var r = battle.context.turn_service.start_turn(&"player")
	if not bool(r.get("ok", false)):
		return "start_turn 失败"
	await _pump_frames(10)
	var snap: Dictionary = _StateSnapshot.new().serialize(battle.context, &"player")
	if int(_ActionPilotEffects.get_face_value_buy_uses(gs, &"player").get("uses", 0)) != 2:
		return "快照前 uses 应=2"
	# 反序列化到新窗口 gs（模拟 client 收到 snapshot）
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle2 := BattleState.new()
	battle2.rng_seed = 90079
	var start_result := battle2.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_StateSnapshot.new().apply_snapshot(battle2.context, snap)
	var q_after: Dictionary = _ActionPilotEffects.get_face_value_buy_uses(battle2.context.game_state, &"player")
	if int(q_after.get("uses", 0)) != 2:
		return "快照往返后 uses 应=2 实=%s" % str(q_after)
	return true


## 测试11：PVP3 UI 选项构建——模拟 app_root._on_shop_normal_buy_clicked 的
## 原价选项条件（uses>0 且 gold>=face_price），确认条件满足（bug：选项不显示）
func test_pilot_079_pvp3_ui_options_build() -> Variant:
	var battle := _new_pvp3_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var pmech = gs.get_mech_for_player(&"player")
	var card = _make_instance(gs, cdb, "pilot_079_莉诺", &"player")
	battle.context.game_setup_service.set_pilot(pmech.mech_id, card)
	var r = battle.context.turn_service.start_turn(&"player")
	if not bool(r.get("ok", false)):
		return "start_turn 失败"
	await _pump_frames(10)
	# 构造一张普通装备牌实例（不塞 shop_state，直接查价），复刻 app_root 选项条件
	var shop_svc = battle.context.shop_service
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"")
	if equip == null:
		return "装备牌实例构造失败"
	var full_price: int = shop_svc._get_buy_price(equip)
	var face_price: int = shop_svc._get_face_value_price(equip)
	var fv_buy: Dictionary = _ActionPilotEffects.get_face_value_buy_uses(gs, &"player")
	var pilot_face_uses: int = int(fv_buy.get("uses", 0))
	var can_afford_face: bool = gs.players.get(&"player").gold >= face_price
	if not (pilot_face_uses > 0 and can_afford_face):
		return "UI选项构建: 原价条件不满足 uses=%d gold=%d face=%d full=%d" % [pilot_face_uses, int(gs.players.get(&"player").gold), face_price, full_price]
	return true

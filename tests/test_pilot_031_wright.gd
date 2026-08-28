## test_pilot_031_wright.gd - 莱特（pilot_031，联邦 R）效果测试
##
## 效果1（DIRECT 按钮1，我方回合1次）「交牌·共抽·护甲」：
##   将任意张行动牌交给4格范围内1台其他机甲（选目标可取消，不消耗次数），
##   选牌窗不可取消（必须选≥1张确认）。X = floor(交牌数 / 2)：
##   交牌后我方与目标各抽 X 张行动牌，双方护甲 +2X（持续到下个我方回合开始）。
## 通用化：CHOOSE_OTHER_MECH + TARGET_IN_RANGE(4)；TRANSFER_ACTION_CARDS 交牌；
##   post_actions 用 $choice.count（抽牌/护甲量）与 $choice.card_ids（交牌）计算，零新增原子动作。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 531
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura），避免跨测试泄漏
func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)


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


## 设莱特为 player 机甲机师，返回 {player_mech, enemy_mech, pilot_card, gs}；失败返回空。
func _setup_pilot_031(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_instance(gs, cdb, "pilot_031_莱特", &"player")
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	return {"player_mech": player_mech, "enemy_mech": enemy_mech, "pilot_card": card, "gs": gs}


## 放机甲到指定坐标
func _place_mech(battle, mech_id: StringName, q: int, r: int) -> void:
	var mech = battle.context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.position = {"q": q, "r": r}


## 给 owner_id 玩家补 N 张行动牌（从牌堆顶抽），返回 [cid,...]
func _give_action_cards(battle, owner_id: StringName, count: int) -> Array:
	var gs = battle.context.game_state
	var player = gs.players.get(owner_id)
	var out: Array = []
	for i in range(count):
		if gs.deck_state.action_deck.is_empty():
			break
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		player.action_hand.append(cid)
		var c = gs.get_card(cid)
		if c != null:
			c.zone = &"action_hand"
			c.owner_player_id = owner_id
		out.append(cid)
	return out


## 清空 owner_id 行动手牌（移回牌堆顶，测试用占位）
func _clear_action_hand(battle, owner_id: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(owner_id)
	if player == null:
		return
	for cid in player.action_hand.duplicate():
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 触发莱特 DIRECT 按钮1（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_031(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_031_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_031_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": src,
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## 统计 mech 上 UNTIL_NEXT_OWNER_TURN ARMOR_MODIFIER 的总 delta（含指定 duration_owner_id 过滤）
func _armor_bonus(mech, owner_id: StringName = &"") -> int:
	var total: int = 0
	for s in mech.statuses:
		if String(s.get("type", &"")) != "ARMOR_MODIFIER":
			continue
		if String(s.get("duration", &"")) != "UNTIL_NEXT_OWNER_TURN":
			continue
		if owner_id != &"" and String(s.get("duration_owner_id", &"")) != String(owner_id):
			continue
		total += int(s.get("delta", 0))
	return total


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（DIRECT + 条件 + 目标规则 + once_per_turn + 选牌参数 + post_actions 链）
func test_pilot_031_effect_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_031_effect_01")
	if e == null:
		return "缺 pilot_031_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 DIRECT 实=%s" % String(e.mode)
	if e.once_per_turn_key != &"pilot_031_effect_01":
		return "once_per_turn_key 应 pilot_031_effect_01 实=%s" % String(e.once_per_turn_key)
	if int(e.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1（我方回合1次）"
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND", "HAS_OTHER_MECH_IN_HEX_RANGE"]:
		if not ops.has(need):
			return "effect_01 应含条件 %s 实=%s" % [need, str(ops)]
	for c in e.conditions:
		if String(c.get("op", &"")) == "HAS_OTHER_MECH_IN_HEX_RANGE" and int(c.get("params", {}).get("range", 0)) != 4:
			return "HAS_OTHER_MECH_IN_HEX_RANGE range 应 4"
	# 目标规则：CHOOSE_OTHER_MECH + TARGET_IN_RANGE(4, hex_distance)
	var rules: Array = e.target_rules
	var has_choose_other := false
	var has_range := false
	for r in rules:
		if String(r.get("rule", &"")) == "CHOOSE_OTHER_MECH":
			has_choose_other = true
		if String(r.get("rule", &"")) == "TARGET_IN_RANGE" and int(r.get("params", {}).get("range", 0)) == 4 and String(r.get("params", {}).get("metric", &"")) == "hex_distance":
			has_range = true
	if not has_choose_other:
		return "目标规则应含 CHOOSE_OTHER_MECH（除自己外全部机甲）"
	if not has_range:
		return "目标规则应含 TARGET_IN_RANGE(4, hex_distance)"
	# actions: [CHOOSE_MANY_CARDS]
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "effect_01 actions 应 [CHOOSE_MANY_CARDS]"
	var cm: Dictionary = acts[0].get("params", {})
	if cm.get("source", &"") != &"OWNER_ACTION_HAND":
		return "CHOOSE_MANY_CARDS source 应 OWNER_ACTION_HAND"
	if int(cm.get("min_count", 0)) != 1:
		return "CHOOSE_MANY_CARDS min_count 应 1（至少选1张）"
	if int(cm.get("max_count", 0)) != -1:
		return "CHOOSE_MANY_CARDS max_count 应 -1（任意张）"
	if not bool(cm.get("no_cancel", false)):
		return "CHOOSE_MANY_CARDS no_cancel 应 true（选牌窗不可取消）"
	if bool(cm.get("discard_selected", true)):
		return "CHOOSE_MANY_CARDS discard_selected 应 false（交牌由 TRANSFER 执行，不弃置）"
	var post: Array = cm.get("post_actions", [])
	if post.size() != 5:
		return "post_actions 应5个（交牌/我方抽/目标抽/我方护甲/目标护甲）实=%d" % post.size()
	# 1) TRANSFER_ACTION_CARDS
	var pa0: Dictionary = post[0]
	if String(pa0.get("type", &"")) != "TRANSFER_ACTION_CARDS":
		return "post_actions[0] 应 TRANSFER_ACTION_CARDS"
	if pa0.get("params", {}).get("card_ids", &"") != "$choice.card_ids":
		return "TRANSFER card_ids 应 $choice.card_ids"
	if pa0.get("params", {}).get("target_mech_id", &"") != "$payload.target_id":
		return "TRANSFER target_mech_id 应 $payload.target_id"
	# 2) 3) EXECUTE_GAIN_CARD（我方先抽、目标后抽，count=floor(count/2)）
	for i in [1, 2]:
		var pa: Dictionary = post[i]
		if String(pa.get("type", &"")) != "EXECUTE_GAIN_CARD":
			return "post_actions[%d] 应 EXECUTE_GAIN_CARD" % i
		if pa.get("params", {}).get("count_expr", "") != "int($choice.count / 2)":
			return "post_actions[%d] count_expr 应 int($choice.count / 2)" % i
		if pa.get("params", {}).get("from_zone", &"") != &"action_deck":
			return "post_actions[%d] from_zone 应 action_deck" % i
		if pa.get("params", {}).get("card_kind", &"") != &"action":
			return "post_actions[%d] card_kind 应 action" % i
	if post[1].get("params", {}).get("mech_ids", []) != ["$binding_context.mech_id"]:
		return "post_actions[1] mech_ids 应 [我方]"
	if post[2].get("params", {}).get("mech_ids", []) != ["$payload.target_id"]:
		return "post_actions[2] mech_ids 应 [目标]"
	# 4) 5) MODIFY_ARMOR（双方护甲 +2X，UNTIL_NEXT_OWNER_TURN + duration_owner_id=我方）
	for i in [3, 4]:
		var pa: Dictionary = post[i]
		if String(pa.get("type", &"")) != "MODIFY_ARMOR":
			return "post_actions[%d] 应 MODIFY_ARMOR" % i
		var pp: Dictionary = pa.get("params", {})
		if pp.get("delta_expr", "") != "int($choice.count / 2) * 2":
			return "post_actions[%d] delta_expr 应 int($choice.count / 2) * 2" % i
		if pp.get("duration", &"") != &"UNTIL_NEXT_OWNER_TURN":
			return "post_actions[%d] duration 应 UNTIL_NEXT_OWNER_TURN" % i
		if pp.get("duration_owner_id", &"") != "$binding_context.player_id":
			return "post_actions[%d] duration_owner_id 应 $binding_context.player_id（下个我方回合开始移除）" % i
	if post[3].get("params", {}).get("mech_id", &"") != "$binding_context.mech_id":
		return "post_actions[3] mech_id 应 $binding_context.mech_id"
	if post[4].get("params", {}).get("mech_id", &"") != "$payload.target_id":
		return "post_actions[4] mech_id 应 $payload.target_id"
	return true


# ═══════════════════════════════════════════
# 行为
# ═══════════════════════════════════════════

## 标准场景：莱特(player) + 敌机移到4格内(4,2)（player(2,2) 距离2）+ 双方手牌清空
func _setup_standard(battle) -> Dictionary:
	var setup = _setup_pilot_031(battle)
	if setup.is_empty():
		return {}
	_place_mech(battle, setup["enemy_mech"].mech_id, 4, 2)
	_clear_action_hand(battle, &"player")
	_clear_action_hand(battle, &"enemy")
	return setup


## 测试2：完整流程——交2张 -> 敌方收2张 + 双方各抽1 + 双方护甲+2 + 消耗次数
func test_pilot_031_effect_full_flow_2_cards() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var player = gs.players[&"player"]
	var enemy = gs.players[&"enemy"]
	# 给莱特 2 张行动牌
	var hand = _give_action_cards(battle, &"player", 2)
	if hand.size() != 2:
		return "无法补2张行动牌"
	var enemy_hand_before: int = enemy.action_hand.size()

	var ef = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起（应弹选机甲窗）"
	# 选目标（敌机，4格内）
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	if te._pending_effect.get(ef.action_id, {}).get("phase", &"") != &"choose_many_cards":
		return "选中机甲后应挂起选牌阶段（choose_many_cards）实=%s" % String(te._pending_effect.get(ef.action_id, {}).get("phase", &""))
	# 选2张行动牌确认
	var player_hand_before: int = player.action_hand.size()
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _pump_frames(12)
	# 交牌+双方抽牌均已完成：交出的牌进敌方手牌
	for cid in hand:
		if not enemy.action_hand.has(cid):
			return "交出的牌 %s 应进入敌方手牌" % String(cid)
	# 双方各抽 X=1：莱特手牌 = (2-2)+1 = 1；敌方手牌 = (原+2收到)+1抽 = 原+3
	if player.action_hand.size() != player_hand_before - 2 + 1:
		return "莱特应抽1张 after=%d（before=%d）" % [player.action_hand.size(), player_hand_before]
	if enemy.action_hand.size() != enemy_hand_before + 2 + 1:
		return "敌方应收2张+抽1张 after=%d（before=%d）" % [enemy.action_hand.size(), enemy_hand_before]
	# 双方护甲 +2（UNTIL_NEXT_OWNER_TURN，duration_owner_id=player）
	if _armor_bonus(player_mech, &"player") != 2:
		return "莱特护甲应+2 实=%d" % _armor_bonus(player_mech, &"player")
	if _armor_bonus(enemy_mech, &"player") != 2:
		return "目标护甲应+2 实=%d" % _armor_bonus(enemy_mech, &"player")
	# 消耗次数：第二次触发不挂起
	var ef2 = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef2 != null:
		return "每回合1次 -- 第二次触发不应挂起"
	return true


## 测试3：交4张 -> X=2：双方各抽2 + 双方护甲+4
func test_pilot_031_effect_4_cards_x2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var player = gs.players[&"player"]
	var enemy = gs.players[&"enemy"]
	var hand = _give_action_cards(battle, &"player", 4)
	if hand.size() != 4:
		return "无法补4张行动牌"
	var enemy_hand_before: int = enemy.action_hand.size()

	var ef = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _pump_frames(12)
	if player.action_hand.size() != 4 - 4 + 2:
		return "交4张应抽2 莱特手牌实=%d" % player.action_hand.size()
	if enemy.action_hand.size() != enemy_hand_before + 4 + 2:
		return "交4张敌方应收4+抽2 after=%d（before=%d）" % [enemy.action_hand.size(), enemy_hand_before]
	if _armor_bonus(player_mech, &"player") != 4:
		return "莱特护甲应+4 实=%d" % _armor_bonus(player_mech, &"player")
	if _armor_bonus(enemy_mech, &"player") != 4:
		return "目标护甲应+4 实=%d" % _armor_bonus(enemy_mech, &"player")
	return true


## 测试4：交1张 -> X=0：不抽牌、不加护甲（护甲守卫 delta=0 跳过）
func test_pilot_031_effect_1_card_x0() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var player = gs.players[&"player"]
	var enemy = gs.players[&"enemy"]
	var hand = _give_action_cards(battle, &"player", 1)
	if hand.size() != 1:
		return "无法补1张行动牌"
	var enemy_hand_before: int = enemy.action_hand.size()

	var ef = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _pump_frames(12)
	# 交1张成功（敌方 +1），但 X=0：不抽牌、不加护甲
	if enemy.action_hand.size() != enemy_hand_before + 1:
		return "交1张敌方手牌应收1 after=%d（before=%d）" % [enemy.action_hand.size(), enemy_hand_before]
	if player.action_hand.size() != 0:
		return "交1张 X=0 莱特不应抽牌 after=%d" % player.action_hand.size()
	if enemy.action_hand.size() != enemy_hand_before + 1 + 0:
		return "交1张敌方不应抽牌 after=%d" % enemy.action_hand.size()
	if _armor_bonus(player_mech, &"player") != 0:
		return "交1张 X=0 莱特不应加护甲 实=%d" % _armor_bonus(player_mech, &"player")
	if _armor_bonus(enemy_mech, &"player") != 0:
		return "交1张 X=0 目标不应加护甲 实=%d" % _armor_bonus(enemy_mech, &"player")
	return true


## 测试5：选目标取消 -> 不消耗次数，可再次发动
func test_pilot_031_target_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	_give_action_cards(battle, &"player", 1)

	var ef = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	# 取消选目标
	te.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	# 次数未消耗：再次触发仍挂起
	var ef2 = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef2 == null:
		return "选目标取消不应消耗每回合1次，第二次应能再次挂起"
	# 收尾：第二次完整走完，验证消耗
	te.resume_pending_effect(ef2.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef2.action_id, {"selected_card_ids": gs.players[&"player"].action_hand.duplicate(), "cancelled": false})
	await _pump_frames(12)
	var ef3 = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef3 != null:
		return "第二次完整发动后应消耗每回合1次"
	return true


## 测试6：护甲加成在下个我方回合开始移除（不延续到下下回合）
func test_pilot_031_armor_cleared_next_owner_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_standard(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var te = battle.context.timing_engine
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var hand = _give_action_cards(battle, &"player", 2)
	if hand.size() != 2:
		return "无法补2张行动牌"
	var ef = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef == null:
		return "effect_fire 未挂起"
	te.resume_pending_effect(ef.action_id, {"target_id": enemy_mech.mech_id})
	await _pump_frames(5)
	te.resume_pending_effect(ef.action_id, {"selected_card_ids": hand, "cancelled": false})
	await _pump_frames(12)
	if _armor_bonus(player_mech, &"player") != 2 or _armor_bonus(enemy_mech, &"player") != 2:
		return "前置：双方护甲应+2"
	# 模拟下个我方回合开始：清理 UNTIL_NEXT_OWNER_TURN（duration_owner_id=player）
	battle.context.turn_service.start_turn(&"player")
	if _armor_bonus(player_mech, &"player") != 0:
		return "下个我方回合开始时莱特护甲加成应移除 实=%d" % _armor_bonus(player_mech, &"player")
	if _armor_bonus(enemy_mech, &"player") != 0:
		return "下个我方回合开始时目标护甲加成应移除 实=%d" % _armor_bonus(enemy_mech, &"player")
	return true


## 测试7：目标超出4格 -> 按钮条件不满足，effect_fire 不挂起（无4格内目标）
func test_pilot_031_no_target_in_range_hidden() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_pilot_031(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = setup["gs"]
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	# 敌机保持默认位置 (20,2)（player(2,2) 距离18，超出4格）
	_clear_action_hand(battle, &"player")
	_give_action_cards(battle, &"player", 1)
	if _HexGrid.distance(player_mech.position, enemy_mech.position) <= 4:
		return "前置错误：敌机应在4格外"
	var ef = await _fire_pilot_031(battle, pilot_card, player_mech, &"player")
	if ef != null:
		return "无4格内目标时 effect_fire 不应挂起（按钮不可用）"
	return true

## test_pilot_046_hawn.gd - 霍恩（pilot_046，帝国 R）效果测试
##
## 霍恩 1 个效果按钮（主动 DIRECT）「查看获取隐藏装」：
##   我方可以无条件查看商店和其他机甲备用区内的隐藏装备牌（背面朝上）。
##   我方回合1次，可以消耗隐藏装备牌其上记述的金币获得该牌，之后将其背面朝上置于我方或其他机甲的备用区域上。
##
## 实现拆解（通用 HIDDEN_VIEW_AND_ACQUIRE act_type，不新增原子动作，复用=整段复制改参数）：
##   1. effect_01（按钮，DIRECT 主动）我方主阶段（IS_OWNER_MAIN_PHASE）。查看无条件（无 once_per_turn_key
##      条件，按钮常亮）；获取每回合1次由内部 is_once_per_turn_key_available(once_per_turn_key, 来源牌) 校验
##      + 面板「花费获取」置灰。
##   2. Phase A 打开 hidden_card_view_panel（阻塞，可关闭=取消效果可反复再点；打开即给商店隐藏牌
##      known_to 标记本玩家，幂等）。候选 = 商店隐藏高级槽 + 所有其他机甲 RESERVE 槽白板。
##   3. Phase B（resume_pending_effect phase=hidden_reserve_slot）弹 choice_panel(allow_cancel=false)
##      选目标 RESERVE 槽（全部机甲）→ 清来源 + 重置归属 + 追加目标手牌 →
##      _seq[SPEND_GOLD(牌面原价), MARK_EFFECT_ONCE_PER_TURN_USED, EXECUTE_SET_EQUIP]。
##   4. 商店隐藏牌每玩家独立得知（CardInstance.known_to）：公开揭示/霍恩查看仅标记查看者；
##      商店面板/买价按 known_to 显示真名+1.5x 或 ★★★ + 10金盲买。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")

const _W1 = "weapon_001_光束军刀"  # cost 3（N）
const _W2 = "weapon_002_热能战斧"  # cost 3（N）


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90046
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


## 设霍恩为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb}
func _setup_horn(battle, owner_id: StringName) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_046_霍恩", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 放置一张隐藏装备到商店隐藏高级槽（zone=shop, face_down），返回实例 id
func _place_hidden_shop_card(battle, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var card = _make_instance(gs, battle.context.card_database, def_id, &"player")
	card.zone = &"shop"
	card.face_down = true
	gs.shop_state.hidden_advanced_slot = card.instance_id
	return card.instance_id


## 放置一张隐藏装备到某机甲 RESERVE 槽（face_down），返回实例 id
func _place_hidden_reserve_card(battle, mech, slot_id: StringName, def_id: String, owner_pid: StringName) -> StringName:
	var gs = battle.context.game_state
	var card = _make_instance(gs, battle.context.card_database, def_id, owner_pid)
	card.zone = &"equipment_slot"
	card.mech_id = mech.mech_id
	card.slot_id = slot_id
	card.face_down = true
	mech.slots[slot_id].equipped_card = card
	return card.instance_id


## 牌面原价（与 TimingEngine._hidden_card_face_cost 同逻辑）
func _face_cost(battle, card) -> int:
	if card == null or card.def == null:
		return 0
	if "cost" in card.def and int(card.def.cost) > 0:
		return int(card.def.cost)
	return int(battle.context.shop_service._get_buy_price(card))


## 触发霍恩 DIRECT 按钮（effect_01）。Phase A 挂起返回 effect_fire action；条件不满足返回 null。
func _fire_pilot_046(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_046_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_046_effect_01",
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


## 校验当前 pending phase（hidden_card_view / hidden_reserve_slot），非法返回错误串
func _pending_phase(battle, ef_action) -> String:
	var te = battle.context.timing_engine
	if te == null or not te.has_pending_effect(ef_action.action_id):
		return ""
	var p = te._pending_effect.get(ef_action.action_id, {})
	if p == null or p.is_empty():
		return ""
	return String(p.get("phase", ""))


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（DIRECT 主动、主阶段条件、NO_TARGET、单个 HIDDEN_VIEW_AND_ACQUIRE）
func test_p046_definitions() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	if effects.has(&"pilot_046_effect_02"):
		return "不应存在 pilot_046_effect_02（新效果只有1个按钮）"
	var e1 = effects.get(&"pilot_046_effect_01")
	if e1 == null:
		return "缺 pilot_046_effect_01"
	if e1.mode != _TimingConst.MODE_DIRECT:
		return "effect_01 mode 应 MODE_DIRECT 实=%s" % String(e1.mode)
	var conds: Array = []
	for c in e1.conditions:
		conds.append(String(c.get("op", &"")))
	if not conds.has("IS_OWNER_MAIN_PHASE"):
		return "effect_01 应含条件 IS_OWNER_MAIN_PHASE"
	# 查看无条件：不应有 EFFECT_ONCE_PER_TURN_AVAILABLE 条件（按钮常亮，获取限次由内部校验）
	if conds.has("EFFECT_ONCE_PER_TURN_AVAILABLE"):
		return "effect_01 不应设 once_per_turn 条件（查看无条件，获取限次内部校验）"
	if e1.target_rules.size() != 1 or String(e1.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "effect_01 目标规则应 NO_TARGET"
	if e1.actions.size() != 1 or String(e1.actions[0].get("type", &"")) != "HIDDEN_VIEW_AND_ACQUIRE":
		return "effect_01 动作应 HIDDEN_VIEW_AND_ACQUIRE"
	var hv = e1.actions[0].get("params", {})
	if String(hv.get("once_per_turn_key", &"")) != "pilot_046_effect_01":
		return "HIDDEN_VIEW_AND_ACQUIRE once_per_turn_key 应 pilot_046_effect_01"
	if String(hv.get("price_mode", &"")) != "face":
		return "HIDDEN_VIEW_AND_ACQUIRE price_mode 应 face（牌面原价）"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：完整流程——商店隐藏牌获取到自己备用区：扣牌面原价金、来源清空、备用区放置 face_down、
## 不留在手牌；商店隐藏牌打开面板即标记本玩家已知。
func test_p046_acquire_shop_to_self() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var player = gs.players.get(&"player")
	# 清掉 tutorial 自动生成的商店隐藏牌，放自己的（weapon_001 cost 3）
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)
	var shop_card = gs.get_card(shop_card_id)
	var expected_price: int = _face_cost(battle, shop_card)
	if expected_price != 3:
		return "预期牌面原价3 实=%d（weapon_001 cost=3）" % expected_price
	var gold_before: int = player.gold
	if player.gold < expected_price:
		return "测试玩家金币不足（需%d 有%d）" % [expected_price, player.gold]

	# 触发 → Phase A 挂起
	var ef = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起 Phase A（hidden_card_view）"
	if _pending_phase(battle, ef) != "hidden_card_view":
		return "Phase A 应为 hidden_card_view 实=%s" % _pending_phase(battle, ef)
	# 打开面板即给商店隐藏牌标记本玩家已知（每玩家独立得知）
	if not battle.context.shop_service.is_hidden_advanced_known_to(&"player"):
		return "打开面板后商店隐藏牌应标记 player 已知"
	if battle.context.shop_service.is_hidden_advanced_known_to(&"enemy"):
		return "商店隐藏牌不应标记 enemy 已知（每玩家独立）"

	# Phase A 选中商店隐藏牌 → Phase B 选目标备用槽
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_id": shop_card_id})
	await _pump_frames(6)
	if _pending_phase(battle, ef) != "hidden_reserve_slot":
		return "Phase B 应为 hidden_reserve_slot 实=%s" % _pending_phase(battle, ef)

	# Phase B 选自己 reserve_1 → 扣金 + 放置
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"target_mech_id": player_mech.mech_id, "target_slot_id": &"reserve_1"})
	await _pump_frames(30)

	if player.gold != gold_before - expected_price:
		return "应扣牌面原价%d金币 前=%d 后=%d" % [expected_price, gold_before, player.gold]
	if gs.shop_state.hidden_advanced_slot != &"":
		return "商店隐藏槽应被清空"
	var slot = player_mech.slots.get(&"reserve_1")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != shop_card_id:
		return "备用区1应放置该隐藏装备"
	if not slot.equipped_card.face_down:
		return "备用区装备应 face_down（背面朝上）"
	if slot.equipped_card.owner_player_id != &"player":
		return "装备归属应改为目标玩家"
	if player.equipment_hand.has(shop_card_id):
		return "装备不应留在手牌（已设置到备用区）"
	return true


## 测试3：完整流程——其他机甲（enemy）备用区隐藏装备获取到自己：来源备用区清空、牌面原价扣金
func test_p046_acquire_enemy_reserve_to_self() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var player = gs.players.get(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	gs.shop_state.hidden_advanced_slot = &""
	var enemy_reserve_id = _place_hidden_reserve_card(battle, enemy_mech, &"reserve_1", _W2, &"enemy")
	var enemy_reserve_card = gs.get_card(enemy_reserve_id)
	var expected_price: int = _face_cost(battle, enemy_reserve_card)
	var gold_before: int = player.gold

	var ef = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起 Phase A"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_id": enemy_reserve_id})
	await _pump_frames(6)
	if _pending_phase(battle, ef) != "hidden_reserve_slot":
		return "Phase B 应为 hidden_reserve_slot 实=%s" % _pending_phase(battle, ef)
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"target_mech_id": player_mech.mech_id, "target_slot_id": &"reserve_2"})
	await _pump_frames(30)

	if player.gold != gold_before - expected_price:
		return "应扣牌面原价%d金币 前=%d 后=%d" % [expected_price, gold_before, player.gold]
	if enemy_mech.slots.get(&"reserve_1").equipped_card != null:
		return "来源备用区1应被清空"
	var slot = player_mech.slots.get(&"reserve_2")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != enemy_reserve_id:
		return "备用区2应放置获取的隐藏装备"
	if not slot.equipped_card.face_down:
		return "备用区装备应 face_down"
	return true


## 测试4：目标备用区已有旧装备 -> 替换弃置旧牌（set_equipment 标准替换流程）
func test_p046_replace_occupied_reserve() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)
	var old_id = _place_hidden_reserve_card(battle, player_mech, &"reserve_1", _W2, &"player")
	var old_card = gs.get_card(old_id)

	var ef = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起 Phase A"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_id": shop_card_id})
	await _pump_frames(6)
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"target_mech_id": player_mech.mech_id, "target_slot_id": &"reserve_1"})
	await _pump_frames(30)

	var slot = player_mech.slots.get(&"reserve_1")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != shop_card_id:
		return "新装备应放置到 reserve_1"
	if not slot.equipped_card.face_down:
		return "新装备应 face_down"
	if old_card.zone == &"equipment_slot":
		return "旧装备应离开区域"
	if not gs.deck_state.equipment_discard_pile.has(old_id):
		return "旧装备应进装备弃牌堆"
	return true


## 测试5：Phase A 关闭（取消）-> 不扣金、不移动、来源保留，可再次触发
func test_p046_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var player = gs.players.get(&"player")
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)
	var gold_before: int = player.gold

	var ef = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起 Phase A"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(30)

	if player.gold != gold_before:
		return "取消不应扣金 前=%d 后=%d" % [gold_before, player.gold]
	if gs.shop_state.hidden_advanced_slot != shop_card_id:
		return "取消不应清空商店隐藏槽"
	# 可再次触发（查看无条件，取消不消耗获取额度）
	var ef2 = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef2 == null:
		return "取消后应可再次触发（查看无条件）"
	return true


## 测试6：获取每回合1次——首次成功后第2次获取被内部校验拦截（面板照开=查看无条件，但选中牌后中止，
## 不扣金不移动）
func test_p046_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var player = gs.players.get(&"player")
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)
	var expected_price: int = _face_cost(battle, gs.get_card(shop_card_id))
	var gold_before: int = player.gold

	# 第1次：正常获取到 enemy reserve_1（避免替换干扰）
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var ef1 = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef1 == null:
		return "第1次应挂起 Phase A"
	battle.context.timing_engine.resume_pending_effect(ef1.action_id, {"selected_card_id": shop_card_id})
	await _pump_frames(6)
	battle.context.timing_engine.resume_pending_effect(ef1.action_id, {"target_mech_id": enemy_mech.mech_id, "target_slot_id": &"reserve_1"})
	await _pump_frames(30)
	if player.gold != gold_before - expected_price:
		return "第1次应扣%d金 前=%d 后=%d" % [expected_price, gold_before, player.gold]

	# 第2次：查看面板照开（Phase A 挂起），但选中牌后获取额度已用满 -> 中止不扣金不移动
	var gold_after_1: int = player.gold
	var shop_card2 = _place_hidden_shop_card(battle, _W2)
	var ef2 = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef2 == null:
		return "第2次查看应仍挂起（查看无条件，面板照开）"
	battle.context.timing_engine.resume_pending_effect(ef2.action_id, {"selected_card_id": shop_card2})
	await _pump_frames(30)
	if player.gold != gold_after_1:
		return "第2次获取额度已用满不应扣金 前=%d 后=%d" % [gold_after_1, player.gold]
	if gs.shop_state.hidden_advanced_slot != shop_card2:
		return "第2次中止不应清空商店隐藏槽"
	return true


## 测试7：金币不足 -> 选中牌后校验失败中止（不扣金不移动）
func test_p046_gold_insufficient() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player_mech = s.mech
	var player = gs.players.get(&"player")
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)
	var expected_price: int = _face_cost(battle, gs.get_card(shop_card_id))
	player.gold = expected_price - 1  # 差1金不够
	var gold_before: int = player.gold

	var ef = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起 Phase A"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_id": shop_card_id})
	await _pump_frames(30)
	if player.gold != gold_before:
		return "金不足不应扣金 前=%d 后=%d" % [gold_before, player.gold]
	if gs.shop_state.hidden_advanced_slot != shop_card_id:
		return "金不足不应清空商店隐藏槽"
	return true


## 测试8：商店隐藏牌每玩家独立得知——reveal 只标记查看者；买价 known=1.5x原价 / unknown=10盲买
func test_p046_shop_per_player_known_and_price() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	var shop_svc = battle.context.shop_service
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)
	var shop_card = gs.get_card(shop_card_id)

	# 初始：双方都未知 -> 买价都是10金盲买
	if shop_svc.is_hidden_advanced_known_to(&"player") or shop_svc.is_hidden_advanced_known_to(&"enemy"):
		return "初始双方应均未知"
	var buy_price_unknown: int = shop_svc._hidden_advanced_price_for(&"player")
	if buy_price_unknown != 10:
		return "未知盲买价应10 实=%d" % buy_price_unknown

	# player 花2金公开揭示 -> 仅 player 已知；买价变1.5x原价；enemy 仍10
	enemy.gold = 50
	var reveal_ret = shop_svc.reveal_hidden_advanced(&"player")
	if not reveal_ret.get("ok", false):
		return "公开揭示应成功: %s" % str(reveal_ret.get("message", ""))
	if not shop_svc.is_hidden_advanced_known_to(&"player"):
		return "揭示后 player 应已知"
	if shop_svc.is_hidden_advanced_known_to(&"enemy"):
		return "揭示后 enemy 不应已知（每玩家独立）"
	if shop_card.known_to == null or not shop_card.known_to.has(&"enemy"):
		if shop_card.known_to.has(&"enemy"):
			return "enemy 不应被标记已知"
	if shop_svc._hidden_advanced_price_for(&"enemy") != 10:
		return "enemy 未知买价应仍10"
	var buy_price_known: int = shop_svc._hidden_advanced_price_for(&"player")
	var expected_known: int = int(ceil(shop_card.def.cost * 1.5)) if "cost" in shop_card.def and int(shop_card.def.cost) > 0 else shop_svc._get_buy_price(shop_card)
	if buy_price_known != expected_known:
		return "player 已知买价应1.5x原价%d 实=%d" % [expected_known, buy_price_known]
	return true


## 测试9：PVP3 多人——third 机甲备用区隐藏装备也可被获取（候选收集遍历所有其他玩家机甲）
func test_p046_pvp3_third_reserve_candidate() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	# 创建 third 玩家 + 机甲（无 RESERVE 槽，需补上）
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
		sl.slot_kind = (&"RESERVE" if String(slot_id).begins_with("reserve_") else &"PART")
		m.slots[slot_id] = sl
	gs.mechs[m.mech_id] = m

	var s = _setup_horn(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	var player_mech = s.mech
	var player = gs.players.get(&"player")
	gs.shop_state.hidden_advanced_slot = &""
	var third_reserve_id = _place_hidden_reserve_card(battle, m, &"reserve_1", _W2, &"third")
	var expected_price: int = _face_cost(battle, gs.get_card(third_reserve_id))
	var gold_before: int = player.gold

	var ef = await _fire_pilot_046(battle, s.pilot_card, player_mech, &"player")
	if ef == null:
		return "应挂起 Phase A"
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_id": third_reserve_id})
	await _pump_frames(6)
	if _pending_phase(battle, ef) != "hidden_reserve_slot":
		return "Phase B 应为 hidden_reserve_slot 实=%s" % _pending_phase(battle, ef)
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"target_mech_id": player_mech.mech_id, "target_slot_id": &"reserve_2"})
	await _pump_frames(30)

	if player.gold != gold_before - expected_price:
		return "应扣牌面原价%d金币 前=%d 后=%d" % [expected_price, gold_before, player.gold]
	if m.slots.get(&"reserve_1").equipped_card != null:
		return "third 备用区1应被清空"
	var slot = player_mech.slots.get(&"reserve_2")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != third_reserve_id:
		return "备用区2应放置获取的 third 隐藏装备"
	return true

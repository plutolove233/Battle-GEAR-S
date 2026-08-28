## test_pilot_078_falco.gd - 法尔科（pilot_078，帝国 N）效果测试
##
## 法尔科 1 按钮（DIRECT 主动）「弃2抽高级装置备用区」：
##   effect_01（每回合1次）「我方回合1次，可以弃置2张行动牌，之后抽取1张高级装备牌，并背面朝上置于
##   我方或其他机甲的备用区，直到下个我方回合开始后，该高级装备牌不能主动设置与卖出。」
##   动作链：CHOOSE_MANY_CARDS(选2行动牌, 可取消, 确认计次) → EXECUTE_DISCARD → EXECUTE_GAIN_CARD
##   (高级装备牌 + 打"禁"标签 + _draw_result_sink 回写) → CHOOSE_RESERVE_SLOT_AND_SET_EQUIP(弹备用区
##   选择) → EXECUTE_SET_EQUIP(RESERVE 槽自动 face_down，效果驱动绕过主动设置/卖出拦截)。
##
## 通用模块（与效果绑定不绑机师，改 params 复制即可复用）：
##   · build_discard_draw_advanced_equip_set_reserve_effect(params) 构建器。
##   · "禁"标签：EQUIP_FORBID_TAG 打标签 → CardSetService 主动设置/卖出拦截 + UI 置灰
##     → 下轮开始 ROUND_START 统一清除全场（TurnService.clear_all_equip_forbid，替代旧的按玩家
##     TURN_AFTER_START 清除——权威「直到下个我方回合开始后」在轮次语义下=下轮开始到期）。
##
## 关键覆盖点：
##   1. 效果定义结构（DIRECT + 条件 + once_per_turn_key + 4 动作链 + 禁标签参数）。
##   2. 完整流程放自己备用区（弃2/抽1高级/带禁标签/face_down/标签保留）。
##   3. 完整流程放敌方备用区（owner_player_id 变敌方）。
##   4. 取消选牌 -> 中止不弃不抽不消耗次数（可再触发）。
##   5. 每回合1次用满 -> 再次触发被跳过。
##   6. 手牌 < 2 -> 条件不满足按钮置灰（不挂起）。
##   7. 禁标签帮助函数（equip_forbid_tagged / clear_all_equip_forbid_for_player 按玩家隔离）。
##   8. CardSetService 主动设置/卖出拦截（带禁标签拦截；清除后放行）。
##   9. 下轮开始（ROUND_START，位次1触发）清禁标签（含非位次1玩家名下标签）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90073
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


## 设法尔科为 owner_id 机甲的机师，返回 {pilot_card, mech, gs, cdb, battle}；失败返回空字典。
func _setup_falco(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_078_法尔科", owner_id)
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb, "battle": battle}


## 给玩家装备手牌加一张装备牌，返回实例 id
func _add_equip_to_hand(battle, pid: StringName, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, def_id, pid)
	if card == null:
		return &""
	card.zone = &"equipment_hand"
	gs.players.get(pid).equipment_hand.append(card.instance_id)
	return card.instance_id


## 触发法尔科 DIRECT 按钮（effect_fire），返回挂起的 effect_fire action（或 null）
func _fire_pilot_078(battle, pilot_card, mech, player_id: StringName) -> _Action:
	var src: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"mech_id": mech.mech_id,
		"player_id": player_id,
		"effect_id": &"pilot_078_effect_01",
	}
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_078_effect_01",
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


## resume 选弃窗（确认：弃牌+抽高级装备+弹备用区选择）
func _resume_discard(battle, ef, selected: Array) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"selected_card_ids": selected})
	await _pump_frames(10)


## resume 取消选弃窗（中止，不消耗次数）
func _resume_cancel(battle, ef) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)


## resume 备用区选择（确认放置到 mech_id/slot_id）
func _resume_reserve(battle, ef, mech_id: StringName, slot_id: StringName) -> void:
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {
		"target_mech_id": mech_id,
		"target_slot_id": slot_id,
	})
	await _pump_frames(12)


## 读取 effect 动作当前挂起阶段名
func _pending_phase(battle, ef_action) -> String:
	var pend: Dictionary = battle.context.timing_engine._pending_effect.get(ef_action.action_id, {})
	if pend.is_empty():
		return ""
	return String(pend.get("phase", &""))


## 检查 cid 是否在行动弃牌堆
func _in_action_discard(battle, cid: StringName) -> bool:
	return battle.context.game_state.deck_state.action_discard_pile.has(cid)


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（DIRECT + 条件 + once_per_turn + 4动作链 + 禁标签参数）
func test_pilot_078_effect_definition() -> Variant:
	var effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var e = effects.get(&"pilot_078_effect_01")
	if e == null:
		return "缺 pilot_078_effect_01"
	if e.mode != _TimingConst.MODE_DIRECT:
		return "mode 应 MODE_DIRECT 实=%s" % String(e.mode)
	if String(e.once_per_turn_key) != "pilot_078_effect_01":
		return "once_per_turn_key 应 pilot_078_effect_01"
	if int(e.once_per_turn_max) != 1:
		return "once_per_turn_max 应 1"
	# 条件：IS_OWNER_MAIN_PHASE + HAS_ACTION_CARD_IN_HAND(count=2)
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	for need in ["IS_OWNER_MAIN_PHASE", "HAS_ACTION_CARD_IN_HAND"]:
		if not ops.has(need):
			return "应含条件 %s" % need
	var found_count: bool = false
	for c in e.conditions:
		if String(c.get("op", &"")) == "HAS_ACTION_CARD_IN_HAND":
			if int(c.get("params", {}).get("count", 0)) != 2:
				return "HAS_ACTION_CARD_IN_HAND count 应 2"
			found_count = true
	if not found_count:
		return "应含 HAS_ACTION_CARD_IN_HAND"
	if String(e.target_rules[0].get("rule", &"")) != "NO_TARGET":
		return "target_rule 应 NO_TARGET"
	# 动作链：CHOOSE_MANY_CARDS(OWNER_ACTION_HAND min=max=2) -> EXECUTE_DISCARD -> EXECUTE_GAIN_CARD
	# (advanced_equipment_deck, count=1, 禁标签, sink) -> CHOOSE_RESERVE_SLOT_AND_SET_EQUIP
	var acts = e.actions
	if acts.size() != 4:
		return "应有4个动作 实=%d" % acts.size()
	if String(acts[0].get("type", &"")) != "CHOOSE_MANY_CARDS":
		return "动作0 应 CHOOSE_MANY_CARDS"
	var cm_p: Dictionary = acts[0].get("params", {})
	if String(cm_p.get("source", &"")) != "OWNER_ACTION_HAND":
		return "选择来源应 OWNER_ACTION_HAND"
	if int(cm_p.get("min_count", 0)) != 2 or int(cm_p.get("max_count", 0)) != 2:
		return "min/max_count 应 2"
	if String(cm_p.get("store_result_key", &"")) != "pilot_078_effect_01_discard_ids":
		return "store_result_key 应 pilot_078_effect_01_discard_ids"
	if String(acts[1].get("type", &"")) != "EXECUTE_DISCARD":
		return "动作1 应 EXECUTE_DISCARD"
	if String(acts[2].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "动作2 应 EXECUTE_GAIN_CARD"
	var gc_p: Dictionary = acts[2].get("params", {})
	if String(gc_p.get("from_zone", &"")) != "advanced_equipment_deck":
		return "抽牌来源应 advanced_equipment_deck"
	if int(gc_p.get("count", 0)) != 1:
		return "抽牌 count 应 1"
	if String(gc_p.get("player_id", &"")) != "$binding_context.player_id":
		return "抽牌 player_id 应 $binding_context.player_id"
	var tag_cfg: Dictionary = gc_p.get("_tag_on_draw", {})
	if String(tag_cfg.get("tag_name", &"")) != String(_ActionPilotEffects.EQUIP_FORBID_TAG):
		return "_tag_on_draw.tag_name 应 EQUIP_FORBID_TAG"
	var sink_cfg: Dictionary = gc_p.get("_draw_result_sink", {})
	if String(sink_cfg.get("key", &"")) != "pilot_078_effect_01_drawn":
		return "_draw_result_sink.key 应 pilot_078_effect_01_drawn"
	if String(acts[3].get("type", &"")) != "CHOOSE_RESERVE_SLOT_AND_SET_EQUIP":
		return "动作3 应 CHOOSE_RESERVE_SLOT_AND_SET_EQUIP"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：完整流程——弃2行动抽1高级装备，背面朝上置于自己备用区，带禁标签
func test_pilot_078_full_flow_own_reserve() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_falco(battle, &"player")
	if s.is_empty():
		return "setup 失败（缺 pilot_078_法尔科）"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var hand = player.action_hand.duplicate()
	if hand.size() < 2:
		return "起手行动牌不足2张 实=%d" % hand.size()
	var sel1: StringName = hand[0]
	var sel2: StringName = hand[1]
	var adv_before: int = gs.deck_state.advanced_equipment_deck.size()
	if adv_before <= 0:
		return "高级装备牌堆为空，无法验证抽高级"
	var ef = await _fire_pilot_078(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起（应弹选弃行动牌窗）"
	await _resume_discard(battle, ef, [sel1, sel2])
	# 弃2：不再手牌，进行动弃牌堆
	if player.action_hand.has(sel1) or player.action_hand.has(sel2):
		return "被弃行动牌不应仍在手牌"
	if not _in_action_discard(battle, sel1) or not _in_action_discard(battle, sel2):
		return "被弃行动牌应进行动弃牌堆"
	# 抽1高级装备 + 禁标签 + 牌堆-1
	var drawn: Array = ef.record.get(&"pilot_078_effect_01_drawn", [])
	if drawn.size() != 1:
		return "应抽1张高级装备 实=%d" % drawn.size()
	var drawn_card = gs.get_card(drawn[0])
	if drawn_card == null:
		return "抽到的牌实例缺失"
	if not _ActionPilotEffects.equip_forbid_tagged(drawn_card):
		return "抽到的牌应带禁标签"
	if gs.deck_state.advanced_equipment_deck.size() != adv_before - 1:
		return "高级装备牌堆应-1"
	# 弃牌后弹备用区选择
	if _pending_phase(battle, ef) != "choose_reserve_slot_and_set":
		return "弃牌后应弹备用区选择 实phase=%s" % _pending_phase(battle, ef)
	# 放自己备用区
	var my_mech = gs.get_mech_for_player(&"player")
	await _resume_reserve(battle, ef, my_mech.mech_id, &"reserve_1")
	var slot = my_mech.slots.get(&"reserve_1")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != drawn[0]:
		return "抽到的牌应背面朝上置于自己备用区"
	if not slot.equipped_card.face_down:
		return "备用区牌应 face_down"
	if String(slot.equipped_card.owner_player_id) != "player":
		return "备用区牌 owner 应 player"
	if not _ActionPilotEffects.equip_forbid_tagged(slot.equipped_card):
		return "备用区牌应仍带禁标签"
	return true


## 测试3：完整流程——弃2行动抽1高级装备，置于敌方备用区（owner_player_id 变敌方）
func test_pilot_078_full_flow_enemy_reserve() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_falco(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var hand = player.action_hand.duplicate()
	if hand.size() < 2:
		return "起手行动牌不足2张 实=%d" % hand.size()
	var sel1: StringName = hand[0]
	var sel2: StringName = hand[1]
	var ef = await _fire_pilot_078(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_discard(battle, ef, [sel1, sel2])
	if _pending_phase(battle, ef) != "choose_reserve_slot_and_set":
		return "弃牌后应弹备用区选择 实phase=%s" % _pending_phase(battle, ef)
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	await _resume_reserve(battle, ef, enemy_mech.mech_id, &"reserve_1")
	var slot = enemy_mech.slots.get(&"reserve_1")
	if slot == null or slot.equipped_card == null:
		return "抽到的牌应置于敌方备用区"
	if not slot.equipped_card.face_down:
		return "敌方备用区牌应 face_down"
	if String(slot.equipped_card.owner_player_id) != "enemy":
		return "置于敌方备用区后 owner_player_id 应 enemy 实=%s" % String(slot.equipped_card.owner_player_id)
	if not _ActionPilotEffects.equip_forbid_tagged(slot.equipped_card):
		return "敌方备用区牌应仍带禁标签（禁标签 owner=打标签玩家）"
	return true


## 测试4：取消选牌 -> 中止，不弃不抽不消耗次数（可再触发）
func test_pilot_078_cancel_no_cost() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_falco(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var hand_size_before: int = player.action_hand.size()
	var adv_before: int = gs.deck_state.advanced_equipment_deck.size()
	var ef = await _fire_pilot_078(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "effect_01 未挂起"
	await _resume_cancel(battle, ef)
	if player.action_hand.size() != hand_size_before:
		return "取消不应弃牌"
	if gs.deck_state.advanced_equipment_deck.size() != adv_before:
		return "取消不应抽牌"
	if not battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_078_effect_01", s.pilot_card.instance_id, 1):
		return "取消不应消耗每回合1次"
	var ef2 = await _fire_pilot_078(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "取消中止后应可再触发"
	return true


## 测试5：完整发动后每回合1次用满 -> 再次触发被跳过
func test_pilot_078_once_per_turn() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_falco(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	var hand = player.action_hand.duplicate()
	if hand.size() < 2:
		return "起手行动牌不足2张"
	var ef1 = await _fire_pilot_078(battle, s.pilot_card, s.mech, &"player")
	if ef1 == null:
		return "第1次未挂起"
	await _resume_discard(battle, ef1, [hand[0], hand[1]])
	if _pending_phase(battle, ef1) != "choose_reserve_slot_and_set":
		return "第1次应弹备用区选择"
	await _resume_reserve(battle, ef1, s.mech.mech_id, &"reserve_1")
	if battle.context.timing_engine.is_once_per_turn_key_available(&"pilot_078_effect_01", s.pilot_card.instance_id, 1):
		return "完整发动后每回合1次应已消耗"
	# 再次触发：once_per_turn 用满 -> 跳过，不挂起、不再弃牌
	var hand_after: int = player.action_hand.size()
	var ef2 = await _fire_pilot_078(battle, s.pilot_card, s.mech, &"player")
	if ef2 != null:
		return "第2次不应挂起（每回合1次用满）"
	if player.action_hand.size() != hand_after:
		return "第2次跳过不应再弃牌"
	return true


## 测试6：手牌 < 2 -> HAS_ACTION_CARD_IN_HAND 条件不满足 -> 按钮置灰（不挂起）
func test_pilot_078_insufficient_hand() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_falco(battle, &"player")
	if s.is_empty():
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var gs = s.gs
	var player = gs.players.get(&"player")
	# 清到只剩1张行动牌
	var hand = player.action_hand.duplicate()
	for i in range(hand.size() - 1):
		var c: StringName = hand[i]
		player.action_hand.erase(c)
		gs.deck_state.action_deck.push_front(c)
	var ef = await _fire_pilot_078(battle, s.pilot_card, s.mech, &"player")
	if ef != null:
		return "手牌<2时不应挂起（按钮应置灰）"
	return true


## 测试7：禁标签帮助函数（equip_forbid_tagged / clear_all_equip_forbid_for_player 按玩家隔离）
func test_pilot_078_tag_helpers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	var card = gs.get_card(cid)
	if card == null:
		return "造装备失败"
	if _ActionPilotEffects.equip_forbid_tagged(card):
		return "未打标签不应判定为禁"
	card.add_tag(_ActionPilotEffects.EQUIP_FORBID_TAG, &"player", {})
	if not _ActionPilotEffects.equip_forbid_tagged(card):
		return "打标签后应判定为禁"
	# 清他人标签不影响当前玩家
	_ActionPilotEffects.clear_all_equip_forbid_for_player(gs, &"enemy")
	if not _ActionPilotEffects.equip_forbid_tagged(card):
		return "清敌方不应清我方标签"
	# 清当前玩家
	_ActionPilotEffects.clear_all_equip_forbid_for_player(gs, &"player")
	if _ActionPilotEffects.equip_forbid_tagged(card):
		return "清当前玩家后应已清除"
	return true


## 测试8：CardSetService 主动设置/卖出拦截（带禁标签拦截；清除后放行卖出）
func test_pilot_078_set_sell_gates() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var css = battle.context.card_set_service
	var cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	var card = gs.get_card(cid)
	if card == null:
		return "造装备失败"
	# 带禁标签：不能主动设置/卖出
	card.add_tag(_ActionPilotEffects.EQUIP_FORBID_TAG, &"player", {})
	var r_set = css.set_equipment(&"player", cid, &"头部")
	if r_set.get("ok", false):
		return "带禁标签不应能主动设置"
	var r_sell = css.sell_equipment(&"player", cid)
	if r_sell.get("ok", false):
		return "带禁标签不应能主动卖出"
	# 清除后可卖出（主动路径放行）
	_ActionPilotEffects.clear_all_equip_forbid_for_player(gs, &"player")
	var r_sell2 = css.sell_equipment(&"player", cid)
	if not r_sell2.get("ok", false):
		return "清除禁标签后应能主动卖出 实=%s" % str(r_sell2)
	return true


## 测试9：下轮开始（ROUND_START，位次1玩家 start_turn 触发）清禁标签
func test_pilot_078_turn_start_clear() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cid = _add_equip_to_hand(battle, &"player", "part_001_量产装_头部")
	var card = gs.get_card(cid)
	if card == null:
		return "造装备失败"
	card.add_tag(_ActionPilotEffects.EQUIP_FORBID_TAG, &"player", {})
	if not _ActionPilotEffects.equip_forbid_tagged(card):
		return "打标签失败"
	var start_res = battle.context.turn_service.start_turn(&"player")
	if not start_res.get("ok", false):
		return "start_turn 失败: %s" % str(start_res)
	await _pump_frames(12)
	if _ActionPilotEffects.equip_forbid_tagged(card):
		return "下轮开始后应清禁标签"
	return true


## 测试10：ROUND_START 清全场禁标签——非位次1玩家（enemy）名下标签也在位次1开始回合时清除。
## 法尔科解锁时机=下一轮开始（ROUND_START 全局一次），不再等到 tag-owner 自己的下个回合。
func test_pilot_078_round_start_clear_all() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cid = _add_equip_to_hand(battle, &"enemy", "part_001_量产装_头部")
	var card = gs.get_card(cid)
	if card == null:
		return "造装备失败"
	card.add_tag(_ActionPilotEffects.EQUIP_FORBID_TAG, &"enemy", {})
	if not _ActionPilotEffects.equip_forbid_tagged(card):
		return "打标签失败"
	# 位次1玩家开始回合 → ROUND_START 触发 → 全场禁标签清除（含 enemy 名下）
	var start_res = battle.context.turn_service.start_turn(&"player")
	if not start_res.get("ok", false):
		return "start_turn 失败: %s" % str(start_res)
	await _pump_frames(12)
	if _ActionPilotEffects.equip_forbid_tagged(card):
		return "ROUND_START 应清全场禁标签（含非位次1玩家名下）"
	return true

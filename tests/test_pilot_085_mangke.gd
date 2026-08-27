## test_pilot_085_mangke.gd - 莽克（pilot_085，混乱 N，cost 4, attack_limit 1, action_card_limit 3）效果测试
##
## 1 个效果按钮（LISTEN 被动，悬停看完整说明）：
##   effect_01「装弃获金」：持续被动，监听所有弃置牌动作的结算时点（DISCARD_SETTLE）。
##     本次弃置中每张「原先正面设置在机甲上」的装备牌：
##       原先属于我方机甲 → 我方立即获得4金币；其他机甲 → 我方立即获得3金币。
##     每张都发、按类型累加后一次发放。
##
## 关键覆盖点：
##   1. 效果定义 + JSON effect_ids + 按钮形态（LISTEN 被动 / DISCARD_SETTLE / PILOT_085_DISCARD_GOLD）。
##   2. 我方正面装备弃置 -> 我方 +4 金币。
##   3. 他方（enemy 机甲）正面装备弃置 -> 我方 +3 金币。
##   4. 手上未设置的装备弃置（from_zone=equipment_hand）-> 不触发。
##   5. 备用区背面设置的装备弃置（face_down）-> 不触发。
##   6. 替换弃置 reason（equipment_replace，被新牌顶掉）-> 同样触发 +4。
##   7. 批量弃置多张正面装备（自1他1）-> 累加 4+3=7 金币。
##   8. 量产装已设置装备卖出（sell_set_equipment）-> 同样触发 +4。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90085
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	battle.context.action_ui_bridge.context = battle.context
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（阵营光环等），避免跨测试泄漏
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


## 设莽克为 owner_id 机甲机师，返回 {card, mech, gs, cdb, player}；失败返回 null。
func _setup_pilot_085(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_085_莽克", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "gs": gs, "cdb": cdb, "player": gs.players.get(owner_id)}


## 手动把装备牌正面设置到机甲槽（模拟 set_equipment 后状态：zone=equipment_slot，
## face_down 由是否备用区决定）。备用区 face_down=true（白板）。
func _equip_to_slot(gs, mech, card, slot_id: StringName, face_down: bool) -> void:
	var slot = mech.slots.get(slot_id)
	if slot == null:
		return
	slot.equipped_card = card
	card.slot_id = slot_id
	card.mech_id = mech.mech_id
	card.zone = &"equipment_slot"
	card.face_down = face_down


## 走 deck_service 弃置（转发 discard_card 动作，发 DISCARD_BEFORE/AFTER/SETTLE 时点）。
func _discard_cards(battle, card_ids: Array, reason: StringName) -> void:
	if card_ids.size() == 1:
		battle.context.deck_service.discard_card(card_ids[0], reason)
	else:
		battle.context.deck_service.discard_cards(card_ids, reason)
	await _pump_frames(10)


# ═══════════════════════════════════════════
# 定义
# ═══════════════════════════════════════════

## 测试1：效果定义正确 + JSON effect_ids 注册 + 按钮形态（LISTEN 被动 / DISCARD_SETTLE）
func test_pilot_085_effect_definitions() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var ids: Array = _ActionPilotEffects.get_effects_for_pilot(&"pilot_085_莽克", battle.context)
	var id_strs: Array = []
	for i in ids:
		id_strs.append(String(i))
	if not id_strs.has("pilot_085_effect_01"):
		return "effect_ids 应含 pilot_085_effect_01 实=%s" % str(id_strs)
	var e1 = _ActionPilotEffects.build_pilot_effects().get(&"pilot_085_effect_01")
	if e1 == null:
		return "缺 pilot_085_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "e1 mode 应 LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.DISCARD_SETTLE:
		return "e1 listen_timing 应 DISCARD_SETTLE 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "discard_card":
		return "e1 listen_action_type 应 discard_card 实=%s" % String(e1.listen_action_type)
	var ops: Array = []
	for c in e1.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("DISCARD_CONTAINS_FACEUP_EQUIPMENT"):
		return "e1 应含条件 DISCARD_CONTAINS_FACEUP_EQUIPMENT 实=%s" % str(ops)
	var acts: Array = e1.actions
	if acts.is_empty() or String(acts[0].get("type", &"")) != "PILOT_085_DISCARD_GOLD":
		return "e1 actions 应 [PILOT_085_DISCARD_GOLD] 实=%s" % str(acts)
	return true


# ═══════════════════════════════════════════
# 弃装获金（被动）
# ═══════════════════════════════════════════

## 测试2：我方正面装备弃置 -> 我方 +4 金币
func test_pilot_085_self_equipment_discard_gives_4() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_085(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_085_莽克）"
	var gs = s.gs
	var cdb = s.cdb
	var player = s.player
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if equip == null:
		return "无法创建装备实例"
	_equip_to_slot(gs, s.mech, equip, &"头部", false)
	var gold_before: int = int(player.gold)
	await _discard_cards(battle, [equip.instance_id], &"damage_durability")
	if int(player.gold) != gold_before + 4:
		return "我方正面装备弃置应+4金币：期望 %d 实际 %d" % [gold_before + 4, int(player.gold)]
	return true


## 测试3：他方（enemy 机甲）正面装备弃置 -> 我方 +3 金币
func test_pilot_085_other_equipment_discard_gives_3() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_085(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player = s.player
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"enemy")
	if equip == null:
		return "无法创建装备实例"
	_equip_to_slot(gs, enemy_mech, equip, &"头部", false)
	var gold_before: int = int(player.gold)
	await _discard_cards(battle, [equip.instance_id], &"equipment_replace")
	if int(player.gold) != gold_before + 3:
		return "他方正面装备弃置应+3金币：期望 %d 实际 %d" % [gold_before + 3, int(player.gold)]
	return true


## 测试4：手上未设置的装备弃置（from_zone=equipment_hand）-> 不触发
func test_pilot_085_hand_equipment_discard_no_gold() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_085(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player = s.player
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if equip == null:
		return "无法创建装备实例"
	# 放到装备手牌（未设置），zone=equipment_hand
	player.equipment_hand.append(equip.instance_id)
	equip.zone = &"equipment_hand"
	equip.mech_id = &""
	equip.slot_id = &""
	equip.face_down = false
	var gold_before: int = int(player.gold)
	await _discard_cards(battle, [equip.instance_id], &"sell")
	if int(player.gold) != gold_before:
		return "手牌未设置装备弃置不应获金：期望 %d 实际 %d" % [gold_before, int(player.gold)]
	return true


## 测试5：备用区背面设置的装备弃置（face_down=true）-> 不触发
func test_pilot_085_reserve_face_down_discard_no_gold() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_085(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player = s.player
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if equip == null:
		return "无法创建装备实例"
	_equip_to_slot(gs, s.mech, equip, &"reserve_1", true)
	var gold_before: int = int(player.gold)
	await _discard_cards(battle, [equip.instance_id], &"sell_set_equipment")
	if int(player.gold) != gold_before:
		return "备用区背面装备弃置不应获金：期望 %d 实际 %d" % [gold_before, int(player.gold)]
	return true


## 测试6：替换弃置 reason（被新牌顶掉 equipment_replace）-> 同样触发 +4
func test_pilot_085_replace_reason_also_counts() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_085(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player = s.player
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if equip == null:
		return "无法创建装备实例"
	_equip_to_slot(gs, s.mech, equip, &"头部", false)
	var gold_before: int = int(player.gold)
	await _discard_cards(battle, [equip.instance_id], &"equipment_replace")
	if int(player.gold) != gold_before + 4:
		return "替换弃置应+4金币：期望 %d 实际 %d" % [gold_before + 4, int(player.gold)]
	return true


## 测试7：批量弃置多张正面装备（自1他1）-> 累加 4+3=7 金币
func test_pilot_085_multi_discard_accumulates() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_085(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player = s.player
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var eq_self = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	var eq_other = _make_instance(gs, cdb, "part_001_量产装_头部", &"enemy")
	if eq_self == null or eq_other == null:
		return "无法创建装备实例"
	_equip_to_slot(gs, s.mech, eq_self, &"头部", false)
	_equip_to_slot(gs, enemy_mech, eq_other, &"头部", false)
	var gold_before: int = int(player.gold)
	await _discard_cards(battle, [eq_self.instance_id, eq_other.instance_id], &"test_batch")
	if int(player.gold) != gold_before + 7:
		return "批量弃置自1他1应+7金币：期望 %d 实际 %d" % [gold_before + 7, int(player.gold)]
	return true


## 测试8：量产装已设置装备卖出（sell_set_equipment）-> 同样触发 +4（含卖价金币）
func test_pilot_085_sell_set_equipment_counts() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_pilot_085(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	var cdb = s.cdb
	var player = s.player
	# 量产装 part_001 带 equipment_effect_001「已设置装备可卖出」
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if equip == null:
		return "无法创建装备实例"
	var sell_price: int = int(equip.def.cost) if equip.def != null else 1
	_equip_to_slot(gs, s.mech, equip, &"头部", false)
	var gold_before: int = int(player.gold)
	var ret: Dictionary = battle.context.card_set_service.sell_equipment(&"player", equip.instance_id)
	if not ret.get("ok", false):
		return "卖出已设置量产装应成功：%s" % str(ret)
	await _pump_frames(10)
	var expected: int = gold_before + sell_price + 4
	if int(player.gold) != expected:
		return "量产装卖出应+%d（卖价%d+莽克4）：期望 %d 实际 %d" % [sell_price + 4, sell_price, expected, int(player.gold)]
	return true

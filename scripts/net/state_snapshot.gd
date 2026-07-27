## state_snapshot.gd - PvP 双进程状态同步的快照序列化
##
## host 调 serialize(context, viewer_pid) 把 game_state 序列化成纯 Variant Dict
## （可经 StreamPeerTCP.put_var 传输）；client 调 apply_snapshot(context, snap)
## 把 Dict 重建回 game_state，使现有 UI 面板（HandPanel/EquipmentPanel/BattleBoard
## 等读 game_state 的面板）无需改动即可渲染。
##
## viewer_pid：
##   &""  -> 全量（不隐藏任何信息，供往返测试用）
##   <pid> -> 按该玩家视角隐藏对手手牌（对手 action_hand/equipment_hand 仅给数量，
##            对手手牌的 CardInstance 不进入 cards 表）。装备/地图/商店/弃牌堆公开。
##
## 注意：StringName 必须保留。Godot Dictionary 对 String 与 StringName key 区分对待，
## runtime 大量用 &"头部" / &"weapon_1" 等 StringName 查 slots/mechs/players 字典，
## 若重建时 key 变成 String 会导致查表 miss。故本模块全程保留 StringName。
## 传输用 put_var/get_var（原生支持 StringName + 自带长度前缀分帧），不用 JSON。
class_name StateSnapshot
extends RefCounted

const _PlayerState = preload("res://scripts/runtime/PlayerState.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _MechFrameDef = preload("res://scripts/card_defs/MechFrameDef.gd")


# ═══════════════════════════════════════════
# 序列化
# ═══════════════════════════════════════════

## 序列化整个 game_state 为纯 Dict。
func serialize(context, viewer_pid: StringName = &"") -> Dictionary:
	var gs = context.game_state
	var snap := {}
	snap["viewer"] = viewer_pid
	snap["turn_number"] = gs.turn_number
	snap["active_player_id"] = gs.active_player_id
	snap["phase"] = gs.phase
	snap["players"] = _serialize_players(gs, viewer_pid)
	snap["mechs"] = _serialize_mechs(gs)
	# cards 表只含 viewer 可见的牌（全量模式 = 全部；视角模式 = 自己手牌+公开牌）
	snap["cards"] = _serialize_cards(gs, viewer_pid)
	snap["map"] = _serialize_map(gs)
	snap["deck"] = _serialize_deck(gs, viewer_pid)
	snap["shop"] = _serialize_shop(gs)
	snap["log"] = gs.log.duplicate(true)
	snap["temp_values"] = gs.temp_values.duplicate(true)
	return snap


func _serialize_players(gs, viewer_pid: StringName) -> Dictionary:
	var out := {}
	for pid: StringName in gs.players:
		var p = gs.players[pid]
		var hidden := viewer_pid != &"" and pid != viewer_pid
		var entry := {
			"player_id": p.player_id,
			"gold": p.gold,
			"is_human": p.is_human,
			"action_card_limit": p.action_card_limit,
			"attack_limit": p.attack_limit,
			"once_per_turn_used": p.once_per_turn_used.duplicate(true),
			"turn_counters": p.turn_counters.duplicate(true),
			"statuses": p.statuses.duplicate(true),
			"hand_revealed": p.hand_revealed,
			"sell_equipment_count_this_turn": p.sell_equipment_count_this_turn,
			"hand_hidden": hidden,
		}
		if hidden:
			# 对手手牌：只给数量，不给 instance_id（防偷看）
			entry["action_hand"] = []
			entry["equipment_hand"] = []
			entry["action_hand_count"] = p.action_hand.size()
			entry["equipment_hand_count"] = p.equipment_hand.size()
		else:
			entry["action_hand"] = p.action_hand.duplicate()
			entry["equipment_hand"] = p.equipment_hand.duplicate()
			entry["action_hand_count"] = p.action_hand.size()
			entry["equipment_hand_count"] = p.equipment_hand.size()
		out[pid] = entry
	return out


func _serialize_mechs(gs) -> Dictionary:
	var out := {}
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		var frame_card_id: StringName = m.frame_def.card_id if m.frame_def != null else &""
		var slots_out := {}
		for sid: StringName in m.slots:
			var slot: MechSlotState = m.slots[sid]
			slots_out[sid] = {
				"slot_id": slot.slot_id,
				"slot_kind": slot.slot_kind,
				"base_armor": slot.base_armor,
				"base_power": slot.base_power,
				"base_durability": slot.base_durability,
				"region_damage_tokens": slot.region_damage_tokens,
				"armor_modifier": slot.armor_modifier,
				"power_modifier": slot.power_modifier,
				"equipped_card_instance_id": slot.equipped_card.instance_id if slot.equipped_card != null else &"",
			}
		out[mech_id] = {
			"mech_id": m.mech_id,
			"owner_player_id": m.owner_player_id,
			"frame_card_id": frame_card_id,
			"base_weapons": m.base_weapons.duplicate(true),
			"current_hp": m.current_hp,
			"max_hp": m.max_hp,
			"power": m.power,
			"max_power": m.max_power,
			"position": m.position.duplicate(),
			"destroyed": m.destroyed,
			"attack_count_this_turn": m.attack_count_this_turn,
			"max_attacks_per_turn": m.max_attacks_per_turn,
			"statuses": m.statuses.duplicate(true),
			"temp_armor_bonus": m.temp_armor_bonus,
			"slots": slots_out,
		}
	return out


## 判定一张牌对 viewer 是否可见
func _is_card_visible(card, viewer_pid: StringName) -> bool:
	if viewer_pid == &"":
		return true
	# 对手手牌不可见；其余区域（装备槽/武器槽/备用/事件/机师/弃牌/临时区/商店/虚空）公开
	if card.zone == &"action_hand" or card.zone == &"equipment_hand":
		return card.owner_player_id == viewer_pid
	return true


func _serialize_cards(gs, viewer_pid: StringName) -> Dictionary:
	var out := {}
	for instance_id: StringName in gs.cards:
		var card = gs.cards[instance_id]
		if not _is_card_visible(card, viewer_pid):
			continue
		var card_id: StringName = card.def.card_id if card.def != null else &""
		out[instance_id] = {
			"instance_id": card.instance_id,
			"card_id": card_id,
			"owner_player_id": card.owner_player_id,
			"mech_id": card.mech_id,
			"zone": card.zone,
			"slot_id": card.slot_id,
			"damage_tokens": card.damage_tokens,
			"face_down": card.face_down,
			"disabled": card.disabled,
			"timer": card.timer,
			"counters": card.counters.duplicate(true),
			"known_to": card.known_to.duplicate(),
			"energy_charge_stacks": card.energy_charge_stacks,
		}
	return out


func _serialize_map(gs) -> Dictionary:
	var cells_out := {}
	if gs.map_state != null:
		for key: String in gs.map_state.cells:
			var cell = gs.map_state.cells[key]
			cells_out[key] = {
				"cell_id": cell.cell_id,
				"q": cell.q,
				"r": cell.r,
				"terrain": cell.terrain,
				"marker_id": cell.marker_id,
			}
	return {
		"cells": cells_out,
		"markers": gs.map_state.markers.duplicate(true) if gs.map_state != null else [],
	}


## 牌堆：全量模式给完整 instance_id 列表；视角模式只给数量（牌堆顺序对双方均保密）
func _serialize_deck(gs, viewer_pid: StringName) -> Dictionary:
	var d = gs.deck_state
	if viewer_pid == &"":
		return {
			"action_deck": d.action_deck.duplicate(),
			"equipment_deck": d.equipment_deck.duplicate(),
			"advanced_equipment_deck": d.advanced_equipment_deck.duplicate(),
			"pilot_deck": d.pilot_deck.duplicate(),
			"event_deck": d.event_deck.duplicate(),
			"action_discard_pile": d.action_discard_pile.duplicate(),
			"equipment_discard_pile": d.equipment_discard_pile.duplicate(),
			"full": true,
		}
	return {
		"action_deck_count": d.action_deck.size(),
		"equipment_deck_count": d.equipment_deck.size(),
		"advanced_equipment_deck_count": d.advanced_equipment_deck.size(),
		"pilot_deck_count": d.pilot_deck.size(),
		"event_deck_count": d.event_deck.size(),
		"action_discard_pile": d.action_discard_pile.duplicate(),  # 弃牌堆公开
		"equipment_discard_pile": d.equipment_discard_pile.duplicate(),
		"full": false,
	}


func _serialize_shop(gs) -> Dictionary:
	var s = gs.shop_state
	return {
		"normal_slots": s.normal_slots.duplicate(),
		"advanced_slot": s.advanced_slot,
		"hidden_advanced_slot": s.hidden_advanced_slot,
		"hidden_revealed": s.hidden_revealed,
	}


# ═══════════════════════════════════════════
# 反序列化（重建 game_state，供 client 渲染）
# ═══════════════════════════════════════════

## 把快照重建到 context.game_state（先清空再重建）。
## CardDef 经 context.card_database.get_card(card_id) 重绑；
## MechFrameDef 经 context.registry.get_mech_frame(frame_card_id) 重绑。
func apply_snapshot(context, snap: Dictionary) -> void:
	var gs = context.game_state
	_reset_game_state(gs)

	gs.turn_number = int(snap.get("turn_number", 1))
	gs.active_player_id = snap.get("active_player_id", &"")
	gs.phase = snap.get("phase", &"")

	# 1. 先重建所有 CardInstance（玩家手牌/装备/弃牌/商店/临时区等）
	#    全量模式还包含牌堆里的牌。
	var cards_snap: Dictionary = snap.get("cards", {})
	var rehydrated_cards: Dictionary = {}
	for instance_id: StringName in cards_snap:
		var c_snap: Dictionary = cards_snap[instance_id]
		var card_id: StringName = c_snap.get("card_id", &"")
		var def = null
		if context.card_database != null and card_id != &"":
			def = context.card_database.get_card(card_id)
		var card: CardInstance = _CardInstance.new(instance_id, def)
		card.owner_player_id = c_snap.get("owner_player_id", &"")
		card.mech_id = c_snap.get("mech_id", &"")
		card.zone = c_snap.get("zone", &"")
		card.slot_id = c_snap.get("slot_id", &"")
		card.damage_tokens = int(c_snap.get("damage_tokens", 0))
		card.face_down = bool(c_snap.get("face_down", false))
		card.disabled = bool(c_snap.get("disabled", false))
		card.timer = int(c_snap.get("timer", 0))
		card.counters = c_snap.get("counters", {}).duplicate(true)
		card.known_to = c_snap.get("known_to", []).duplicate()
		card.energy_charge_stacks = int(c_snap.get("energy_charge_stacks", 0))
		gs.cards[instance_id] = card
		rehydrated_cards[instance_id] = card

	# 2. 全量模式的牌堆实例也要进 cards（它们已在 cards_snap 里，上面已重建）。
	#    若是视角模式，牌堆里的牌不在 cards_snap 中，不重建（client 不需要）。

	# 3. 重建玩家
	var players_snap: Dictionary = snap.get("players", {})
	for pid: StringName in players_snap:
		var p_snap: Dictionary = players_snap[pid]
		var p: PlayerState = _PlayerState.new()
		p.player_id = p_snap.get("player_id", pid)
		p.gold = int(p_snap.get("gold", 0))
		p.is_human = bool(p_snap.get("is_human", true))
		p.action_card_limit = int(p_snap.get("action_card_limit", 5))
		p.attack_limit = int(p_snap.get("attack_limit", 1))
		p.once_per_turn_used = p_snap.get("once_per_turn_used", {}).duplicate(true)
		p.turn_counters = p_snap.get("turn_counters", {}).duplicate(true)
		p.statuses = p_snap.get("statuses", []).duplicate(true)
		p.hand_revealed = bool(p_snap.get("hand_revealed", false))
		p.sell_equipment_count_this_turn = int(p_snap.get("sell_equipment_count_this_turn", 0))
		# 手牌：hidden 时为空数组（client 用 action_hand_count 渲染牌背）；否则真实 instance_id
		var ah: Array = p_snap.get("action_hand", [])
		var eh: Array = p_snap.get("equipment_hand", [])
		for cid in ah:
			p.action_hand.append(cid)
		for cid in eh:
			p.equipment_hand.append(cid)
		gs.players[pid] = p

	# 4. 重建机甲（含槽位，equipped_card 从已重建的 cards 表取引用）
	var mechs_snap: Dictionary = snap.get("mechs", {})
	for mech_id: StringName in mechs_snap:
		var m_snap: Dictionary = mechs_snap[mech_id]
		var m: MechState = _MechState.new()
		m.mech_id = m_snap.get("mech_id", mech_id)
		m.owner_player_id = m_snap.get("owner_player_id", &"")
		m.frame_def = _rehydrate_frame_def(context, m_snap.get("frame_card_id", &""))
		m.base_weapons = m_snap.get("base_weapons", []).duplicate(true)
		m.current_hp = int(m_snap.get("current_hp", 0))
		m.max_hp = int(m_snap.get("max_hp", 0))
		m.power = int(m_snap.get("power", 0))
		m.max_power = int(m_snap.get("max_power", 0))
		m.position = m_snap.get("position", {"q": 0, "r": 0}).duplicate()
		m.destroyed = bool(m_snap.get("destroyed", false))
		m.attack_count_this_turn = int(m_snap.get("attack_count_this_turn", 0))
		m.max_attacks_per_turn = int(m_snap.get("max_attacks_per_turn", 1))
		m.statuses = m_snap.get("statuses", []).duplicate(true)
		m.temp_armor_bonus = int(m_snap.get("temp_armor_bonus", 0))
		var slots_snap: Dictionary = m_snap.get("slots", {})
		for sid: StringName in slots_snap:
			var s_snap: Dictionary = slots_snap[sid]
			var slot: MechSlotState = _MechSlotState.new()
			slot.slot_id = s_snap.get("slot_id", sid)
			slot.slot_kind = s_snap.get("slot_kind", &"PART")
			slot.base_armor = int(s_snap.get("base_armor", 0))
			slot.base_power = int(s_snap.get("base_power", 0))
			slot.base_durability = int(s_snap.get("base_durability", 0))
			slot.region_damage_tokens = int(s_snap.get("region_damage_tokens", 0))
			slot.armor_modifier = int(s_snap.get("armor_modifier", 0))
			slot.power_modifier = int(s_snap.get("power_modifier", 0))
			var eq_id: StringName = s_snap.get("equipped_card_instance_id", &"")
			if eq_id != &"" and rehydrated_cards.has(eq_id):
				slot.equipped_card = rehydrated_cards[eq_id]
			else:
				slot.equipped_card = null
			m.slots[sid] = slot
		gs.mechs[mech_id] = m

	# 5. 重建地图
	_apply_map(gs, snap.get("map", {}))

	# 6. 重建牌堆
	_apply_deck(gs, snap.get("deck", {}))

	# 7. 重建商店
	_apply_shop(gs, snap.get("shop", {}))

	# 8. 日志与临时值
	gs.log = snap.get("log", []).duplicate(true)
	gs.temp_values = snap.get("temp_values", {}).duplicate(true)


func _reset_game_state(gs) -> void:
	gs.players.clear()
	gs.mechs.clear()
	gs.cards.clear()
	gs.attacks.clear()
	gs.damage_contexts.clear()
	gs.rule_modifiers.clear()
	gs.temp_values.clear()
	gs.pending_custom_effects.clear()
	gs.current_attack_id = &""
	gs.current_damage_context_id = &""
	gs.turn_number = 1
	gs.active_player_id = &""
	gs.phase = &""
	gs.log.clear()
	if gs.map_state != null:
		gs.map_state.cells.clear()
		gs.map_state.markers.clear()
	if gs.deck_state != null:
		gs.deck_state.action_deck.clear()
		gs.deck_state.equipment_deck.clear()
		gs.deck_state.advanced_equipment_deck.clear()
		gs.deck_state.pilot_deck.clear()
		gs.deck_state.event_deck.clear()
		gs.deck_state.action_discard_pile.clear()
		gs.deck_state.equipment_discard_pile.clear()
	if gs.shop_state != null:
		gs.shop_state.normal_slots.clear()
		gs.shop_state.advanced_slot = &""
		gs.shop_state.hidden_advanced_slot = &""
		gs.shop_state.hidden_revealed = false


## 从 data_registry 重建 MechFrameDef（与 GameSetupService._create_mech_from_frame 中
## frame_def 部分一致）。client 必须加载同一份资料（DataRegistry.load_all）才能重绑。
func _rehydrate_frame_def(context, frame_card_id: StringName):
	if frame_card_id == &"" or context.registry == null:
		return null
	var frame_data: Dictionary = context.registry.get_mech_frame(String(frame_card_id))
	if frame_data.is_empty():
		return null
	var fd: MechFrameDef = _MechFrameDef.new()
	fd.card_id = StringName(frame_data.get("id", frame_card_id))
	fd.display_name = frame_data.get("name", "")
	fd.card_kind = &"mech_frame"
	fd.faction = frame_data.get("faction", "")
	fd.life = int(frame_data.get("life", 25))
	fd.base_slots = frame_data.get("base_slots", {})
	var raw_weapons: Array = frame_data.get("base_weapons", [])
	var weapons: Array[Dictionary] = []
	for w: Dictionary in raw_weapons:
		weapons.append(w)
	fd.base_weapons = weapons
	return fd


func _apply_map(gs, map_snap: Dictionary) -> void:
	if gs.map_state == null:
		return
	var cells_snap: Dictionary = map_snap.get("cells", {})
	for key: String in cells_snap:
		var c_snap: Dictionary = cells_snap[key]
		var q: int = int(c_snap.get("q", 0))
		var r: int = int(c_snap.get("r", 0))
		var terrain: StringName = c_snap.get("terrain", &"NORMAL")
		gs.map_state.add_cell(q, r, terrain)
		# add_cell 用默认 marker_id=&""，覆盖为快照值
		var cell = gs.map_state.cells.get(key)
		if cell != null:
			cell.marker_id = c_snap.get("marker_id", &"")
	gs.map_state.markers = map_snap.get("markers", []).duplicate(true)


func _apply_deck(gs, deck_snap: Dictionary) -> void:
	if gs.deck_state == null:
		return
	var d = gs.deck_state
	if bool(deck_snap.get("full", false)):
		# 全量模式：直接还原 instance_id 列表（client 不用，但往返测试要等价）
		for cid in deck_snap.get("action_deck", []):
			d.action_deck.append(cid)
		for cid in deck_snap.get("equipment_deck", []):
			d.equipment_deck.append(cid)
		for cid in deck_snap.get("advanced_equipment_deck", []):
			d.advanced_equipment_deck.append(cid)
		for cid in deck_snap.get("pilot_deck", []):
			d.pilot_deck.append(cid)
		for cid in deck_snap.get("event_deck", []):
			d.event_deck.append(cid)
		for cid in deck_snap.get("action_discard_pile", []):
			d.action_discard_pile.append(cid)
		for cid in deck_snap.get("equipment_discard_pile", []):
			d.equipment_discard_pile.append(cid)
	else:
		# 视角模式：牌堆内容保密，只保留弃牌堆（公开）；牌堆数组留空
		# （client 的 deck_info_popup 会显示 0 张，Phase I 再补 counts 字段）
		for cid in deck_snap.get("action_discard_pile", []):
			d.action_discard_pile.append(cid)
		for cid in deck_snap.get("equipment_discard_pile", []):
			d.equipment_discard_pile.append(cid)


func _apply_shop(gs, shop_snap: Dictionary) -> void:
	if gs.shop_state == null:
		return
	var s = gs.shop_state
	for cid in shop_snap.get("normal_slots", []):
		s.normal_slots.append(cid)
	s.advanced_slot = shop_snap.get("advanced_slot", &"")
	s.hidden_advanced_slot = shop_snap.get("hidden_advanced_slot", &"")
	s.hidden_revealed = bool(shop_snap.get("hidden_revealed", false))

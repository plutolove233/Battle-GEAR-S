## test_state_snapshot_roundtrip.gd - Phase A: 状态快照序列化往返测试
##
## 验证 StateSnapshot.serialize -> apply_snapshot 能忠实重建 game_state，
## 供 PvP client 渲染。全量模式(viewer="")测字段等价；视角模式测对手手牌隐藏。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const StateSnapshot = preload("res://scripts/net/state_snapshot.gd")
const GameContext = preload("res://scripts/runtime/GameContext.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


## 建一个全新的 client 风格 context（仅装数据 + 空 game_state），供 apply_snapshot
func _new_client_context(host_registry) -> GameContext:
	var ctx: GameContext = GameContext.new()
	ctx.initialize(host_registry)
	return ctx


## 给玩家机甲的 weapon_1 装一把装备武器，并在躯干槽放一个损伤标记，以测装备牌+损伤序列化
func _equip_one_weapon_and_damage(battle: BattleState) -> StringName:
	var ctx = battle.context
	var gs = ctx.game_state
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	# 从装备牌堆取一张武器
	var picked: StringName = &""
	for cid: StringName in gs.deck_state.equipment_deck:
		var card = gs.cards.get(cid)
		if card and card.def and card.def.weapon_kind != &"" and card.def.weapon_kind != null:
			# EquipmentCardDef 有 weapon_kind 字段即武器
			picked = cid
			break
	if picked == &"" and gs.deck_state.equipment_deck.size() > 0:
		picked = gs.deck_state.equipment_deck[0]
	if picked != &"":
		gs.deck_state.equipment_deck.erase(picked)
		var card = gs.cards.get(picked)
		card.owner_player_id = &"player"
		card.zone = &"equipment_hand"
		player.equipment_hand.append(picked)
		ctx.card_set_service.set_equipment(&"player", picked, &"weapon_1")
	# 躯干槽放 2 个区域损伤标记
	if mech.slots.has(&"躯干"):
		mech.slots[&"躯干"].region_damage_tokens = 2
	return picked


## 全量往返：核心标量字段（金币/HP/动力/位置/回合）
func test_full_roundtrip_core_fields() -> Variant:
	var battle: BattleState = _new_battle()
	var host_gs = battle.context.game_state
	# 改一些状态
	host_gs.turn_number = 5
	host_gs.active_player_id = &"enemy"
	host_gs.phase = &"ATTACK"
	var p_mech = host_gs.get_mech_for_player(&"player")
	p_mech.current_hp = 17
	p_mech.power = 3
	p_mech.position = {"q": 7, "r": 1}
	host_gs.players.get(&"player").gold = 42

	var snap := StateSnapshot.new().serialize(battle.context, &"")
	var client_ctx := _new_client_context(battle.registry)
	StateSnapshot.new().apply_snapshot(client_ctx, snap)
	var cgs = client_ctx.game_state

	if cgs.turn_number != 5:
		return "turn_number mismatch: %d" % cgs.turn_number
	if cgs.active_player_id != &"enemy":
		return "active_player_id mismatch: %s" % String(cgs.active_player_id)
	if cgs.phase != &"ATTACK":
		return "phase mismatch: %s" % String(cgs.phase)
	var c_p_mech = cgs.get_mech_for_player(&"player")
	if c_p_mech.current_hp != 17:
		return "player hp mismatch: %d" % c_p_mech.current_hp
	if c_p_mech.power != 3:
		return "player power mismatch: %d" % c_p_mech.power
	if c_p_mech.position != {"q": 7, "r": 1}:
		return "player position mismatch: %s" % str(c_p_mech.position)
	if cgs.players.get(&"player").gold != 42:
		return "player gold mismatch: %d" % cgs.players.get(&"player").gold
	return true


## 全量往返：机甲槽位/损伤/基础武器/装备牌
func test_full_roundtrip_mech_slots_and_equipment() -> Variant:
	var battle: BattleState = _new_battle()
	var equipped_id := _equip_one_weapon_and_damage(battle)
	var host_gs = battle.context.game_state
	var host_mech = host_gs.get_mech_for_player(&"player")

	var snap := StateSnapshot.new().serialize(battle.context, &"")
	var client_ctx := _new_client_context(battle.registry)
	StateSnapshot.new().apply_snapshot(client_ctx, snap)
	var cgs = client_ctx.game_state
	var c_mech = cgs.get_mech_for_player(&"player")

	# 槽数一致
	if c_mech.slots.size() != host_mech.slots.size():
		return "slot count mismatch: %d vs %d" % [c_mech.slots.size(), host_mech.slots.size()]
	# 躯干损伤标记
	if not c_mech.slots.has(&"躯干"):
		return "client missing 躯干 slot"
	if c_mech.slots[&"躯干"].region_damage_tokens != 2:
		return "躯干 damage tokens mismatch: %d" % c_mech.slots[&"躯干"].region_damage_tokens
	# 基础武器一致
	if c_mech.base_weapons.size() != host_mech.base_weapons.size():
		return "base_weapons count mismatch: %d vs %d" % [c_mech.base_weapons.size(), host_mech.base_weapons.size()]
	# get_weapon_ids 应返回相同（含 frame_base_weapon_* 虚拟ID 或装备ID）
	var host_wids = host_mech.get_weapon_ids()
	var c_wids = c_mech.get_weapon_ids()
	if host_wids.size() != c_wids.size():
		return "weapon_ids count mismatch: %d vs %d" % [host_wids.size(), c_wids.size()]
	# 装备的武器牌应在 client 重建
	if equipped_id != &"":
		if not cgs.cards.has(equipped_id):
			return "equipped card %s missing in client cards" % String(equipped_id)
		var c_slot_card = c_mech.slots.get(&"weapon_1")
		if c_slot_card == null or c_slot_card.equipped_card == null:
			return "client weapon_1 equipped_card is null"
		if c_slot_card.equipped_card.instance_id != equipped_id:
			return "client weapon_1 equipped card id mismatch: %s" % String(c_slot_card.equipped_card.instance_id)
		# 装备牌的 def 应已重绑（card_database.get_card）
		if c_slot_card.equipped_card.def == null:
			return "client equipped card def is null (rehydrate failed)"
	return true


## 全量往返：玩家手牌 instance_id 与卡牌 def 重绑
func test_full_roundtrip_hand_cards() -> Variant:
	var battle: BattleState = _new_battle()
	var host_gs = battle.context.game_state
	var host_player = host_gs.players.get(&"player")
	if host_player.action_hand.is_empty():
		return "precondition: player has no action cards"

	var snap := StateSnapshot.new().serialize(battle.context, &"")
	var client_ctx := _new_client_context(battle.registry)
	StateSnapshot.new().apply_snapshot(client_ctx, snap)
	var cgs = client_ctx.game_state
	var c_player = cgs.players.get(&"player")

	if c_player.action_hand.size() != host_player.action_hand.size():
		return "action_hand size mismatch: %d vs %d" % [c_player.action_hand.size(), host_player.action_hand.size()]
	for i in range(host_player.action_hand.size()):
		var hid: StringName = host_player.action_hand[i]
		var cid: StringName = c_player.action_hand[i]
		if hid != cid:
			return "action_hand[%d] id mismatch: %s vs %s" % [i, String(hid), String(cid)]
		var c_card = cgs.cards.get(cid)
		if c_card == null:
			return "client missing card %s" % String(cid)
		if c_card.def == null:
			return "client card %s def is null" % String(cid)
		var h_card = host_gs.cards.get(hid)
		if c_card.def.card_id != h_card.def.card_id:
			return "card %s card_id mismatch: %s vs %s" % [String(cid), String(c_card.def.card_id), String(h_card.def.card_id)]
	return true


## 全量往返：地图格子与商店
func test_full_roundtrip_map_and_shop() -> Variant:
	var battle: BattleState = _new_battle()
	var host_gs = battle.context.game_state
	var host_cell_count = host_gs.map_state.cells.size()

	var snap := StateSnapshot.new().serialize(battle.context, &"")
	var client_ctx := _new_client_context(battle.registry)
	StateSnapshot.new().apply_snapshot(client_ctx, snap)
	var cgs = client_ctx.game_state

	if cgs.map_state.cells.size() != host_cell_count:
		return "map cell count mismatch: %d vs %d" % [cgs.map_state.cells.size(), host_cell_count]
	# 抽查一个格子地形
	var sample_key = host_gs.map_state.cells.keys()[0]
	var h_cell = host_gs.map_state.cells[sample_key]
	var c_cell = cgs.map_state.cells.get(sample_key)
	if c_cell == null:
		return "client missing cell %s" % sample_key
	if c_cell.terrain != h_cell.terrain:
		return "cell terrain mismatch: %s vs %s" % [String(c_cell.terrain), String(h_cell.terrain)]
	# 商店槽位数一致（tutorial 初始化了商店）
	if cgs.shop_state.normal_slots.size() != host_gs.shop_state.normal_slots.size():
		return "shop normal_slots size mismatch: %d vs %d" % [cgs.shop_state.normal_slots.size(), host_gs.shop_state.normal_slots.size()]
	return true


## 视角模式：viewer=enemy 时，player(对手)手牌应隐藏（count 给出，instance_id 不在 cards 表）
func test_viewer_hides_opponent_hand() -> Variant:
	var battle: BattleState = _new_battle()
	var host_gs = battle.context.game_state
	var player = host_gs.players.get(&"player")
	var player_hand_size = player.action_hand.size()
	if player_hand_size == 0:
		return "precondition: player has no action cards"

	# viewer=enemy：enemy 视角下 player 是对手
	var snap := StateSnapshot.new().serialize(battle.context, &"enemy")

	# 对手(player)手牌应被隐藏
	var p_snap: Dictionary = snap["players"][&"player"]
	if not bool(p_snap.get("hand_hidden", false)):
		return "player hand should be hidden from enemy viewer"
	if int(p_snap.get("action_hand_count", -1)) != player_hand_size:
		return "player action_hand_count mismatch: %d vs %d" % [int(p_snap.get("action_hand_count", -1)), player_hand_size]
	if p_snap.get("action_hand", []).size() != 0:
		return "player action_hand should be empty array when hidden"

	# player 的手牌 instance_id 不应出现在 cards 表
	var cards_snap: Dictionary = snap["cards"]
	for cid: StringName in player.action_hand:
		if cards_snap.has(cid):
			return "opponent hand card %s leaked into cards table" % String(cid)

	# 但 enemy 自己手牌应可见
	var e_snap: Dictionary = snap["players"][&"enemy"]
	if bool(e_snap.get("hand_hidden", true)):
		return "enemy own hand should be visible to self"
	var enemy = host_gs.players.get(&"enemy")
	if e_snap.get("action_hand", []).size() != enemy.action_hand.size():
		return "enemy own action_hand size mismatch"

	# 重建到 client 后，对手手牌为空数组（client 用 count 渲染牌背，Phase C 实现）
	var client_ctx := _new_client_context(battle.registry)
	StateSnapshot.new().apply_snapshot(client_ctx, snap)
	var cgs = client_ctx.game_state
	if cgs.players.get(&"player").action_hand.size() != 0:
		return "client player action_hand should be empty (hidden)"
	if cgs.players.get(&"enemy").action_hand.size() != enemy.action_hand.size():
		return "client enemy action_hand size mismatch"
	return true


## 视角模式：viewer=enemy 时，敌方装备/公开信息仍可见
func test_viewer_keeps_public_info() -> Variant:
	var battle: BattleState = _new_battle()
	_equip_one_weapon_and_damage(battle)
	var host_gs = battle.context.game_state
	# 找到玩家装备的武器 instance_id（公开，应可见）
	var host_mech = host_gs.get_mech_for_player(&"player")
	var equipped_id: StringName = &""
	if host_mech.slots.has(&"weapon_1") and host_mech.slots[&"weapon_1"].equipped_card:
		equipped_id = host_mech.slots[&"weapon_1"].equipped_card.instance_id
	if equipped_id == &"":
		return "precondition: no equipped weapon"

	var snap := StateSnapshot.new().serialize(battle.context, &"enemy")
	var cards_snap: Dictionary = snap["cards"]
	if not cards_snap.has(equipped_id):
		return "public equipped card %s should be visible to enemy viewer" % String(equipped_id)

	# 重建后 client 仍能看到该装备牌与 def
	var client_ctx := _new_client_context(battle.registry)
	StateSnapshot.new().apply_snapshot(client_ctx, snap)
	var cgs = client_ctx.game_state
	if not cgs.cards.has(equipped_id):
		return "client missing public equipped card"
	var c_mech = cgs.get_mech_for_player(&"player")
	if c_mech == null or not c_mech.slots.has(&"weapon_1"):
		return "client missing player mech / weapon_1 slot"
	if c_mech.slots[&"weapon_1"].equipped_card == null:
		return "client weapon_1 equipped_card should be visible (public)"
	if c_mech.slots[&"weapon_1"].equipped_card.def == null:
		return "client public equipped card def null"
	return true


## 机师静态状态往返：悬赏/控制/批次/跳过 四字典随快照同步
func test_roundtrip_pilot_static() -> Variant:
	var battle: BattleState = _new_battle()
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	# 用真实机师建立各静态状态（source 用 pilot 实例 id）
	var pdef = cdb.get_card(&"pilot_006_里昂")
	if pdef == null:
		return "找不到 pilot_006_里昂"
	var inst_id: StringName = gs.next_id(&"card")
	var card = preload("res://scripts/runtime/CardInstance.gd").new(inst_id, pdef)
	card.owner_player_id = &"player"
	gs.cards[inst_id] = card
	var pilot_effects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
	# 建立：pilot_006 悬赏 / pilot_009 控制 / pilot_002 批次 / pilot_003 skip
	pilot_effects.set_pilot_006_mark(inst_id, &"enemy_mech", 1)
	pilot_effects.grant_temp_card_control(&"enemy_mech", &"攻击", &"player", inst_id)
	var b1: StringName = gs.next_id(&"card")
	gs.cards[b1] = preload("res://scripts/runtime/CardInstance.gd").new(b1, cdb.get_card(&"action_001_进攻"))
	pilot_effects.register_pilot_002_batch("test_snap_batch", &"enemy_mech", [b1], &"进攻", inst_id)
	pilot_effects.toggle_pilot_003_skip(inst_id, &"player", true)

	var snap := StateSnapshot.new().serialize(battle.context, &"")
	var client_ctx := _new_client_context(battle.registry)
	StateSnapshot.new().apply_snapshot(client_ctx, snap)
	# 静态状态应随快照恢复
	if pilot_effects.get_pilot_006_mark(inst_id) != &"enemy_mech":
		return "pilot_006 悬赏标记未随快照同步"
	if not pilot_effects.is_card_type_controlled_by(&"enemy_mech", &"攻击", &"player"):
		return "pilot_009 控制未随快照同步"
	var batch_found := false
	for bid in pilot_effects._pilot_002_batches:
		if String(pilot_effects._pilot_002_batches[bid].get("grant_source", &"")) == String(inst_id):
			batch_found = true
	if not batch_found:
		return "pilot_002 批次未随快照同步"
	if not pilot_effects.is_pilot_003_skip_active(&"player"):
		return "pilot_003 skip 未随快照同步"
	return true

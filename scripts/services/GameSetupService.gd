## GameSetupService.gd — 游戏初始化服务
##
## 负责创建教学战斗的完整初始状态：
## 玩家/敌方 PlayerState + MechState + CardInstance + 地图 + 牌堆
class_name GameSetupService
extends RefCounted

var context = null  # type: GameContext

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


## 初始化教学战斗
## 从 DataRegistry 读取教学战役配置，构建完整游戏状态
## pvp_map_features: 为 true 时在地图上配置绿/红格子 + 金币/事件标记点 + 初始标记
##   （仅 PvP 模式启用，教学/测试不启用以避免影响既有测试与固定布局）。
func setup_tutorial_battle(data_registry: DataRegistry, pvp_map_features: bool = false) -> Dictionary:
	var gs: GameState = context.game_state
	gs.reset_all()

	# 清空 TimingEngine 监听器：开新局时确保无上一局残留的状态/临时监听器
	# （状态监听器用 action_id="" 注册，不随动作 cleanup 清除，需在此显式清空）
	if context.timing_engine != null:
		context.timing_engine.temporary_listeners.clear()
		context.timing_engine.suppressed_effects.clear()
		context.timing_engine.permanent_listeners.clear()

	# ── 1. 读取教学战役配置 ──
	var battle_config: Dictionary = data_registry.get_tutorial_battle()
	if battle_config.is_empty():
		return {"ok": false, "message": "未找到教学战役配置"}

	# ── 2. 创建双方玩家 ──
	var player: PlayerState = _create_player(&"player", 15, true)
	var enemy: PlayerState = _create_player(&"enemy", 15, false)
	gs.players[player.player_id] = player
	gs.players[enemy.player_id] = enemy

	# ── 3. 创建双方机甲 ──
	var player_frame_id: String = battle_config.get("player_frame_id", "frame_001_基础框架")
	var enemy_frame_id: String = battle_config.get("enemy_frame_id", "frame_002_原始框架")

	var player_mech: MechState = _create_mech_from_frame(
		&"player_mech", &"player", player_frame_id, data_registry
	)
	var enemy_mech: MechState = _create_mech_from_frame(
		&"enemy_mech", &"enemy", enemy_frame_id, data_registry
	)
	gs.mechs[player_mech.mech_id] = player_mech
	gs.mechs[enemy_mech.mech_id] = enemy_mech

	# ── 4. 设置初始位置 ──
	var player_start: Dictionary = battle_config.get("player_start", {"q": 2, "r": 2})
	var enemy_start: Dictionary = battle_config.get("enemy_start", {"q": 20, "r": -6})
	player_mech.position = {"q": int(player_start.get("q", 2)), "r": int(player_start.get("r", 2))}
	enemy_mech.position = {"q": int(enemy_start.get("q", 20)), "r": int(enemy_start.get("r", 2))}

	# ── 5. 生成地图 ──
	var map_cols: int = int(battle_config.get("map", {}).get("cols", 24))
	var map_rows: int = int(battle_config.get("map", {}).get("rows", 8))
	var map_blocked: Array = battle_config.get("map", {}).get("blocked", [])
	var cells: Array[Dictionary] = _HexGrid.generate_rectangle(map_cols, map_rows, map_blocked)
	for cell: Dictionary in cells:
		gs.map_state.add_cell(int(cell.q), int(cell.r), &"NORMAL")

	# ── 5b. PvP 模式：配置绿/红格子 + 标记点 + 初始标记 ──
	if pvp_map_features:
		configure_map_features(gs)

	# ── 6. 构建牌堆 ──
	context.deck_build_service.build_all_decks_from_card_database()

	# ── 7. 注册所有已装备卡牌的效果 ──
	_register_equipped_effects(player_mech)
	_register_equipped_effects(enemy_mech)

	# ── 8. 记录回合上限 ──
	gs.temp_values["turn_limit"] = int(battle_config.get("turn_limit", 12))

	gs.write_log(&"game_setup", {"battle_id": battle_config.get("id", "")})
	return {"ok": true, "message": "initialized"}


## ── 内部方法 ──


## 创建玩家状态
func _create_player(pid: StringName, gold: int, is_human: bool = true) -> PlayerState:
	var p: PlayerState = PlayerState.new()
	p.player_id = pid
	p.gold = gold
	p.is_human = is_human
	return p


## 从框架定义创建机甲，包含所有槽位和基础武器
func _create_mech_from_frame(mech_id: StringName, owner_id: StringName, frame_id: String, data_registry: DataRegistry) -> MechState:
	var mech: MechState = MechState.new()
	mech.mech_id = mech_id
	mech.owner_player_id = owner_id

	# 获取框架定义
	var frame_data: Dictionary = data_registry.get_mech_frame(frame_id)
	var frame_def: MechFrameDef = MechFrameDef.new()
	frame_def.card_id = StringName(frame_data.get("id", frame_id))
	frame_def.display_name = frame_data.get("name", "")
	frame_def.card_kind = &"mech_frame"
	frame_def.faction = frame_data.get("faction", "")
	frame_def.life = int(frame_data.get("life", 25))
	frame_def.base_slots = frame_data.get("base_slots", {})
	var _raw_weapons: Array = frame_data.get("base_weapons", [])
	var _weapons: Array[Dictionary] = []
	for w: Dictionary in _raw_weapons:
		_weapons.append(w)
	frame_def.base_weapons = _weapons

	mech.frame_def = frame_def
	mech.max_hp = frame_def.life
	mech.current_hp = frame_def.life

	# ── 创建6个部件槽位 ──
	var body_slot_ids: Array[StringName] = [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]
	for slot_id: StringName in body_slot_ids:
		var slot: MechSlotState = MechSlotState.new()
		slot.slot_id = slot_id
		slot.slot_kind = &"PART"
		# 从框架定义读取基础属性
		var slot_data: Dictionary = frame_def.base_slots.get(String(slot_id), {})
		slot.base_armor = int(slot_data.get("armor", 0))
		slot.base_power = int(slot_data.get("power", 0))
		slot.base_durability = int(slot_data.get("durability", 0))
		mech.slots[slot_id] = slot

	# ── 创建2个武器槽位 ──
	for i: int in range(2):
		var weapon_slot_id: StringName = StringName("weapon_%d" % [i + 1])
		var w_slot: MechSlotState = MechSlotState.new()
		w_slot.slot_id = weapon_slot_id
		w_slot.slot_kind = &"WEAPON"
		mech.slots[weapon_slot_id] = w_slot

	# ── 收集所有基础武器数据 ──
	var base_weapons_list: Array[Dictionary] = []
	for i: int in range(frame_def.base_weapons.size()):
		var weapon_def_data: Dictionary = frame_def.base_weapons[i]
		base_weapons_list.append({
			"name": weapon_def_data.get("name", "基础武器"),
			"might": int(weapon_def_data.get("damage", 0)),
			"range_value": int(weapon_def_data.get("range", 1)),
			"weapon_kind": StringName(weapon_def_data.get("weapon_type", "")),
		})
	# 一次性设置所有基础武器
	if not base_weapons_list.is_empty():
		mech.set_base_weapons(base_weapons_list)

	# ── 创建2个备用槽位 ──
	for i: int in range(2):
		var reserve_slot_id: StringName = StringName("reserve_%d" % [i + 1])
		var r_slot: MechSlotState = MechSlotState.new()
		r_slot.slot_id = reserve_slot_id
		r_slot.slot_kind = &"RESERVE"
		mech.slots[reserve_slot_id] = r_slot

	# ── 创建1个事件槽位 ──
	var event_slot: MechSlotState = MechSlotState.new()
	event_slot.slot_id = &"event"
	event_slot.slot_kind = &"EVENT"
	mech.slots[&"event"] = event_slot

	# ── 创建1个机师槽位 ──
	var pilot_slot: MechSlotState = MechSlotState.new()
	pilot_slot.slot_id = &"pilot"
	pilot_slot.slot_kind = &"PILOT"
	mech.slots[&"pilot"] = pilot_slot

	# ── 计算初始动力 ──
	mech.max_power = mech.get_total_power()
	mech.power = mech.max_power

	return mech


## 创建卡牌实例
func _create_card_instance(card_id: StringName, owner_id: StringName, mech_id: StringName, zone: StringName, slot_id: StringName) -> CardInstance:
	var gs: GameState = context.game_state
	var instance_id: StringName = gs.next_id("card")
	var card: CardInstance = CardInstance.new(instance_id, null)
	card.owner_player_id = owner_id
	card.mech_id = mech_id
	card.zone = zone
	card.slot_id = slot_id
	return card


## 注册已装备卡牌的效果到 EffectRegistry
func _register_equipped_effects(mech: MechState) -> void:
	if context.effect_registry == null:
		return
	for slot_id: StringName in mech.slots:
		var slot: MechSlotState = mech.slots[slot_id]
		if slot.equipped_card != null:
			context.effect_registry.register_card(slot.equipped_card)


# ════════════════════════════════════════════════════════════
# 机师牌：设置 / 注销 / 效果注册（infra 2.2 + 2.3）
# ════════════════════════════════════════════════════════════

## 设置机师牌到机甲 pilot 槽：放牌 + 联动基础数值 + 注册机师效果。
## 建局 / dev 换机师调用。换机师须先调 unset_pilot 注销旧机师 listener 与派生状态。
## 数值联动（infra 2.2）：pilot.attack_limit -> PlayerState.attack_limit + MechState.max_attacks_per_turn；
## pilot.action_card_limit -> PlayerState.action_card_limit。
func set_pilot(mech_id: StringName, pilot_card_instance) -> void:
	var gs: GameState = context.game_state
	var mech = gs.mechs.get(mech_id)
	if mech == null or pilot_card_instance == null:
		return
	var slot = mech.slots.get(&"pilot")
	if slot == null:
		return
	# 放牌进 pilot 槽
	slot.equipped_card = pilot_card_instance
	pilot_card_instance.zone = &"pilot_slot"
	pilot_card_instance.slot_id = &"pilot"
	pilot_card_instance.mech_id = mech_id
	# 联动基础数值（机师牌决定回合攻击数与行动牌上限）
	var pdef = pilot_card_instance.def
	if pdef != null and pdef.card_kind == &"pilot":
		var player = gs.get_player_for_mech(mech_id)
		if player != null:
			player.attack_limit = pdef.attack_limit
			player.action_card_limit = pdef.action_card_limit
		mech.max_attacks_per_turn = pdef.attack_limit
	# 注册机师效果（DIRECT 出按钮 / LISTEN 监听时点 / AVAILABILITY 响应窗口）
	_register_pilot_effects(pilot_card_instance, mech_id)
	# 阵营光环注册（pilot_002 莱比尔联邦护甲+4 / pilot_005 肯特帝国动力+4）
	if pdef != null and (String(pdef.card_id) == "pilot_002_莱比尔" or String(pdef.card_id) == "pilot_005_肯特"):
		_ActionPilotEffects.register_faction_aura(pilot_card_instance.instance_id, pdef.card_id, String(pdef.faction))
	# 派生光环（pilot_002 护甲 / pilot_005 动力）注册后重算动力上限，使 max_power 算入
	mech.recalc_power_limits()
	var _log_card_id: String = String(pdef.card_id) if pdef != null else ""
	gs.write_log(&"pilot_set", {"mech_id": String(mech_id), "card_id": _log_card_id})


## 注销机师牌效果（换机师前调用）：注销 permanent listener，清出 pilot 槽。
## 派生光环/变量按 source_card_instance_id 清除由各 pilot 实现负责
## （pilot_002 授予全清 / pilot_008 X 不转移 / pilot_009 控制立即解除）。
func unset_pilot(mech_id: StringName) -> void:
	var gs: GameState = context.game_state
	var mech = gs.mechs.get(mech_id)
	if mech == null:
		return
	var slot = mech.slots.get(&"pilot")
	if slot == null or slot.equipped_card == null:
		return
	var old_card = slot.equipped_card
	# 注销该机师实例的全部 permanent listener（按 card_instance_id）
	if context.timing_engine != null:
		context.timing_engine.unregister_permanent_listeners_for_card(old_card.instance_id)
	# 注销阵营光环（pilot_002/005 换机师即时失效）
	_ActionPilotEffects.unregister_faction_aura(old_card.instance_id)
	# pilot_002 莱比尔离场：清除所有已转移批次权限（裁定歧义4：离场后所有权限和增益都没了）
	if old_card.def != null and String(old_card.def.card_id) == "pilot_002_莱比尔":
		_ActionPilotEffects.clear_pilot_002_batches_for_source(old_card.instance_id)
	# pilot_003 瑟尔基尔离场：清除跳过正面牌设置
	if old_card.def != null and String(old_card.def.card_id) == "pilot_003_瑟尔基尔":
		_ActionPilotEffects.clear_pilot_003_skip_for_source(old_card.instance_id)
	# pilot_009 美杜莎离场：立即解除本回合已建立的控制（裁定歧义5：换下立即解）
	if old_card.def != null and String(old_card.def.card_id) == "pilot_009_美杜莎":
		_ActionPilotEffects.clear_pilot_009_control_for_source(old_card.instance_id)
	# pilot_006 里昂离场：清除悬赏标记（持续效果随离场终止）
	if old_card.def != null and String(old_card.def.card_id) == "pilot_006_里昂":
		_ActionPilotEffects.clear_pilot_006_mark(old_card.instance_id)
	slot.equipped_card = null
	old_card.zone = &""
	old_card.slot_id = &""
	gs.write_log(&"pilot_unset", {"mech_id": String(mech_id), "card_id": String(old_card.def.card_id) if old_card.def != null else ""})


## 注册机师牌效果到 TimingEngine（仿 set_equipment_action._register_equipment_effects）。
## 遍历该机师的 effect_ids，对 LISTEN/AVAILABILITY 注册到 listen_timing，
## 对 DIRECT（无 listen_timing）注册到虚拟时点供 skill_bar 扫描，
## 派生值型效果跳过（实时重算）。
func _register_pilot_effects(card, mech_id: StringName) -> void:
	if context == null or context.timing_engine == null:
		return
	if card == null or card.def == null:
		return
	var effect_ids: Array = _ActionPilotEffects.get_effects_for_pilot(card.def.card_id, context)
	if effect_ids.is_empty():
		return
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var player_id: StringName = card.owner_player_id
	var binding_ctx: Dictionary = {
		"card_instance_id": card.instance_id,
		"mech_id": mech_id,
		"player_id": player_id,
		"card_def_id": card.def.card_id,
		"slot_id": &"pilot",
	}
	for effect_id: StringName in effect_ids:
		# pilot_005_effect_01 是 aura provider（授予型）：不注册自己 listener，向帝国机师授予 granted listener
		# （provider 本身无 ActionEffect 定义，须在 effect==null 检查前处理）
		if effect_id == &"pilot_005_effect_01":
			_grant_pilot_005_to_empire_mechs(card, mech_id)
			continue
		if effect_id == &"pilot_002_effect_01":
			# pilot_002 effect_01 aura provider：向联邦机师授予交牌转化能力（DIRECT 进攻 + AVAILABILITY 防御）
			_grant_pilot_002_to_federation_mechs(card, mech_id)
			continue
		var effect = all_effects.get(effect_id)
		if effect == null:
			continue
		# 派生值型效果不注册监听器（pilot_002 effect_02 护甲+4 / pilot_005 effect_02 动力+4 实时重算）
		if _ActionPilotEffects.is_pilot_derived_effect(effect_id):
			continue
		# DIRECT 主动效果（无 listen_timing）：用 effect_id 作虚拟时点注册，供 skill_bar/pilot 按钮扫描
		if effect.mode == _TimingConst.MODE_DIRECT and effect.listen_timing == &"":
			context.timing_engine.register_permanent_listener(effect_id, effect, binding_ctx)
			continue
		# LISTEN / AVAILABILITY：注册到 effect.listen_timing
		if (effect.mode == _TimingConst.MODE_LISTEN or effect.mode == _TimingConst.MODE_AVAILABILITY) and effect.listen_timing != &"":
			context.timing_engine.register_permanent_listener(effect.listen_timing, effect, binding_ctx)


## pilot_005 effect_01 授予机制：向所有帝国阵营机甲注册 granted ATTACK_PRE 弃牌 listener。
## granted listener 的 binding_context.card_instance_id=pilot_005 实例（注销用），
## mech_id=被授予帝国机甲（conditions SELF_MECH_IS_ATTACKER_OR_TARGET/PILOT_AURA_ACTIVE_FOR_MECH 用）。
## unset_pilot 时 unregister_permanent_listeners_for_card(pilot_005_instance) 注销所有 granted。
## 裁定：阵营含对手同阵营；toggle off 由 PILOT_AURA_ACTIVE_FOR_MECH 条件拦截（listener 保留但不触发）。
func _grant_pilot_005_to_empire_mechs(card, _source_mech_id: StringName) -> void:
	if context == null or context.timing_engine == null or context.game_state == null:
		return
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var granted_effect = all_effects.get(&"pilot_005_granted_suppression")
	if granted_effect == null:
		return
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null:
			continue
		var slot = m.slots.get(&"pilot") if "slots" in m else null
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		var faction: String = String(slot.equipped_card.def.faction) if "faction" in slot.equipped_card.def else ""
		if faction != "帝国":
			continue
		var granted_ctx: Dictionary = {
			"card_instance_id": card.instance_id,
			"mech_id": mid,
			"player_id": m.owner_player_id,
			"slot_id": &"pilot",
			"card_def_id": &"pilot_005_肯特",
		}
		context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_PRE, granted_effect, granted_ctx)


## pilot_002 effect_01 授予机制：向所有联邦阵营机甲注册 granted DIRECT 进攻 + AVAILABILITY 防御 listener。
## granted listener 的 binding_context.card_instance_id=pilot_002 实例（注销用），
## mech_id=被授予联邦机甲。unset_pilot 时 unregister_permanent_listeners_for_card(pilot_002_instance) 注销所有 granted。
## 裁定：阵营含敌方同阵营；toggle 只关闭对应莱比尔来源（由 is_aura_active_for_mech 判定）。
func _grant_pilot_002_to_federation_mechs(card, _source_mech_id: StringName) -> void:
	if context == null or context.timing_engine == null or context.game_state == null:
		return
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var granted_attack = all_effects.get(&"pilot_002_granted_transfer_attack")
	var granted_defense = all_effects.get(&"pilot_002_granted_transfer_defense")
	if granted_attack == null and granted_defense == null:
		return
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null:
			continue
		var slot = m.slots.get(&"pilot") if "slots" in m else null
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		var faction: String = String(slot.equipped_card.def.faction) if "faction" in slot.equipped_card.def else ""
		if faction != "联邦":
			continue
		var granted_ctx: Dictionary = {
			"card_instance_id": card.instance_id,
			"mech_id": mid,
			"player_id": m.owner_player_id,
			"slot_id": &"pilot",
			"card_def_id": &"pilot_002_莱比尔",
		}
		# DIRECT 进攻分支：注册到虚拟时点（skill_bar 按钮扫描）
		if granted_attack != null:
			context.timing_engine.register_permanent_listener(&"pilot_002_granted_transfer_attack", granted_attack, granted_ctx)
		# AVAILABILITY 防御分支：注册到 ATTACK_AT（response_window 扫描）
		if granted_defense != null:
			context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_AT, granted_defense, granted_ctx)


# ═══════════════════════════════════════════
# 地图特征配置（仅 PvP）
# ═══════════════════════════════════════════

## 配置地图特征：绿/红格子 + 金币/事件标记点 + 初始标记。
## 使用 context.rng（PvP 双端同种子）保证布局一致。
## 约束：
##   - 红格/绿格/标记点均避开双方起始格及其 6 邻居（避免开局阻挡或立即触发）。
##   - 标记点不放在红格上（标记不能在红格）。
##   - 金币/事件标记点优先放在绿格上（用户：很大一部分标记点在绿格）。
##   - 金币点与事件点一般不重叠（用户：一般不会同时在同一格）。
##   - 绿格倾向成簇（几个凑一起，也有零散）；红格相对零散（偶有成簇）。
func configure_map_features(gs: GameState) -> void:
	var map_state = gs.map_state
	var rng = context.rng if (context != null and context.rng != null) else RandomNumberGenerator.new()

	# ── 1. 禁区：双方机甲起始格 + 6 邻居 ──
	var forbidden: Dictionary = {}
	for pid: StringName in gs.players:
		var m = gs.get_mech_for_player(pid)
		if m != null and not m.position.is_empty():
			_add_forbidden(map_state, forbidden, int(m.position.get("q", 0)), int(m.position.get("r", 0)))

	# ── 2. 候选格（非禁区）引用 MapCellState 对象 ──
	var candidates: Array = []
	for key: String in map_state.cells:
		if not forbidden.has(key):
			candidates.append(map_state.cells[key])

	# ── 3. 放红格（零散，偶有成簇）──
	_place_red_tiles(map_state, candidates, rng, forbidden)
	# ── 4. 放绿格（成簇）──
	_place_green_clusters(map_state, candidates, rng, forbidden)

	# ── 5. 标记点候选（非红格、非禁区）+ 绿格子集 ──
	var point_pool: Array = []
	var green_pool: Array = []
	for c in candidates:
		if c.terrain == &"RED":
			continue
		point_pool.append(c)
		if c.terrain == &"GREEN":
			green_pool.append(c)
	_shuffle(point_pool, rng)
	_shuffle(green_pool, rng)

	# ── 6. 金币点（优先绿格）──
	var used: Dictionary = {}
	var gold_points: Array = _pick_points(gs, point_pool, green_pool, rng, _GameConfig.GOLD_MARKER_POINT_COUNT, used)
	# ── 7. 事件点（优先绿格，不与金币点重叠）──
	var event_points: Array = _pick_points(gs, point_pool, green_pool, rng, _GameConfig.EVENT_MARKER_POINT_COUNT, used)

	# ── 8. 添加标记点 + 初始标记（一对一）──
	for c in gold_points:
		var pid: StringName = gs.next_id(&"marker_point")
		map_state.add_marker_point(pid, c.q, c.r, &"GOLD")
		map_state.add_marker(gs.next_id(&"marker"), c.q, c.r, &"GOLD", pid)
	for c in event_points:
		var pid: StringName = gs.next_id(&"marker_point")
		map_state.add_marker_point(pid, c.q, c.r, &"EVENT")
		map_state.add_marker(gs.next_id(&"marker"), c.q, c.r, &"EVENT", pid)

	gs.write_log(&"map_features_configured", {
		"green_tiles": _GameConfig.GREEN_TILE_COUNT,
		"red_tiles": _GameConfig.RED_TILE_COUNT,
		"gold_points": gold_points.size(),
		"event_points": event_points.size(),
	})


## 标记禁区：自身格 + 6 邻居
func _add_forbidden(map_state, forbidden: Dictionary, q: int, r: int) -> void:
	var key := "%s,%s" % [q, r]
	forbidden[key] = true
	for n: Dictionary in _HexGrid.neighbors({"q": q, "r": r}):
		if map_state.has_cell(n):
			forbidden[_HexGrid.key(n)] = true


## Fisher-Yates 洗牌
func _shuffle(arr: Array, rng) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## 放红格：零散为主，约 35% 概率与一个邻居成簇。
func _place_red_tiles(map_state, candidates: Array, rng, forbidden: Dictionary) -> void:
	var placed: int = 0
	var pool: Array = candidates.duplicate()
	_shuffle(pool, rng)
	var i: int = 0
	while placed < _GameConfig.RED_TILE_COUNT and i < pool.size():
		var c = pool[i]
		i += 1
		if c.terrain != &"NORMAL":
			continue
		c.terrain = &"RED"
		placed += 1
		# 概率成簇：把一个 NORMAL 邻居也变红
		if placed < _GameConfig.RED_TILE_COUNT and rng.randf() < 0.35:
			var nbrs: Array = _cell_neighbors_in_state(map_state, c.q, c.r)
			_shuffle(nbrs, rng)
			for nb in nbrs:
				if nb.terrain == &"NORMAL" and not forbidden.has(nb.cell_id):
					nb.terrain = &"RED"
					placed += 1
					break


## 放绿格：以若干种子向邻居扩展成簇，凑满 GREEN_TILE_COUNT。
func _place_green_clusters(map_state, candidates: Array, rng, forbidden: Dictionary) -> void:
	var placed: int = 0
	var pool: Array = candidates.duplicate()
	_shuffle(pool, rng)
	var seed_idx: int = 0
	while placed < _GameConfig.GREEN_TILE_COUNT and seed_idx < pool.size():
		var seed_cell = pool[seed_idx]
		seed_idx += 1
		if seed_cell.terrain != &"NORMAL":
			continue
		# 种子变绿
		seed_cell.terrain = &"GREEN"
		placed += 1
		# 扩展 1-3 个邻居（成簇）
		var want: int = rng.randi_range(1, 3)
		var nbrs: Array = _cell_neighbors_in_state(map_state, seed_cell.q, seed_cell.r)
		_shuffle(nbrs, rng)
		for nb in nbrs:
			if placed >= _GameConfig.GREEN_TILE_COUNT:
				break
			if nb.terrain == &"NORMAL" and not forbidden.has(nb.cell_id):
				nb.terrain = &"GREEN"
				placed += 1
	# 若成簇未凑满（边界/禁区挤压），从剩余 NORMAL 候选零散补足
	if placed < _GameConfig.GREEN_TILE_COUNT:
		for c in pool:
			if placed >= _GameConfig.GREEN_TILE_COUNT:
				break
			if c.terrain == &"NORMAL" and not forbidden.has(c.cell_id):
				c.terrain = &"GREEN"
				placed += 1


## 从候选池选 N 个标记点：优先绿格，排除 used。
func _pick_points(gs, point_pool: Array, green_pool: Array, rng, count: int, used: Dictionary) -> Array:
	var result: Array = []
	# 优先绿格（约 60% 从绿格取，无绿格则回退普通格）
	var gi: int = 0
	var pi: int = 0
	while result.size() < count:
		var picked = null
		# 60% 尝试绿格
		if rng.randf() < 0.6:
			while gi < green_pool.size():
				var c = green_pool[gi]
				gi += 1
				if not used.has(c.cell_id):
					picked = c
					break
		# 回退普通池
		if picked == null:
			while pi < point_pool.size():
				var c = point_pool[pi]
				pi += 1
				if used.has(c.cell_id):
					continue
				if result.has(c):
					continue
				picked = c
				break
		if picked == null:
			break
		used[picked.cell_id] = true
		result.append(picked)
	return result


## 返回该格在 map_state 中存在的邻居 MapCellState 列表
func _cell_neighbors_in_state(map_state, q: int, r: int) -> Array:
	var result: Array = []
	for n: Dictionary in _HexGrid.neighbors({"q": q, "r": r}):
		var c = map_state.get_cell_state(n)
		if c != null:
			result.append(c)
	return result

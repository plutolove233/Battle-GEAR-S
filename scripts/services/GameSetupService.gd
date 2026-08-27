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
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
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


## 初始化 3人 PvP 战斗（PVP3 模式）
## 仿 setup_tutorial_battle，创建 3 玩家（player/enemy/third 全 is_human=true）+ 3 机甲。
## 第3玩家 third 复用 player 的 frame_001_基础框架（仅 2 个框架定义）。
## 建机甲顺序固定 player_mech->enemy_mech->third_mech，保证双端 instance_id 同步（next_id 纯计数）。
## 起始位置：player(2,2) / enemy(20,-6) / third(2,-6)。
## 地图/牌堆/装备效果注册复用现有；configure_map_features 遍历 gs.players 自动含3方起始格禁区。
func setup_pvp3_battle(data_registry: DataRegistry, pvp_map_features: bool = true) -> Dictionary:
	var gs: GameState = context.game_state
	gs.reset_all()

	# 清空 TimingEngine 监听器：开新局时确保无上一局残留
	if context.timing_engine != null:
		context.timing_engine.temporary_listeners.clear()
		context.timing_engine.suppressed_effects.clear()
		context.timing_engine.permanent_listeners.clear()

	# ── 1. 读取教学战役配置（复用 frame 定义 + 地图尺寸 + 回合上限）──
	var battle_config: Dictionary = data_registry.get_tutorial_battle()
	if battle_config.is_empty():
		return {"ok": false, "message": "未找到教学战役配置"}

	# ── 2. 创建 3 玩家（全人类，PvP 各窗口独立控制）──
	var player: PlayerState = _create_player(&"player", 15, true)
	var enemy: PlayerState = _create_player(&"enemy", 15, true)
	var third: PlayerState = _create_player(&"third", 15, true)
	gs.players[player.player_id] = player
	gs.players[enemy.player_id] = enemy
	gs.players[third.player_id] = third

	# ── 3. 创建 3 机甲（固定顺序保证 instance_id 同步）──
	var player_frame_id: String = battle_config.get("player_frame_id", "frame_001_基础框架")
	var enemy_frame_id: String = battle_config.get("enemy_frame_id", "frame_002_原始框架")
	var player_mech: MechState = _create_mech_from_frame(&"player_mech", &"player", player_frame_id, data_registry)
	var enemy_mech: MechState = _create_mech_from_frame(&"enemy_mech", &"enemy", enemy_frame_id, data_registry)
	var third_mech: MechState = _create_mech_from_frame(&"third_mech", &"third", player_frame_id, data_registry)
	gs.mechs[player_mech.mech_id] = player_mech
	gs.mechs[enemy_mech.mech_id] = enemy_mech
	gs.mechs[third_mech.mech_id] = third_mech

	# ── 4. 设置初始位置（player/enemy 复用教学配置，third 固定 (11,-3)）──
	# third 不能用 (2,-6)：odd-q 地图 q=2 的 r 范围仅 -1..6，r=-6 超出该列范围不在地图格内。
	# (11,-3) 在 q=11 的 r 范围(-6..1)内，3方分散(player左上/enemy右下/third中部)。
	player_mech.position = {
		"q": int(battle_config.get("player_start", {}).get("q", 2)),
		"r": int(battle_config.get("player_start", {}).get("r", 2)),
	}
	enemy_mech.position = {
		"q": int(battle_config.get("enemy_start", {}).get("q", 20)),
		"r": int(battle_config.get("enemy_start", {}).get("r", -6)),
	}
	third_mech.position = {"q": 11, "r": -3}

	# ── 5. 生成地图 ──
	var map_cols: int = int(battle_config.get("map", {}).get("cols", 24))
	var map_rows: int = int(battle_config.get("map", {}).get("rows", 8))
	var map_blocked: Array = battle_config.get("map", {}).get("blocked", [])
	var cells: Array[Dictionary] = _HexGrid.generate_rectangle(map_cols, map_rows, map_blocked)
	for cell: Dictionary in cells:
		gs.map_state.add_cell(int(cell.q), int(cell.r), &"NORMAL")

	# ── 5b. PvP 地图特征（绿/红格 + 标记点，遍历 gs.players 含3方起始格禁区）──
	if pvp_map_features:
		configure_map_features(gs)

	# ── 6. 构建牌堆 ──
	context.deck_build_service.build_all_decks_from_card_database()

	# ── 7. 注册所有已装备卡牌效果（开局无装备，遍历无害）──
	_register_equipped_effects(player_mech)
	_register_equipped_effects(enemy_mech)
	_register_equipped_effects(third_mech)

	# ── 8. 记录回合上限 ──
	gs.temp_values["turn_limit"] = int(battle_config.get("turn_limit", 12))

	gs.write_log(&"game_setup", {"battle_id": "pvp3"})
	return {"ok": true, "message": "pvp3_initialized"}


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
	# pilot_005 肯特动力+4 给的是「帝国框架机甲」（按框架阵营，非被设机甲），须遍历全场重算
	_recalc_power_for_faction_frames(&"帝国")
	# 刷新该机甲的 pilot_002 granted 加成（换人/新机甲框架：清旧+若联邦且场上有莱比尔则授予 EX）
	# 莱比尔自身 set_pilot 时 _grant 全量已注册，此处 ungrant+授予幂等；其他联邦机师换人由此获 EX。
	_refresh_pilot_002_grant_for_mech(mech_id)
	# 刷新该机甲的 pilot_005 肯特 granted 加成（换人/新机甲：清旧+若帝国且场上有肯特则授予 EX）
	_refresh_pilot_005_grant_for_mech(mech_id)
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
	# pilot_014 亚伦 +2 离场清理：任意机师牌换下，清理以其为目标(target)或来源(source)的 +2。
	# 目标机师牌换下 -> 其 +2 扣回；亚伦(来源)换下 -> 其施加的全部 +2 扣回。
	if context.game_actions != null:
		context.game_actions.remove_pilot_014_bonus_for_pilot_instance(old_card.instance_id)
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
	# pilot_035 库马斯离场：清除本轮标记机甲（持续效果随离场终止）
	if old_card.def != null and String(old_card.def.card_id) == "pilot_035_库马斯":
		_ActionPilotEffects.clear_pilot_035_mark(old_card.instance_id)
	# pilot_021 塔莉娅离场：清除其玩家手牌的"禁"标签（剩余赐予牌恢复可用）
	# + 清其名下"策"标签（他人持有的赐予牌不再触发其抽2）
	if old_card.def != null and String(old_card.def.card_id) == "pilot_021_塔莉娅":
		_ActionPilotEffects.pilot_021_clear_all_jin_for_player(context.game_state, old_card.owner_player_id)
		_ActionPilotEffects.pilot_021_clear_all_ce_for_player(context.game_state, old_card.owner_player_id)
	# pilot_082 温斯顿离场：清除其名下全部"联"标签（他人持有的联牌不再触发对其施加联合）。
	if old_card.def != null and String(old_card.def.card_id) == "pilot_082_温斯顿":
		_ActionPilotEffects.pilot_082_clear_all_lian_for_player(context.game_state, old_card.owner_player_id)
	# pilot_087 塔妮拉离场：清除其名下全部"交"标签（他人持有的交牌不再触发其抽1）。
	if old_card.def != null and String(old_card.def.card_id) == "pilot_087_塔妮拉":
		_ActionPilotEffects.pilot_087_clear_all_jiao_for_player(context.game_state, old_card.owner_player_id)
	# pilot_074 泰特离场：清除近战弃牌威力状态（待发 buff + 授予登记）。
	# unregister_permanent_listeners_for_card 已注销全部绑定该实例的监听器（含他机授予），
	# 静态 registry 须手动清，避免残留（换回泰特时旧 buff/授予不复活）。
	if old_card.def != null and String(old_card.def.card_id) == "pilot_074_泰特":
		_ActionPilotEffects.clear_melee_might_for_source(old_card.instance_id)
	slot.equipped_card = null
	old_card.zone = &""
	old_card.slot_id = &""
	# pilot_005 肯特离场：帝国框架动力+4 失效；pilot_002 莱比尔离场：联邦框架护甲+4 失效。
	# 派生光环 unregister 后须遍历全场对应阵营框架机甲重算上限（max_power 是存储字段）。
	if old_card.def != null:
		if String(old_card.def.card_id) == "pilot_005_肯特":
			_recalc_power_for_faction_frames(&"帝国")
		elif String(old_card.def.card_id) == "pilot_002_莱比尔":
			# 莱比尔离场仅联邦护甲派生失效（护甲非动力上限，recalc 仍幂等无害）
			_recalc_power_for_faction_frames(&"联邦")
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
		# 通用 init_counters：效果注册即初始化计数器（仅当键不存在，不覆盖运行中已消耗值）。
		# 解决"中途换上机师牌要等下回合才生效"（如莉诺原价购买次数初始为0直到首个回合开始）。
		# 与机师ID无关：任何效果声明 init_counters 即生效。
		if not effect.init_counters.is_empty() and card != null and "counters" in card:
			for ck in effect.init_counters:
				if not card.counters.has(ck):
					card.counters[ck] = effect.init_counters[ck]
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
	# 琳 pilot_024 RE 请求（DIRECT 无 listen_timing）：不在卡牌 effect_ids 里（不渲染第4按钮），
	# 单独注册到虚拟时点 pilot_024_re_request，供请求方 equipment_panel RE 按钮 granted_effect_clicked
	# -> effect_fire 直发时 _execute_effect_by_id 能查找到。binding mech_id/player_id 留空：
	# RE 来源是"请求方"而非琳，_make_binding 回退 action.source 取请求方机甲/玩家；
	# 空 mech 也不被 _execute_effect_by_id 的 want_mech_id 过滤跳过（任意请求方都能命中）；
	# 且装备面板 _active_by_card 的 mech 过滤（mech==本机甲）会跳过空 mech，不会多渲染按钮。
	if card.def.card_id == &"pilot_024_琳":
		var re_eff = all_effects.get(&"pilot_024_re_request")
		if re_eff != null:
			# 注意：不能带 mech_id/player_id 键（即使置空）。带空键会导致下游 .get("mech_id",
			# payload.get("mech_id")) 命中空键返回空串而非回退 payload——RE 请求方标记/确认
			# 会取空机甲而失效。省略键 → .get 走默认回退 action.source 取请求方机甲/玩家。
			context.timing_engine.register_permanent_listener(&"pilot_024_re_request", re_eff, {
				"card_instance_id": card.instance_id,
				"card_def_id": card.def.card_id,
				"slot_id": &"pilot",
			})
	# 汀兰 pilot_081 RE 请求回复（DIRECT 无 listen_timing）：不在卡牌 effect_ids 里（不渲染额外按钮），
	# 单独注册到虚拟时点 pilot_081_re_request，供光环格上机甲 equipment_panel RE 按钮
	# granted_effect_clicked -> effect_fire 直发时 _execute_effect_by_id 查找。
	# binding 不带 mech_id/player_id（同琳）：RE 来源是"请求方"而非持有者，回退 action.source 取请求方；
	# card_instance_id = 持有者 pilot 牌实例，多汀兰场景据此精确定位弹窗给哪个持有者。
	if card.def.card_id == &"pilot_081_汀兰":
		var p081_re_eff = all_effects.get(&"pilot_081_re_request")
		if p081_re_eff != null:
			context.timing_engine.register_permanent_listener(&"pilot_081_re_request", p081_re_eff, {
				"card_instance_id": card.instance_id,
				"card_def_id": card.def.card_id,
				"slot_id": &"pilot",
			})
	# 瓦恩 pilot_083 RE 请求武器修改（DIRECT 无 listen_timing）：不在卡牌 effect_ids 里渲染按钮
	# （re_request hide_button=true），单独注册到虚拟时点 pilot_083_re_request，供3格内机甲
	# equipment_panel RE 按钮 granted_effect_clicked -> effect_fire 直发时 _execute_effect_by_id 查找。
	# binding 不带 mech_id/player_id（同琳/汀兰）：RE 来源是"请求方"而非持有者，回退 action.source
	# 取请求方；card_instance_id = 持有者瓦恩 pilot 牌实例，多瓦恩场景据此精确定位弹窗给哪个持有者。
	if card.def.card_id == &"pilot_083_瓦恩":
		var p083_re_eff = all_effects.get(&"pilot_083_re_request")
		if p083_re_eff != null:
			context.timing_engine.register_permanent_listener(&"pilot_083_re_request", p083_re_eff, {
				"card_instance_id": card.instance_id,
				"card_def_id": card.def.card_id,
				"slot_id": &"pilot",
			})
	# 克劳德 pilot_029 当作聚能：完全复用标准聚能（energy_direct，来自 GeneratedActionEffects），
	# 不在克劳德 effect_ids 里（不渲染第3按钮），单独注册到虚拟时点 &"energy_direct"，
	# 供 effect_02 的 EXECUTE_EFFECT_FIRE 直发时 _execute_effect_by_id 查找。
	# 真实聚能牌走 use_action_card → _execute_effect（非 _execute_effect_by_id），两条路径独立，
	# 注册不干扰聚能牌本身。binding 须带 mech_id/player_id（非空真实值）：CHOOSE_OWN_WEAPON 的
	# 武器选择窗按 binding_context.mech_id 取本机甲武器，APPLY_ENERGY_TO_WEAPON 按 source_mech_id
	# 施加聚能；多克劳德场景 _execute_effect_by_id 按 want_mech_id 各自命中对应 listener。
	if card.def.card_id == &"pilot_029_克劳德":
		var p029_energy_eff = _GeneratedActionEffects.build_all_effects().get(&"energy_direct")
		if p029_energy_eff != null:
			context.timing_engine.register_permanent_listener(&"energy_direct", p029_energy_eff, {
				"card_instance_id": card.instance_id,
				"mech_id": mech_id,
				"player_id": player_id,
				"card_def_id": card.def.card_id,
				"slot_id": &"pilot",
			})


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
		_grant_pilot_005_to_one_mech(card, mid, m, granted_effect)


## 向单个机甲注册 pilot_005 granted 帝国压制 listener（_grant 全量与 _refresh 换人共用）。
## binding_context.card_instance_id=pilot_005 实例（注销用），mech_id=被授予帝国机甲。
func _grant_pilot_005_to_one_mech(card, mid: StringName, m, granted_effect) -> void:
	if context == null or context.timing_engine == null:
		return
	var granted_ctx: Dictionary = {
		"card_instance_id": card.instance_id,
		"mech_id": mid,
		"player_id": m.owner_player_id,
		"slot_id": &"pilot",
		"card_def_id": &"pilot_005_肯特",
	}
	context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_PRE, granted_effect, granted_ctx)


## 刷新某机甲的 pilot_005 肯特 granted 加成（换机师/新机甲框架时调用）：
## 先注销该机甲旧 granted listener（清非帝国残留），再若新机师帝国阵营且场上有肯特 aura 则授予。
## 解决"后续换帝国机师/新机甲无法享受肯特加成"（set_pilot 时调用，镜像 pilot_002 莱比尔）。
func _refresh_pilot_005_grant_for_mech(target_mid: StringName) -> void:
	if context == null or context.timing_engine == null or context.game_state == null:
		return
	# 1. 清旧 granted（换非帝国机师时移除残留 EX）
	context.timing_engine.ungrant_pilot_005_for_mech(target_mid)
	# 2. 查目标机甲机师阵营，非帝国不授予
	var target_mech = context.game_state.mechs.get(target_mid)
	if target_mech == null:
		return
	var t_slot = target_mech.slots.get(&"pilot") if "slots" in target_mech else null
	if t_slot == null or t_slot.equipped_card == null or t_slot.equipped_card.def == null:
		return
	var t_faction: String = String(t_slot.equipped_card.def.faction) if "faction" in t_slot.equipped_card.def else ""
	if t_faction != "帝国":
		return
	# 3. 查场上是否已有肯特 aura（pilot_005 帝国来源）
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var granted_effect = all_effects.get(&"pilot_005_granted_suppression")
	for src_instance: StringName in _ActionPilotEffects._pilot_aura:
		var aura: Dictionary = _ActionPilotEffects._pilot_aura[src_instance]
		if String(aura.get("pilot_def_id", "")) == "pilot_005_肯特" and String(aura.get("faction", "")) == "帝国":
			var card = context.game_state.get_card(src_instance)
			if card != null:
				_grant_pilot_005_to_one_mech(card, target_mid, target_mech, granted_effect)
			return


## 遍历全场所有指定阵营框架机甲，重算动力上限。
## pilot_005 肯特动力+4 按「机甲框架阵营」判定（frame_def.faction），非被设机甲。
## set_pilot/unset_pilot/toggle 后派生光环变化，max_power 是存储字段须 recalc 才同步。
func _recalc_power_for_faction_frames(faction: StringName) -> void:
	if context == null or context.game_state == null:
		return
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null or m.get("frame_def") == null:
			continue
		var ff: String = String(m.frame_def.faction) if "faction" in m.frame_def else ""
		if ff != String(faction):
			continue
		m.recalc_power_limits()


## pilot_002 effect_01 授予机制：向所有联邦阵营机甲注册 granted DIRECT 进攻 + AVAILABILITY 防御 listener。
## granted listener 的 binding_context.card_instance_id=pilot_002 实例（注销用），
## mech_id=被授予联邦机甲。unset_pilot 时 unregister_permanent_listeners_for_card(pilot_002_instance) 注销所有 granted。
## 裁定：阵营含敌方同阵营；toggle 只关闭对应莱比尔来源（由 is_aura_active_for_mech 判定）。
func _grant_pilot_002_to_federation_mechs(card, source_mech_id: StringName) -> void:
	if context == null or context.timing_engine == null or context.game_state == null:
		return
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var granted_attack = all_effects.get(&"pilot_002_granted_transfer_attack")
	var granted_defense = all_effects.get(&"pilot_002_granted_transfer_defense")
	if granted_attack == null and granted_defense == null:
		return
	for mid: StringName in context.game_state.mechs:
		# 莱比尔自身也获 EX（裁定修订：莱比尔自己也能发动交牌转化）
		var m = context.game_state.mechs[mid]
		if m == null:
			continue
		var slot = m.slots.get(&"pilot") if "slots" in m else null
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		var faction: String = String(slot.equipped_card.def.faction) if "faction" in slot.equipped_card.def else ""
		if faction != "联邦":
			continue
		_grant_pilot_002_to_one_mech(card, mid, m, granted_attack, granted_defense)


## 向单个机甲注册 pilot_002 granted 进攻+防御 listener（_grant 全量与 _refresh 换人共用）。
func _grant_pilot_002_to_one_mech(card, mid: StringName, m, granted_attack, granted_defense) -> void:
	if context == null or context.timing_engine == null:
		return
	var granted_ctx: Dictionary = {
		"card_instance_id": card.instance_id,
		"mech_id": mid,
		"player_id": m.owner_player_id,
		"slot_id": &"pilot",
		"card_def_id": &"pilot_002_莱比尔",
	}
	# DIRECT 进攻分支：注册到虚拟时点（EX 按钮扫描）
	if granted_attack != null:
		context.timing_engine.register_permanent_listener(&"pilot_002_granted_transfer_attack", granted_attack, granted_ctx)
	# AVAILABILITY 防御分支：注册到 ATTACK_AT（response_window 扫描）
	if granted_defense != null:
		context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_AT, granted_defense, granted_ctx)


## 刷新某机甲的 pilot_002 granted 加成（换机师/新机甲框架时调用）：
## 先注销该机甲旧 granted listener（清非联邦残留），再若新机师联邦阵营且场上有莱比尔 aura 则授予。
## 解决"后续换联邦机师/新机甲无法享受莱比尔加成"（set_pilot 时调用）。
func _refresh_pilot_002_grant_for_mech(target_mid: StringName) -> void:
	if context == null or context.timing_engine == null or context.game_state == null:
		return
	# 1. 清旧 granted（换非联邦机师时移除残留 EX）
	context.timing_engine.ungrant_pilot_002_for_mech(target_mid)
	# 2. 查目标机甲机师阵营，非联邦不授予
	var target_mech = context.game_state.mechs.get(target_mid)
	if target_mech == null:
		return
	var t_slot = target_mech.slots.get(&"pilot") if "slots" in target_mech else null
	if t_slot == null or t_slot.equipped_card == null or t_slot.equipped_card.def == null:
		return
	var t_faction: String = String(t_slot.equipped_card.def.faction) if "faction" in t_slot.equipped_card.def else ""
	if t_faction != "联邦":
		return
	# 3. 查场上是否已有莱比尔 aura（pilot_002 联邦来源）
	var all_effects: Dictionary = _ActionPilotEffects.build_pilot_effects()
	var granted_attack = all_effects.get(&"pilot_002_granted_transfer_attack")
	var granted_defense = all_effects.get(&"pilot_002_granted_transfer_defense")
	for src_instance: StringName in _ActionPilotEffects._pilot_aura:
		var aura: Dictionary = _ActionPilotEffects._pilot_aura[src_instance]
		if String(aura.get("pilot_def_id", "")) == "pilot_002_莱比尔" and String(aura.get("faction", "")) == "联邦":
			var card = context.game_state.get_card(src_instance)
			if card != null:
				_grant_pilot_002_to_one_mech(card, target_mid, target_mech, granted_attack, granted_defense)
			return


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

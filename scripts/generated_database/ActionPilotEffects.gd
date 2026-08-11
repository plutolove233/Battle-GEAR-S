## ActionPilotEffects.gd - 机师牌效果定义（新 ActionEffect 体系）
##
## SSR 批次（pilot_001-010）机师牌效果，走新 Action + Timing 体系（非旧 CardEffect）。
## 与 GeneratedEquipmentEffects 一样：
##   - DIRECT 模式：机师主动效果（skill_bar 按钮触发，如 pilot_009 美杜莎支配）
##   - LISTEN 模式：监听指定动作的指定时点（pilot_004 玛沙回合开始护甲转动力等）
##   - AVAILABILITY 模式：响应窗口可选（pilot_002 莱比尔防御分支等）
##
## 注册方式：机师牌由 GameSetupService.set_pilot 设置到 pilot 槽后，_register_pilot_effects
## 查本表 get_effects_for_pilot 并 register_permanent_listener（binding_context.slot_id=&"pilot"）。
## 换机师时先 unregister_permanent_listeners_for_card 注销旧实例。
##
## 派生值型效果（pilot_002 effect_02 联邦护甲+4、pilot_005 effect_02 帝国动力+4）不注册监听器，
## 由 MechState.get_armor/get_total_power 实时重算（调用本文件 compute_* helper）。
##
## effect_ids 沿用 data/cards/pilot_cards.json 的命名（pilot_XXX_effect_YY）。
## 权威拆解：new_logic/机师牌效果逻辑拆解_SSR_001-010.txt + 下一session提示词第1节裁定 delta。
class_name ActionPilotEffects
extends RefCounted

const _TC = preload("res://scripts/action_core/TimingConst.gd")
const _ActionEffect = preload("res://scripts/action_core/ActionEffect.gd")

## card_def_id -> [effect_id, ...] 映射（由 CardDatabaseLoader._effect_ids_map 提供）
## set_pilot 注册时调用 get_effects_for_pilot 查询
static var _card_effect_map: Dictionary = {}

## 是否已初始化
static var _initialized: bool = false

## 全场光环查询所需的 game_state（建局时注入；pilot_002/005 全场阵营光环用）
static var _aura_game_state = null


## 注入 game_state 供全场光环 helper 查询所有机甲（建局时调用）
static func set_aura_game_state(gs) -> void:
	_aura_game_state = gs


## 初始化 card_def_id -> effect_id 列表 映射
## 由 set_pilot 首次调用时注入 effect_ids_map（来自 CardDatabaseLoader）
static func _init_map(effect_ids_map: Dictionary = {}) -> void:
	if effect_ids_map.size() > 0:
		_card_effect_map = effect_ids_map.duplicate(true)
	_initialized = true


## 获取机师牌的效果ID列表（用于注册）
## 若 _card_effect_map 为空，尝试从 context.card_database.loader.get_effect_ids_map() 取
static func get_effects_for_pilot(card_def_id: StringName, context = null) -> Array:
	if not _initialized and context != null:
		_try_load_map_from_context(context)
	return _card_effect_map.get(card_def_id, [])


## 从 context 尝试加载 effect_ids_map（懒加载）
static func _try_load_map_from_context(context) -> void:
	if context == null:
		return
	var cdb = context.get("card_database") if context is Dictionary else context.card_database
	if cdb == null:
		return
	if cdb.get("loader") != null:
		_init_map(cdb.loader.get_effect_ids_map())
	elif cdb.has_method("get_effect_ids_map"):
		_init_map(cdb.get_effect_ids_map())


## 派生值型效果集合（不注册监听器，由 MechState 实时重算）
static func is_pilot_derived_effect(effect_id: StringName) -> bool:
	return effect_id in [
		&"pilot_002_effect_02",  # 莱比尔·联邦机甲护甲+4（实时重算）
		&"pilot_005_effect_02",  # 肯特·帝国机甲动力+4（实时重算）
	]


# ════════════════════════════════════════════════════════════
# 阵营光环状态（pilot_002 莱比尔 联邦护甲+4 / pilot_005 肯特 帝国动力+4 共用）
# ════════════════════════════════════════════════════════════
## source pilot 设置后向同阵营机师授予光环（派生值 effect_02 + 授予能力 effect_01）。
## toggle off 按 source×mech 存储；换机师 unregister 清除。
## 裁定：阵营含对手同阵营；多来源叠加；toggle 只影响本来源。
static var _pilot_aura: Dictionary = {}  # { source_pilot_instance: {pilot_def_id, faction, toggled_off: {mech_id: true}} }


static func register_faction_aura(source_pilot_instance: StringName, pilot_def_id: StringName, faction: String) -> void:
	_pilot_aura[source_pilot_instance] = {"pilot_def_id": pilot_def_id, "faction": faction, "toggled_off": {}}


static func unregister_faction_aura(source_pilot_instance: StringName) -> void:
	_pilot_aura.erase(source_pilot_instance)


## 切换某机甲是否获得该来源光环（effect_03 toggle）
static func toggle_aura_target(source_pilot_instance: StringName, mech_id: StringName) -> void:
	if not _pilot_aura.has(source_pilot_instance):
		return
	var entry: Dictionary = _pilot_aura[source_pilot_instance]
	var toggled_off: Dictionary = entry.get("toggled_off", {})
	if toggled_off.has(mech_id):
		toggled_off.erase(mech_id)
	else:
		toggled_off[mech_id] = true
	entry["toggled_off"] = toggled_off


## 显式取消某机甲的光环（effect_03「取消」分支：排除 1 效果 EX 按钮 + 2 效果护甲+4）
static func set_aura_off(source_pilot_instance: StringName, mech_id: StringName) -> void:
	if not _pilot_aura.has(source_pilot_instance):
		return
	var entry: Dictionary = _pilot_aura[source_pilot_instance]
	var toggled_off: Dictionary = entry.get("toggled_off", {})
	toggled_off[mech_id] = true
	entry["toggled_off"] = toggled_off


## 显式恢复某机甲的光环（effect_03「恢复」分支：重新囊括 1+2 效果；未排除则无事发生）
static func set_aura_on(source_pilot_instance: StringName, mech_id: StringName) -> void:
	if not _pilot_aura.has(source_pilot_instance):
		return
	var entry: Dictionary = _pilot_aura[source_pilot_instance]
	var toggled_off: Dictionary = entry.get("toggled_off", {})
	toggled_off.erase(mech_id)
	entry["toggled_off"] = toggled_off


## 派生值：机甲获得的阵营光环加成。
## 每个有效 source（pilot_def_id 匹配 + mech pilot faction 匹配 + 未 toggle off）+ per_source_bonus。
## 裁定：同阵营含对手；多来源叠加。
static func get_faction_pilot_aura_bonus(mech, faction: String, source_pilot_def_id: StringName, per_source_bonus: int) -> int:
	if mech == null or not "slots" in mech:
		return 0
	var slot = mech.slots.get(&"pilot")
	if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
		return 0
	var mech_faction: String = String(slot.equipped_card.def.faction) if "faction" in slot.equipped_card.def else ""
	if mech_faction != faction:
		return 0
	var total := 0
	for src_instance: StringName in _pilot_aura:
		var entry: Dictionary = _pilot_aura[src_instance]
		if String(entry.get("pilot_def_id", &"")) != String(source_pilot_def_id):
			continue
		if String(entry.get("faction", "")) != faction:
			continue
		var toggled_off: Dictionary = entry.get("toggled_off", {})
		var mid: StringName = mech.mech_id if "mech_id" in mech else &""
		if toggled_off.has(mid):
			continue
		total += per_source_bonus
	return total


## pilot_005 肯特：帝国机甲框架动力+4（实时重算，MechState.get_total_power 调用）
## 裁定：按机甲框架阵营判断（基础框架=联邦/原始框架=帝国），与 effect_01 EX 按钮（按机师牌阵营）分开。
## effect_03 取消针对机甲整体（toggled_off[mech_id] 同时让 EX 失效与本 +4 失效）。
## 镜像 pilot_002 莱比尔 get_pilot_002_federation_armor_bonus。
static func get_pilot_005_empire_power_bonus(mech) -> int:
	if mech == null or mech.get("frame_def") == null:
		return 0
	var frame_faction: String = String(mech.frame_def.faction) if "faction" in mech.frame_def else ""
	if frame_faction != "帝国":
		return 0
	var mid: StringName = mech.mech_id if "mech_id" in mech else &""
	var total := 0
	for src_instance: StringName in _pilot_aura:
		var entry: Dictionary = _pilot_aura[src_instance]
		if String(entry.get("pilot_def_id", &"")) != "pilot_005_肯特":
			continue
		var toggled_off: Dictionary = entry.get("toggled_off", {})
		if toggled_off.has(mid):
			continue
		total += 4
	return total


## pilot_002 莱比尔：联邦机甲框架护甲+4（实时重算，MechState.get_armor 调用）
## 裁定：按机甲框架阵营判断（基础框架=联邦/原版=帝国），与 effect_01 EX 按钮（按机师牌阵营）分开。
## effect_03 取消针对机甲整体（toggled_off[mech_id] 同时让 EX 失效与本 +4 失效）。
static func get_pilot_002_federation_armor_bonus(mech) -> int:
	if mech == null or mech.get("frame_def") == null:
		return 0
	var frame_faction: String = String(mech.frame_def.faction) if "faction" in mech.frame_def else ""
	if frame_faction != "联邦":
		return 0
	var mid: StringName = mech.mech_id if "mech_id" in mech else &""
	var total := 0
	for src_instance: StringName in _pilot_aura:
		var entry: Dictionary = _pilot_aura[src_instance]
		if String(entry.get("pilot_def_id", &"")) != "pilot_002_莱比尔":
			continue
		var toggled_off: Dictionary = entry.get("toggled_off", {})
		if toggled_off.has(mid):
			continue
		total += 4
	return total


## 本机甲是否有任意 pilot 光环 active（未被 toggle off + 阵营匹配）。
## granted effect（pilot_005_effect_01 授予能力）的 conditions 用：toggle off 时不触发。
static func is_aura_active_for_mech(gs, mech_id: StringName) -> bool:
	if gs == null:
		return false
	var mech = gs.mechs.get(mech_id)
	if mech == null or not "slots" in mech:
		return false
	var slot = mech.slots.get(&"pilot")
	if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
		return false
	var mech_faction: String = String(slot.equipped_card.def.faction) if "faction" in slot.equipped_card.def else ""
	if mech_faction == "":
		return false
	for src_instance: StringName in _pilot_aura:
		var entry: Dictionary = _pilot_aura[src_instance]
		if String(entry.get("faction", "")) != mech_faction:
			continue
		var toggled_off: Dictionary = entry.get("toggled_off", {})
		if not toggled_off.has(mech_id):
			return true
	return false


## pilot_008 安德洛美达 X 变量（绑 card_instance_id，初始0 max5，回收维修+1）。
## 存 card.counters["var_X"]，换机师不转移（旧实例 listener 注销，新实例从0开始）。
static func get_pilot_008_x(pilot_card) -> int:
	if pilot_card == null or not "counters" in pilot_card:
		return 0
	return int(pilot_card.counters.get("var_X", 0))


## pilot_008 effect_01b 本回合已回收的维修 card_id 集合。
## 用途：TurnService.end_turn 第5步弃超限牌时跳过本回合刚回收的维修，避免安德洛美达自己回合末
## while pop_back 重取 append 到末尾的回收维修再弃（once_per_turn 已用 -> 维修进弃牌堆）。
## start_turn 清空（与 once_per_turn_used 一起，下回合失效）。
static var _pilot_008_recovered_this_turn: Dictionary = {}

static func mark_pilot_008_recovered(card_id: StringName) -> void:
	_pilot_008_recovered_this_turn[card_id] = true

static func is_pilot_008_recovered(card_id) -> bool:
	return _pilot_008_recovered_this_turn.has(card_id)

static func clear_pilot_008_recovered() -> void:
	_pilot_008_recovered_this_turn.clear()


# ════════════════════════════════════════════════════════════
# pilot_006 里昂 狩猎标记（effect_01 轮次选目标 + effect_02 抽牌打标签 共享）
# ════════════════════════════════════════════════════════════
## source pilot 设置后每轮 ROUND_START 选1台其他机甲为本轮狩猎目标。
## 存 {source_pilot_instance: {target, prev_target}}：
##   target = 本轮标记机甲；prev_target = 上一轮标记机甲（用于"还是这台则不改变"判定）。
## 换机师清除全部标记。
static var _pilot_006_marks: Dictionary = {}

## tag 名：pilot_006_hunting_bonus。一张牌可被多个里昂各打各的（owner_pid 去歧义）。
const PILOT_006_HUNTING_TAG := &"pilot_006_hunting_bonus"



## 设置本轮狩猎目标。若新目标 != 上轮目标，则上轮目标上所有未失效的 hunting 标签永久失效。
## 若新目标 == 上轮目标（还是这台），不改变、不失效任何标签。
## 首轮/无上轮目标：直接设置，无需失效。
static func set_pilot_006_mark(source_pilot_instance: StringName, target_mech_id: StringName, game_state) -> void:
	var prev_entry: Dictionary = _pilot_006_marks.get(source_pilot_instance, {})
	var prev_target: StringName = prev_entry.get("target", &"")
	var prev_prev: StringName = prev_entry.get("prev_target", &"")
	# 判定"还是这台"：新目标 == 上轮 target 且上轮 target == 上轮 prev（连续两轮同机甲）。
	# 实际语义：若新目标与上一轮选择的标记机甲相同，则不改变。
	# 首轮（无上轮 target）直接设置。
	if prev_target != &"" and prev_target == target_mech_id:
		# 还是这台，不改变、不失效
		return
	# 目标更换：将所有未失效的 hunting 标签失效（永久，不恢复）
	if prev_target != &"" and game_state != null:
		_invalidate_all_hunting_tags(game_state, source_pilot_instance)
	_pilot_006_marks[source_pilot_instance] = {
		"target": target_mech_id,
		"prev_target": prev_target,
	}


## 取本轮标记机甲。
static func get_pilot_006_mark(source_pilot_instance: StringName) -> StringName:
	var entry: Dictionary = _pilot_006_marks.get(source_pilot_instance, {})
	return entry.get("target", &"")


static func clear_pilot_006_mark(source_pilot_instance: StringName) -> void:
	_pilot_006_marks.erase(source_pilot_instance)


## pilot_006 effect_02：抽到攻击牌时打 hunting 标签（不计回合攻击数，绑定本轮标记机甲）。
## 用 CardInstance tag 系统（同瑟尔基尔，一张牌可多标签）。owner_pid = 里昂拥有者。
## tag data 存 marked_mech_id（打标签时本轮标记机甲），用于"目标==标记机甲才不计攻击数"判定。
static func pilot_006_tag_if_attack(card, owner_pid: StringName, marked_mech_id: StringName) -> void:
	if card == null or card.def == null:
		return
	if String(card.def.action_type) == "攻击":
		card.add_tag(PILOT_006_HUNTING_TAG, owner_pid, {
			"marked_mech_id": marked_mech_id,
			"invalidated": false,
		})


## 标记更换：将指定 source pilot 的所有未失效 hunting 标签永久失效（不删除，留 invalidated 标记）。
## 失效后即使后来又选回原机甲，标签也不恢复（裁定："不会恢复"）。
static func _invalidate_all_hunting_tags(game_state, source_pilot_instance: StringName) -> void:
	# owner_pid = source_pilot_instance 对应的玩家。标签是按 owner_pid 存的。
	# 多里昂场景下，每个里昂各自换标记时只失效自己的标签（按 owner_pid 匹配）。
	var owner_pid := _pilot_006_owner_pid_for_source(game_state, source_pilot_instance)
	if owner_pid == &"" or game_state == null:
		return
	# 遍历 game_state.cards 所有牌（标签挂在 CardInstance 上）
	var cards_dict: Dictionary = game_state.cards if "cards" in game_state else {}
	for card in cards_dict.values():
		if card == null:
			continue
		if not card.has_tag(PILOT_006_HUNTING_TAG, owner_pid):
			continue
		var tag_entry: Dictionary = card.get_tag(PILOT_006_HUNTING_TAG, owner_pid)
		if not bool(tag_entry.get("invalidated", false)):
			# 直接改写 tag entry（add_tag 覆盖同 owner）
			card.add_tag(PILOT_006_HUNTING_TAG, owner_pid, {
				"marked_mech_id": tag_entry.get("marked_mech_id", &""),
				"invalidated": true,
			})


## 取 source_pilot_instance 对应的 owner player_id（用于按 owner 失效标签）。
## 里昂机师牌的 owner_player_id = 其所属机甲的 owner。
static func _pilot_006_owner_pid_for_source(game_state, source_pilot_instance: StringName) -> StringName:
	if game_state == null:
		return &""
	var card = game_state.get_card(source_pilot_instance) if game_state.has_method(&"get_card") else null
	if card == null:
		return &""
	return card.owner_player_id if "owner_player_id" in card else &""


## 标签是否有效（未失效且存在）。用于攻击牌使用判定。
static func pilot_006_hunting_tag_active(card, owner_pid: StringName) -> bool:
	if card == null or not card.has_tag(PILOT_006_HUNTING_TAG, owner_pid):
		return false
	var tag_entry: Dictionary = card.get_tag(PILOT_006_HUNTING_TAG, owner_pid)
	return not bool(tag_entry.get("invalidated", false))


## 卡牌是否有任意 owner 的有效狩猎标签（用于 UI 显示"牌名(狩)"后缀）。
## 多里昂场景下一张牌可被多个里昂各打标签；只要有一个未失效即显示。
static func pilot_006_card_has_active_hunting_tag(card) -> bool:
	if card == null:
		return false
	var owners: Array = card.get_tag_owners(PILOT_006_HUNTING_TAG) if card.has_method(&"get_tag_owners") else []
	for owner_pid: StringName in owners:
		if pilot_006_hunting_tag_active(card, owner_pid):
			return true
	return false


## 取标签绑定的标记机甲。
static func pilot_006_hunting_tag_marked_mech(card, owner_pid: StringName) -> StringName:
	if card == null:
		return &""
	var tag_entry: Dictionary = card.get_tag(PILOT_006_HUNTING_TAG, owner_pid)
	return tag_entry.get("marked_mech_id", &"")


## 里昂狩猎标签豁免检查（validate_card 攻击数=0 时调用）。
## 返回标记机甲 id（""=不豁免）。条件：牌有有效 hunting 标签 + 标记机甲在场存活 +
## 机甲任一武器射程能覆盖标记机甲（hex 距离 <= 该武器 range_value）。
## owner_pid = 牌的 owner（里昂拥有者，多里昂各自独立）。
static func pilot_006_check_zero_exemption(game_state, mech_id: StringName, card, owner_pid: StringName) -> StringName:
	if card == null or game_state == null or mech_id == &"":
		return &""
	# 多里昂：若 owner_pid 未指定，取牌的 owner
	if owner_pid == &"":
		owner_pid = card.owner_player_id if "owner_player_id" in card else &""
	if owner_pid == &"":
		return &""
	if not pilot_006_hunting_tag_active(card, owner_pid):
		return &""
	var marked_mech: StringName = pilot_006_hunting_tag_marked_mech(card, owner_pid)
	if marked_mech == &"":
		return &""
	var target_mech = game_state.mechs.get(marked_mech) if game_state.get("mechs") != null else null
	if target_mech == null or target_mech.destroyed:
		return &""  # 标记机甲不在场/已毁
	var attacker_mech = game_state.mechs.get(mech_id)
	if attacker_mech == null:
		return &""
	# 检查任一武器射程能覆盖标记机甲（hex 距离）
	var _HexGrid = _get_hex_grid()
	var weapon_ids: Array = attacker_mech.get_weapon_ids() if attacker_mech.has_method(&"get_weapon_ids") else []
	var best_range: int = 0
	for wid in weapon_ids:
		var r := _weapon_range_value(game_state, attacker_mech, wid)
		if r > best_range:
			best_range = r
	if best_range <= 0:
		return &""
	var dist: int = _HexGrid.distance(attacker_mech.position, target_mech.position)
	if dist <= best_range:
		return marked_mech
	return &""


## 取武器射程值（基础武器虚拟ID 或 装备武器 def.range_value）。
static func _weapon_range_value(game_state, attacker_mech, weapon_id: StringName) -> int:
	var wid_str := String(weapon_id)
	if wid_str.begins_with("frame_base_weapon"):
		var slot_index: int = 0
		if wid_str.begins_with("frame_base_weapon_"):
			slot_index = wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
		var base_weapon: Dictionary = attacker_mech.get_base_weapon(slot_index) if attacker_mech.has_method(&"get_base_weapon") else {}
		return int(base_weapon.get("range_value", 1))
	var weapon_card = game_state.get_card(weapon_id) if game_state.has_method(&"get_card") else null
	if weapon_card != null and weapon_card.def != null:
		return int(weapon_card.def.range_value) if "range_value" in weapon_card.def else 1
	return 0


## 获取 _HexGrid 单例（延迟 preload，避免循环依赖）。
static var _hex_grid_cache = null
static func _get_hex_grid():
	if _hex_grid_cache == null:
		_hex_grid_cache = load("res://scripts/battle/hex_grid.gd")
	return _hex_grid_cache


# ════════════════════════════════════════════════════════════
# pilot_009 美杜莎 临时卡牌控制（effect_01 蛇发支配）
# ════════════════════════════════════════════════════════════
## 裁定：非排他控制（双方可用，先用者得）；必须全弃该类型；持续光环到回合结束；换下立即解。
## 存 {target_mech_id: {card_type: {controller_player_id, source_pilot_instance}}}。
static var _pilot_009_control: Dictionary = {}


static func grant_temp_card_control(target_mech: StringName, card_type: StringName, controller_player: StringName, source_pilot: StringName) -> void:
	if not _pilot_009_control.has(target_mech):
		_pilot_009_control[target_mech] = {}
	_pilot_009_control[target_mech][card_type] = {"controller": controller_player, "source_pilot": source_pilot}


## 目标机甲的某类型牌是否被该玩家控制（非排他：双方都可控制，分别 grant）
static func is_card_type_controlled_by(target_mech: StringName, card_type: StringName, player_id: StringName) -> bool:
	var entry: Dictionary = _pilot_009_control.get(target_mech, {}).get(card_type, {})
	return String(entry.get("controller", &"")) == String(player_id)


## 清除某 source pilot 的所有控制（换下立即解除，裁定歧义5）
static func clear_pilot_009_control_for_source(source_pilot: StringName) -> void:
	for target_mech: StringName in _pilot_009_control:
		var types: Dictionary = _pilot_009_control[target_mech]
		var to_remove: Array = []
		for ct: StringName in types:
			if String(types[ct].get("source_pilot", &"")) == String(source_pilot):
				to_remove.append(ct)
		for ct in to_remove:
			types.erase(ct)


## 回合结束清除所有 pilot_009 控制（持续光环到回合结束）
static func clear_all_pilot_009_control() -> void:
	_pilot_009_control.clear()


## 取控制某机甲某类型牌的全部控制器（非排他：可能多个玩家各自 grant）。
## 供响应窗口/按钮枚举受控牌、register_hand_card_availability 动态注册 granted 监听器。
static func get_pilot_009_controllers(target_mech: StringName, card_type: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	var types: Dictionary = _pilot_009_control.get(target_mech, {})
	var entry: Dictionary = types.get(card_type, {})
	var controller: StringName = entry.get("controller", &"")
	if String(controller) != "":
		result.append(controller)
	return result


## 取某控制器当前所有受控授权：[{target_mech_id, card_type, card_ids}]。
## card_ids 为目标手牌中该类型的全部牌实例（含新抽；主动牌由「美杜莎操控」按钮列出使用）。
## 供「美杜莎操控」按钮枚举美杜莎可使用的目标主动牌。需传 game_state 以取目标手牌。
static func get_pilot_009_controlled_grants(controller_pid: StringName, game_state) -> Array:
	var result: Array = []
	if controller_pid == &"" or game_state == null:
		return result
	for target_mech: StringName in _pilot_009_control:
		var types: Dictionary = _pilot_009_control[target_mech]
		for ct: StringName in types:
			var entry: Dictionary = types[ct]
			if String(entry.get("controller", &"")) != String(controller_pid):
				continue
			var card_ids: Array = []
			var tgt_player = game_state.get_player_for_mech(target_mech) if game_state.has_method(&"get_player_for_mech") else null
			if tgt_player != null:
				for cid: StringName in tgt_player.action_hand:
					var c = game_state.get_card(cid) if game_state.has_method(&"get_card") else null
					if c != null and c.def != null and String(c.def.action_type) == String(ct):
						card_ids.append(cid)
			if not card_ids.is_empty():
				result.append({"target_mech_id": target_mech, "card_type": String(ct), "card_ids": card_ids})
	return result


# ════════════════════════════════════════════════════════════
# pilot_002 莱比尔 批次转化权限（effect_01 交牌后接收者获"当作具名牌使用"权限）
# ════════════════════════════════════════════════════════════
## 存 {batch_id: {target_mech, card_ids, named_type, grant_source, used, broken}}
## 裁定：莱比尔离场后所有权限清除（不保留已转移批次权限）。
static var _pilot_002_batches: Dictionary = {}


## 登记批次转化权限（GRANT_TRANSFER_BATCH_AS_NAMED_TYPE 调用）。
## 标记批次牌 card.counters["pilot_002_batch"]=batch_id；目标获一次性"当作具名牌使用"权限。
## batch_id 建议格式："pilot002:<grant_source_instance>:<effect_fire_action_id>"。
static func register_pilot_002_batch(batch_id: String, target_mech: StringName, card_ids: Array, named_type: StringName, grant_source: StringName) -> void:
	_pilot_002_batches[batch_id] = {
		"target_mech": target_mech,
		"card_ids": card_ids.duplicate(),
		"named_type": named_type,
		"grant_source": grant_source,
		"used": false,
		"broken": false,
	}
	for cid in card_ids:
		var c = _aura_game_state.get_card(cid) if _aura_game_state != null else null
		if c != null:
			if not "counters" in c:
				c.counters = {}
			c.counters["pilot_002_batch"] = batch_id


static func get_pilot_002_batch(batch_id: String) -> Dictionary:
	return _pilot_002_batches.get(batch_id, {})


## 目标机甲是否有未使用未破裂的进攻批次（DIRECT skill_bar 按钮扫描用）
static func get_pilot_002_usable_attack_batch(target_mech: StringName) -> String:
	for bid in _pilot_002_batches:
		var b: Dictionary = _pilot_002_batches[bid]
		if String(b.get("named_type", &"")) == "进攻" and String(b.get("target_mech", &"")) == String(target_mech) and not bool(b.get("used", false)) and not bool(b.get("broken", false)):
			return bid
	return ""


## 标记批次已使用（批次使用后清除权限）
static func mark_pilot_002_batch_used(batch_id: String) -> void:
	if not _pilot_002_batches.has(batch_id):
		return
	_pilot_002_batches[batch_id]["used"] = true
	# 清除牌上的 batch 标记
	for cid in _pilot_002_batches[batch_id].get("card_ids", []):
		var c = _aura_game_state.get_card(cid) if _aura_game_state != null else null
		if c != null and "counters" in c:
			c.counters.erase("pilot_002_batch")


## 清除某来源莱比尔的所有批次权限（换下/离场立即解除，裁定歧义4）
static func clear_pilot_002_batches_for_source(grant_source: StringName) -> void:
	var to_remove: Array = []
	for bid in _pilot_002_batches:
		if String(_pilot_002_batches[bid].get("grant_source", &"")) == String(grant_source):
			to_remove.append(bid)
	for bid in to_remove:
		for cid in _pilot_002_batches[bid].get("card_ids", []):
			var c = _aura_game_state.get_card(cid) if _aura_game_state != null else null
			if c != null and "counters" in c:
				c.counters.erase("pilot_002_batch")
		_pilot_002_batches.erase(bid)


# ════════════════════════════════════════════════════════════
# pilot_003 瑟尔基尔 跳过正面牌（effect_03）
# ════════════════════════════════════════════════════════════
## 存 {source_pilot_instance: {player_id: true}}。开启时该玩家抽牌跳过牌堆正面牌且数量+1。
static var _pilot_003_skip: Dictionary = {}


static func toggle_pilot_003_skip(source_pilot: StringName, player_id: StringName, enable: bool) -> void:
	if enable:
		if not _pilot_003_skip.has(source_pilot):
			_pilot_003_skip[source_pilot] = {}
		_pilot_003_skip[source_pilot][player_id] = true
	else:
		if _pilot_003_skip.has(source_pilot):
			_pilot_003_skip[source_pilot].erase(player_id)


## 批量设置跳过玩家集合（pilot_003 effect_03 复选框提交，裁定权威"重要补充"）。
## 用一个 source_pilot 的整组 player_ids 覆盖原勾选（含取消全部=空数组清空）。
static func set_pilot_003_skip_players(source_pilot: StringName, player_ids: Array) -> void:
	_pilot_003_skip[source_pilot] = {}
	for pid in player_ids:
		_pilot_003_skip[source_pilot][StringName(pid)] = true


## 取该 source_pilot 当前勾选的跳过玩家（复选框回显用）
static func get_pilot_003_skip_players(source_pilot: StringName) -> Array:
	var result: Array = []
	var entry: Dictionary = _pilot_003_skip.get(source_pilot, {})
	for pid: StringName in entry:
		result.append(String(pid))
	return result


static func is_pilot_003_skip_active(player_id: StringName) -> bool:
	for src in _pilot_003_skip:
		if _pilot_003_skip[src].has(player_id):
			return true
	return false


## 瑟尔基尔本人是否被勾选（+1 增益判定）。裁定"重要补充"：跳过行为对被勾选玩家都生效，
## 但"此次抽牌数+1"仅在瑟尔基尔自己勾选（即抽牌者是瑟尔基尔拥有者）时生效。
## 需 game_state 反查 source pilot 的 owner_player_id。
static func is_pilot_003_self_skip_active(player_id: StringName, game_state) -> bool:
	for src in _pilot_003_skip:
		if not _pilot_003_skip[src].has(player_id):
			continue
		if game_state == null:
			return false
		var pilot_card = game_state.cards.get(src)
		if pilot_card == null:
			continue
		if String(pilot_card.owner_player_id) == String(player_id):
			return true
	return false


static func clear_pilot_003_skip_for_source(source_pilot: StringName) -> void:
	_pilot_003_skip.erase(source_pilot)


# ═══════════════════════════════════════════
# PvP 快照：机师静态状态序列化/恢复
# ═══════════════════════════════════════════
## 机师效果的静态字典（悬赏/控制/批次/跳过）不在 game_state 内，PvP 双端需经快照同步。
## serialize_pilot_static 产出纯 Variant Dict（可 put_var 传输）；apply_pilot_static 恢复。

static func serialize_pilot_static() -> Dictionary:
	return {
		"pilot_006_marks": _pilot_006_marks.duplicate(true),
		"pilot_009_control": _pilot_009_control.duplicate(true),
		"pilot_002_batches": _pilot_002_batches.duplicate(true),
		"pilot_003_skip": _pilot_003_skip.duplicate(true),
	}


static func apply_pilot_static(data: Dictionary) -> void:
	if data.is_empty():
		return
	_pilot_006_marks = data.get("pilot_006_marks", {}).duplicate(true)
	_pilot_009_control = data.get("pilot_009_control", {}).duplicate(true)
	_pilot_002_batches = data.get("pilot_002_batches", {}).duplicate(true)
	_pilot_003_skip = data.get("pilot_003_skip", {}).duplicate(true)


## 构建所有机师效果定义，返回 { effect_id: ActionEffect }
## SSR pilot_001-010 效果按拆解文 + 裁定 delta 逐张填入（见各 pilot 实现提交）。
static func build_pilot_effects() -> Dictionary:
	var effects: Dictionary = {}

	# ═══════════════════════════════════════════
	# pilot_010 刻托（混乱 SSR，cost 15, attack_limit 3, action_card_limit 1）
	# ═══════════════════════════════════════════

	# ── pilot_010_effect_01 限额互换 ──
	# 我方回合开始时，可互换行动牌上限与回合攻击数，之后抽 互换后的行动牌上限+1 张。
	# 裁定（歧义1/2）：持久 orientation（不本回合恢复）；不互换则不抽。
	# 互换 action_card_limit <-> attack_limit（max_attacks_per_turn 跟随），
	# 设本回合剩余攻击数=新攻击上限（attack_count_this_turn=0），抽 新action_card_limit+1。
	# SWAP_HAND_LIMIT_AND_ATTACK_COUNT 已改为持久语义（GameActions.swap_hand_limit_and_attack_count）。
	var p010e1 := _ActionEffect.new()
	p010e1.effect_id = &"pilot_010_effect_01"
	p010e1.display_name = "限额互换"
	p010e1.description = "我方回合开始时，可互换行动牌上限与回合攻击数，之后抽 互换后的行动牌上限+1 张。"
	p010e1.mode = _TC.MODE_LISTEN
	p010e1.priority = 20
	p010e1.listen_timing = _TC.TURN_START
	p010e1.listen_action_type = &"turn"
	p010e1.set_conditions([{"op": &"IS_OWNER_TURN"}])
	p010e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p010e1.set_costs([])
	p010e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "互换行动牌上限与回合攻击数，之后抽牌",
				"actions": [{
					"type": &"SWAP_HAND_LIMIT_AND_ATTACK_COUNT",
					"params": {
						"mech_id": "$binding_context.mech_id",
						"player_id": "$binding_context.player_id",
						"source_card_id": "$binding_context.card_instance_id",
					}
				}]
			}]
		}
	}])
	effects[p010e1.effect_id] = p010e1

	# ── pilot_010_effect_02 三段演算 ──
	# 当前活动回合内，刻托使用的第1张实体攻击牌视为强袭，第2张视为闪击，第3张视为预判。
	# 视为（出牌后替换「执行的效果」，保留 USE_ACTION_* 时点与攻击来源=原牌本身；珀修斯可在该牌
	# use_action 结算后夺走原牌，但夺到的是原牌而非视为的强袭）。区别于当作（出牌前经 cost 转化，
	# 虚拟当作不计数/不视为，PAYLOAD_IS_PHYSICAL_ACTION_CARD 排除）。每活动回合各自重置（counter 按
	# turn_number 建 key）；牌进临时区即计数（use_action 取消也计——计数在 USE_ACTION_BEFORE 已 +1）。
	#
	# 监听时点用 USE_ACTION_BEFORE（而非 USE_ACTION_AT）：REPLACE 设 as_card_def_id 必须早于
	# step② card_to_temp_zone 的 _register_card_effects（它读 _as_card_def_id 注册 LISTEN/bind_to_sub 效果）。
	# 旧实现用 USE_ACTION_AT：时点翻转后 step② handler（注册原牌 LISTEN 效果）先跑、再 fire USE_ACTION_AT
	# 设 as_card_def_id——结果被替换牌(强袭/闪击/预判)的 bind_to_sub LISTEN 效果未注册，原牌 LISTEN 效果泄漏。
	# 改到 USE_ACTION_BEFORE：step① validate handler 先跑（写 card_instance_id/mech_id 入 record）、
	# 再 fire USE_ACTION_BEFORE 设 as_card_def_id、随后 step② 读到具名牌注册正确 LISTEN 效果，无泄漏。
	# 条件在 USE_ACTION_BEFORE 均可读：payload=record.duplicate()（含 card_instance_id/mech_id/virtual_transform）
	# + listener binding_context（机师实例/刻托机甲），见 TimingEngine.fire_timing。
	#
	# max_index=3：仅前3张（uses 0/1/2）视为；第4张（uses=3）已在 step① validate 被
	# can_pilot_010_use_physical_attack_card 拦截（返回 error->cancel，不 fire USE_ACTION_BEFORE，不会到此）。
	# REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE 设 as_card_def_id 让 _step_execute_effects/register 用具名牌 effect 链。
	var p010e2 := _ActionEffect.new()
	p010e2.effect_id = &"pilot_010_effect_02"
	p010e2.display_name = "三段演算"
	p010e2.description = "刻托使用的第1张实体攻击牌视为强袭，第2张视为闪击，第3张视为预判。"
	p010e2.mode = _TC.MODE_LISTEN
	p010e2.priority = 20
	p010e2.listen_timing = _TC.USE_ACTION_BEFORE
	p010e2.listen_action_type = &"use_action_card"
	p010e2.set_conditions([
		{"op": &"USED_CARD_EXECUTOR_IS_SELF"},
		{"op": &"USED_CARD_TYPE_IS", "card_type": &"攻击"},
		{"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"OWNER_ATTACK_CARD_USE_INDEX_THIS_TURN_BELOW", "params": {"max_index": 3}},
	])
	p010e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p010e2.set_costs([])
	p010e2.set_actions([{
		"type": &"REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE",
		"params": {
			"source_card_id": "$binding_context.card_instance_id",
		}
	}])
	effects[p010e2.effect_id] = p010e2

	# ═══════════════════════════════════════════
	# pilot_004 玛沙（帝国 SSR，cost 15, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════

	# ── pilot_004_effect_01a 装甲转能（按钮1：主动+被动合并）──
	# 每回合开始（任意玩家回合）可选转化 N 护甲为 N 动力（增加动力上限并补满），每完整3点抽2张。
	# 裁定（歧义1）：转化动力增加上限并补满，护甲减少上限；跨回合持久到下个我方 TURN_BEFORE_START 清。
	# 裁定（歧义5）：任意玩家回合开始均触发。
	# 护甲 -N: ARMOR_MODIFIER(duration=UNTIL_NEXT_OWNER_TURN, runtime_tag=pilot_004_armor_conversion)。
	# 动力 +N: POWER_CAP_MODIFIER(mode=cap_bonus, runtime_tag=pilot_004_power_conversion)，get_total_power 算入。
	# CHOOSE_INTEGER stepper=true：步进面板（LineEdit+±3按钮,默认0,键盘输入,最大=有效护甲）。
	var p004e1a := _ActionEffect.new()
	p004e1a.effect_id = &"pilot_004_effect_01a"
	p004e1a.display_name = "装甲转能"
	p004e1a.description = "每回合开始时，可将护甲转化为动力（增加动力上限并补满），每完整3点立即抽2张。"
	p004e1a.mode = _TC.MODE_LISTEN
	p004e1a.priority = 10
	p004e1a.listen_timing = _TC.TURN_START
	p004e1a.listen_action_type = &"turn"
	p004e1a.set_conditions([
		{"op": &"SELF_MECH_ALIVE"},
		{"op": &"SELF_EFFECTIVE_ARMOR_ABOVE", "params": {"threshold": 0}},
	])
	p004e1a.set_target_rules([{"rule": &"NO_TARGET"}])
	p004e1a.set_costs([])
	p004e1a.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "将护甲转化为动力",
				"actions": [{
					"type": &"CHOOSE_INTEGER",
					"params": {
						"label": "选择要转化的护甲数",
						"min_value": 0,
						"max_value_expr": "$binding_context.mech_effective_armor",
						"bind_as": "n",
						"stepper": true,
						"optional": false,
						"actions": [
							{"type": &"EXECUTE_STAT_MODIFY", "params": {
								"stat_type": &"armor", "value_expr": "-$choice.n", "method": &"add",
								"duration": &"UNTIL_NEXT_OWNER_TURN", "runtime_tag": &"pilot_004_armor_conversion",
								"target_id": "$binding_context.mech_id", "source_card_id": "$binding_context.card_instance_id",
							}},
							{"type": &"EXECUTE_STAT_MODIFY", "params": {
								"stat_type": &"power", "value_expr": "$choice.n", "method": &"add", "mode": &"cap_bonus",
								"duration": &"UNTIL_NEXT_OWNER_TURN", "runtime_tag": &"pilot_004_power_conversion",
								"target_id": "$binding_context.mech_id", "source_card_id": "$binding_context.card_instance_id",
							}},
							{"type": &"EXECUTE_GAIN_CARD", "params": {
								"from_zone": &"action_deck",
								"card_kind": &"action",
								"count_expr": "floor($choice.n / 3) * 2",
								"player_id": "$binding_context.player_id",
								"reason": &"pilot_004_armor_conversion",
							}},
						],
					}
				}]
			}]
		}
	}])
	effects[p004e1a.effect_id] = p004e1a

	# ── pilot_004_effect_01b 护甲恢复（隐藏被动，不显示按钮）──
	# 仅当即将开始的是机师拥有者回合时，清除本机师实例建立的全部转换层（护甲/动力 modifier）。
	# priority 30 先于回合动力回复。裁定：转化层持久到下个我方 TURN_BEFORE_START。
	# 隐藏：equipment_panel 跳过此 effect 不显示按钮（按钮1合并描述）。
	var p004e1b := _ActionEffect.new()
	p004e1b.effect_id = &"pilot_004_effect_01b"
	p004e1b.display_name = "护甲恢复"
	p004e1b.description = "下个我方回合即将开始时，清除护甲转动力层，护甲与动力上限恢复。"
	p004e1b.mode = _TC.MODE_LISTEN
	p004e1b.priority = 30
	p004e1b.listen_timing = _TC.TURN_BEFORE_START
	p004e1b.listen_action_type = &"turn"
	p004e1b.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"SOURCE_RUNTIME_MODIFIER_EXISTS", "params": {"tag": &"pilot_004_armor_conversion"}},
	])
	p004e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p004e1b.set_costs([])
	p004e1b.set_actions([{
		"type": &"CLEAR_SOURCE_STAT_MODIFIERS",
		"params": {
			"mech_id": "$binding_context.mech_id",
			"source_card_id": "$binding_context.card_instance_id",
			"runtime_tags": [&"pilot_004_armor_conversion", &"pilot_004_power_conversion"],
		}
	}])
	effects[p004e1b.effect_id] = p004e1b

	# ── pilot_004_effect_02 动力穿透（按钮2：攻击或被攻击）──
	# 玛沙攻击或被攻击时，可消耗3动力，使本次攻击伤害计算用（被攻击目标的）当前动力代替护甲。
	# 攻守合并：SELF_MECH_IS_ATTACKER_OR_TARGET 单条件覆盖两种情形。
	# 裁定（歧义3）：攻击/被攻击都是玛沙效果；每个目标用其自身当前动力代替自身护甲。
	#   - 玛沙攻击：target=敌人，用敌人动力代替敌人护甲（动力通常<护甲，伤害↑）
	#   - 玛沙被攻击：target=玛沙，用玛沙支付后动力代替玛沙护甲
	# 时点：ATTACK_AT（迎击窗后触发），LISTEN 延迟到响应窗关闭后执行，payload 从 action.record 重新快照。
	# 确认机制：CHOOSE_ONE(optional) 弹"消耗3动力？"确认窗（替代旧 optional SPEND_POWER cost 不弹窗的 bug）。
	#   确认 -> SPEND_POWER(mech_id=$binding_context.mech_id=玛沙, amount=3) + SET_ATTACK_DEFENSE_STAT_SOURCE(target=$payload.target_id, current_power)
	#   依赖 CHOOSE_ONE 分支 $-占位符解析（TimingEngine._execute_actions CHOOSE_ONE 分支已补 _resolve_atomic_value）。
	var p004e2 := _ActionEffect.new()
	p004e2.effect_id = &"pilot_004_effect_02"
	p004e2.display_name = "动力穿透"
	p004e2.description = "攻击或被攻击时，可消耗3动力，使本次攻击伤害计算用机甲动力代替护甲。"
	p004e2.mode = _TC.MODE_LISTEN
	p004e2.priority = 30
	p004e2.listen_timing = _TC.ATTACK_PRE
	p004e2.listen_action_type = &"attack"
	p004e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER_OR_TARGET"},
		{"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "params": {"threshold": 3}},
	])
	p004e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p004e2.set_costs([])
	p004e2.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "消耗3动力，用动力代替护甲",
				"actions": [
					{"type": &"SPEND_POWER", "params": {
						"mech_id": "$binding_context.mech_id",
						"amount": 3,
					}},
					{"type": &"SET_ATTACK_DEFENSE_STAT_SOURCE", "params": {
						"target_id": "$payload.target_id",
						"stat_source": &"current_power",
					}},
				]
			}]
		}
	}])
	effects[p004e2.effect_id] = p004e2

	# ═══════════════════════════════════════════
	# pilot_005 肯特（帝国 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_005_effect_01 帝国压制光环（aura provider，被动展示）──
	# 向场上所有帝国阵营机师（含肯特自身）授予 EX 压制能力（ATTACK_PRE 弃牌）。
	# 本身无主动动作，仅作 1 号被动按钮展示（置灰+悬停说明）；授予逻辑在
	# GameSetupService._grant_pilot_005_to_empire_mechs，不注册 listener。
	var p005e1 := _ActionEffect.new()
	p005e1.effect_id = &"pilot_005_effect_01"
	p005e1.display_name = "帝国压制光环"
	p005e1.description = "授予场上所有帝国阵营机师牌（含自身）EX 压制能力：攻击或被攻击时，可消耗4动力，由使用方选弃对侧（目标或攻击方）2张行动牌（不足2弃全部）。被取消加成的机甲 EX 按钮消失。"
	p005e1.mode = _TC.MODE_LISTEN
	p005e1.priority = 10
	p005e1.set_conditions([])
	p005e1.set_target_rules([])
	p005e1.set_costs([])
	p005e1.set_actions([])
	effects[p005e1.effect_id] = p005e1

	# ── pilot_005_effect_02 帝国机甲动力+4（派生值，被动展示）──
	# 帝国阵营机甲框架动力+4（按机甲框架阵营判断，与 EX 按机师牌阵营分开）。
	# 实时重算于 MechState.get_total_power，不注册 listener；仅作 2 号被动按钮展示。
	var p005e2 := _ActionEffect.new()
	p005e2.effect_id = &"pilot_005_effect_02"
	p005e2.display_name = "帝国机甲动力+4"
	p005e2.description = "帝国阵营机甲框架动力+4（按机甲框架阵营判断，与 EX 按机师牌阵营分开）。原始框架=帝国 +4，基础框架=联邦 +0。"
	p005e2.mode = _TC.MODE_LISTEN
	p005e2.priority = 10
	p005e2.set_conditions([])
	p005e2.set_target_rules([])
	p005e2.set_costs([])
	p005e2.set_actions([])
	effects[p005e2.effect_id] = p005e2

	# ── pilot_005_effect_03 取消/恢复加成 ──
	# 我方回合1次，选择1台其他机甲，弹窗二选一：取消（排除其 1 效果 EX 按钮 + 2 效果动力+4）
	# 或恢复（重新囊括；未排除则无事）。仍需帝国框架/机师牌才享受对应加成。
	var p005e3 := _ActionEffect.new()
	p005e3.effect_id = &"pilot_005_effect_03"
	p005e3.display_name = "取消/恢复加成"
	p005e3.description = "我方回合1次，选择1台其他机甲，取消或恢复其获得的肯特加成（动力+4与压制弃牌）。"
	p005e3.mode = _TC.MODE_DIRECT
	p005e3.priority = 10
	p005e3.once_per_turn_key = &"pilot_005_effect_03"
	p005e3.once_per_turn_max = 1
	p005e3.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_OTHER_MECH_ON_FIELD"},
	])
	p005e3.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	p005e3.set_costs([])
	p005e3.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"title": "肯特：取消/恢复加成",
			"description": "选择对该机甲执行的操作",
			"options": [
				{"label": "取消该机甲的肯特加成（动力+4与压制弃牌）", "actions": [
					{"type": &"TOGGLE_AURA_TARGET", "params": {"toggle": &"off"}}
				]},
				{"label": "恢复该机甲的肯特加成", "actions": [
					{"type": &"TOGGLE_AURA_TARGET", "params": {"toggle": &"on"}}
				]},
			],
		}
	}])
	effects[p005e3.effect_id] = p005e3

	# ── pilot_005_granted_suppression 帝国压制（授予帝国机师的 ATTACK_PRE 弃牌能力）──
	# 由 pilot_005_effect_01（aura provider）向帝国阵营机师授予，注册为 granted ATTACK_PRE listener。
	# binding_context.mech_id=被授予帝国机甲；card_instance_id=pilot_005 实例（grant_source，注销用）。
	# 裁定（歧义1）：手牌不足2弃全部（触发效果非成本）；攻击/被攻击都触发；每来源独立。
	var p005_granted := _ActionEffect.new()
	p005_granted.effect_id = &"pilot_005_granted_suppression"
	p005_granted.display_name = "帝国压制"
	p005_granted.description = "攻击或被攻击时，可消耗4动力，由使用方选弃对侧（目标或攻击方）2张行动牌（不足2弃全部）。"
	p005_granted.mode = _TC.MODE_LISTEN
	p005_granted.priority = 30
	p005_granted.listen_timing = _TC.ATTACK_PRE
	p005_granted.listen_action_type = &"attack"
	p005_granted.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER_OR_TARGET"},
		{"op": &"PILOT_AURA_ACTIVE_FOR_MECH"},
		{"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "params": {"threshold": 4}},
		{"op": &"OPPOSING_ATTACK_PARTICIPANT_ACTION_HAND_ABOVE", "params": {"threshold": 0}},
	])
	p005_granted.set_target_rules([{"rule": &"NO_TARGET"}])
	p005_granted.set_costs([])
	# 确认机制（镜像 pilot_004 玛沙 effect_02）：CHOOSE_ONE(optional) 弹"消耗4动力？"确认窗，
	# 确认 -> SPEND_POWER(mech_id=$binding_context.mech_id=肯特被授予机甲, amount=4)
	#       + EXECUTE_DISCARD(from_opposing, count=2, choose=true, face_up=false) 由使用方选对侧2张暗牌弃置。
	# from_opposing：discard_card_action 按 source_mech(=binding_context.mech_id) 判断对侧=非 source 的攻击参与方
	# （攻击方->目标 / 目标->攻击方），player_id=对侧玩家、executor=使用方(选牌)。
	p005_granted.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "消耗4动力，弃置对侧2张行动牌",
				"actions": [
					{"type": &"SPEND_POWER", "params": {
						"mech_id": "$binding_context.mech_id",
						"amount": 4,
					}},
					{"type": &"EXECUTE_DISCARD", "params": {
						"from_opposing": true,
						"count": 2,
						"choose": true,
						"face_up": false,
						"reason": &"PILOT_005_SUPPRESSION",
					}},
				]
			}]
		}
	}])
	effects[p005_granted.effect_id] = p005_granted

	# ═══════════════════════════════════════════
	# pilot_002 莱比尔（联邦 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_002_effect_01 联邦协同光环（aura provider，被动展示）──
	# 向场上所有联邦阵营机师（含莱比尔自身）授予 EX 进攻/防御转化能力。
	# 本身无主动动作，仅作 1 号被动按钮展示（置灰+悬停说明）；授予逻辑在
	# GameSetupService._grant_pilot_002_to_federation_mechs，不注册 listener。
	var p002e1 := _ActionEffect.new()
	p002e1.effect_id = &"pilot_002_effect_01"
	p002e1.display_name = "联邦协同光环"
	p002e1.description = "授予场上所有联邦阵营机师（含自身）EX 进攻/防御转化能力：交任意张行动牌给5格内其他机甲后，自己当作进攻/防御使用。被取消加成的机甲 EX 按钮消失。"
	p002e1.mode = _TC.MODE_LISTEN
	p002e1.priority = 10
	p002e1.set_conditions([])
	p002e1.set_target_rules([])
	p002e1.set_costs([])
	p002e1.set_actions([])
	effects[p002e1.effect_id] = p002e1

	# ── pilot_002_effect_02 联邦机甲护甲+4（派生值，被动展示）──
	# 联邦阵营机甲框架护甲+4（按框架阵营判断，与 EX 按机师牌阵营分开）。
	# 实时重算于 MechState.get_armor，不注册 listener；仅作 2 号被动按钮展示。
	var p002e2 := _ActionEffect.new()
	p002e2.effect_id = &"pilot_002_effect_02"
	p002e2.display_name = "联邦机甲护甲+4"
	p002e2.description = "联邦阵营机甲框架护甲+4（按机甲框架阵营判断，与 EX 按机师牌阵营分开）。基础框架=联邦 +4，原始框架=帝国 +0。"
	p002e2.mode = _TC.MODE_LISTEN
	p002e2.priority = 10
	p002e2.set_conditions([])
	p002e2.set_target_rules([])
	p002e2.set_costs([])
	p002e2.set_actions([])
	effects[p002e2.effect_id] = p002e2

	# ── pilot_002_effect_03 取消/恢复加成 ──
	# 我方回合1次，选择1台其他机甲，弹窗二选一：取消（排除其 1 效果 EX 按钮 + 2 效果护甲+4）
	# 或恢复（重新囊括；未排除则无事）。仍需联邦阵营才享受加成。
	var p002e3 := _ActionEffect.new()
	p002e3.effect_id = &"pilot_002_effect_03"
	p002e3.display_name = "取消/恢复加成"
	p002e3.description = "我方回合1次，选择1台其他机甲，取消或恢复其获得的莱比尔加成（护甲+4与交牌转化）。"
	p002e3.mode = _TC.MODE_DIRECT
	p002e3.priority = 10
	p002e3.once_per_turn_key = &"pilot_002_effect_03"
	p002e3.once_per_turn_max = 1
	p002e3.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_OTHER_MECH_ON_FIELD"},
	])
	p002e3.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	p002e3.set_costs([])
	p002e3.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"title": "莱比尔：取消/恢复加成",
			"description": "选择对该机甲执行的操作",
			"options": [
				{"label": "取消该机甲的莱比尔加成（护甲+4与交牌转化）", "actions": [
					{"type": &"TOGGLE_AURA_TARGET", "params": {"toggle": &"off"}}
				]},
				{"label": "恢复该机甲的莱比尔加成", "actions": [
					{"type": &"TOGGLE_AURA_TARGET", "params": {"toggle": &"on"}}
				]},
			],
		}
	}])
	effects[p002e3.effect_id] = p002e3

	# ── pilot_002_granted_transfer_attack 莱比尔协同·进攻（授予联邦机师的 DIRECT 主动能力）──
	# 由 pilot_002_effect_01（aura provider）向联邦阵营机师授予，注册为 granted DIRECT listener（虚拟时点）。
	# binding_context.mech_id=被授予联邦机甲；card_instance_id=pilot_002 实例（grant_source，注销用）。
	# 裁定：交牌不进临时区直接给目标手牌；交牌者(A)自己当作进攻使用(主动攻击,消耗A攻击数,
	# 选A武器范围内任选目标进攻,与接牌目标B无关)；结算后交牌者抽2。
	var p002g_atk := _ActionEffect.new()
	p002g_atk.effect_id = &"pilot_002_granted_transfer_attack"
	p002g_atk.display_name = "EX-莱比尔转化进攻"
	p002g_atk.description = "交任意张行动牌给5格内其他机甲，自己当作进攻使用（消耗攻击数），抽2。"
	p002g_atk.mode = _TC.MODE_DIRECT
	p002g_atk.priority = 10
	p002g_atk.set_conditions([
		{"op": &"PILOT_AURA_ACTIVE_FOR_MECH"},
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 5}},
		{"op": &"ATTACK_COUNT_ABOVE", "params": {"threshold": 0}},
	])
	p002g_atk.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 5, "metric": &"hex_distance"}},
	])
	p002g_atk.set_costs([])
	p002g_atk.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": -1, "store_result_key": &"pilot_002_transfer_batch", "label": "选择要交给目标的行动牌", "confirm_verb": "交给", "cancel_label": "取消"}},
		{"type": &"TRANSFER_ACTION_CARDS", "params": {"card_ids": "$runtime.pilot_002_transfer_batch", "target_mech_id": "$payload.target_id", "from_player_id": "$binding_context.player_id"}},
		{"type": &"EXECUTE_ATTACK", "params": {"attacker_id": "$binding_context.mech_id", "target_count": 1, "choose_new_target": true, "cardless_weapon_attack": true, "consume_turn_attack_count": true, "source_action_card": null}},
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 2, "player_id": "$binding_context.player_id", "reason": &"pilot_002_after_transfer"}},
	])
	effects[p002g_atk.effect_id] = p002g_atk

	# ── pilot_002_granted_transfer_defense 莱比尔协同·防御（授予联邦机师的 AVAILABILITY 响应能力）──
	# ATTACK_AT 响应窗口：被授予机甲 A 自身被攻击时，交任意张行动牌给5格内其他机甲 B
	# （B 可为任意人，含攻击者），随后 A 自己当作防御响应（护甲+5 本次攻击可见、损伤标记-1），A 抽2。
	# 裁定：A 自己使用防御（非 B）；交牌不进临时区直接给 B 手牌；与进攻分支相同，不消耗攻击数。
	# binding_context.mech_id=A（被攻击目标）；attack_action_id 经响应窗口注入，定位当前攻击。
	var p002g_def := _ActionEffect.new()
	p002g_def.effect_id = &"pilot_002_granted_transfer_defense"
	p002g_def.display_name = "EX-莱比尔转化防御"
	p002g_def.description = "被攻击时，交牌给5格内其他机甲，自己当作防御响应（护甲+5、损伤-1），抽2。"
	p002g_def.mode = _TC.MODE_AVAILABILITY
	p002g_def.priority = 5
	p002g_def.listen_timing = _TC.ATTACK_AT
	p002g_def.listen_action_type = &"attack"
	p002g_def.set_conditions([
		{"op": &"PILOT_AURA_ACTIVE_FOR_MECH"},
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 5}},
	])
	p002g_def.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 5, "metric": &"hex_distance"}},
	])
	p002g_def.set_costs([])
	p002g_def.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": -1, "store_result_key": &"pilot_002_transfer_batch", "label": "选择要交给目标的行动牌", "confirm_verb": "交给", "cancel_label": "取消"}},
		{"type": &"TRANSFER_ACTION_CARDS", "params": {"card_ids": "$runtime.pilot_002_transfer_batch", "target_mech_id": "$payload.target_id", "from_player_id": "$binding_context.player_id"}},
		{"type": &"ADD_MECH_TEMP_ARMOR", "params": {"delta": 5, "mech_id": "$binding_context.mech_id"}},
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -1}},
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 2, "player_id": "$binding_context.player_id", "reason": &"pilot_002_after_transfer"}},
	])
	effects[p002g_def.effect_id] = p002g_def

	# ── pilot_002_batch_use_attack 批次当作进攻使用（DIRECT，目标点击批次按钮触发）──
	# binding_context.batch_id 由 GRANT_TRANSFER_BATCH_AS_NAMED_TYPE 注册时注入。
	# 整批牌进弃牌堆（保留首张作虚拟牌），use_action_card virtual_transform as action_001_进攻。
	var p002_bu_atk := _ActionEffect.new()
	p002_bu_atk.effect_id = &"pilot_002_batch_use_attack"
	p002_bu_atk.display_name = "莱比尔批次·进攻"
	p002_bu_atk.description = "使用莱比尔交牌转化的进攻批次，当作进攻使用（整批进弃牌堆，保留首张作虚拟牌）。"
	p002_bu_atk.mode = _TC.MODE_DIRECT
	p002_bu_atk.priority = 10
	p002_bu_atk.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"PILOT_002_HAS_USABLE_BATCH", "params": {"named_type": &"进攻"}},
	])
	p002_bu_atk.set_target_rules([{"rule": &"NO_TARGET"}])
	p002_bu_atk.set_costs([])
	p002_bu_atk.set_actions([
		{"type": &"PILOT_002_USE_BATCH_AS_NAMED", "params": {"as_card_def_id": &"action_001_进攻", "attack_is_active": true}},
	])
	effects[p002_bu_atk.effect_id] = p002_bu_atk

	# ── pilot_002_batch_use_defense 批次当作防御使用（AVAILABILITY，响应窗口）──
	var p002_bu_def := _ActionEffect.new()
	p002_bu_def.effect_id = &"pilot_002_batch_use_defense"
	p002_bu_def.display_name = "莱比尔批次·防御"
	p002_bu_def.description = "响应窗口使用莱比尔转化的防御批次，当作防御响应。"
	p002_bu_def.mode = _TC.MODE_AVAILABILITY
	p002_bu_def.priority = 5
	p002_bu_def.listen_timing = _TC.ATTACK_AT
	p002_bu_def.listen_action_type = &"attack"
	p002_bu_def.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"PILOT_002_HAS_USABLE_BATCH", "params": {"named_type": &"防御"}},
	])
	p002_bu_def.set_target_rules([{"rule": &"NO_TARGET"}])
	p002_bu_def.set_costs([])
	p002_bu_def.set_actions([
		{"type": &"PILOT_002_USE_BATCH_AS_NAMED", "params": {"as_card_def_id": &"action_009_防御", "attack_is_active": false}},
	])
	effects[p002_bu_def.effect_id] = p002_bu_def

	# ═══════════════════════════════════════════
	# pilot_003 瑟尔基尔（联邦 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_003_effect_01 公开埋牌 ──
	# 我方回合1次，将任意张行动牌正面朝上随机放入行动牌堆，可选其中1张置顶。
	# 裁定：正面牌离堆时由瑟尔基尔拥有者立即使用（effect_02）；无法使用则弃置+抽1（effect_text 说抽2，拆解改抽1，以拆解为准）。
	var p003e1 := _ActionEffect.new()
	p003e1.effect_id = &"pilot_003_effect_01"
	p003e1.display_name = "公开埋牌"
	p003e1.description = "我方回合1次，将任意张行动牌正面朝上随机放入行动牌堆，可选1张置顶。"
	p003e1.mode = _TC.MODE_DIRECT
	p003e1.priority = 10
	p003e1.once_per_turn_key = &"pilot_003_effect_01"
	p003e1.once_per_turn_max = 1
	p003e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
	])
	p003e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p003e1.set_costs([])
	p003e1.set_actions([
		# phase 链：CHOOSE_MANY 选牌 -> (resume 存牌后弹"选1张置顶"窗 phase=pilot_003_choose_top)
		# -> (resume 存置顶牌后) 续跑 INSERT：非顶随机插入 + 置顶牌插 index0 + 打 face_up_bury 标签。
		# store_next_phase 触发 choose-top 弹窗；deck_top_card_id=$runtime.pilot_003_top_card_id 由 phase 链写入。
		{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": -1, "store_result_key": &"pilot_003_face_up_cards", "store_next_phase": &"pilot_003_choose_top", "store_next_phase_label": "选择1张正面牌放置到牌堆顶（可取消）", "label": "选择正面朝上随机放入行动牌堆的牌", "confirm_verb": "放入牌堆", "cancel_label": "取消"}},
		{"type": &"INSERT_ACTION_CARDS_FACE_UP_RANDOM", "params": {"card_ids": "$runtime.pilot_003_face_up_cards", "deck_top_card_id": "$runtime.pilot_003_top_card_id", "deck_id": &"action_deck", "face_up": true}},
	])
	effects[p003e1.effect_id] = p003e1

	# ── pilot_003_effect_02 离堆强制使用 ──
	# 标记牌离开行动牌堆时，由瑟尔基尔拥有者立即使用（无法使用则弃置+抽1）。
	# 方案B：draw_from_deck 在抽出正面牌时用虚拟 Action fire CARD_LEAVE_ACTION_DECK_BEFORE。
	# CANCEL 原子标记拦截（原抽牌不把牌交给原目标）；IMMEDIATELY_USE 由 metadata owner 立即
	# 完整使用（passive 攻击），不可用则公开弃置+拥有者抽1。
	var p003e2 := _ActionEffect.new()
	p003e2.effect_id = &"pilot_003_effect_02"
	p003e2.display_name = "离堆强制使用"
	p003e2.description = "正面牌离开牌堆时，由瑟尔基尔拥有者立即使用；无法使用则弃置并抽1。"
	p003e2.mode = _TC.MODE_LISTEN
	p003e2.priority = 30
	p003e2.listen_timing = _TC.CARD_LEAVE_ACTION_DECK_BEFORE
	p003e2.listen_action_type = &"card_zone_change"
	p003e2.set_conditions([
		{"op": &"PAYLOAD_CARD_HAS_RUNTIME_TAG", "params": {"tag": &"face_up_bury"}},
		{"op": &"PAYLOAD_FROM_ZONE_IS", "params": {"zone": &"action_deck"}},
	])
	p003e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p003e2.set_costs([])
	p003e2.set_actions([
		{"type": &"IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK", "params": {"card_instance_id": "$payload.card_instance_id"}},
	])
	effects[p003e2.effect_id] = p003e2

	# ── pilot_003_effect_03 跳过公开牌（DIRECT 复选框，裁定权威"重要补充"）──
	# 点按钮弹复选框列出所有玩家（含自己），勾选"抽牌跳过正面牌"的玩家，提交后生效。
	# 被勾选玩家抽牌遇正面牌自动跳过；瑟尔基尔自己勾选且本次将抽到正面牌时抽牌数+1
	# （按"次"计：一次抽 N 张只 +1 → N+1）。CHOOSE_MANY_PLAYERS need_input 弹窗 +
	# SET_PILOT_003_SKIP_PLAYERS atomic 整组覆盖。
	var p003e3 := _ActionEffect.new()
	p003e3.effect_id = &"pilot_003_effect_03"
	p003e3.display_name = "跳过公开牌"
	p003e3.description = "勾选「抽牌跳过正面牌」的玩家（含自己）。被勾选者抽牌遇正面牌自动跳过；自己勾选且将抽到正面牌时抽牌数+1。"
	p003e3.mode = _TC.MODE_DIRECT
	p003e3.priority = 10
	# 任何时候可点（去掉每回合/主阶段限制）：点按钮弹复选框，提交后才更新跳过玩家。
	p003e3.set_conditions([])
	p003e3.set_target_rules([{"rule": &"NO_TARGET"}])
	p003e3.set_costs([])
	p003e3.set_actions([
		{"type": &"CHOOSE_MANY_PLAYERS", "params": {}},
	])
	effects[p003e3.effect_id] = p003e3

	# ═══════════════════════════════════════════
	# pilot_008 安德洛美达（秩序 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_008_effect_01a 回收维修(使用) ──
	# 维修被使用后（USE_ACTION_SETTLE），强制回收弃牌堆的维修入手牌 + X+1（max5）。
	# 裁定：当作维修不触发；X 绑 card_instance_id 换机师不转移；01a/01b 共享 once_per_turn。
	# 强制执行（非选框）：条件满足即自动回收，不弹「是否获得」确认窗。
	var p008e1a := _ActionEffect.new()
	p008e1a.effect_id = &"pilot_008_effect_01a"
	p008e1a.display_name = "回收维修"
	p008e1a.description = "每回合1次，维修被使用或弃置后，我方获得之，X+1（上限5）。"
	p008e1a.mode = _TC.MODE_LISTEN
	p008e1a.priority = 20
	p008e1a.listen_timing = _TC.USE_ACTION_SETTLE
	p008e1a.listen_action_type = &"use_action_card"
	p008e1a.once_per_turn_key = &"pilot_008_effect_01"
	p008e1a.once_per_turn_max = 1
	p008e1a.set_conditions([
		{"op": &"PAYLOAD_PHYSICAL_CARD_DEF_ID_IS", "params": {"card_def_id": &"action_013_维修"}},
		{"op": &"SOURCE_CARD_INSTANCE_CAN_BE_GAINED"},
	])
	p008e1a.set_target_rules([{"rule": &"NO_TARGET"}])
	p008e1a.set_costs([])
	p008e1a.set_actions([
		{"type": &"PILOT_008_RECOVER_REPAIR", "params": {}}
	])
	effects[p008e1a.effect_id] = p008e1a

	# ── pilot_008_effect_01b 回收维修(弃置) ──
	# 维修被弃置后（DISCARD_SETTLE，含回合末超限弃牌），强制回收 + X+1。
	# 隐藏被动：不建独立按钮，描述合并到按钮1(01a) hover（01a/01b 共享 once_per_turn_key）。
	var p008e1b := _ActionEffect.new()
	p008e1b.effect_id = &"pilot_008_effect_01b"
	p008e1b.display_name = "回收维修"
	p008e1b.description = "每回合1次，维修被使用或弃置后，我方获得之，X+1（上限5）。"
	p008e1b.mode = _TC.MODE_LISTEN
	p008e1b.priority = 20
	p008e1b.listen_timing = _TC.DISCARD_SETTLE
	p008e1b.listen_action_type = &"discard_card"
	p008e1b.once_per_turn_key = &"pilot_008_effect_01"
	p008e1b.once_per_turn_max = 1
	p008e1b.set_conditions([
		{"op": &"DISCARD_CONTAINS_CARD_DEF_ID", "params": {"card_def_id": &"action_013_维修"}},
	])
	p008e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p008e1b.set_costs([])
	p008e1b.set_actions([
		{"type": &"PILOT_008_RECOVER_REPAIR", "params": {}}
	])
	effects[p008e1b.effect_id] = p008e1b

	# ── pilot_008_effect_02 逆转治疗(回复->等量伤害) ──
	# 5+X 格内机甲即将回复生命时，可改为受到等量伤害（按实际可回复量，无源伤害）。
	# 满血（实际回复0）不触发；弹窗显示机甲HP+实际回复量供安德洛美达玩家确认。
	var p008e2 := _ActionEffect.new()
	p008e2.effect_id = &"pilot_008_effect_02"
	p008e2.display_name = "逆转治疗"
	p008e2.description = "每回合1次，5+X格内的机甲即将回复生命时，可改为使其受到等量伤害。"
	p008e2.mode = _TC.MODE_LISTEN
	p008e2.priority = 30
	p008e2.listen_timing = _TC.HP_CHANGE_BEFORE
	p008e2.listen_action_type = &"hp_change"
	p008e2.once_per_turn_key = &"pilot_008_effect_02"
	p008e2.once_per_turn_max = 1
	p008e2.set_conditions([
		{"op": &"HP_CHANGE_METHOD_IS", "params": {"method": &"restore"}},
		{"op": &"PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE", "params": {"base_range": 5}},
		{"op": &"HP_CHANGE_ACTUAL_RESTORE_ABOVE", "params": {"threshold": 0}},
	])
	p008e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p008e2.set_costs([])
	p008e2.set_actions([
		# 前置：算实际可回复量+机甲HP，写 payload._popup_description 供 CHOOSE_ONE 弹窗显示
		{"type": &"PILOT_008_BUILD_HEAL_REDIRECT_PROMPT", "params": {}},
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "将回复改为受到等量伤害", "actions": [
			{"type": &"REDIRECT_HEAL_TO_DAMAGE", "params": {}}
		]}]}},
	])
	effects[p008e2.effect_id] = p008e2

	# ── pilot_008_effect_03 逆转维修(移除损伤->设置等量损伤) ──
	# 5+X 格内机甲即将移除损伤时，可改为设置等量损伤（安德洛美达选位置）。
	# 无损伤（实际可移除0）不触发；弹窗显示机甲损伤+实际可移除量供确认。
	# 设装备替换移区域损伤也走 damage_change(decrease)，可被本效果逆转。
	var p008e3 := _ActionEffect.new()
	p008e3.effect_id = &"pilot_008_effect_03"
	p008e3.display_name = "逆转维修"
	p008e3.description = "每回合1次，5+X格内的机甲即将移除损伤时，可改为设置等量损伤（由我方指定位置）。"
	p008e3.mode = _TC.MODE_LISTEN
	p008e3.priority = 30
	p008e3.listen_timing = _TC.DAMAGE_CHANGE_BEFORE
	p008e3.listen_action_type = &"damage_change"
	p008e3.once_per_turn_key = &"pilot_008_effect_03"
	p008e3.once_per_turn_max = 1
	p008e3.set_conditions([
		{"op": &"DAMAGE_CHANGE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE", "params": {"base_range": 5}},
		{"op": &"DAMAGE_CHANGE_ACTUAL_REMOVABLE_ABOVE", "params": {"threshold": 0}},
	])
	p008e3.set_target_rules([{"rule": &"NO_TARGET"}])
	p008e3.set_costs([])
	p008e3.set_actions([
		# 前置：算实际可移除量+机甲损伤，写 payload._popup_description 供 CHOOSE_ONE 弹窗显示
		{"type": &"PILOT_008_BUILD_REMOVE_REDIRECT_PROMPT", "params": {}},
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "将移除损伤改为设置等量损伤", "actions": [
			{"type": &"REDIRECT_REMOVE_TO_PLACE_TOKENS", "params": {}}
		]}]}},
	])
	effects[p008e3.effect_id] = p008e3

	# ═══════════════════════════════════════════
	# pilot_006 里昂（帝国 SSR，cost 15, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════

	# ── pilot_006_effect_01 狩猎标记（按钮1，显示）──
	# 每轮 ROUND_START 选1台其他机甲为本轮狩猎目标（替换上一轮标记，旧标签永久失效不恢复）。
	# 首轮/无上轮目标直接设置；还是这台则不改变、不失效。
	var p006e1 := _ActionEffect.new()
	p006e1.effect_id = &"pilot_006_effect_01"
	p006e1.display_name = "狩猎标记"
	p006e1.description = "每轮开始选1台其他机甲为本轮狩猎目标。目标被攻击时攻击方抽1张行动牌，若为攻击牌则对该目标使用此牌不计回合攻击数。"
	p006e1.mode = _TC.MODE_LISTEN
	p006e1.priority = 10
	p006e1.listen_timing = _TC.ROUND_START
	p006e1.listen_action_type = &"turn"
	p006e1.set_conditions([{"op": &"HAS_OTHER_MECH_ON_FIELD"}])
	p006e1.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	p006e1.set_costs([])
	p006e1.set_actions([{
		"type": &"SET_ROUND_MARKED_TARGET",
		"params": {}
	}])
	effects[p006e1.effect_id] = p006e1

	# ── pilot_006_effect_02 狩猎追击（隐藏被动，描述合并到按钮1 hover）──
	# 狩猎目标被攻击时（ATTACK_PRE），攻击方立即抽1张行动牌，
	# 若为攻击牌则打 hunting 标签（不计回合攻击数，绑定本轮标记机甲）。
	# 用 CardInstance tag 系统（同瑟尔基尔，一张牌可多标签）。owner_pid=里昂拥有者。
	# 标签失效语义：标记更换机甲后旧标签永久失效（不恢复）。
	# 隐藏：equipment_panel 跳过此 effect 不显示按钮（描述合并到按钮1）。
	# 问题3：触发时弹窗询问里昂拥有者是否发动（CHOOSE_ONE optional，显示效果说明）。
	# 取消=不发动（不抽牌）；确认=抽牌+打标签。AI 拥有者自动选首项（发动）。
	var p006e2 := _ActionEffect.new()
	p006e2.effect_id = &"pilot_006_effect_02"
	p006e2.display_name = "狩猎追击"
	p006e2.description = "狩猎目标被攻击时，攻击方抽1张行动牌，若为攻击牌则对该目标使用此牌不计回合攻击数。"
	p006e2.mode = _TC.MODE_LISTEN
	p006e2.priority = 20
	p006e2.listen_timing = _TC.ATTACK_PRE
	p006e2.listen_action_type = &"attack"
	p006e2.set_conditions([
		{"op": &"ATTACK_TARGET_HAS_SOURCE_MARK"},
		{"op": &"ATTACKER_ALIVE"},
	])
	p006e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p006e2.set_costs([])
	p006e2.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "发动狩猎追击（抽1张行动牌，若为攻击牌则对该目标使用不计攻击数）",
				"actions": [{
					"type": &"DRAW_ACTION_AND_TAG_IF_ATTACK",
					"params": {}
				}]
			}]
		}
	}])
	effects[p006e2.effect_id] = p006e2

	# ── pilot_006_effect_03 战后逼迫（按钮2，显示，阻塞式 ATTACK_SETTLE priority 30）──
	# 我方攻击结算后，选5格内其他机甲，其立即使用1张攻击牌或受到4伤害。无每回合次数限制：
	# 原文"我方攻击结算后"无次数限制，每次我方攻击(含闪击/反击额外攻击)结算后均可触发。
	# priority 30：高于反击 effect2(20)与闪击 effect2(10)，先于额外攻击 spawn 弹窗，完成后按优先级续跑额外攻击。
	# 选机甲（CHOOSE_OTHER_MECH + 5格内）-> 被选机甲二选一（chooser=被选机甲，不可取消）：
	#   立即使用1张攻击牌（MECH_HAS_USABLE_ATTACK_CARD 置灰：无真实攻击牌或攻击牌不可用）/ 受到4伤害。
	# 被选机甲用攻击牌：source_action_id 非空不计回合攻击数，任选范围内目标。
	var p006e3 := _ActionEffect.new()
	p006e3.effect_id = &"pilot_006_effect_03"
	p006e3.display_name = "战后逼迫"
	p006e3.description = "我方攻击结算后，选5格内其他机甲，其立即使用1张攻击牌或受到4伤害。"
	p006e3.mode = _TC.MODE_LISTEN
	p006e3.priority = 30
	p006e3.listen_timing = _TC.ATTACK_SETTLE
	p006e3.listen_action_type = &"attack"
	p006e3.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 5}},
	])
	p006e3.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH", "force_select": true},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 5, "metric": &"hex_distance"}},
	])
	p006e3.set_costs([])
	p006e3.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": false,
			"chooser_mech_id": "$payload.target_id",
			"options": [
				{"label": "立即使用1张攻击牌", "condition": {"op": &"MECH_HAS_USABLE_ATTACK_CARD"}, "actions": [
					{"type": &"PILOT_006_FORCE_USE_ATTACK", "params": {"target_mech_id": "$payload.target_id"}}
				]},
				{"label": "受到4伤害", "actions": [
					{"type": &"PILOT_006_DEAL_4_DAMAGE", "params": {"amount": 4}}
				]}
			]
		}
	}])
	effects[p006e3.effect_id] = p006e3

	# ═══════════════════════════════════════════
	# pilot_007 珀修斯（秩序 SSR，cost 15, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════

	# ── pilot_007_effect_01 反夺攻击牌 ──
	# 指定我方为目标的实体攻击牌「使用结算后」(USE_ACTION_SETTLE)，可从弃牌堆回收该牌到手牌，
	# 再弹窗询问是否立即使用（不可用=范围内无目标则置灰跳过；立即使用不消耗回合攻击数）。
	# 裁定：当作转化/飞弹不触发（实体攻击牌）；攻击未命中仍可夺；USE_ACTION_SETTLE 每牌仅一次
	# （阿克罗姆双重生效也只夺1张）；无每回合次数限制。回收=从弃牌堆取出（同 pilot_008 维修回收）。
	var p007e1 := _ActionEffect.new()
	p007e1.effect_id = &"pilot_007_effect_01"
	p007e1.display_name = "反夺攻击牌"
	p007e1.description = "指定我方为目标的实体攻击牌结算后，可从弃牌堆获得该牌并可立即使用（不消耗攻击数）。"
	p007e1.mode = _TC.MODE_LISTEN
	p007e1.priority = 30
	p007e1.listen_timing = _TC.USE_ACTION_SETTLE
	p007e1.listen_action_type = &"use_action_card"
	p007e1.set_conditions([
		{"op": &"USED_ATTACK_TARGETED_SELF"},
		{"op": &"ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"ATTACK_SOURCE_ACTION_CARD_TYPE_IS", "params": {"card_type": &"攻击"}},
	])
	p007e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p007e1.set_costs([])
	# 单个 CHOOSE_ONE（optional）双选项：①「获得并立即使用」（condition PILOT_007_CLAIMED_CARD_USABLE：
	# 机甲可攻击+某武器射程内有目标；回收牌进手牌后立即 use_action_card，不消耗攻击数）
	# ②「获得此攻击牌」（仅回收）。不可用（无射程内目标）则①置灰不可选；optional 允许放弃。
	# 用单个 CHOOSE_ONE 而非两个顶层 CHOOSE_ONE：两者共享 payload.chosen_option_index，
	# 第二个会沿用首个的已选索引直接执行 option[0]（不弹窗、不复检 condition）。
	# attack 子动作选目标后把 target_id/target_ids 回传到父 use_action_card record（attack_action
	# _propagate_targets_to_parent_use_action），USE_ACTION_SETTLE payload 携带之，USED_ATTACK_TARGETED_SELF 据此判定。
	p007e1.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "options": [
				{
					"label": "获得并立即使用此牌",
					"condition": [{"op": &"PILOT_007_CLAIMED_CARD_USABLE"}],
					"actions": [
						{"type": &"CLAIM_RESOLVED_ATTACK_SOURCE_CARD", "params": {}},
						{"type": &"EXECUTE_USE_ACTION_CARD", "params": {
							"card_instance_id": "$payload.card_instance_id",
							"mech_id": "$binding_context.mech_id",
							"player_id": "$binding_context.player_id",
							"target_count": 1
						}}
					]
				},
				{
					"label": "获得此攻击牌",
					"actions": [
						{"type": &"CLAIM_RESOLVED_ATTACK_SOURCE_CARD", "params": {}}
					]
				}
			]}
		},
	])
	effects[p007e1.effect_id] = p007e1

	# ── pilot_007_effect_02 类型破绽 ──
	# 我方用实体攻击牌攻击时(ATTACK_PRE priority30)，查看目标所持行动牌，X=缺失类型数(攻击/迎击/辅助)，
	# 弃目标 X+1 张（明牌选弃，须选 X+1 张/不足全选/可只确认无取消键），我方抽 X+1 张。
	# 裁定：闪击额外攻击可触发（来源攻击牌）；反击额外攻击不触发（来源是迎击牌）。
	# 无每回合次数限制；仅主目标（双连后续）。EXECUTE_DISCARD 的 count 取 $runtime.pilot_007_flaw_count
	# （PILOT_007_COMPUTE_X 算 X+1 写入 payload）；EXECUTE_GAIN_CARD 抽同数。
	var p007e2 := _ActionEffect.new()
	p007e2.effect_id = &"pilot_007_effect_02"
	p007e2.display_name = "类型破绽"
	p007e2.description = "我方用攻击牌攻击时，查看目标行动牌，按缺失类型数X弃目标X+1张、我方抽X+1。"
	p007e2.mode = _TC.MODE_LISTEN
	p007e2.priority = 30
	p007e2.listen_timing = _TC.ATTACK_PRE
	p007e2.listen_action_type = &"attack"
	p007e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"ATTACK_SOURCE_ACTION_CARD_TYPE_IS", "params": {"card_type": &"攻击"}},
		{"op": &"ATTACK_HAS_TARGET"},
	])
	p007e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p007e2.set_costs([])
	p007e2.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "options": [{"label": "查看并弃置目标行动牌", "actions": [
				# 先算 X+1 存 payload.pilot_007_flaw_count；再弃目标 X+1 张（明牌选弃，无取消键）；
				# 再我方抽 X+1。from_target=true 把 discard 目标锁定为攻击目标，choose=true 走弃牌选择 UI。
				{"type": &"PILOT_007_COMPUTE_X", "params": {}},
				{"type": &"EXECUTE_DISCARD", "params": {
					"from_target": true,
					"choose": true,
					"face_up": true,
					"no_cancel": true,
					"count": "$runtime.pilot_007_flaw_count"
				}},
				{"type": &"EXECUTE_GAIN_CARD", "params": {
					"count": "$runtime.pilot_007_flaw_count",
					"from_zone": &"action_deck"
				}}
			]}]}
		},
	])
	effects[p007e2.effect_id] = p007e2

	# ═══════════════════════════════════════════
	# pilot_009 美杜莎（混乱 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_009_effect_01 蛇发支配 ──
	# 我方回合1次：5格内选其他机甲 -> 展示其行动牌(可拖拽浮窗,只弹给美杜莎) ->
	# 弹窗① 美杜莎弃1张自己行动牌(记录类型,可取消=中止) -> 弹窗② 强制二选一:
	#   使用 -> 授予该类型控制(非排他,本回合,目标新抽同类型也受控)+ 显示「美杜莎操控」按钮;
	#   立即弃置 -> 弃目标当前全部该类型牌(不授控制,终结;后续新牌不管)。
	# 控制牌接入:主动牌(攻击/可主动辅助)点按钮使用;被动牌(迎击/掩护/推进)在各自触发窗口
	# 作为可用项列出、标注「(来自XX)」,非排他(目标也能用,先到先得)。
	var p009e1 := _ActionEffect.new()
	p009e1.effect_id = &"pilot_009_effect_01"
	p009e1.display_name = "蛇发支配"
	p009e1.description = "我方回合1次，5格内选目标展示其行动牌，弃1张自己行动牌记录类型，这回合可使用或立即弃置目标该类型行动牌。"
	p009e1.mode = _TC.MODE_DIRECT
	p009e1.priority = 10
	p009e1.once_per_turn_key = &"pilot_009_effect_01"
	p009e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		# 注：不放 HAS_ACTION_CARD_IN_HAND。弹窗①的 PILOT_009_PAY_AND_RECORD_TYPE 分支
		# 内 p9_can_pay（TimingEngine）已在“选完目标后、弹弃牌窗前”校验美杜莎手牌并兜底中止；
		# 若放在 set_conditions，支付弃牌后 _execute_effect 重跑（pay 续跑/CHOOSE_ONE 续跑均经
		# _execute_effect）会因手牌已空而 conditions_not_met 静默跳过，二选一永不弹出。
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 5}},
	])
	p009e1.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 5, "metric": &"hex_distance"}},
	])
	p009e1.set_costs([])
	p009e1.set_actions([
		# 弹窗①:展示目标行动牌(非阻塞浮窗,只弹给美杜莎)+ 列美杜莎行动牌选1弃(记录类型,可取消=中止)
		{"type": &"PILOT_009_PAY_AND_RECORD_TYPE", "params": {"optional": true}},
		# 弹窗②:强制二选一(不可取消) -- 使用授控制 / 立即弃置目标当前全部该类型牌
		{"type": &"CHOOSE_ONE", "params": {"optional": false, "options": [
			{"label": "这回合可以使用", "actions": [
				{"type": &"GRANT_TEMP_CARD_CONTROL", "params": {"card_type": "$runtime.pilot_009_recorded_type"}},
			]},
			{"label": "立即弃置", "actions": [
				{"type": &"PILOT_009_DISCARD_ALL_CONTROLLED_TYPE", "params": {"card_type": "$runtime.pilot_009_recorded_type"}},
			]},
		]}},
	])
	effects[p009e1.effect_id] = p009e1

	# ═══════════════════════════════════════════
	# pilot_001 阿克罗姆（联邦 SSR，cost 15, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════

	# ── pilot_001_effect_01a 双重生效·确认 ──
	# LISTEN USE_ACTION_BEFORE：我方使用非迎击行动牌时弹窗询问是否双重生效。
	# 确认 -> 消耗每回合1次 + 标记 executed（供 01b requires_effect 判定）；
	# 取消 -> 不消耗（CHOOSE_ONE optional 取消路径不重跑 _execute_effect，不标记 executed/once_per_turn）。
	# 迎击牌排除（一次攻击只能被响应一次）；repeat_depth 防递归。
	var p001e1a := _ActionEffect.new()
	p001e1a.effect_id = &"pilot_001_effect_01a"
	p001e1a.display_name = "双重生效·确认"
	p001e1a.description = "每回合第1张使用的非迎击行动牌，可选择使其效果再生效1次。"
	p001e1a.mode = _TC.MODE_LISTEN
	p001e1a.priority = 10
	p001e1a.listen_timing = _TC.USE_ACTION_BEFORE
	p001e1a.listen_action_type = &"use_action_card"
	p001e1a.once_per_turn_key = &"pilot_001_effect_01"
	p001e1a.once_per_turn_max = 1
	p001e1a.set_conditions([
		{"op": &"USED_CARD_EXECUTOR_IS_SELF"},
		{"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"ACTION_CARD_IS_NOT_COUNTER"},
		{"op": &"PAYLOAD_REPEAT_DEPTH_BELOW", "params": {"max_depth": 1}},
	])
	p001e1a.set_target_rules([{"rule": &"NO_TARGET"}])
	p001e1a.set_costs([])
	p001e1a.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "使该行动牌的效果再生效1次", "actions": [
			{"type": &"SET_ACTION_RECORD_FLAG", "params": {"flag": &"pilot_001_double_active", "value": true}}
		]}]}
	}])
	effects[p001e1a.effect_id] = p001e1a

	# ── pilot_001_effect_01b 双重生效·重跑 ──
	# LISTEN USE_ACTION_AFTER + requires_effect=01a：01a 确认过的本 use_action_card，
	# 首次效果链（DIRECT + 其产生的 attack 子动作 + 绑定的 LISTEN 效果2）全部结算完成后自动重跑 DIRECT 效果链。
	# 复用 use_action_card 上下文（REPEAT 内 payload.duplicate: card_instance_id/player_id/mech_id/attack_action_id），
	# 目标/武器由新 attack 子动作重新选择；第2次 attack passive（REPEAT 不走 settle，不计回合攻击数）；不重发 USE_ACTION_* 时点。
	var p001e1b := _ActionEffect.new()
	p001e1b.effect_id = &"pilot_001_effect_01b"
	p001e1b.display_name = "双重生效·重跑"
	p001e1b.description = "首次效果结算完成后，自动将该牌直接执行的效果再执行1次。"
	p001e1b.mode = _TC.MODE_LISTEN
	p001e1b.priority = 10
	p001e1b.listen_timing = _TC.USE_ACTION_AFTER
	p001e1b.listen_action_type = &"use_action_card"
	p001e1b.requires_effect = &"pilot_001_effect_01a"
	p001e1b.set_conditions([
		{"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"ACTION_CARD_IS_NOT_COUNTER"},
		{"op": &"PAYLOAD_REPEAT_DEPTH_BELOW", "params": {"max_depth": 1}},
	])
	p001e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p001e1b.set_costs([])
	p001e1b.set_actions([{"type": &"REPEAT_USED_ACTION_EFFECT_CHAIN", "params": {}}])
	effects[p001e1b.effect_id] = p001e1b

	# ═══════════════════════════════════════════
	# pilot_011 迪恩（联邦 SR，cost 11, attack_limit 1, action_card_limit 4）
	# 权威拆解：new_logic/机师牌效果逻辑拆解_SR_修订版_011-013.txt
	# ═══════════════════════════════════════════

	# ── pilot_011_effect_01 迪恩--响应（当作疾行/反击转化）──
	# AVAILABILITY ATTACK_AT：迪恩被攻击时，每回合1次（与effect_02共享 pilot_011_effect_01 计数）。
	# 选择转化使用的2张行动牌（cost 移到 temp_zone 不触发时点），选中后弹二选一：当作疾行/反击
	# （optional=false 不能取消）。转化时立即回复4动力，疾行完整移动链/反击完整链结算后抽1张行动牌。
	# 顺序：选中"迪恩--响应" -> response_discard 选2张转化牌 -> _pay_costs（temp_zone）-> _execute_actions
	# -> CHOOSE_ONE 二选一（疾行/反击）-> 执行对应分支（回复4 -> RESPOND_ATTACK -> 移动 -> 抽1）。
	# availability_condition=AVAIL_RESPOND_ATTACK（迪恩=攻击目标）+ 锁封锁；_check_availability 末尾
	# fall-through 评估 set_conditions：HAS_ACTION_CARD_IN_HAND(2) + ATTACK_NOT_RESPONDED。
	var p011e1 := _ActionEffect.new()
	p011e1.effect_id = &"pilot_011_effect_01"
	p011e1.display_name = "迪恩--响应"
	p011e1.description = "每回合1次，选择转化使用的2张行动牌，当作疾行/反击之一响应攻击；转化时立即回复4动力，执行结算后抽1张行动牌。"
	p011e1.mode = _TC.MODE_AVAILABILITY
	p011e1.priority = 10
	p011e1.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	p011e1.availability_priority = 5
	p011e1.listen_timing = _TC.ATTACK_AT
	p011e1.listen_action_type = &"attack"
	p011e1.once_per_turn_key = &"pilot_011_effect_01"
	p011e1.once_per_turn_max = 1
	p011e1.set_conditions([
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}},
		{"op": &"ATTACK_NOT_RESPONDED"},
	])
	p011e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p011e1.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "params": {"reason": &"pilot_conversion_cost", "exact_count": true, "to_temp_zone": true, "no_cancel": true, "label": "选择转化使用的2张行动牌"}},
	])
	p011e1.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": false, "options": [
			{"label": "当作疾行", "actions": [
				{"type": &"RESTORE_POWER", "params": {"mech_id": "$binding_context.mech_id", "amount": 4, "method": &"restore"}},
				{"type": &"RESPOND_ATTACK", "params": {}},
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"use_current_power": true, "loop_until_cancel": true}},
				{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1, "player_id": "$binding_context.player_id", "reason": &"pilot_011_after_conversion"}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
			{"label": "当作反击", "actions": [
				{"type": &"RESTORE_POWER", "params": {"mech_id": "$binding_context.mech_id", "amount": 4, "method": &"restore"}},
				{"type": &"RESPOND_ATTACK", "params": {}},
				{"type": &"REGISTER_LISTEN", "params": {
					"timing": _TC.ATTACK_SETTLE,
					"listen_action_id": "$payload.attack_action_id",
					"listen_effect_id": &"pilot_011_counter_strike",
				}},
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"power_fraction": 0.5, "loop_until_cancel": true}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
		]}},
	])
	effects[p011e1.effect_id] = p011e1

	# ── pilot_011_counter_strike 反击效果2（迪恩虚拟反击的反击攻击）──
	# LISTEN ATTACK_SETTLE priority20（与 counter_effect2 同优先级，先于闪击 effect2 等）。
	# 由 01b 的 REGISTER_LISTEN 注册为临时监听器，绑定原攻击 action_id（仅该攻击 SETTLE 触发）。
	# 无 requires_effect（迪恩反击非出牌触发，01b 转化时已提交）。binding_context 由 REGISTER_LISTEN
	# 派生 responder_mech_id/player_id/card_id，供 EXECUTE_ATTACK counter_strike 取反击发动方。
	# 动作链：EXECUTE_ATTACK(counter_strike,范围内任选目标) -> EXECUTE_GAIN_CARD(1)（_seq 续跑，反击攻击结算后抽牌）。
	var p011cs := _ActionEffect.new()
	p011cs.effect_id = &"pilot_011_counter_strike"
	p011cs.display_name = "迪恩·反击攻击"
	p011cs.description = "当作反击转化后，监听原攻击结算时点发动反击攻击；反击攻击结算后抽1张行动牌。"
	p011cs.mode = _TC.MODE_LISTEN
	p011cs.priority = 20
	p011cs.listen_timing = _TC.ATTACK_SETTLE
	p011cs.listen_action_type = &"attack"
	p011cs.set_conditions([{"op": &"ALWAYS"}])
	p011cs.set_target_rules([{"rule": &"NO_TARGET"}])
	p011cs.set_costs([])
	p011cs.set_actions([
		{"type": &"EXECUTE_ATTACK", "params": {"target_count": 1, "counter_strike": true}},
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1, "player_id": "$binding_context.player_id", "reason": &"pilot_011_after_counter_strike"}},
	])
	effects[p011cs.effect_id] = p011cs

	# ── pilot_011_effect_02 迪恩--挡攻（替相邻友军响应 + 转化）──
	# AVAILABILITY ATTACK_AT（空 availability_condition，走 set_conditions fall-through：迪恩非攻击目标）。
	# 相邻其他机甲被攻击 + 迪恩在攻击范围内 + 非迪恩自己攻击 + 未响应 + 持≥2行动牌 时可用。
	# 每回合1次（与 effect_01 共享 pilot_011_effect_01 转化额度）。选择转化使用的2张行动牌
	# （temp_zone 不触发时点），弹二选一（当作疾行/反击，optional=false 不能取消），执行前先
	# REDIRECT_ATTACK_TARGET_TO_SELF 将攻击目标改为迪恩自身（保护被攻击友军，回退 PRE 重 fire）。
	# 顺序：选中 effect_02 -> response_discard 选2张转化牌 -> _pay_costs -> REDIRECT -> 二选一 -> 分支链。
	var p011e2 := _ActionEffect.new()
	p011e2.effect_id = &"pilot_011_effect_02"
	p011e2.display_name = "迪恩--挡攻"
	p011e2.description = "每回合1次，相邻其他机甲被攻击且自身在攻击范围内时，选择转化使用的2张行动牌，当作疾行/反击之一响应并将攻击目标改为自身；回复4动力，执行结算后抽1张行动牌。"
	p011e2.mode = _TC.MODE_AVAILABILITY
	p011e2.priority = 20
	p011e2.availability_condition = &""  # 空：迪恩非攻击目标，不走 AVAIL_RESPOND_ATTACK，靠 set_conditions
	p011e2.availability_priority = 10
	p011e2.listen_timing = _TC.ATTACK_AT
	p011e2.listen_action_type = &"attack"
	p011e2.once_per_turn_key = &"pilot_011_effect_01"  # 与 effect_01 共享每回合1次转化额度
	p011e2.once_per_turn_max = 1
	p011e2.set_conditions([
		{"op": &"ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET"},
		{"op": &"SELF_MECH_IN_CURRENT_ATTACK_RANGE"},
		{"op": &"ATTACKER_IS_NOT_SELF_MECH"},
		{"op": &"ATTACK_NOT_RESPONDED"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}},
	])
	p011e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p011e2.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "params": {"reason": &"pilot_conversion_cost", "exact_count": true, "to_temp_zone": true, "no_cancel": true, "label": "选择转化使用的2张行动牌"}},
	])
	p011e2.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": false, "options": [
			{"label": "当作疾行", "actions": [
				{"type": &"REDIRECT_ATTACK_TARGET_TO_SELF", "params": {"protect_target_id": "$payload.target_id"}},
				{"type": &"RESTORE_POWER", "params": {"mech_id": "$binding_context.mech_id", "amount": 4, "method": &"restore"}},
				{"type": &"RESPOND_ATTACK", "params": {}},
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"use_current_power": true, "loop_until_cancel": true}},
				{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1, "player_id": "$binding_context.player_id", "reason": &"pilot_011_after_conversion"}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
			{"label": "当作反击", "actions": [
				{"type": &"REDIRECT_ATTACK_TARGET_TO_SELF", "params": {"protect_target_id": "$payload.target_id"}},
				{"type": &"RESTORE_POWER", "params": {"mech_id": "$binding_context.mech_id", "amount": 4, "method": &"restore"}},
				{"type": &"RESPOND_ATTACK", "params": {}},
				{"type": &"REGISTER_LISTEN", "params": {
					"timing": _TC.ATTACK_SETTLE,
					"listen_action_id": "$payload.attack_action_id",
					"listen_effect_id": &"pilot_011_counter_strike",
				}},
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"power_fraction": 0.5, "loop_until_cancel": true}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
		]}},
	])
	effects[p011e2.effect_id] = p011e2

	# ═══════════════════════════════════════════
	# pilot_012 玛丽尔（联邦 SR，cost 10, attack_limit 1, action_card_limit 5）
	# 权威拆解：new_logic/机师牌效果逻辑拆解_SR_修订版_011-013.txt
	# ═══════════════════════════════════════════

	# ── pilot_012_effect_01 夺牌压制 ──
	# LISTEN ATTACK_PRE priority 30（每玩家回合1次，seat 制 turn_number）。玛丽尔攻击时可选：对每个机甲攻击目标，
	# 若其持有行动牌则偷1张（玛丽尔玩家选暗牌），并使其当前动力-3（clamp[0,max]，保留 temp_power，不降上限）。
	# 多目标只消耗1次回合额度（e01 在主攻击 PRE 只发1次，FOR_EACH_TARGET 遍历全部目标）。
	# SET_ACTION_RECORD_FLAG 写 flag（pilot_012_effect_01_fired）到 attack.record["_effect_flags"]，
	# fork 深拷贝继承，供 effect_02 在各 fork AFTER 判定 e01 是否发动 + 命中奖励触发。
	var p012e1 := _ActionEffect.new()
	p012e1.effect_id = &"pilot_012_effect_01"
	p012e1.display_name = "玛丽尔·夺牌压制"
	p012e1.description = "每回合1次，攻击时对每个机甲目标偷1张行动牌并使其当前动力-3。"
	p012e1.mode = _TC.MODE_LISTEN
	p012e1.priority = 30
	p012e1.listen_timing = _TC.ATTACK_PRE
	p012e1.listen_action_type = &"attack"
	p012e1.once_per_turn_key = &"pilot_012_effect_01"
	p012e1.once_per_turn_max = 1
	p012e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HAS_OTHER_MECH_TARGET"},
	])
	p012e1.set_target_rules([{
		"rule": &"ALL_CURRENT_ATTACK_MECH_TARGETS",
		"params": {"exclude_attacker": true, "preserve_attack_target_order": true, "allowed_target_kinds": [&"MECH"]},
	}])
	p012e1.set_costs([])
	p012e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "对每个机甲目标偷1张行动牌并使其当前动力-3",
				"actions": [
					{"type": &"FOR_EACH_TARGET", "params": {
						"targets": "$selected_targets",
						"execution_mode": &"SERIAL",
						"preserve_order": true,
						"current_target_variable": &"current_target",
						"actions": [
							{"type": &"CONDITIONAL_ACTIONS", "params": {
								"conditions": [{"op": &"TARGET_HAS_ACTION_CARD", "params": {"target_id": "$current_target.mech_id", "count": 1}}],
								"if_true_actions": [{"type": &"EXECUTE_STEAL", "params": {
									"from_target_id": "$current_target.mech_id",
									"to_target_id": "$binding_context.mech_id",
									"card_kind": &"ACTION",
									"count": 1,
									"choose": true,
									"chooser_id": "$binding_context.player_id",
									"optional": false,
									"reason": &"pilot_012_steal",
								}}],
								"if_false_actions": [],
							}},
							{"type": &"MODIFY_MECH_POWER", "params": {
								"target_id": "$current_target.mech_id",
								"delta": -3,
								"value_scope": &"CURRENT",
								"method": &"decrease",
								"min_value": 0,
								"reason": &"pilot_012_power_drain",
							}},
						],
					}},
					{"type": &"SET_ACTION_RECORD_FLAG", "params": {
						"action_id": "$payload.action_id",
						"flag": &"pilot_012_effect_01_fired",
						"value": true,
						"data": {"limit_counted_per_attack": true},
					}},
				],
			}],
		},
	}])
	effects[p012e1.effect_id] = p012e1

	# ── pilot_012_effect_02 命中奖励 ──
	# LISTEN ATTACK_AFTER。夺牌压制(e01)影响的目标命中时，玛丽尔可选：对该命中目标抽1张行动牌并回复3动力。
	# e01 是否发动由 flag（pilot_012_effect_01_fired，e01 SET_ACTION_RECORD_FLAG 写入 attack.record["_effect_flags"]）
	# 判定；fork 深拷贝 record 故双连每个复制攻击的 AFTER 都能读 flag 触发（每个命中目标各抽1+回3，逐个可选弹窗）。
	# RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT：flag 已设 + 命中；ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG 收集命中目标。
	# FOR_EACH_TARGET inner CHOOSE_ONE：逐命中目标串行弹窗（per-target chosen/executed，_flat_item_choose_one）。
	var p012e2 := _ActionEffect.new()
	p012e2.effect_id = &"pilot_012_effect_02"
	p012e2.display_name = "玛丽尔·命中奖励"
	p012e2.description = "夺牌压制影响的目标命中时，可选抽1张行动牌并回复3动力。"
	p012e2.mode = _TC.MODE_LISTEN
	p012e2.priority = 10
	p012e2.listen_timing = _TC.ATTACK_AFTER
	p012e2.listen_action_type = &"attack"
	# 不用 requires_effect（它查同 action_id，双连 fork 子动作 id 不同 -> e02 在 fork AFTER 永不触发）。
	# 改靠 RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT / ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG 读 e01 写的
	# flag（pilot_012_effect_01_fired，fork 深拷贝继承）判断 e01 是否发动 + 命中。
	p012e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT", "params": {"flag": &"pilot_012_effect_01_fired", "target_ids_path": &"data.affected_target_ids"}},
	])
	p012e2.set_target_rules([{
		"rule": &"ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG",
		"params": {"flag": &"pilot_012_effect_01_fired", "target_ids_path": &"data.affected_target_ids", "allowed_target_kinds": [&"MECH"], "preserve_attack_target_order": true},
	}])
	p012e2.set_costs([])
	p012e2.set_actions([{
		"type": &"FOR_EACH_TARGET", "params": {
			"targets": "$selected_targets",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"CHOOSE_ONE", "params": {
					"optional": true,
					"title": "玛丽尔：命中奖励",
					"description": "当前目标命中，是否抽1张行动牌并回复3动力？",
					"options": [{
						"label": "抽1张行动牌并回复3动力",
						"actions": [
							{"type": &"EXECUTE_GAIN_CARD", "params": {
								"from_zone": &"action_deck",
								"card_kind": &"action",
								"player_id": "$binding_context.player_id",
								"count": 1,
								"reason": &"pilot_012_hit_reward",
							}},
							{"type": &"RESTORE_POWER", "params": {
								"mech_id": "$binding_context.mech_id",
								"amount": 3,
								"reason": &"pilot_012_hit_reward",
							}},
						],
					}],
				}},
			],
		},
	}])
	effects[p012e2.effect_id] = p012e2

	# ═══════════════════════════════════════════
	# pilot_013 巴托洛夫（联邦 SR，cost 10, attack_limit 1, action_card_limit 5）
	# 权威拆解：new_logic/机师牌效果逻辑拆解_SR_修订版_011-013.txt
	# ═══════════════════════════════════════════

	# ── pilot_013_effect_01 非攻击伤害免疫 ──
	# LISTEN HP_CHANGE_BEFORE。巴托洛夫所属机甲即将因非攻击来源受到生命减少时，取消该次生命变动。
	# 攻击动作步骤7产生的攻击伤害（reason=attack_damage / created_by_attack_damage_step）正常生效。
	# 不阻止损伤设置。scope=CURRENT_ACTION 仅取消当前 hp_change，不取消来源效果其他动作。
	var p013e1 := _ActionEffect.new()
	p013e1.effect_id = &"pilot_013_effect_01"
	p013e1.display_name = "巴托洛夫·非攻击伤害免疫"
	p013e1.description = "不会受到攻击产生伤害之外的其他伤害；不免疫损伤。"
	p013e1.mode = _TC.MODE_LISTEN
	p013e1.priority = 30
	p013e1.listen_timing = _TC.HP_CHANGE_BEFORE
	p013e1.listen_action_type = &"hp_change"
	p013e1.set_conditions([
		{"op": &"HP_CHANGE_TARGET_IS_SELF"},
		{"op": &"HP_CHANGE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE"},
	])
	p013e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p013e1.set_costs([])
	p013e1.set_actions([{
		"type": &"CANCEL_PARENT_ACTION",
		"params": {
			"scope": &"CURRENT_ACTION",
			"reason": &"pilot_013_non_attack_damage_immunity",
			"preserve_source_parent_action": true,
		},
	}])
	effects[p013e1.effect_id] = p013e1

	# ── pilot_013_effect_02a 同归压制 ──
	# LISTEN ATTACK_PRE，每回合1次。巴托洛夫攻击时可选使自身及全部机甲目标护甲/动力上限与当前值各-4。
	# 上限降低持续到巴托洛夫玩家下个回合开始前（UNTIL_NEXT_OWNER_TURN）；当前值-4不恢复。
	# SET_ACTION_RECORD_FLAG 最小闭环 no-op：effect_02b 用 requires_effect + TargetChecker 重算命中目标。
	var p013e2a := _ActionEffect.new()
	p013e2a.effect_id = &"pilot_013_effect_02a"
	p013e2a.display_name = "巴托洛夫·同归压制"
	p013e2a.description = "每回合1次，攻击时使自身及全部机甲目标护甲和动力的上限与当前值各-4；命中目标的攻击伤害+3。"
	p013e2a.mode = _TC.MODE_LISTEN
	p013e2a.priority = 20
	p013e2a.listen_timing = _TC.ATTACK_PRE
	p013e2a.listen_action_type = &"attack"
	p013e2a.once_per_turn_key = &"pilot_013_effect_02"
	p013e2a.once_per_turn_max = 1
	p013e2a.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HAS_OTHER_MECH_TARGET"},
	])
	p013e2a.set_target_rules([{
		"rule": &"ALL_CURRENT_ATTACK_MECH_TARGETS",
		"params": {"exclude_attacker": true, "preserve_attack_target_order": true, "allowed_target_kinds": [&"MECH"]},
	}])
	p013e2a.set_costs([])
	p013e2a.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "使我方与全部攻击目标护甲、动力上限及当前值-4",
				"actions": [
					{"type": &"EXECUTE_STAT_MODIFY", "params": {
						"target_id": "$binding_context.mech_id",
						"stat_changes": [
							{"stat_type": &"armor", "max_delta": -4, "current_delta": -4},
							{"stat_type": &"power", "max_delta": -4, "current_delta": -4},
						],
						"method": &"add",
						"apply_max_and_current_atomically": true,
						"clamp_current_min": 0,
						"clamp_current_to_new_max": true,
						"duration": &"UNTIL_NEXT_OWNER_TURN",
						"duration_owner_id": "$binding_context.player_id",
						"source_card_id": "$binding_context.card_instance_id",
						"source_effect_id": &"pilot_013_effect_02a",
						"source_key": &"pilot_013_effect_02_self",
						"restore_current_on_expire": false,
						"remove_max_modifier_on_expire": true,
					}},
					{"type": &"FOR_EACH_TARGET", "params": {
						"targets": "$selected_targets",
						"execution_mode": &"SERIAL",
						"preserve_order": true,
						"current_target_variable": &"current_target",
						"actions": [
							{"type": &"EXECUTE_STAT_MODIFY", "params": {
								"target_id": "$current_target.mech_id",
								"stat_changes": [
									{"stat_type": &"armor", "max_delta": -4, "current_delta": -4},
									{"stat_type": &"power", "max_delta": -4, "current_delta": -4},
								],
								"method": &"add",
								"apply_max_and_current_atomically": true,
								"clamp_current_min": 0,
								"clamp_current_to_new_max": true,
								"duration": &"UNTIL_NEXT_OWNER_TURN",
								"duration_owner_id": "$binding_context.player_id",
								"source_card_id": "$binding_context.card_instance_id",
								"source_effect_id": &"pilot_013_effect_02a",
								"source_key": &"pilot_013_effect_02_target",
								"source_target_id": "$current_target.mech_id",
								"restore_current_on_expire": false,
								"remove_max_modifier_on_expire": true,
							}},
						],
					}},
					{"type": &"SET_ACTION_RECORD_FLAG", "params": {
						"action_id": "$payload.action_id",
						"flag": &"pilot_013_effect_02_fired",
						"value": true,
						"data": {"affected_target_ids": "$selected_targets.mech_ids", "self_mech_id": "$binding_context.mech_id", "limit_counted_per_attack": true},
					}},
				],
			}],
		},
	}])
	effects[p013e2a.effect_id] = p013e2a

	# ── pilot_013_effect_02b 命中伤害追加 ──
	# LISTEN ATTACK_AFTER，requires_effect=pilot_013_effect_02a。对本次攻击命中的机甲目标各+3攻击伤害。
	# 修改 attack.record["damage"]，不另开 DEAL_DAMAGE -> 仍属攻击产生伤害（不被 effect_01 免疫）。
	var p013e2b := _ActionEffect.new()
	p013e2b.effect_id = &"pilot_013_effect_02b"
	p013e2b.display_name = "巴托洛夫·命中伤害追加"
	p013e2b.description = "同归压制影响的每个攻击目标命中时，该目标受到的本次攻击伤害+3。"
	p013e2b.mode = _TC.MODE_LISTEN
	p013e2b.priority = 20
	p013e2b.listen_timing = _TC.ATTACK_AFTER
	p013e2b.listen_action_type = &"attack"
	p013e2b.requires_effect = &"pilot_013_effect_02a"
	p013e2b.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT", "params": {"flag": &"pilot_013_effect_02_fired", "target_ids_path": &"data.affected_target_ids"}},
	])
	p013e2b.set_target_rules([{
		"rule": &"ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG",
		"params": {"flag": &"pilot_013_effect_02_fired", "target_ids_path": &"data.affected_target_ids", "allowed_target_kinds": [&"MECH"], "preserve_attack_target_order": true},
	}])
	p013e2b.set_costs([])
	p013e2b.set_actions([{
		"type": &"FOR_EACH_TARGET",
		"params": {
			"targets": "$selected_targets",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"MODIFY_ATTACK_DAMAGE", "params": {
					"attack_id": "$payload.action_id",
					"target_id": "$current_target.mech_id",
					"delta": 3,
					"min_value": 0,
					"reason": &"pilot_013_hit_damage_bonus",
					"source_card_id": "$binding_context.card_instance_id",
					"source_effect_id": &"pilot_013_effect_02b",
				}},
			],
		},
	}])
	effects[p013e2b.effect_id] = p013e2b

	return effects


# ════════════════════════════════════════════════════════════
# pilot_010 刻托：攻击牌使用计数器（effect_02 视为序列 + effect_03 第4张禁止 共享）
# ════════════════════════════════════════════════════════════
## 存 card.counters["pilot_010_uses_<turn_number>"]，按 turn_number 自动每回合重置（新回合新 key=0）。
## 裁定（歧义4）：牌进临时区即计数（use_action 取消也计）；歧义5：每个活动回合各自重置。


static func get_pilot_010_attack_card_uses(pilot_card, turn_number: int) -> int:
	if pilot_card == null or not "counters" in pilot_card:
		return 0
	return int(pilot_card.counters.get("pilot_010_uses_%d" % turn_number, 0))


static func increment_pilot_010_attack_card_uses(pilot_card, turn_number: int) -> void:
	if pilot_card == null or not "counters" in pilot_card:
		return
	var key := "pilot_010_uses_%d" % turn_number
	pilot_card.counters[key] = int(pilot_card.counters.get(key, 0)) + 1


## pilot_010 effect_03（权限型）：刻托本回合是否还能使用实体攻击牌（已用<3）。
## 非刻托机师返回 true（不限制）。由 use_action_card._step_validate_card 调用。
static func can_pilot_010_use_physical_attack_card(gs, mech_id: StringName) -> bool:
	if gs == null:
		return true
	var mech = gs.mechs.get(mech_id)
	if mech == null:
		return true
	var slot = mech.slots.get(&"pilot")
	if slot == null or slot.equipped_card == null:
		return true
	var pcard = slot.equipped_card
	if pcard.def == null or String(pcard.def.card_id) != "pilot_010_刻托":
		return true  # 不是刻托，不限制
	var uses := get_pilot_010_attack_card_uses(pcard, int(gs.turn_number))
	return uses < 3

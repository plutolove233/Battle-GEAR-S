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
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")
const _GeneratedEventEffects = preload("res://scripts/generated_database/GeneratedEventEffects.gd")
const SLog = preload("res://scripts/services/slog.gd")

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


## ── 通用移动消耗修正索引（效果元数据 move_cost_mod，不绑机师ID） ──
## {card_def_id: [move_cost_mod, ...]}，首次查询时按 _card_effect_map + build_pilot_effects
## 构建并缓存（值拷贝，无效果对象共享；效果定义是静态数据，跨局缓存安全）。
## MapService.resolve_move_cost_params 扫描场上机甲槽位牌查本索引聚合折扣/光环。
static var _pilot_move_mod_index: Dictionary = {}


## 获取全部机师牌的移动消耗修正索引（懒构建+缓存）。
## 供 MapService.resolve_move_cost_params 使用；任何牌效果声明 move_cost_mod 即自动收录。
static func get_pilot_move_mod_index(context = null) -> Dictionary:
	if not _pilot_move_mod_index.is_empty():
		return _pilot_move_mod_index
	if not _initialized and context != null:
		_try_load_map_from_context(context)
	if _card_effect_map.is_empty():
		return {}
	var all_effects: Dictionary = build_pilot_effects()
	for card_def_id: StringName in _card_effect_map:
		for eid: StringName in _card_effect_map[card_def_id]:
			var eff = all_effects.get(eid)
			if eff == null or eff.move_cost_mod.is_empty():
				continue
			var mod_list: Array = _pilot_move_mod_index.get(card_def_id, [])
			mod_list.append(eff.move_cost_mod.duplicate(true))
			_pilot_move_mod_index[card_def_id] = mod_list
	return _pilot_move_mod_index


## 派生值型效果集合（不注册监听器，由 MechState 实时重算）
static func is_pilot_derived_effect(effect_id: StringName) -> bool:
	return effect_id in [
		&"pilot_002_effect_02",  # 莱比尔·联邦机甲护甲+4（实时重算）
		&"pilot_005_effect_02",  # 肯特·帝国机甲动力+4（实时重算）
		&"pilot_029_effect_01",  # 克劳德·远程武器范围+1（实时重算，仿狙击装头部）
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
# ═══════════════════════════════════════════
## 塞万提斯 pilot_034 effect_02：记录「对我方造成过伤害的其他机甲」。
## 存 {source_pilot_instance: {mech_id: true, ...}}：每次我方机甲受到生命减少（HP_CHANGE_AFTER
## decrease，来源非空且非自身）时，把伤害来源机甲加入记录集。永久保留，不清除。
## 换机师时 clear_pilot_034_recorded 清除。
static var _pilot_034_recorded: Dictionary = {}


## 记录一台伤害来源机甲。source_pilot=塞万提斯机师牌实例 id；mech_id=来源机甲（排除自身由调用方过滤）。
static func pilot_034_record_source(source_pilot: StringName, mech_id: StringName) -> void:
	if source_pilot == &"" or mech_id == &"":
		return
	var entry: Dictionary = _pilot_034_recorded.get(source_pilot, {})
	entry[String(mech_id)] = true
	_pilot_034_recorded[source_pilot] = entry


## 来源机甲是否已在记录集内（供 ATTACK_TARGET_IN_PILOT_034_RECORDED 条件查询）。
static func pilot_034_is_recorded(source_pilot: StringName, mech_id: StringName) -> bool:
	if source_pilot == &"" or mech_id == &"":
		return false
	var entry: Dictionary = _pilot_034_recorded.get(source_pilot, {})
	return bool(entry.get(String(mech_id), false))


static func clear_pilot_034_recorded(source_pilot: StringName) -> void:
	_pilot_034_recorded.erase(source_pilot)


# ════════════════════════════════════════════════════════════
# pilot_035 库马斯：每轮选1台其他机甲，其抽取行动牌时我方抽1
# ════════════════════════════════════════════════════════════
## 存 { source_pilot_instance: {target: mech_id} }。
## target 每轮 ROUND_START 由 effect_01(reset, priority 20) 清空、effect_02(select, priority 10) 重设；
## 取消选择=不重设 -> 本轮不监听（上轮选择不延续）。换机师清除。
static var _pilot_035_marks: Dictionary = {}


## 设置本轮标记机甲（effect_02 选择确认后）。
static func set_pilot_035_mark(source_pilot_instance: StringName, target_mech_id: StringName) -> void:
	if source_pilot_instance == &"" or target_mech_id == &"":
		return
	_pilot_035_marks[source_pilot_instance] = {"target": target_mech_id}


## 清除本轮标记（effect_01 轮始 reset / 换机师）。
static func clear_pilot_035_mark(source_pilot_instance: StringName) -> void:
	_pilot_035_marks.erase(source_pilot_instance)


## 取本轮标记机甲；未标记返回 &""（取消选择/本轮未选）。
static func get_pilot_035_mark(source_pilot_instance: StringName) -> StringName:
	var entry: Dictionary = _pilot_035_marks.get(source_pilot_instance, {})
	return entry.get("target", &"")


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
		"pilot_034_recorded": _pilot_034_recorded.duplicate(true),
		"pilot_035_marks": _pilot_035_marks.duplicate(true),
		"melee_buff": _melee_buff.duplicate(true),
		"melee_grant_mechs": _melee_grant_mechs.duplicate(true),
	}


static func apply_pilot_static(data: Dictionary) -> void:
	if data.is_empty():
		return
	_pilot_006_marks = data.get("pilot_006_marks", {}).duplicate(true)
	_pilot_009_control = data.get("pilot_009_control", {}).duplicate(true)
	_pilot_002_batches = data.get("pilot_002_batches", {}).duplicate(true)
	_pilot_003_skip = data.get("pilot_003_skip", {}).duplicate(true)
	_pilot_034_recorded = data.get("pilot_034_recorded", {}).duplicate(true)
	_pilot_035_marks = data.get("pilot_035_marks", {}).duplicate(true)
	_melee_buff = data.get("melee_buff", {}).duplicate(true)
	_melee_grant_mechs = data.get("melee_grant_mechs", {}).duplicate(true)


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
	p004e1b.hide_button = true
	p004e1b.merge_desc_into_index = 1
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
	p003e2.hide_button = true
	p003e2.merge_desc_into_index = 1
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
	p008e1b.hide_button = true
	p008e1b.merge_desc_into_index = 1
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
	p006e2.hide_button = true
	p006e2.merge_desc_into_index = 1
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
		"type": &"DRAW_ACTION_AND_TAG_IF_ATTACK",
		"params": {}
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
	# 选机甲前先弹确认窗询问里昂是否发动（通用 confirm_before_target 机制），可取消。
	p006e3.confirm_before_target = true
	p006e3.confirm_label = "发动战后逼迫"
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
					{"type": &"EXECUTE_HP_CHANGE", "params": {
						"value": 4, "method": &"decrease",
						"source_mech_id": "$binding_context.mech_id",
						"reason": &"pilot_006_refused_attack",
					}}
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

	# ── pilot_007_effect_02 类型破绽（双连逐目标） ──
	# 我方用实体攻击牌攻击时(ATTACK_PRE priority30)，查看各目标所持行动牌，X=缺失类型数(攻击/迎击/辅助)，
	# 弃目标 X+1 张（明牌选弃，须选 X+1 张/不足全选/可只确认无取消键），我方抽 X+1 张。
	# 双连（多目标）：按目标选择顺序逐目标执行（主目标在前，fork 目标按选择顺序），每个目标各算
	# X 各弃/抽一次（与玛丽尔 pilot_012 多目标同构：FOR_EACH_TARGET over ALL_CURRENT_ATTACK_MECH_TARGETS）。
	# 裁定：闪击额外攻击可触发（来源攻击牌）；反击额外攻击不触发（来源是迎击牌）。
	# 无每回合次数限制。PILOT_007_COMPUTE_X 按当前目标（$current_target.mech_id）算 X+1 写入
	# payload.pilot_007_flaw_count；EXECUTE_DISCARD 从当前目标弃（target_id=$current_target.mech_id，
	# from_target+choose 明牌选弃 executor=攻击方）；EXECUTE_GAIN_CARD 抽同数。
	var p007e2 := _ActionEffect.new()
	p007e2.effect_id = &"pilot_007_effect_02"
	p007e2.display_name = "类型破绽"
	p007e2.description = "我方用攻击牌攻击时，查看各目标行动牌，按缺失类型数X弃目标X+1张、我方抽X+1。"
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
	p007e2.set_target_rules([{
		"rule": &"ALL_CURRENT_ATTACK_MECH_TARGETS",
		"params": {"exclude_attacker": true, "preserve_attack_target_order": true, "allowed_target_kinds": [&"MECH"]},
	}])
	p007e2.set_costs([])
	p007e2.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "options": [{"label": "查看并弃置各目标行动牌", "actions": [
				# 逐目标串行：先算 X+1 存 payload.pilot_007_flaw_count；再弃当前目标 X+1 张（明牌选弃，
				# 无取消键）；再我方抽 X+1。from_target+target_id=$current_target.mech_id 把 discard 目标
				# 锁定为当前遍历目标，choose=true 走弃牌选择 UI（executor 由 discard 动作反查攻击方）。
				{"type": &"FOR_EACH_TARGET", "params": {
					"targets": "$selected_targets",
					"execution_mode": &"SERIAL",
					"preserve_order": true,
					"current_target_variable": &"current_target",
					"actions": [
						{"type": &"PILOT_007_COMPUTE_X", "params": {"target_id": "$current_target.mech_id"}},
						{"type": &"EXECUTE_DISCARD", "params": {
							"from_target": true,
							"target_id": "$current_target.mech_id",
							"choose": true,
							"face_up": true,
							"no_cancel": true,
							"count": "$runtime.pilot_007_flaw_count"
						}},
						{"type": &"EXECUTE_GAIN_CARD", "params": {
							"count": "$runtime.pilot_007_flaw_count",
							"from_zone": &"action_deck"
						}},
					],
				}},
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
	p001e1b.hide_button = true
	p001e1b.merge_desc_into_index = 1
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
	# LISTEN ATTACK_SETTLE priority30（ATTACK_SETTLE 上「结算后再攻击」类效果统一优先级
	# 对齐：反击额外攻击=30、联合连携攻击=20、闪击再次攻击=10；与 counter_effect2 同级同序）。
	# 由 01b 的 REGISTER_LISTEN 注册为临时监听器，绑定原攻击 action_id（仅该攻击 SETTLE 触发）。
	# 无 requires_effect（迪恩反击非出牌触发，01b 转化时已提交）。binding_context 由 REGISTER_LISTEN
	# 派生 responder_mech_id/player_id/card_id，供 EXECUTE_ATTACK counter_strike 取反击发动方。
	# 动作链：EXECUTE_ATTACK(counter_strike,范围内任选目标) -> EXECUTE_GAIN_CARD(1)（_seq 续跑，反击攻击结算后抽牌）。
	var p011cs := _ActionEffect.new()
	p011cs.effect_id = &"pilot_011_counter_strike"
	p011cs.display_name = "迪恩·反击攻击"
	p011cs.description = "当作反击转化后，监听原攻击结算时点发动反击攻击；反击攻击结算后抽1张行动牌。"
	p011cs.mode = _TC.MODE_LISTEN
	p011cs.priority = 30
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

	# ── pilot_011_effect_02 迪恩--挡攻（转移目标窗口 + 转化响应）──
	# AVAILABILITY ATTACK_AT（availability_condition = AVAIL_TRANSFER_TARGET：迪恩非攻击目标，
	# 进转移目标窗口，而非响应窗口）。
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
	p011e2.availability_condition = _TC.AVAIL_TRANSFER_TARGET  # 转移目标窗口：相邻友军被攻击时可用（非响应窗口）
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
	p012e2.hide_button = true
	p012e2.merge_desc_into_index = 1
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
	# LISTEN ATTACK_PRE priority 30，每回合1次（每玩家回合1次，含他人回合巴托洛夫反击/联合攻击时）。
	# 巴托洛夫攻击时弹窗询问是否发动（显示效果简介）。确认后自身+全部机甲目标护甲/动力-4：
	#   护甲-4（ARMOR_MODIFIER UNTIL_NEXT_OWNER_TURN 到期恢复）、动力上限-4（POWER_CAP_MODIFIER 到期恢复）
	#   +动力当前-4（current_only，上限恢复+下回合 restore_power 回满 => 到期恢复）。
	# 持续到下个巴托洛夫回合开始前（TURN_BEFORE_START 后 _clean_until_next_owner_turn 清理）。
	# SET_ACTION_RECORD_FLAG 写 flag（pilot_013_effect_02_fired）+ affected_target_ids，fork 深拷贝继承，
	# 供 effect_02b 在各 fork AFTER 纯靠 flag 判定（不用 requires_effect，避双连 fork 失效）。
	var p013e2a := _ActionEffect.new()
	p013e2a.effect_id = &"pilot_013_effect_02a"
	p013e2a.display_name = "巴托洛夫·同归压制"
	p013e2a.description = "每回合1次，我方发动攻击时，使我方和攻击目标的护甲和动力-4（持续到下个我方回合开始前），命中产生的伤害+3。"
	p013e2a.mode = _TC.MODE_LISTEN
	p013e2a.priority = 30
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
			"title": "巴托洛夫：同归压制",
			"description": "每回合1次，我方发动攻击时，使我方和攻击目标的护甲和动力-4（持续到下个我方回合开始前），命中产生的伤害+3。是否发动？",
			"options": [{
				"label": "发动同归压制",
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
	# LISTEN ATTACK_AFTER priority 20。对本次攻击命中的机甲目标各+3攻击伤害。
	# 不用 requires_effect（双连 fork 子动作 action_id 不同 -> requires_effect 在 fork AFTER 失效），
	# 纯靠 flag（pilot_013_effect_02_fired，fork 深拷贝继承）+ RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT 判定。
	# 修改 attack.record["damage"]，不另开 DEAL_DAMAGE -> 仍属攻击产生伤害（不被 effect_01 免疫）。
	var p013e2b := _ActionEffect.new()
	p013e2b.effect_id = &"pilot_013_effect_02b"
	p013e2b.display_name = "巴托洛夫·命中伤害追加"
	p013e2b.hide_button = true
	p013e2b.merge_desc_into_index = 2
	p013e2b.description = "同归压制影响的每个攻击目标命中时，该目标受到的本次攻击伤害+3。"
	p013e2b.mode = _TC.MODE_LISTEN
	p013e2b.priority = 20
	p013e2b.listen_timing = _TC.ATTACK_AFTER
	p013e2b.listen_action_type = &"attack"
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

	# ═══════════════════════════════════════════
	# pilot_014 亚伦（联邦 SR，cost 10, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════

	# ── pilot_014_effect_01 机师行动上限+2 ──
	# 我方回合2次（once_per_turn_max=2）：点击按钮 -> PILOT_014_SELECT_TARGET_PILOT_AND_GRANT
	# 弹窗列场上所有机师牌(含自己+所有玩家)+对应行动牌上限数值，选1个确定 -> 对其施加行动牌上限+2。
	# 可取消不计次数（optional，取消路径不 mark once_per_turn）。
	# 状态绑 target_pilot_instance(目标机师牌)+source_pilot_instance(亚伦)+duration_owner_id(亚伦玩家)：
	#   UNTIL_NEXT_OWNER_TURN 到下个亚伦回合开始前(TURN_BEFORE_START 后 _clean_until_next_owner_turn)扣回；
	#   目标/来源机师牌换下或机甲被毁 -> unset_pilot/destroy_mech 调 remove_pilot_014_bonus_for_pilot_instance 扣回；
	#   刻托交换 -> swap_hand_limit_and_attack_count 翻转 current_field(+2 跟随变攻击数+2)，到期按 current_field 扣回。
	# 多次施加独立 status（2次=2个），各自到期/离场扣回。
	var p014e1 := _ActionEffect.new()
	p014e1.effect_id = &"pilot_014_effect_01"
	p014e1.display_name = "机师行动上限+2"
	p014e1.description = "我方回合2次，可以选择场上1张机师牌，使其行动牌上限+2（效果持续至下个我方回合开始）。"
	p014e1.mode = _TC.MODE_DIRECT
	p014e1.priority = 10
	p014e1.once_per_turn_key = &"pilot_014_effect_01"
	p014e1.once_per_turn_max = 2
	p014e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
	])
	p014e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p014e1.set_costs([])
	p014e1.set_actions([{
		"type": &"PILOT_014_SELECT_TARGET_PILOT_AND_GRANT",
		"params": {"optional": true}
	}])
	effects[p014e1.effect_id] = p014e1

	# ════════════════════════════════════════════════════════════
	# pilot_015 诺拉（联邦 SR，cost 10, attack_limit 2, action_card_limit 1）
	# ════════════════════════════════════════════════════════════
	# 2 按钮：
	#   按钮1 = 效果1（被动置灰）：3 个隐藏被动 01a/01b/01c 合并到 hover。
	#     条件统一：诺拉拥有者行动手牌 == 0（动态查 game_state，OWNER_ACTION_HAND_IS_EMPTY）。
	#     01a ATTACK_PRE priority 40：敌方物理攻击牌指定我方机甲为目标 -> 强制当作纯进攻
	#         （剥离攻击牌额外效果 effect2/3 + 双连仅首 fork + 还原威力为武器牌面值）。
	#     01b ATTACK_AT priority 0：物理攻击牌攻击被我方效果响应后 -> 剥离尚未 fire 的额外效果
	#         （已生效的保留；双连当前 fork 跑完，后续 fork 取消）。
	#     01c USE_ACTION_BEFORE：迎击牌响应我方攻击时 -> 视为防御（as_card_def_id=action_009_防御）。
	#   按钮2 = 效果2（主动进攻，每玩家回合1次）：02a 进攻 DIRECT + 02b 防御 AVAILABILITY（不建按钮）。
	#     复用莱比尔 PILOT_002_USE_BATCH_AS_NAMED 模式：全部行动牌（≥1）入 temp_zone，
	#     保留首张作虚拟牌 virtual_transform 当作具名牌使用；链末 DISCARD_TEMP_ZONE_CARDS 入弃牌堆。

	# ── pilot_015_effect_01a 空手·攻击视为纯进攻（trigger A，隐藏被动）──
	# LISTEN ATTACK_PRE priority 40（高于破甲/猛击/预判 effect2 的 10/20/30，先 fire 抢先剥离）。
	# 条件：诺拉拥有者手牌0 + 攻击源是物理攻击牌（非虚拟转化）+ 目标是诺拉所属机甲。
	# 动作：SET_ACTION_RECORD_FLAG pilot_015_force_pure_assault=true。
	#   flag 由 TimingEngine.fire_timing 读取：跳过 card_instance_id==attack_card_id 的额外效果 listener；
	#   attack_action._step_calculate_damage 读 flag 还原威力（extra_might=0）；
	#   attack_action._create_next_fork 读 flag 仅保留首个 fork（清空 _multi_target_fork_queue）。
	#   fork 深拷贝 record 继承 flag，故每个 fork 都被剥离+还原威力。
	var p015e1a := _ActionEffect.new()
	p015e1a.effect_id = &"pilot_015_effect_01a"
	p015e1a.display_name = "空手·攻击视为纯进攻"
	p015e1a.description = "【空手·攻击视为纯进攻】诺拉拥有者行动手牌为0时：①敌方物理攻击牌指定我方机甲为目标，强制视为纯进攻（剥离额外效果、还原威力为武器牌面值、双连仅首目标）；②该攻击被我方效果响应后，剥离尚未生效的额外效果（已生效的保留）；③响应我方攻击的迎击牌视为防御（护甲+5、损伤-1）。"
	p015e1a.mode = _TC.MODE_LISTEN
	p015e1a.priority = 40
	p015e1a.listen_timing = _TC.ATTACK_PRE
	p015e1a.listen_action_type = &"attack"
	p015e1a.set_conditions([
		{"op": &"OWNER_ACTION_HAND_IS_EMPTY"},
		{"op": &"ATTACK_SOURCE_IS_PHYSICAL_ATTACK_CARD"},
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
	])
	p015e1a.set_target_rules([{"rule": &"NO_TARGET"}])
	p015e1a.set_costs([])
	p015e1a.set_actions([{
		"type": &"SET_ACTION_RECORD_FLAG",
		"params": {"flag": &"pilot_015_force_pure_assault", "value": true}
	}])
	effects[p015e1a.effect_id] = p015e1a

	# ── pilot_015_effect_01b 空手·被响应后剥离额外效果（trigger B，隐藏被动）──
	# LISTEN ATTACK_AT priority 0（补跑阶段，高于强袭 effect2 的 -1，先于强袭2执行）。
	# 条件：诺拉拥有者手牌0 + 攻击源是物理攻击牌 + 本攻击已被我方效果响应（responded=true）。
	# 动作：PILOT_015_FORCE_PURE_ASSAULT（设 flag 到当前 attack + 根 attack，作用于 fork 时同时标根）。
	#   - 已 fire 的额外效果（ATTACK_PRE/AT 之前）保留生效；
	#   - 尚未 fire 的额外效果（ATTACK_AFTER/SETTLE 的 effect2/3）被剥离；
	#   - 双连：当前 fork 跑完，后续 fork 取消（_create_next_fork 读 flag 清队列）。
	#   - 还原威力：当前 fork 及后续 fork（若有）extra_might=0。
	var p015e1b := _ActionEffect.new()
	p015e1b.effect_id = &"pilot_015_effect_01b"
	p015e1b.display_name = "空手·被响应后剥离"
	p015e1b.hide_button = true
	p015e1b.description = "诺拉拥有者行动手牌为0时，敌方物理攻击牌被我方效果响应后，剥离尚未生效的额外效果（双连仅完成当前目标）。"
	p015e1b.mode = _TC.MODE_LISTEN
	p015e1b.priority = 0
	p015e1b.listen_timing = _TC.ATTACK_AT
	p015e1b.listen_action_type = &"attack"
	p015e1b.set_conditions([
		{"op": &"OWNER_ACTION_HAND_IS_EMPTY"},
		{"op": &"ATTACK_SOURCE_IS_PHYSICAL_ATTACK_CARD"},
		{"op": &"ATTACK_WAS_RESPONDED"},
	])
	p015e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p015e1b.set_costs([])
	p015e1b.set_actions([{
		"type": &"PILOT_015_FORCE_PURE_ASSAULT",
		"params": {}
	}])
	effects[p015e1b.effect_id] = p015e1b

	# ── pilot_015_effect_01c 空手·迎击视为防御（trigger C，隐藏被动）──
	# LISTEN USE_ACTION_BEFORE（listen_action_type=use_action_card）：迎击牌响应我方攻击时触发。
	# 条件：诺拉拥有者手牌0 + 当前 use_action 是迎击牌（action_type=迎击/counter）
	#       + 非虚拟转化牌 + 是响应我方攻击（attack_action_id 非空 + 该攻击发起方=诺拉所属机甲）。
	# 动作：PILOT_015_REPLACE_COUNTER_AS_DEFEND（设 as_card_def_id=action_009_防御 到 use_action record）。
	#   视为机制（同刻托 REPLACE）：_as_card_def_id 读 as_card_def_id，step②/③ 按防御效果链执行。
	#   迎击牌本身的 effect2（反击的反击攻击 bind_to_attack_action）仍按防御链注册（防御无 effect2）。
	var p015e1c := _ActionEffect.new()
	p015e1c.effect_id = &"pilot_015_effect_01c"
	p015e1c.display_name = "空手·迎击视为防御"
	p015e1c.hide_button = true
	p015e1c.description = "诺拉拥有者行动手牌为0时，响应我方攻击的迎击牌视为防御（护甲+5、损伤-1）。"
	p015e1c.mode = _TC.MODE_LISTEN
	p015e1c.priority = 20
	p015e1c.listen_timing = _TC.USE_ACTION_BEFORE
	p015e1c.listen_action_type = &"use_action_card"
	p015e1c.set_conditions([
		{"op": &"OWNER_ACTION_HAND_IS_EMPTY"},
		{"op": &"USED_COUNTER_CARD"},
		{"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"USED_CARD_RESPONDS_TO_OWN_ATTACK"},
	])
	p015e1c.set_target_rules([{"rule": &"NO_TARGET"}])
	p015e1c.set_costs([])
	p015e1c.set_actions([{
		"type": &"PILOT_015_REPLACE_COUNTER_AS_DEFEND",
		"params": {"as_card_def_id": &"action_009_防御"}
	}])
	effects[p015e1c.effect_id] = p015e1c

	# ── pilot_015_effect_02a 全部当进攻（按钮2，主动，每玩家回合1次）──
	# DIRECT：我方主阶段 + 手牌≥1 + 范围内有可攻击目标 + 本回合未用过（once_per_turn_max=1，按 _current_turn_number 每玩家回合独立）。
	# 动作：PLAY_AS_NAMED（通用转化：全部行动牌入 temp_zone，保留首张作虚拟牌，
	#   virtual_transform 当作 action_001_进攻 使用，消耗1次攻击数，链末 DISCARD_TEMP_ZONE_CARDS 入弃牌堆）。
	#   进攻为主动攻击牌（attack_is_active=true），消耗回合攻击数。
	#   范围条件 HAS_ATTACK_TARGET_IN_RANGE：任一武器射程内无目标时按钮置灰，避免烧掉全部行动牌。
	var p015e2a := _ActionEffect.new()
	p015e2a.effect_id = &"pilot_015_effect_02a"
	p015e2a.display_name = "全部当进攻"
	p015e2a.description = "每回合1次，将全部行动牌（至少1张）当作进攻使用（整批进弃牌堆，保留首张作虚拟牌，消耗1次攻击数；需范围内有目标）。"
	p015e2a.mode = _TC.MODE_DIRECT
	p015e2a.priority = 10
	p015e2a.once_per_turn_key = &"pilot_015_effect_02"
	p015e2a.once_per_turn_max = 1
	p015e2a.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_ATTACK_TARGET_IN_RANGE"},
	])
	p015e2a.set_target_rules([{"rule": &"NO_TARGET"}])
	p015e2a.set_costs([
		# 全部行动手牌移入临时区（写 payload.temp_zone_card_ids），链末 DISCARD_TEMP_ZONE_CARDS 入弃牌堆。
		{"cost_type": &"DISCARD_ALL_ACTION_CARDS", "params": {"to_temp_zone": true, "no_cancel": true}},
	])
	p015e2a.set_actions([
		{
			"type": &"PLAY_AS_NAMED",
			"params": {"as_card_def_id": &"action_001_进攻", "attack_is_active": true}
		},
		# 链末：临时区全部牌入弃牌堆（不触发 Action Engine 时点，走 legacy GameActions.discard_card）
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p015e2a.effect_id] = p015e2a

	# ── pilot_015_effect_02b 全部当防御（AVAILABILITY，响应窗口，每玩家回合1次）──
	# AVAILABILITY ATTACK_AT：我方机甲被攻击 + 手牌≥1 + 本回合未用过（与 02a 共享 once_per_turn_key）。
	# 动作：PLAY_AS_NAMED（通用转化，同 02a，但 attack_is_active=false，当作 action_009_防御 响应）。
	#   防御为被动响应（不消耗攻击数）；attack_action_id 经响应窗口注入定位原攻击。无需范围条件。
	var p015e2b := _ActionEffect.new()
	p015e2b.effect_id = &"pilot_015_effect_02b"
	p015e2b.display_name = "全部当防御"
	p015e2b.hide_button = true
	p015e2b.merge_desc_into_index = 2
	p015e2b.description = "响应窗口，将全部行动牌（至少1张）当作防御响应（护甲+5、损伤-1）。每回合1次（与进攻共享次数）。"
	p015e2b.mode = _TC.MODE_AVAILABILITY
	p015e2b.priority = 5
	p015e2b.listen_timing = _TC.ATTACK_AT
	p015e2b.listen_action_type = &"attack"
	p015e2b.once_per_turn_key = &"pilot_015_effect_02"
	p015e2b.once_per_turn_max = 1
	p015e2b.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
	])
	p015e2b.set_target_rules([{"rule": &"NO_TARGET"}])
	p015e2b.set_costs([
		# 全部行动手牌移入临时区（写 payload.temp_zone_card_ids），链末 DISCARD_TEMP_ZONE_CARDS 入弃牌堆。
		{"cost_type": &"DISCARD_ALL_ACTION_CARDS", "params": {"to_temp_zone": true, "no_cancel": true}},
	])
	p015e2b.set_actions([
		{
			"type": &"PLAY_AS_NAMED",
			"params": {"as_card_def_id": &"action_009_防御", "attack_is_active": false}
		},
		# 链末：临时区全部牌入弃牌堆
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p015e2b.effect_id] = p015e2b

	# ── pilot_016_effect_01 展示转化（被动监听，显示说明按钮）──
	# 每玩家回合1次：默多克拥有者使用实体行动牌前（USE_ACTION_BEFORE，牌未进临时区），可展示此牌，
	# 将另外1张行动牌当作此牌使用（转化机制）。迎击牌响应窗口也触发（不排除迎击牌）。
	# 触发方式：玩家先点击牌A（正常使用，use_action_card validate 已检查A可用：攻击牌需范围内有目标+
	#   攻击次数等，条件不足点不了A），USE_ACTION_BEFORE 触发本效果再弹窗选B。
	# 流程：CHOOSE_ONE optional 询问 -> 确认 -> PILOT_016_SHOW_AND_CONVERT（展示牌A给其他玩家 +
	#   选1张B排除牌A。B 由父 card_to_temp_zone 移入临时区，改造父record为B当牌A virtual_transform）。
	# 改造后父use_action_card继续跑：card_to_temp_zone(B进temp_zone+注册牌A效果) -> execute_effects(执行牌A的
	#   DIRECT效果，即"调用执行A的效果") -> settle(弃B)。
	# 牌A保留手牌。迎击牌LISTEN(如counter_effect2)注册到原攻击触发完整响应。
	# 防递归：条件 PAYLOAD_IS_PHYSICAL_ACTION_CARD 排除virtual_transform虚拟牌（改造后父不再触发本效果）。
	# priority 20：高于阿克罗姆01a(10)，先转化使01a排除虚拟牌不触发。
	var p016e1 := _ActionEffect.new()
	p016e1.effect_id = &"pilot_016_effect_01"
	p016e1.display_name = "展示转化"
	p016e1.description = "每回合1次，可以展示持有的1张行动牌，之后将另外1张行动牌当作该展示的牌使用。"
	p016e1.mode = _TC.MODE_LISTEN
	p016e1.priority = 20
	p016e1.listen_timing = _TC.USE_ACTION_BEFORE
	p016e1.listen_action_type = &"use_action_card"
	p016e1.once_per_turn_key = &"pilot_016_effect_01"
	p016e1.once_per_turn_max = 1
	p016e1.set_conditions([
		{"op": &"USED_CARD_EXECUTOR_IS_SELF"},
		{"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}},
	])
	p016e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p016e1.set_costs([])
	p016e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "展示此牌，将另外1张行动牌当作此牌使用", "actions": [
			{"type": &"PILOT_016_SHOW_AND_CONVERT", "params": {}}
		]}]}
	}])
	effects[p016e1.effect_id] = p016e1

	# ═══════════════════════════════════════════
	# pilot_017 伏特（帝国 SR，cost 11, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════
	# 2 按钮：
	#   按钮1 = effect_01（主动 DIRECT，每玩家回合1次）：选2张行动牌当作 强袭/猛击/破甲 之一使用。
	#     走布鲁克式通用转化动作流程（无 cost，选牌可取消不消耗）：三选一当作 ->
	#     CHOOSE_MANY_CARDS 选2张燃料 -> MOVE_ACTION_CARDS_TO_TEMP_ZONE 移入临时区 ->
	#     PLAY_AS_NAMED（通用转化：取 temp_zone 首张作虚拟牌 virtual_transform，attack_is_active=true
	#     消耗1次攻击次数）-> DISCARD_TEMP_ZONE_CARDS 链末入弃牌堆。
	#     转化牌写 counters.virtual_as_def_id（_step_card_to_temp_zone）供效果2识别（ATTACK_SOURCE_CARD_IS）。
	#   按钮2 = effect_02a（被动 LISTEN 置灰，描述含猛击/破甲/强袭3段）：
	#     02a ATTACK_BEFORE 猛击+3威（MODIFY_ATTACK_MIGHT，被诺拉纯进攻清 extra_might 自动排除）；
	#     02b ATTACK_AFTER 命中 破甲+2损（MODIFY_ATTACK_MARKERS，显式 ATTACK_RECORD_FLAG_NOT_SET 排除诺拉）；
	#     02c ATTACK_SETTLE 强袭回4动（RESTORE_POWER，显式 ATTACK_RECORD_FLAG_NOT_SET 排除诺拉）。
	#     条件统一 SELF_MECH_IS_ATTACKER（仅伏特自己执行）+ ATTACK_SOURCE_CARD_IS（识别转化虚拟牌+原版实体牌）。

	# ── pilot_017_effect_01 当作强袭/猛击/破甲使用（按钮1，主动，每玩家回合1次）──
	# DIRECT：我方主阶段 + 手牌≥2 + 还能攻击（转化进攻消耗1次攻击次数）+ 范围内有可攻击目标
	#   （HAS_ATTACK_TARGET_IN_RANGE 条件不足时按钮置灰，避免选燃料后攻击无目标）。
	# 无 cost；三选一（optional=true 可取消=不发动，无消耗）；选燃料弹窗（可取消=放弃分支，无消耗）。
	var p017e1 := _ActionEffect.new()
	p017e1.effect_id = &"pilot_017_effect_01"
	p017e1.display_name = "当作强袭/猛击/破甲"
	p017e1.description = "每回合1次，选择2张行动牌当作强袭/猛击/破甲之一使用（2张牌进临时区，保留首张作虚拟牌，消耗1次攻击次数；链末入弃牌堆；需范围内有目标）。"
	p017e1.mode = _TC.MODE_DIRECT
	p017e1.priority = 10
	p017e1.once_per_turn_key = &"pilot_017_effect_01"
	p017e1.once_per_turn_max = 1
	p017e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}},
		{"op": &"ATTACK_COUNT_ABOVE", "threshold": 0},
		{"op": &"HAS_ATTACK_TARGET_IN_RANGE"},
	])
	p017e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p017e1.set_costs([])
	p017e1.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "title": "当作强袭/猛击/破甲使用", "description": "选择要当作的攻击牌", "options": [
			{"label": "当作强袭使用", "actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 2, "max_count": 2, "store_result_key": &"pilot_017_fuel_ids", "label": "选择转化使用的2张行动牌", "confirm_verb": "转化", "cancel_label": "取消"}},
				{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_017_fuel_ids"}},
				{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_002_强袭", "attack_is_active": true}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
			{"label": "当作猛击使用", "actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 2, "max_count": 2, "store_result_key": &"pilot_017_fuel_ids", "label": "选择转化使用的2张行动牌", "confirm_verb": "转化", "cancel_label": "取消"}},
				{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_017_fuel_ids"}},
				{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_003_猛击", "attack_is_active": true}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
			{"label": "当作破甲使用", "actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 2, "max_count": 2, "store_result_key": &"pilot_017_fuel_ids", "label": "选择转化使用的2张行动牌", "confirm_verb": "转化", "cancel_label": "取消"}},
				{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_017_fuel_ids"}},
				{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_004_破甲", "attack_is_active": true}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
		]}},
	])
	effects[p017e1.effect_id] = p017e1

	# ── pilot_017_effect_02a 猛击+3威（按钮2，被动 LISTEN 置灰，描述含猛击/破甲/强袭3段）──
	# ATTACK_BEFORE priority10：伏特自己用猛击（含转化虚拟牌+原版实体牌）攻击时，威力+3（写 extra_might）。
	# 被诺拉纯进攻自动排除：attack_action._step_calculate_damage 读 pilot_015_force_pure_assault flag 时 extra_might 当 0。
	var p017e2a := _ActionEffect.new()
	p017e2a.effect_id = &"pilot_017_effect_02a"
	p017e2a.display_name = "强袭/猛击/破甲加成"
	p017e2a.description = "【强袭/猛击/破甲加成】伏特自己执行强袭/猛击/破甲时：强袭回复4动力，猛击使本次攻击威力+3，破甲命中后损伤+2。被诺拉变成纯进攻的攻击不享受加成。"
	p017e2a.mode = _TC.MODE_LISTEN
	p017e2a.priority = 10
	p017e2a.listen_timing = _TC.ATTACK_BEFORE
	p017e2a.listen_action_type = &"attack"
	p017e2a.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_SOURCE_CARD_IS", "params": {"card_def_ids": [&"action_003_猛击"]}},
	])
	p017e2a.set_target_rules([{"rule": &"NO_TARGET"}])
	p017e2a.set_costs([])
	p017e2a.set_actions([{
		"type": &"MODIFY_ATTACK_MIGHT",
		"params": {"delta": 3},
	}])
	effects[p017e2a.effect_id] = p017e2a

	# ── pilot_017_effect_02b 破甲命中+2损（隐藏 LISTEN，描述合并到按钮2 hover）──
	# ATTACK_AFTER priority10 + ATTACK_HIT：破甲命中后损伤+2（写 extra_markers）。
	# 诺拉纯进攻不清 extra_markers，故显式 ATTACK_RECORD_FLAG_NOT_SET 排除。
	var p017e2b := _ActionEffect.new()
	p017e2b.effect_id = &"pilot_017_effect_02b"
	p017e2b.display_name = "破甲·命中损伤+2"
	p017e2b.hide_button = true
	p017e2b.merge_desc_into_index = 2
	p017e2b.description = "破甲命中后损伤+2。"
	p017e2b.mode = _TC.MODE_LISTEN
	p017e2b.priority = 10
	p017e2b.listen_timing = _TC.ATTACK_AFTER
	p017e2b.listen_action_type = &"attack"
	p017e2b.set_conditions([
		{"op": &"ATTACK_HIT"},
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_SOURCE_CARD_IS", "params": {"card_def_ids": [&"action_004_破甲"]}},
		{"op": &"ATTACK_RECORD_FLAG_NOT_SET", "params": {"flag": &"pilot_015_force_pure_assault"}},
	])
	p017e2b.set_target_rules([{"rule": &"NO_TARGET"}])
	p017e2b.set_costs([])
	p017e2b.set_actions([{
		"type": &"MODIFY_ATTACK_MARKERS",
		"params": {"delta": 2},
	}])
	effects[p017e2b.effect_id] = p017e2b

	# ── pilot_017_effect_02c 强袭回4动力（隐藏 LISTEN，描述合并到按钮2 hover）──
	# ATTACK_SETTLE priority10：强袭结算后伏特回复4动力。
	# 诺拉纯进攻不排除回动力，故显式 ATTACK_RECORD_FLAG_NOT_SET 排除。
	var p017e2c := _ActionEffect.new()
	p017e2c.effect_id = &"pilot_017_effect_02c"
	p017e2c.display_name = "强袭·回复4动力"
	p017e2c.hide_button = true
	p017e2c.merge_desc_into_index = 2
	p017e2c.description = "强袭结算后回复4动力。"
	p017e2c.mode = _TC.MODE_LISTEN
	p017e2c.priority = 10
	p017e2c.listen_timing = _TC.ATTACK_SETTLE
	p017e2c.listen_action_type = &"attack"
	p017e2c.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_SOURCE_CARD_IS", "params": {"card_def_ids": [&"action_002_强袭"]}},
		{"op": &"ATTACK_RECORD_FLAG_NOT_SET", "params": {"flag": &"pilot_015_force_pure_assault"}},
	])
	p017e2c.set_target_rules([{"rule": &"NO_TARGET"}])
	p017e2c.set_costs([])
	p017e2c.set_actions([{
		"type": &"RESTORE_POWER",
		"params": {"mech_id": "$binding_context.mech_id", "amount": 4, "method": &"restore"},
	}])
	effects[p017e2c.effect_id] = p017e2c

	# ════════════════════════════════════════════════════════════
	# pilot_018 苔丝（帝国 SR，cost 10）
	# 权威：用户口述效果（new_logic 机师牌拆解文档已删，以用户描述为准）
	# ════════════════════════════════════════════════════════════
	# 1 按钮（被动置灰）：2 个隐藏 LISTEN 合并（01a 建按钮1，01b 描述合并 hover）。
	#   01a ATTACK_PRE priority 10：苔丝是攻击目标时弹窗问是否发动（每玩家回合1次）。
	#       确认 -> 抽2行动牌 + 设 flag pilot_018_activated 到 attack.record（fork 深拷贝继承）。
	#       不发动/次数已用 -> 不设 flag，01b 不触发。
	#   01b ATTACK_AT priority 0（响应窗口关闭后补跑，先于强袭 effect2 的 -1；
	#       此时反击 effect2 额外攻击尚未执行，天然只算"第一个光响应"）：
	#       条件 = flag 已设 + 被我方真实迎击牌响应（排除虚拟转化/非苔丝方响应）。
	#       -> PILOT_018_RESPOND_DISCARD：弹 CHOOSE_ONE 选弃攻击方2行动牌或1损伤≥2装备牌。
	#       弃行动牌：≥3弹复选选2；=2直接弃；<2直接弃全部。
	#       弃装备牌：列出攻击方损伤≥2装备牌选1（无则结束）。
	#       弃的是本次攻击武器牌 -> _weapon_still_held 检测武器丢失 -> 未命中立即结算（不造成伤害）。

	# ── pilot_018_effect_01a 被攻抽2（按钮1，被动置灰，ATTACK_PRE 弹窗）──
	var p018e1a := _ActionEffect.new()
	p018e1a.effect_id = &"pilot_018_effect_01a"
	p018e1a.display_name = "苔丝·被攻抽2"
	p018e1a.description = "【被攻抽2+迎击弃牌】每回合1次（每玩家回合1次），被攻击时可立即抽2张行动牌；若我方通过使用真实迎击牌（非转化虚拟牌）响应了此攻击，则弃置攻击方的2张行动牌或1张设置损伤≥2的装备牌；若弃的是发动此次攻击的武器装备牌，此次攻击立即失效（未命中）。"
	p018e1a.mode = _TC.MODE_LISTEN
	p018e1a.priority = 10
	p018e1a.listen_timing = _TC.ATTACK_PRE
	p018e1a.listen_action_type = &"attack"
	p018e1a.once_per_turn_key = &"pilot_018_effect_01"
	p018e1a.once_per_turn_max = 1
	p018e1a.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
	])
	p018e1a.set_target_rules([{"rule": &"NO_TARGET"}])
	p018e1a.set_costs([])
	p018e1a.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"title": "苔丝：被攻击时抽2张",
			"description": "每回合1次，被攻击时可立即抽2张行动牌。若随后我方用真实迎击牌响应此攻击，可弃置攻击方的2张行动牌或1张损伤≥2的装备牌。是否发动？",
			"options": [{
				"label": "发动（抽2张行动牌）",
				"actions": [
					{"type": &"EXECUTE_GAIN_CARD", "params": {
						"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
						"player_id": "$binding_context.player_id",
					}},
					{"type": &"SET_ACTION_RECORD_FLAG", "params": {
						"action_id": "$payload.action_id",
						"flag": &"pilot_018_activated",
						"value": true,
						"data": {"owner_player_id": "$binding_context.player_id"},
					}},
				],
			}],
		},
	}])
	effects[p018e1a.effect_id] = p018e1a

	# ── pilot_018_effect_01b 迎击后弃攻击方牌（隐藏被动，ATTACK_AT 响应后）──
	# priority 0：响应窗口关闭后补跑阶段，responded 已写入。
	# 条件：flag pilot_018_activated 已设（01a 发动）+ 被我方真实迎击牌响应（新 checker）。
	# 动作：PILOT_018_RESPOND_DISCARD（TimingEngine 拦截，弹 CHOOSE_ONE 选弃2行动牌/1损伤≥2装备牌）。
	var p018e1b := _ActionEffect.new()
	p018e1b.effect_id = &"pilot_018_effect_01b"
	p018e1b.display_name = "苔丝·迎击后弃攻击方牌"
	p018e1b.hide_button = true
	p018e1b.merge_desc_into_index = 1
	p018e1b.description = "若我方通过使用真实迎击牌响应了此攻击，则弃置攻击方的2张行动牌或1张设置损伤≥2的装备牌；若弃的是发动此次攻击的武器装备牌，此次攻击立即失效。"
	p018e1b.mode = _TC.MODE_LISTEN
	p018e1b.priority = 0
	p018e1b.listen_timing = _TC.ATTACK_AT
	p018e1b.listen_action_type = &"attack"
	p018e1b.set_conditions([
		{"op": &"ATTACK_RECORD_FLAG_IS_SET", "params": {"flag": &"pilot_018_activated"}},
		{"op": &"ATTACK_RESPONDED_BY_OWNER_REAL_COUNTER"},
	])
	p018e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p018e1b.set_costs([])
	p018e1b.set_actions([{
		"type": &"PILOT_018_RESPOND_DISCARD",
		"params": {}
	}])
	effects[p018e1b.effect_id] = p018e1b

	# ═══════════════════════════════════════════
	# pilot_019 肯耳忒（帝国 SR，cost 11, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_019_effect_01 缴械冲击（弃牌链）──
	# 我方回合1次：选≤2台4格内其他机甲 -> 弹checkbox选自己≥1张行动牌(记X,弃X张) ->
	# 逐目标(按选择顺序)暗牌选X+1张弃(X+1>目标手牌则直接弃全部) ->
	# 弃完若目标行动牌被清空(原本≥1) -> 4伤害(直接扣HP,不吃护甲)。
	# 全程由 TimingEngine 的 PILOT_019_DISCARD_CHAIN 阶段机驱动（弹窗 + discard_card 子动作串行）。
	# HAS_ACTION_CARD_IN_HAND 放 set_conditions 安全：效果仅1个自定义动作，链内 resume
	# 全部走自定义 phase/子动作续跑钩子，不会重跑 _execute_effect（不像 pilot_009 支付后
	# CHOOSE_ONE 续跑重查条件），故支付弃X后手牌变空不会 conditions_not_met 静默跳过；
	# 同时让 can_trigger_active_effect 自动把按钮置灰（手牌空不可点）。
	var p019e1 := _ActionEffect.new()
	p019e1.effect_id = &"pilot_019_effect_01"
	p019e1.display_name = "缴械冲击"
	p019e1.description = "我方回合1次，选择最多2台4格范围的其他机甲为目标，通过弃置我方X张行动牌（X最低为1），弃置目标X+1张行动牌，若因此清空目标所持行动牌（其原本行动牌至少有1张），则对其造成4伤害。"
	p019e1.mode = _TC.MODE_DIRECT
	p019e1.priority = 10
	p019e1.once_per_turn_key = &"pilot_019_effect_01"
	p019e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 4}},
	])
	p019e1.set_target_rules([{"rule": &"NO_TARGET"}])  # 目标由阶段机内多选自选，不走通用 target 检查
	p019e1.set_costs([])
	p019e1.set_actions([
		{"type": &"PILOT_019_DISCARD_CHAIN", "params": {}},
	])
	effects[p019e1.effect_id] = p019e1

	# ═══════════════════════════════════════════
	# pilot_020 肯德（帝国 SR，cost 10, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（DIRECT 按钮1）：我方回合1次，弃任意张行动牌（thrust_select 多选，取消不消耗次数）。
	# 效果2（LISTEN 按钮2 置灰+悬停）：每个回合开始记录 X = 我方行动牌从手牌进弃牌堆数
	#   （使用牌 temp_zone 不计；回合超限/预判/肯特/肯耳忒弃的牌经 DISCARD_SETTLE 快照计入，
	#   from_zone=="action_hand" && from_mech_id==肯德机甲 过滤）。X 按 turn_number 每回合自动重置。
	#   X≥2 时（每回合1次）护甲+3 动力+3（上限+当前，cap_bonus 补满）；
	#   X≥3 时（effect_03 隐藏 ATTACK_BEFORE）攻击威力+2 所有武器范围+1（不限制次数）；
	#   X≥4 时（effect_04 隐藏 TURN_AFTER_END）回合结束后抽 min(X,6) 张行动牌。
	# 3 个阈值叠加（包含区间）。PILOT_020_X_AT_LEAST 条件经 ConditionChecker 读 binding_context 卡实例 counter。
	var p020e1 := _ActionEffect.new()
	p020e1.effect_id = &"pilot_020_effect_01"
	p020e1.display_name = "弃任意行动牌"
	p020e1.description = "我方回合1次，可以弃置任意张行动牌。"
	p020e1.mode = _TC.MODE_DIRECT
	p020e1.priority = 10
	p020e1.once_per_turn_key = &"pilot_020_effect_01"
	p020e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p020e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p020e1.set_costs([])
	p020e1.set_actions([
		{"type": &"PILOT_020_ACTIVE_DISCARD", "params": {}},
	])
	effects[p020e1.effect_id] = p020e1

	var p020e2 := _ActionEffect.new()
	p020e2.effect_id = &"pilot_020_effect_02"
	p020e2.display_name = "弃置计数"
	p020e2.description = "每个回合我方行动牌被弃置一定数目，可获得对应效果。"
	p020e2.mode = _TC.MODE_LISTEN
	p020e2.priority = 10
	p020e2.listen_timing = _TC.DISCARD_SETTLE
	p020e2.listen_action_type = &"discard_card"
	p020e2.set_conditions([{"op": &"ALWAYS"}])
	p020e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p020e2.set_costs([])
	p020e2.set_actions([
		{"type": &"PILOT_020_COUNT_DISCARD", "params": {}},
	])
	effects[p020e2.effect_id] = p020e2

	var p020e3 := _ActionEffect.new()
	p020e3.effect_id = &"pilot_020_effect_03"
	p020e3.display_name = "弃牌>2攻击强化"
	p020e3.hide_button = true
	p020e3.merge_desc_into_index = 2
	p020e3.description = "大于2：当前回合攻击时，威力+2，所有武器范围+1。"
	p020e3.mode = _TC.MODE_LISTEN
	p020e3.priority = 10
	p020e3.listen_timing = _TC.ATTACK_BEFORE
	p020e3.listen_action_type = &"attack"
	p020e3.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"PILOT_020_X_AT_LEAST", "params": {"threshold": 3}},
	])
	p020e3.set_target_rules([{"rule": &"NO_TARGET"}])
	p020e3.set_costs([])
	p020e3.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 2}},
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 1}},
	])
	effects[p020e3.effect_id] = p020e3

	var p020e4 := _ActionEffect.new()
	p020e4.effect_id = &"pilot_020_effect_04"
	p020e4.display_name = "弃牌>3回合末抽牌"
	p020e4.hide_button = true
	p020e4.merge_desc_into_index = 2
	p020e4.description = "大于3：当前回合结束后抽取被弃置数量的行动牌（最多6张）。"
	p020e4.mode = _TC.MODE_LISTEN
	p020e4.priority = 10
	p020e4.listen_timing = _TC.TURN_AFTER_END
	p020e4.listen_action_type = &"turn"
	p020e4.set_conditions([
		{"op": &"PILOT_020_X_AT_LEAST", "params": {"threshold": 4}},
	])
	p020e4.set_target_rules([{"rule": &"NO_TARGET"}])
	p020e4.set_costs([])
	p020e4.set_actions([
		{"type": &"PILOT_020_DRAW_X", "params": {}},
	])
	effects[p020e4.effect_id] = p020e4

	# ═══════════════════════════════════════════
	# pilot_022 塔莉娅（帝国 SR，cost 10, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果1（DIRECT 按钮1，我方回合1次）：抽3张行动牌（打"禁"标签，本回合塔莉娅无法使用），
	#   之后可给予4格内其他机甲，循环：选机甲 -> 选剩余禁牌(至少1张) -> 转移（交牌打"策"标签），
	#   直到牌给完或选机甲界面取消。选牌界面取消可重选机甲（不结束循环）。
	#   循环 handler 在 TimingEngine：PILOT_021_LOOP_DEAL（含 resume phase：pilot_022_choose_mech/pilot_022_choose_cards）。
	# 效果2（LISTEN 按钮2 置灰+悬停，不注册 listener）：行动牌从塔莉娅手牌转移到其他玩家手牌
	#   （效果1交牌/识破偷牌/玛丽尔偷牌都计入）时打"策"标签；带"策"标签的行动牌从临时区进弃牌堆
	#   （通用"使用"判定，含转化代价牌）时塔莉娅抽2，标签随牌入弃牌堆消失。
	#   标签/挂钩逻辑在 GameActions.transfer_action_cards / steal_action_card /
	#   discard_card_action._step_transfer_to_pile / TurnService（清禁标签）。
	var p021e1 := _ActionEffect.new()
	p021e1.effect_id = &"pilot_022_effect_01"
	p021e1.display_name = "赐予行动牌"
	p021e1.description = "我方回合1次，抽3张行动牌，可给予4格内其他机甲（可循环多次），剩余牌本回合无法使用。"
	p021e1.mode = _TC.MODE_DIRECT
	p021e1.priority = 10
	p021e1.once_per_turn_key = &"pilot_022_effect_01"
	p021e1.once_per_turn_max = 1
	p021e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
	])
	p021e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p021e1.set_costs([])
	p021e1.set_actions([
		{"type": &"PILOT_021_LOOP_DEAL", "params": {}},
	])
	effects[p021e1.effect_id] = p021e1

	var p021e2 := _ActionEffect.new()
	p021e2.effect_id = &"pilot_022_effect_02"
	p021e2.display_name = "策略回收"
	p021e2.description = "行动牌从我方手牌转移到其他玩家手牌后打「策」标记；其他机甲使用带「策」标记的行动牌后，我方抽2张行动牌。"
	p021e2.mode = _TC.MODE_LISTEN
	p021e2.priority = 10
	p021e2.set_conditions([])
	p021e2.set_target_rules([])
	p021e2.set_costs([])
	p021e2.set_actions([])
	effects[p021e2.effect_id] = p021e2

	# ═══════════════════════════════════════════
	# pilot_021 提比里安（阵营待确认，cost 待确认, attack_limit 1, action_card_limit 待确认）
	# ═══════════════════════════════════════════
	# 2 按钮：
	#   按钮1 = effect_01（主动 DIRECT，每我方回合1次）「弃甲铸威」：弃置1张武器装备牌（实体，
	#     设置/未设置/备用区都算，虚拟武器天然排除——虚拟武器 def.equipment_kind==PART），
	#     该武器牌面威力每5点 → 本回合下次攻击威力+3。威力加成存 PILOT_022_POWER_BONUS 状态
	#     （stacks=加成点数，duration=1），由状态监听器在下次我方攻击 ATTACK_PRE 注入 extra_might
	#     后移除（用完即清）；回合结束 DECREMENT_STATUS_DURATION 兜底清除（回合结束失效）。
	#     多选窗 source=OWNER_WEAPON_EQUIPMENT_CARDS（TimingEngine 枚举：装备手牌+机甲已设置
	#     WEAPON 槽位），store_result_key=pilot_021_weapon 供 EXECUTE_DISCARD 弃置 +
	#     PILOT_022_APPLY_POWER_BONUS（原子）算加成。
	#   按钮2 = effect_02（被动 LISTEN，ATTACK_PRE priority 40）「本局1次·火力爆发」：
	#     我方发动攻击时弹窗询问是否发动；确认后 PILOT_022_MULTIPLY_ATTACK_MIGHT（原子）把
	#     攻击初始威力改为武器原本威力×1.5（delta=floor(原威力/2) 累加 extra_might，保留猛击/
	#     聚能等其他修正）+ MODIFY_ATTACK_RANGE +3 + FOR_EACH_TARGET(全部攻击目标)→ADD_STATUS
	#     LOCKED duration 1（预判式）+ PILOT_022_MARK_USED（原子）写 counters["pilot_021_effect_02_used"]
	#     本局仅一次（PILOT_022_NOT_USED_THIS_GAME 条件拦截后续攻击）。

	var p022e1 := _ActionEffect.new()
	p022e1.effect_id = &"pilot_021_effect_01"
	p022e1.display_name = "弃甲铸威"
	p022e1.description = "我方回合1次，可以弃置1张武器装备牌，该武器的威力每有5点，就使本回合的下次攻击威力+3。"
	p022e1.mode = _TC.MODE_DIRECT
	p022e1.priority = 10
	p022e1.once_per_turn_key = &"pilot_021_effect_01"
	p022e1.once_per_turn_max = 1
	p022e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"OWNER_HAS_WEAPON_EQUIPMENT_CARD"},
	])
	p022e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p022e1.set_costs([])
	p022e1.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_WEAPON_EQUIPMENT_CARDS",
			"min_count": 1,
			"max_count": 1,
			"store_result_key": &"pilot_021_weapon",
			"label": "选择1张要弃置的武器装备牌",
			"confirm_verb": "弃置",
			"cancel_label": "取消",
		}},
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.pilot_021_weapon",
			"reason": &"pilot_021_effect_01",
		}},
		{"type": &"PILOT_022_APPLY_POWER_BONUS", "params": {}},
	])
	effects[p022e1.effect_id] = p022e1

	var p022e2 := _ActionEffect.new()
	p022e2.effect_id = &"pilot_021_effect_02"
	p022e2.display_name = "本局1次·火力爆发"
	p022e2.description = "本局游戏1次，发动攻击时，可以使该攻击的初始威力变成攻击武器原本威力的1.5倍(向下取整)，范围+3，对所有目标施加锁定效果。"
	p022e2.mode = _TC.MODE_LISTEN
	p022e2.priority = 40
	p022e2.listen_timing = _TC.ATTACK_PRE
	p022e2.listen_action_type = &"attack"
	p022e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"PILOT_022_NOT_USED_THIS_GAME"},
	])
	p022e2.set_target_rules([{
		"rule": &"ALL_CURRENT_ATTACK_MECH_TARGETS",
		"params": {"exclude_attacker": true, "preserve_attack_target_order": true, "allowed_target_kinds": [&"MECH"]},
	}])
	p022e2.set_costs([])
	p022e2.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"title": "提比里安：火力爆发",
			"description": "本局游戏1次，使本次攻击的初始威力变为攻击武器原本威力的1.5倍(向下取整)，范围+3，对所有目标施加锁定效果。是否发动？",
			"options": [{
				"label": "发动（威力×1.5、范围+3、目标锁定）",
				"actions": [
					{"type": &"PILOT_022_MULTIPLY_ATTACK_MIGHT", "params": {}},
					{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 3}},
					{"type": &"FOR_EACH_TARGET", "params": {
						"targets": "$selected_targets",
						"execution_mode": &"SERIAL",
						"preserve_order": true,
						"current_target_variable": &"current_target",
						"actions": [
							{"type": &"ADD_STATUS", "params": {
								"status_type": &"LOCKED",
								"duration": 1,
								"target_id": "$current_target.mech_id",
							}},
						],
					}},
					{"type": &"PILOT_022_MARK_USED", "params": {}},
				],
			}],
		},
	}])
	effects[p022e2.effect_id] = p022e2

	# ═══════════════════════════════════════════
	# pilot_023 坎得（秩序 SR，cost 10, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（DIRECT 按钮1，每我方回合2次）「当作维修」：将1张行动牌当作维修使用。
	#   复用维修机械臂 effect_130 模式：列出持有者全部行动牌选1（source=OWNER_ACTION_HAND），
	#   选中牌 EXECUTE_USE_ACTION_CARD virtual_transform 当作维修打出（不耗攻击次数/不受类型限制）。
	#   按钮条件：主阶段 + 手牌≥1行动牌 + 场上存在维修目标（REPAIR_HAS_VALID_TARGET，范围读 repair_boost）。
	# 效果2（LISTEN 按钮2 置灰+悬停，不注册 listener）：我方使用的维修获得增强——
	#   实际由通用机制 REPAIR_BOOST 实现（def.repair_boost 字段，见本文件底部 helper）：
	#   TargetChecker/ConditionChecker/app_root 维修目标范围读 range=4；repair_direct 执行时
	#   TimingEngine 按 extra_removal=2 改写选项（移除2→合并4；回复4→之后额外移除2）。
	#   本 LISTEN 仅作按钮2展示，无自身逻辑。
	var p023e1 := _ActionEffect.new()
	p023e1.effect_id = &"pilot_023_effect_01"
	p023e1.display_name = "当作维修"
	p023e1.description = "我方回合2次，可以将1张行动牌当作维修使用。"
	p023e1.mode = _TC.MODE_DIRECT
	p023e1.priority = 10
	p023e1.once_per_turn_key = &"pilot_023_effect_01"
	p023e1.once_per_turn_max = 2
	p023e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
		{"op": &"REPAIR_HAS_VALID_TARGET", "params": {"range": 1}},
	])
	p023e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p023e1.set_costs([])
	p023e1.set_actions([
		# 转化行动牌：列出持有者全部行动牌选1，选中牌当作维修打出。
		# discard_selected=false：原牌由 EXECUTE_USE_ACTION_CARD 结算时弃置，不在此重复弃。
		# virtual_transform=true：转化牌为虚拟牌，不消耗攻击次数、不受行动牌类型限制。
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"label": "选择1张行动牌当作维修使用",
			"confirm_verb": "当作维修",
			"cancel_label": "取消",
			"discard_selected": false,
			"per_card_actions": [
				{"type": &"EXECUTE_USE_ACTION_CARD", "params": {"card_instance_id": "$chosen_card.card_instance_id", "as_card_def_id": &"action_013_维修", "consume_original_card": true, "virtual_transform": true}},
			],
		}},
	])
	effects[p023e1.effect_id] = p023e1

	var p023e2 := _ActionEffect.new()
	p023e2.effect_id = &"pilot_023_effect_02"
	p023e2.display_name = "维修增强"
	p023e2.description = "我方使用的维修额外移去2损伤，且可以对4格范围内的其他机甲使用。"
	p023e2.mode = _TC.MODE_LISTEN
	p023e2.priority = 10
	p023e2.set_conditions([])
	p023e2.set_target_rules([])
	p023e2.set_costs([])
	p023e2.set_actions([])
	effects[p023e2.effect_id] = p023e2

	# ═══════════════════════════════════════════
	# pilot_024 琳（秩序 SR，cost 9, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（DIRECT 按钮1，每玩家回合1次）「当作维修」：选1张行动牌当作维修使用。
	#   复用坎得 effect_01 模式：CHOOSE_MANY_CARDS 列持有者行动牌选1 ->
	#   EXECUTE_USE_ACTION_CARD virtual_transform 当作维修打出。
	#   按钮条件（自定义 PILOT_024_CAN_USE_EFFECT1）：自己主阶段且有维修目标，
	#   或 维修窗口激活（被其他机甲 RE 请求时，窗口内按钮按回合重置可用）。
	# 效果2（LISTEN 按钮2 置灰+悬停，不注册 listener）「维修后双方各抽2」：
	#   我方对其他机甲使用维修后，我方与该机甲各抽2张行动牌（我方先抽、目标后抽）。
	#   实际由 TimingEngine CHOOSE_ONE repair_direct 挂钩实现（见 TimingEngine _pilot_024_*）。
	# 效果3（LISTEN 按钮3 置灰+悬停，不注册 listener）「请求维修」：
	#   4格内其他机甲可在其回合内1次请求我方对其使用1次无距离维修（RE 按钮，见
	#   equipment_panel 动态距离渲染 + pilot_024_re_request DIRECT 效果）。
	var p024e1 := _ActionEffect.new()
	p024e1.effect_id = &"pilot_024_effect_01"
	p024e1.display_name = "当作维修"
	p024e1.description = "每回合1次，可以将1张行动牌当作维修使用。"
	p024e1.mode = _TC.MODE_DIRECT
	p024e1.priority = 10
	p024e1.once_per_turn_key = &"pilot_024_effect_01"
	p024e1.once_per_turn_max = 1
	p024e1.set_conditions([
		{"op": &"PILOT_024_CAN_USE_EFFECT1"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p024e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p024e1.set_costs([])
	p024e1.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"label": "选择1张行动牌当作维修使用",
			"confirm_verb": "当作维修",
			"cancel_label": "取消",
			"discard_selected": false,
			"per_card_actions": [
				{"type": &"EXECUTE_USE_ACTION_CARD", "params": {"card_instance_id": "$chosen_card.card_instance_id", "as_card_def_id": &"action_013_维修", "consume_original_card": true, "virtual_transform": true}},
			],
		}},
	])
	effects[p024e1.effect_id] = p024e1

	var p024e2 := _ActionEffect.new()
	p024e2.effect_id = &"pilot_024_effect_02"
	p024e2.display_name = "维修后双方各抽2"
	p024e2.description = "我方对其他机甲使用维修后，我方与该机甲各抽2张行动牌。"
	p024e2.mode = _TC.MODE_LISTEN
	p024e2.priority = 10
	p024e2.set_conditions([])
	p024e2.set_target_rules([])
	p024e2.set_costs([])
	p024e2.set_actions([])
	effects[p024e2.effect_id] = p024e2

	var p024e3 := _ActionEffect.new()
	p024e3.effect_id = &"pilot_024_effect_03"
	p024e3.display_name = "请求维修"
	p024e3.description = "在4格范围内的其他机甲可以在其回合内1次，请求我方对其使用1次无距离限制的维修。"
	p024e3.mode = _TC.MODE_LISTEN
	p024e3.priority = 10
	p024e3.set_conditions([])
	p024e3.set_target_rules([])
	p024e3.set_costs([])
	p024e3.set_actions([])
	effects[p024e3.effect_id] = p024e3

	# ── pilot_024_re_request：请求方点击 RE 时触发的 DIRECT 效果（不注册 listener，由
	#    app_root RE 点击经 _net_granted_effect 触发）。动作1 原子标记 RE 已用（点击即消耗，
	#    即使琳拒绝也不刷新）；动作2 自定义 PILOT_024_RE_CONFIRM 弹确认窗给琳（TimingEngine
	#    _execute_actions 特判）：琳确认->开维修窗口并保持动作挂起（阻塞请求方回合），
	#    取消->无事发生（RE 已消耗）。窗口关闭后由 continue_action 恢复动作完成。
	var p024re := _ActionEffect.new()
	p024re.effect_id = &"pilot_024_re_request"
	p024re.display_name = "请求维修"
	p024re.description = "请求琳对本机甲使用1次无距离限制的维修。"
	p024re.mode = _TC.MODE_DIRECT
	p024re.priority = 10
	p024re.set_conditions([
		{"op": &"PILOT_024_RE_AVAILABLE"},
	])
	p024re.set_target_rules([{"rule": &"NO_TARGET"}])
	p024re.set_costs([])
	p024re.set_actions([
		{"type": &"PILOT_024_RE_MARK_USED", "params": {}},
		{"type": &"PILOT_024_RE_CONFIRM", "params": {}},
	])
	effects[p024re.effect_id] = p024re

	# ═══════════════════════════════════════════════════════════
	# pilot_025 约书亚（秩序 SR，cost 9, attack_limit 1, action_card_limit 4）
	# 权威：用户口述效果（无每回合1次限制）
	# ═══════════════════════════════════════════════════════════
	# 1 按钮（被动置灰）：2 个隐藏 LISTEN 合并（effect_01 建按钮1，effect_02 描述合并 hover）。
	#   effect_01 我方攻击时（ATTACK_PRE priority 40，SELF_MECH_IS_ATTACKER）：
	#       optional CHOOSE_ONE 二选一（可取消=不发动）：
	#       1a 立即抽1张装备牌设置到区域（否则弃置）-- 复用 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET
	#          （_handle_draw_equipment_pseudo 内联处理；设置走 set_equipment，即时使用 hook 自动生效）。
	#       1b 立即设置1张备用区装备牌 + 抽2张行动牌 -- PILOT_025_SELECT_RESERVE_AND_SET
	#          （TimingEngine 拦截：选备用牌->选目标槽->移除备用区设入->set_equipment 子动作->抽2）。
	#          条件 SELF_MECH_HAS_RESERVE_EQUIPMENT（无备用装备时此选项过滤不可用）。
	#   effect_02 我方被攻击时（ATTACK_PRE priority 10，SELF_MECH_IS_ATTACK_TARGET）：同 effect_01 的 CHOOSE_ONE。
	#   即时使用：设置的新装备若带 ATTACK_PRE 防御效果（被指定为目标时），时点已 fire 故由
	#   try_equipment_immediate_use 补 fire；替换攻击武器时 _weapon_still_held 失败 -> 未命中立即结算。
	#   （仅被攻击方设置防御装备才有意义；攻击方设置装备不影响本次攻击，但新装备即时使用可发动。）

	var p025_choose := {
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"title": "约书亚：选择其一",
			"description": "我方攻击或被攻击时，可以选择其一：立即抽1张装备牌设置到区域上（否则立即弃置）；立即设置1张处于备用区的装备牌，并抽2张行动牌。是否发动？",
			"options": [
				{
					"label": "抽1张装备牌立即设置",
					"actions": [
						{"type": &"DRAW_EQUIPMENT_AND_IMMEDIATELY_SET", "params": {
							"target_id": "$binding_context.mech_id", "count": 1,
						}},
					],
				},
				{
					"label": "设置备用区装备牌+抽2张行动牌",
					"condition": [{"op": &"SELF_MECH_HAS_RESERVE_EQUIPMENT"}],
					"actions": [
						{"type": &"PILOT_025_SELECT_RESERVE_AND_SET", "params": {}},
					],
				},
			],
		},
	}

	# ── pilot_025_effect_01 我方攻击时（按钮1，被动置灰，ATTACK_PRE priority 40）──
	var p025e1 := _ActionEffect.new()
	p025e1.effect_id = &"pilot_025_effect_01"
	p025e1.display_name = "约书亚·攻击时设置"
	p025e1.description = "【攻击时设置】我方攻击时，可以选择其一：立即抽1张装备牌设置到区域上（否则立即弃置）；立即设置1张处于备用区的装备牌，并抽2张行动牌。"
	p025e1.mode = _TC.MODE_LISTEN
	p025e1.priority = 40
	p025e1.listen_timing = _TC.ATTACK_PRE
	p025e1.listen_action_type = &"attack"
	p025e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	p025e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p025e1.set_costs([])
	p025e1.set_actions([p025_choose])
	effects[p025e1.effect_id] = p025e1

	# ── pilot_025_effect_02 我方被攻击时（隐藏被动，ATTACK_PRE priority 10）──
	var p025e2 := _ActionEffect.new()
	p025e2.effect_id = &"pilot_025_effect_02"
	p025e2.display_name = "约书亚·被攻时设置"
	p025e2.hide_button = true
	p025e2.merge_desc_into_index = 1
	p025e2.description = "【被攻时设置】我方被攻击时，可以选择其一：立即抽1张装备牌设置到区域上（否则立即弃置）；立即设置1张处于备用区的装备牌，并抽2张行动牌。"
	p025e2.mode = _TC.MODE_LISTEN
	p025e2.priority = 10
	p025e2.listen_timing = _TC.ATTACK_PRE
	p025e2.listen_action_type = &"attack"
	p025e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
	])
	p025e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p025e2.set_costs([])
	p025e2.set_actions([p025_choose.duplicate(true)])
	effects[p025e2.effect_id] = p025e2

	# ═══════════════════════════════════════════════
	# pilot_026 伊万（混乱 SR，cost 11, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════════
	# 效果1（DIRECT 按钮1，每回合1次）「当作设陷」：消耗1点当前回合攻击数，视为使用1次虚拟设陷。
	#   不消耗卡牌：直接执行设陷效果（ADD_STATUS SET_TRAP），与实体设陷牌 set_trap_direct 效果一致。
	#   按钮条件 IS_OWNER_MAIN_PHASE + ATTACK_COUNT_ABOVE(threshold 0 剩余>0)；cost SPEND_ATTACK_CHANCE。
	# 效果2（LISTEN 按钮2 置灰+悬停，不注册 listener）「设陷4次机会」：
	#   我方使用的设陷效果（实体牌/转化/虚拟）SET_TRAP 一律4层。实际由 GameActions.add_status
	#   SET_TRAP 分支查 mech_has_pilot_effect(gs, mech_id, pilot_026_effect_02) 实现。
	# 效果3（LISTEN 按钮3 置灰+悬停，不注册 listener）「陷阱不设损伤」：
	#   所有陷阱标记爆炸对我方仅造成伤害不设损伤。实际由 trap_explosion_action 查
	#   mech_has_pilot_effect(gs, mech_id, pilot_026_effect_03) 实现。
	var p026e1 := _ActionEffect.new()
	p026e1.effect_id = &"pilot_026_effect_01"
	p026e1.display_name = "当作设陷"
	p026e1.description = "每回合1次，消耗1点当前回合攻击数，视为使用出1张设陷。"
	p026e1.mode = _TC.MODE_DIRECT
	p026e1.priority = 10
	p026e1.once_per_turn_key = &"pilot_026_effect_01"
	p026e1.once_per_turn_max = 1
	p026e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"ATTACK_COUNT_ABOVE", "params": {"threshold": 0}},
	])
	p026e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p026e1.set_costs([{"cost_type": &"SPEND_ATTACK_CHANCE"}])
	p026e1.set_actions([
		{"type": &"ADD_STATUS", "params": {"status_type": &"SET_TRAP", "stacks": 2}},
	])
	effects[p026e1.effect_id] = p026e1

	var p026e2 := _ActionEffect.new()
	p026e2.effect_id = &"pilot_026_effect_02"
	p026e2.display_name = "设陷4次机会"
	p026e2.description = "我方使用的设陷共有4次机会设置陷阱。"
	p026e2.mode = _TC.MODE_LISTEN
	p026e2.priority = 10
	p026e2.set_conditions([])
	p026e2.set_target_rules([])
	p026e2.set_costs([])
	p026e2.set_actions([])
	effects[p026e2.effect_id] = p026e2

	var p026e3 := _ActionEffect.new()
	p026e3.effect_id = &"pilot_026_effect_03"
	p026e3.display_name = "陷阱不设损伤"
	p026e3.description = "陷阱对我方仅会造成伤害，不会设置损伤。"
	p026e3.mode = _TC.MODE_LISTEN
	p026e3.priority = 10
	p026e3.set_conditions([])
	p026e3.set_target_rules([])
	p026e3.set_costs([])
	p026e3.set_actions([])
	effects[p026e3.effect_id] = p026e3

	# ═══════════════════════════════════════════════
	# pilot_027 维罗妮卡（混乱 SR，cost 10, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════════
	# 效果1（LISTEN 按钮1 置灰+悬停）「获金分半」：4+X格范围内其他机甲获得非我方给予的金币时，
	#   我方获得其中一半（向下取整，剩下的留给该机甲）。监听 GameActions.gain_gold 虚拟action
	#   fire 的 GAIN_GOLD_AFTER；X 取本机师牌实例 counters["var_pilot_027_x"]。
	#   实际判定（gainer≠自己/距离≤4+X/非我方给予）在 handler PILOT_027_SPLIT_GOLD 内做，
	#   不满足静默跳过；分半的金币直接增减双方玩家字段，不走 gain_gold 避免递归再分半。
	# 效果2（LISTEN 按钮2 置灰+悬停，每回合1次）「给予金币X+1」：
	#   我方给予其他机甲金币时 X+1。监听 GIVE_GOLD_AFTER（from_player 传递时 fire）。
	#   条件 giver==自己 在 handler PILOT_027_X_INC 内判定。
	# 效果3（DIRECT 按钮3，每回合2次）「给予金币并使用行动牌」：
	#   我方回合内，给予4+X格范围内1台其他机甲至少2金币（至多当前金币，+5/-5 stepper），
	#   之后可使其立即使用1张可用行动牌。多阶段流程见 handler PILOT_027_GIFT_AND_USE。
	#   按钮可用性：主阶段 + 金币≥2（GOLD_ABOVE threshold 1）+ 范围内有其他机甲。
	#   不用 SPEND_GOLD cost（会自动扣2再叠加给金金额，双扣）；给金金额由 handler 一次扣。
	var p027e1 := _ActionEffect.new()
	p027e1.effect_id = &"pilot_027_effect_01"
	p027e1.display_name = "获金分半"
	p027e1.description = "4+X格范围内的其他机甲获得非我方给予的金币时，我方获得其中一半金币（向下取整，剩下留给该机甲）。"
	p027e1.mode = _TC.MODE_LISTEN
	p027e1.priority = 100
	p027e1.listen_timing = _TC.GAIN_GOLD_AFTER
	p027e1.listen_action_type = &"gold"
	p027e1.set_conditions([])
	p027e1.set_target_rules([])
	p027e1.set_costs([])
	p027e1.set_actions([{"type": &"PILOT_027_SPLIT_GOLD", "params": {}}])
	effects[p027e1.effect_id] = p027e1

	var p027e2 := _ActionEffect.new()
	p027e2.effect_id = &"pilot_027_effect_02"
	p027e2.display_name = "给予金币X+1"
	p027e2.description = "每回合1次，我方给予其他机甲金币时，X数值+1（X影响4+X范围）。"
	p027e2.mode = _TC.MODE_LISTEN
	p027e2.priority = 90
	p027e2.once_per_turn_key = &"pilot_027_effect_02"
	p027e2.once_per_turn_max = 1
	p027e2.listen_timing = _TC.GIVE_GOLD_AFTER
	p027e2.listen_action_type = &"gold"
	p027e2.set_conditions([])
	p027e2.set_target_rules([])
	p027e2.set_costs([])
	p027e2.set_actions([{"type": &"PILOT_027_X_INC", "params": {}}])
	effects[p027e2.effect_id] = p027e2

	var p027e3 := _ActionEffect.new()
	p027e3.effect_id = &"pilot_027_effect_03"
	p027e3.display_name = "给予金币并使用行动牌"
	p027e3.description = "我方回合2次，可以给予4+X格范围内的1台其他机甲至少2金币，之后可以使其立即使用1张行动牌。"
	p027e3.mode = _TC.MODE_DIRECT
	p027e3.priority = 100
	p027e3.once_per_turn_key = &"pilot_027_effect_03"
	p027e3.once_per_turn_max = 2
	p027e3.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"GOLD_ABOVE", "params": {"threshold": 1}},
		{"op": &"HAS_OTHER_MECH_IN_VARIABLE_RANGE", "params": {"base_range": 4, "variable_name": &"pilot_027_x"}},
	])
	p027e3.set_target_rules([])
	p027e3.set_costs([])
	p027e3.set_actions([{"type": &"PILOT_027_GIFT_AND_USE", "params": {}}])
	effects[p027e3.effect_id] = p027e3

	# ═══════════════════════════════════════════
	# pilot_028 乌尔（混乱 SR，cost 10, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果1（LISTEN 按钮1 置灰+悬停）「宣言」：每轮 ROUND_START 弹选框让乌尔玩家宣言
	#   1种行动牌类型（攻击/迎击/辅助，可取消=本轮无宣言）。选好后给所有玩家弹非阻塞展示浮窗，
	#   记录类型到机师牌实例 counters["var_pilot_028_declared"]，同时 X 重置为 0。
	#   流程在 handler PILOT_028_DECLARE（弹框 + 记录 + 展示；AI 拥有者自动宣言"攻击"）。
	# 效果2（LISTEN 按钮2 置灰+悬停）「需交牌」：本轮中 4+X 格范围内其他机甲使用宣言类型
	#   实体行动牌时（转化虚拟不算），须交给乌尔玩家2张行动牌才能生效；不交或牌不够（手牌<2）
	#   → 该行动牌照常结算进弃牌堆、仅效果不执行（use_action_card._step_execute_effects 读
	#   record._pilot_028_skip_effects）。监听 USE_ACTION_AT（牌已进临时区、效果未执行时）；
	#   handler PILOT_028_FORCE_TRIBUTE。
	# 效果3（LISTEN 按钮3 置灰+悬停）「X+1」：本轮每回合1次，乌尔自己使用宣言类型实体行动牌
	#   时 X+1。监听 USE_ACTION_AT；handler PILOT_028_X_INC。每回合1次用机师牌实例计数器
	#   counters["pilot_028_xinc_turn_<turn>"] 手动管理（不能用 once_per_turn_key：那会在任何
	#   无关行动牌使用时误耗次数）。
	var p028e1 := _ActionEffect.new()
	p028e1.effect_id = &"pilot_028_effect_01"
	p028e1.display_name = "宣言"
	p028e1.description = "每轮开始可宣言1种行动牌类型（攻击/迎击/辅助，可取消）。宣言后，本轮范围4+X内其他机甲使用该类型行动牌须交给我方2张行动牌才能生效；我方使用该类型行动牌时X+1。"
	p028e1.mode = _TC.MODE_LISTEN
	p028e1.priority = 10
	p028e1.listen_timing = _TC.ROUND_START
	p028e1.listen_action_type = &"turn"
	p028e1.set_conditions([])
	p028e1.set_target_rules([])
	p028e1.set_costs([])
	p028e1.set_actions([{"type": &"PILOT_028_DECLARE", "params": {}}])
	effects[p028e1.effect_id] = p028e1

	var p028e2 := _ActionEffect.new()
	p028e2.effect_id = &"pilot_028_effect_02"
	p028e2.display_name = "需交牌"
	p028e2.description = "本轮中，4+X格范围内其他机甲使用宣言类型行动牌时，须交给我方2张行动牌才能生效；不交或牌不够则行动牌照常进弃牌堆、效果不执行。"
	p028e2.mode = _TC.MODE_LISTEN
	p028e2.priority = 80
	p028e2.listen_timing = _TC.USE_ACTION_AT
	p028e2.listen_action_type = &"use_action_card"
	p028e2.set_conditions([])
	p028e2.set_target_rules([])
	p028e2.set_costs([])
	p028e2.set_actions([{"type": &"PILOT_028_FORCE_TRIBUTE", "params": {}}])
	effects[p028e2.effect_id] = p028e2

	var p028e3 := _ActionEffect.new()
	p028e3.effect_id = &"pilot_028_effect_03"
	p028e3.display_name = "X+1"
	p028e3.description = "每回合1次，我方使用宣言类型行动牌时，X数值+1（X影响4+X范围）。"
	p028e3.mode = _TC.MODE_LISTEN
	p028e3.priority = 90
	p028e3.listen_timing = _TC.USE_ACTION_AT
	p028e3.listen_action_type = &"use_action_card"
	p028e3.set_conditions([])
	p028e3.set_target_rules([])
	p028e3.set_costs([])
	p028e3.set_actions([{"type": &"PILOT_028_X_INC", "params": {}}])
	effects[p028e3.effect_id] = p028e3

	# ═══════════════════════════════════════════
	# pilot_029 克劳德（联邦 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（派生值占位，按钮1置灰+悬停）「远程武器范围+1」：使用远程武器攻击时，该攻击范围+1。
	# 实时重算于 GeneratedEquipmentEffects.get_passive_weapon_range_bonus（本机甲 pilot 槽克劳德 +
	# 狙击装·头部加成合并），不注册 listener（is_pilot_derived_effect 跳过），与狙击装头部同机制。
	# 效果2（DIRECT 主动，按钮2，每回合1次）「当作聚能」：我方回合1次，选1张行动牌当作聚能使用。
	# 流程（选行动牌在前）：optional 弃牌窗选1张行动牌（可取消不计次数）→ cost 移入临时区 →
	# EXECUTE_EFFECT_FIRE 执行标准聚能（energy_direct，GameSetupService 随克劳德注册，选武器施加聚能）→
	# DISCARD_TEMP_ZONE_CARDS 把临时区行动牌入弃牌堆。
	var p029e1 := _ActionEffect.new()
	p029e1.effect_id = &"pilot_029_effect_01"
	p029e1.display_name = "远程武器范围+1"
	p029e1.description = "使用远程武器攻击时，该攻击的范围+1。"
	p029e1.mode = _TC.MODE_LISTEN
	p029e1.priority = 10
	p029e1.set_conditions([])
	p029e1.set_target_rules([])
	p029e1.set_costs([])
	p029e1.set_actions([])
	effects[p029e1.effect_id] = p029e1

	var p029e2 := _ActionEffect.new()
	p029e2.effect_id = &"pilot_029_effect_02"
	p029e2.display_name = "当作聚能"
	p029e2.description = "每回合1次，可以将1张行动牌当作聚能使用：选择1张行动牌（可取消），然后选择自己区域内正面设置的1张武器装备牌，施加1层聚能状态。"
	p029e2.mode = _TC.MODE_DIRECT
	p029e2.priority = 10
	p029e2.once_per_turn_key = &"pilot_029_effect_02"
	p029e2.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
		{"op": &"OWNER_MECH_HAS_CHARGEABLE_WEAPON"},
	])
	p029e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p029e2.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true, "params": {"reason": &"pilot_conversion_cost", "exact_count": true, "to_temp_zone": true, "label": "选择当作聚能使用的1张行动牌"}},
	])
	p029e2.set_actions([
		{"type": &"EXECUTE_EFFECT_FIRE", "params": {"effect_id": &"energy_direct"}},
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p029e2.effect_id] = p029e2

	# ═══════════════════════════════════════════
	# pilot_030 布鲁克（联邦 R，cost 6, attack_limit 1, action_card_limit 4）
	# 权威文本：
	#   效果1「转守为攻」：每回合1次，可以将1张行动牌当作防御使用，之后下一个我方回合的攻击数+1（可叠加）。
	#   效果2「以身作盾」：相邻其他机甲被攻击时（我方需在此攻击范围内），可以使用防御响应此攻击，并将目标改为我方。
	# 通用化：效果1走迪恩转化模式（temp_zone 燃料牌）+ 通用攻击数机制 APPLY_NEXT_OWNER_TURN_ATTACK_BONUS；
	# 效果2走迪恩挡攻模式（REDIRECT_ATTACK_TARGET_TO_SELF），防御手段弹窗三选一（实体防御牌/转化防御/莱比尔EX防御）。
	# ═══════════════════════════════════════════

	# ── pilot_030_effect_01 布鲁克·转守为攻（转化防御）──
	# AVAILABILITY ATTACK_AT：布鲁克被攻击时，每回合1次，转化1张行动牌（temp_zone）当作防御使用
	# （RESPOND_ATTACK + 本次攻击护甲+5 + 损伤标记-1），之后给下个我方回合攻击数+1（可叠加，
	# 由 TurnService.start_turn 并入 max_attacks_per_turn 并清除，不延续到下下回合）。
	var p030e1 := _ActionEffect.new()
	p030e1.effect_id = &"pilot_030_effect_01"
	p030e1.display_name = "布鲁克·转守为攻"
	p030e1.description = "每回合1次，可以将1张行动牌当作防御使用（护甲+5、损伤-1），之后下一个我方回合的攻击数+1（可叠加）。"
	p030e1.mode = _TC.MODE_AVAILABILITY
	p030e1.priority = 10
	p030e1.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	p030e1.availability_priority = 5
	p030e1.listen_timing = _TC.ATTACK_AT
	p030e1.listen_action_type = &"attack"
	p030e1.once_per_turn_key = &"pilot_030_effect_01"
	p030e1.once_per_turn_max = 1
	p030e1.set_conditions([
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
		{"op": &"ATTACK_NOT_RESPONDED"},
	])
	p030e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p030e1.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "params": {"reason": &"pilot_conversion_cost", "exact_count": true, "to_temp_zone": true, "no_cancel": true, "label": "选择转化使用的1张行动牌"}},
	])
	p030e1.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {}},
		{"type": &"ADD_MECH_TEMP_ARMOR", "params": {"delta": 5, "mech_id": "$binding_context.mech_id"}},
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -1}},
		{"type": &"APPLY_NEXT_OWNER_TURN_ATTACK_BONUS", "params": {"mech_id": "$binding_context.mech_id", "stacks": 1}},
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p030e1.effect_id] = p030e1

	# ── pilot_030_effect_02 布鲁克·以身作盾（转移目标窗口 + 挡攻防御）──
	# AVAILABILITY ATTACK_AT（availability_condition = AVAIL_TRANSFER_TARGET：布鲁克非攻击目标，
	# 进转移目标窗口，而非响应窗口）。
	# 相邻其他机甲被攻击 + 布鲁克在攻击范围内 + 非布鲁克自己攻击 + 未响应 时可用。无每回合1次限制。
	# 选中后弹三选一防御手段：
	#   1) 实体防御牌：选1张手牌防御牌正常打出（先选牌防取消误 REDIRECT，打出走 use_action_card 完整流程）；
	#   2) 转化防御：消耗效果1额度（EFFECT_ONCE_PER_TURN_AVAILABLE 条件 + MARK_EFFECT_ONCE_PER_TURN_USED 标记），
	#      转化1张行动牌（temp_zone）当作防御（护甲+5/损伤-1），并给下个我方回合攻击数+1；
	#   3) 莱比尔EX防御：若持有莱比尔交牌转化的"防御"批次，用批次当作防御。
	# 三个分支均先 REDIRECT_ATTACK_TARGET_TO_SELF 把攻击目标改为布鲁克（保护被攻击友军，回退 PRE 重 fire）。
	var p030e2 := _ActionEffect.new()
	p030e2.effect_id = &"pilot_030_effect_02"
	p030e2.display_name = "布鲁克·以身作盾"
	p030e2.description = "相邻其他机甲被攻击且自身在此攻击范围内时，可以使用防御响应此攻击，并将目标改为自身。"
	p030e2.mode = _TC.MODE_AVAILABILITY
	p030e2.priority = 20
	p030e2.availability_condition = _TC.AVAIL_TRANSFER_TARGET  # 转移目标窗口：相邻友军被攻击时可用（非响应窗口）
	p030e2.availability_priority = 10
	p030e2.listen_timing = _TC.ATTACK_AT
	p030e2.listen_action_type = &"attack"
	p030e2.set_conditions([
		{"op": &"ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET"},
		{"op": &"SELF_MECH_IN_CURRENT_ATTACK_RANGE"},
		{"op": &"ATTACKER_IS_NOT_SELF_MECH"},
		{"op": &"ATTACK_NOT_RESPONDED"},
	])
	p030e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p030e2.set_costs([])
	p030e2.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": false, "title": "布鲁克·以身作盾", "description": "选择防御手段", "options": [
			{"label": "使用实体防御牌", "condition": [
				{"op": &"HAS_CARD_DEF_ID_IN_HAND", "params": {"card_def_id": &"action_009_防御"}},
			], "actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"HAND_CARDS", "card_def_id": &"action_009_防御", "min_count": 1, "max_count": 1, "store_result_key": &"pilot_030_defend_card", "label": "选择要使用的实体防御牌", "confirm_verb": "使用", "cancel_label": "取消"}},
				{"type": &"REDIRECT_ATTACK_TARGET_TO_SELF", "params": {"protect_target_id": "$payload.target_id"}},
				{"type": &"EXECUTE_USE_ACTION_CARD", "params": {"mech_id": "$binding_context.mech_id", "card_instance_id": "$runtime.pilot_030_defend_card", "as_card_def_id": &"action_009_防御", "virtual_transform": false}},
			]},
			{"label": "转化防御（消耗转守为攻额度，下个我方回合攻击数+1）", "condition": [
				{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {"once_per_turn_key": &"pilot_030_effect_01", "once_per_turn_max": 1}},
				{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
			], "actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": 1, "store_result_key": &"pilot_030_fuel_ids", "label": "选择转化使用的1张行动牌", "confirm_verb": "转化", "cancel_label": "取消"}},
				{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_030_fuel_ids"}},
				{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_030_effect_01"}},
				{"type": &"REDIRECT_ATTACK_TARGET_TO_SELF", "params": {"protect_target_id": "$payload.target_id"}},
				{"type": &"RESPOND_ATTACK", "params": {}},
				{"type": &"ADD_MECH_TEMP_ARMOR", "params": {"delta": 5, "mech_id": "$binding_context.mech_id"}},
				{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -1}},
				{"type": &"APPLY_NEXT_OWNER_TURN_ATTACK_BONUS", "params": {"mech_id": "$binding_context.mech_id", "stacks": 1}},
				{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
			]},
			{"label": "莱比尔EX防御", "condition": [
				{"op": &"PILOT_002_HAS_USABLE_BATCH", "params": {"named_type": &"防御"}},
			], "actions": [
				{"type": &"REDIRECT_ATTACK_TARGET_TO_SELF", "params": {"protect_target_id": "$payload.target_id"}},
				{"type": &"PILOT_002_USE_BATCH_AS_NAMED", "params": {"as_card_def_id": &"action_009_防御", "attack_is_active": false}},
			]},
		]}},
	])
	effects[p030e2.effect_id] = p030e2

	# ── pilot_031 莱特（联邦 R）──
	# 权威文本（用户）+2：我方回合1次，可以将任意张行动牌交给4格范围内1台其他机甲，
	# 每给出2张牌，之后我方和该机甲可以各抽1张行动牌，护甲+2（持续到下个我方回合开始）。
	# 通用化：
	#   - 目标：CHOOSE_OTHER_MECH + TARGET_IN_RANGE(4, hex_distance)（除自己外全部机甲，可取消不消耗次数）。
	#   - 选牌：CHOOSE_MANY_CARDS 整手行动牌多选，no_cancel=true（窗口不可取消，必须选≥1张确认）。
	#   - 交牌：post_actions 里 TRANSFER_ACTION_CARDS（$choice.card_ids 引用选中牌，TimingEngine 注入）。
	#   - X=floor(交牌数/2)：count_expr/delta_expr 用 int($choice.count / 2)；仅完整2张成组才抽牌/加护甲。
	#   - 双方各抽X（EXECUTE_GAIN_CARD mech_ids 解析目标玩家）；双方护甲+X*2 持续到下个我方回合开始
	#     （UNTIL_NEXT_OWNER_TURN + duration_owner_id=我方，TurnService 回合开始时清理）。
	var p031e1 := _ActionEffect.new()
	p031e1.effect_id = &"pilot_031_effect_01"
	p031e1.display_name = "交牌·共抽·护甲"
	p031e1.description = "我方回合1次，可以将任意张行动牌交给4格范围内1台其他机甲，每给出2张牌，之后我方和该机甲各抽1张行动牌，护甲+2（持续到下个我方回合开始）。"
	p031e1.mode = _TC.MODE_DIRECT
	p031e1.priority = 10
	p031e1.once_per_turn_key = &"pilot_031_effect_01"
	p031e1.once_per_turn_max = 1
	p031e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 4}},
	])
	p031e1.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 4, "metric": &"hex_distance"}},
	])
	p031e1.set_costs([])
	p031e1.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": -1,
			"label": "选择要交给目标的行动牌",
			"confirm_verb": "交给",
			"cancel_label": "取消",
			"discard_selected": false,  # 不弃置选中牌，交牌由 post_actions 的 TRANSFER_ACTION_CARDS 执行
			"no_cancel": true,
			"post_actions": [
				{"type": &"TRANSFER_ACTION_CARDS", "params": {"card_ids": "$choice.card_ids", "target_mech_id": "$payload.target_id", "from_player_id": "$binding_context.player_id"}},
				{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count_expr": "int($choice.count / 2)", "mech_ids": ["$binding_context.mech_id"], "reason": &"pilot_031_draw_self"}},
				{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count_expr": "int($choice.count / 2)", "mech_ids": ["$payload.target_id"], "reason": &"pilot_031_draw_target"}},
				{"type": &"MODIFY_ARMOR", "params": {"delta_expr": "int($choice.count / 2) * 2", "mech_id": "$binding_context.mech_id", "duration": &"UNTIL_NEXT_OWNER_TURN", "duration_owner_id": "$binding_context.player_id"}},
				{"type": &"MODIFY_ARMOR", "params": {"delta_expr": "int($choice.count / 2) * 2", "mech_id": "$payload.target_id", "duration": &"UNTIL_NEXT_OWNER_TURN", "duration_owner_id": "$binding_context.player_id"}},
			],
		},
	}])
	effects[p031e1.effect_id] = p031e1

	# ════════════════════════════════════════════════════════════
	# pilot_032 爱瑞娅（联邦 R，cost 8, attack_limit 2, action_card_limit 3）
	# ════════════════════════════════════════════════════════════

	# ── pilot_032_effect_01 弃1张行动牌·机师上限+2 ──
	# 我方回合1次（once_per_turn_max=1）：先弹窗弃1张我方行动牌（可取消=中止不计次数；
	#   无行动牌时按钮置灰 HAS_ACTION_CARD_IN_HAND），确认弃牌后再弹窗选场上1张机师牌
	#   （可取消=已弃牌不返还、不计次数），对其行动牌上限+2。
	# 独立机制（复制自亚伦 PILOT_014 并泛化出弃牌前置步骤，亚伦代码不动）：
	#   - PILOT_032_SELECT_TARGET_PILOT_AND_GRANT 自定义动作类型，TimingEngine 拦截驱动
	#     两阶段（pilot_032_pay 弃牌 -> pilot_032_select 选机师）。
	#   - 施加复用 grant_pilot_014_bonus（按参数 +2 status，UNTIL_NEXT_OWNER_TURN 到期、
	#     目标/来源机师牌换下、机甲被毁、刻托交换的清理路径自动覆盖本效果）。
	#   - HAS_ACTION_CARD_IN_HAND 放 set_conditions 安全：弃牌后重跑不经过 _execute_effect
	#     （phase 直接续跑到选机师弹窗 + 完成手动 mark once_per_turn，仿 pilot_019 链），
	#     手牌变空不会 conditions_not_met 静默跳过。
	var p032e1 := _ActionEffect.new()
	p032e1.effect_id = &"pilot_032_effect_01"
	p032e1.display_name = "弃1张·机师上限+2"
	p032e1.description = "我方回合1次，可以选择场上1张机师牌，弃置1张行动牌，使其行动牌上限+2（效果持续到下个我方回合开始）。"
	p032e1.mode = _TC.MODE_DIRECT
	p032e1.priority = 10
	p032e1.once_per_turn_key = &"pilot_032_effect_01"
	p032e1.once_per_turn_max = 1
	p032e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p032e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p032e1.set_costs([])
	p032e1.set_actions([{
		"type": &"PILOT_032_SELECT_TARGET_PILOT_AND_GRANT",
		"params": {
			"optional": true,
			"discard_count": 1,
			"bonus": 2,
		}
	}])
	effects[p032e1.effect_id] = p032e1

	# pilot_033 尤里（联邦 R，cost 7, attack_limit 1, action_card_limit 4）
	# ════════════════════════════════════════════════════════════

	# ── pilot_033_effect_01 弃装抽装（我方回合2次，DIRECT 主动按钮）──
	# 我方回合2次（once_per_turn_max=2）：点击弹"选1张装备牌"窗（OWNER_EQUIPMENT_CARDS 枚举
	#   装备手牌+该玩家所有机甲已设置槽位含备用区；min_count=1 必选、可取消=中止不消耗次数，
	#   确认即 mark once_per_turn），弃置所选牌后抽1张装备牌。
	# 无装备可弃时按钮置灰（HAS_EQUIPMENT_CARD）。
	var p033e1 := _ActionEffect.new()
	p033e1.effect_id = &"pilot_033_effect_01"
	p033e1.display_name = "弃装抽装"
	p033e1.description = "我方回合2次，可以弃置1张装备牌，之后抽1张装备牌。"
	p033e1.mode = _TC.MODE_DIRECT
	p033e1.priority = 10
	p033e1.once_per_turn_key = &"pilot_033_effect_01"
	p033e1.once_per_turn_max = 2
	p033e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_EQUIPMENT_CARD"},
	])
	p033e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p033e1.set_costs([])
	p033e1.set_actions([
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"OWNER_EQUIPMENT_CARDS",
				"max_count": 1,
				"min_count": 1,
				"store_result_key": &"pilot_033_discard_ids",
				"discard_selected": false,
				"label": "选择1张要弃置的装备牌",
				"confirm_verb": "弃置",
				"cancel_label": "取消",
			}
		},
		{
			"type": &"EXECUTE_DISCARD",
			"params": {
				"card_ids": "$runtime.pilot_033_discard_ids",
				"reason": &"pilot_033_discard",
			}
		},
		{
			"type": &"EXECUTE_GAIN_CARD",
			"params": {
				"from_zone": &"equipment_deck",
				"card_kind": &"equipment",
				"count": 1,
				"player_id": "$binding_context.player_id",
				"reason": &"pilot_033_draw",
			}
		},
	])
	effects[p033e1.effect_id] = p033e1

	# ── pilot_033_effect_02 弃装抽高级（本局1次，DIRECT 主动按钮）──
	# 本局游戏1次（once_per_game_key+max=1）：同上选1张装备弃置，之后抽1张高级装备牌。
	# 确认即 mark once_per_game（store_result_key 路径通用处理）。用满后按钮置灰。
	var p033e2 := _ActionEffect.new()
	p033e2.effect_id = &"pilot_033_effect_02"
	p033e2.display_name = "弃装抽高级"
	p033e2.description = "本局游戏1次，可以弃置1张装备牌，之后抽1张高级装备牌。"
	p033e2.mode = _TC.MODE_DIRECT
	p033e2.priority = 10
	p033e2.once_per_game_key = &"pilot_033_effect_02"
	p033e2.once_per_game_max = 1
	p033e2.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_EQUIPMENT_CARD"},
	])
	p033e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p033e2.set_costs([])
	p033e2.set_actions([
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"OWNER_EQUIPMENT_CARDS",
				"max_count": 1,
				"min_count": 1,
				"store_result_key": &"pilot_033_discard_ids",
				"discard_selected": false,
				"label": "选择1张要弃置的装备牌",
				"confirm_verb": "弃置",
				"cancel_label": "取消",
			}
		},
		{
			"type": &"EXECUTE_DISCARD",
			"params": {
				"card_ids": "$runtime.pilot_033_discard_ids",
				"reason": &"pilot_033_discard",
			}
		},
		{
			"type": &"DRAW_ADVANCED_EQUIPMENT",
			"params": {
				"player_id": "$binding_context.player_id",
				"count": 1,
			}
		},
	])
	effects[p033e2.effect_id] = p033e2

	# ═══════════════════════════════════════════
	# pilot_034 塞万提斯（联邦 R，cost 7, attack_limit 1, action_card_limit 4）
	# 2 按钮，均被动（LISTEN 置灰+悬停说明）：
	#   effect_01 未对我方造成伤害的攻击产生的损伤-1（LISTEN ATTACK_AFTER，只算攻击本身 base_damage）
	#   effect_02 记录对我方造成过伤害的其他机甲（LISTEN HP_CHANGE_AFTER）
	#   effect_02b 我方对记录过的机甲攻击命中时，弹窗确认可额外造成3伤害+回复我方3生命（LISTEN
	#               ATTACK_AFTER，hide_button 隐藏，描述合并到按钮2 hover）
	# ═══════════════════════════════════════════

	# ── pilot_034_effect_01 损伤减免（按钮1，被动）──
	# 未对我方造成伤害的攻击（base_damage==0，只算攻击本身伤害，不含巴托洛夫+3 等 ATTACK_AFTER 追加）
	# 产生的损伤-1。base_damage 由 attack._step_calculate_damage 快照（独立于 record.damage，
	# 避免同窗口其他 ATTACK_AFTER 监听器按优先级先 fire 改写）。
	var p034e1 := _ActionEffect.new()
	p034e1.effect_id = &"pilot_034_effect_01"
	p034e1.display_name = "塞万提斯·损伤减免"
	p034e1.description = "对我方造成伤害为0的攻击，其产生的损伤减少1。"
	p034e1.mode = _TC.MODE_LISTEN
	p034e1.priority = 10
	p034e1.listen_timing = _TC.ATTACK_AFTER
	p034e1.listen_action_type = &"attack"
	p034e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"ATTACK_BASE_DAMAGE_BELOW", "params": {"threshold": 1}},
	])
	p034e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p034e1.set_costs([])
	p034e1.set_actions([{
		"type": &"MODIFY_ATTACK_MARKERS",
		"params": {"delta": -1},
	}])
	effects[p034e1.effect_id] = p034e1

	# ── pilot_034_effect_02 铭记仇敌（按钮2，被动）──
	# 我方受到生命减少（HP_CHANGE_AFTER decrease）时，把伤害来源机甲记入本机师静态记录集。
	# 来源解析（PILOT_034_RECORD_DAMAGE_SOURCE）：hp_change.source.mech_id（效果伤害来源）→
	# 退回 source_action_id 指向的 attack 的 attacker_id（攻击伤害）；陷阱/无来源则跳过；排除自身。
	var p034e2 := _ActionEffect.new()
	p034e2.effect_id = &"pilot_034_effect_02"
	p034e2.display_name = "塞万提斯·铭记仇敌"
	p034e2.description = "记录所有对我方造成过伤害的其他机甲。我方对其攻击命中时，可额外造成3伤害并回复我方3生命。"
	p034e2.mode = _TC.MODE_LISTEN
	p034e2.priority = 10
	p034e2.listen_timing = _TC.HP_CHANGE_AFTER
	p034e2.listen_action_type = &"hp_change"
	p034e2.set_conditions([
		{"op": &"HP_CHANGE_TARGET_IS_SELF"},
		{"op": &"HP_CHANGE_METHOD_IS", "params": {"method": &"decrease"}},
	])
	p034e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p034e2.set_costs([])
	p034e2.set_actions([{
		"type": &"PILOT_034_RECORD_DAMAGE_SOURCE",
		"params": {},
	}])
	effects[p034e2.effect_id] = p034e2

	# ── pilot_034_effect_02b 复仇反击（隐藏被动，描述合并到按钮2 hover）──
	# 我方对记录过的机甲攻击命中（ATTACK_AFTER，ATTACK_TARGET_IN_PILOT_034_RECORDED）时，
	# 弹窗确认（CHOOSE_ONE optional）可额外对该机甲造成3伤害（效果伤害，来源=塞万提斯所属机甲，
	# 非攻击伤害，不产损伤）并回复我方3生命。永久保留记录，每次命中均可触发。
	# hide_button 隐藏第3按钮，merge_desc_into_index=2 描述合并到按钮2（effect_02）hover。
	var p034e2b := _ActionEffect.new()
	p034e2b.effect_id = &"pilot_034_effect_02b"
	p034e2b.display_name = "塞万提斯·复仇反击"
	p034e2b.description = "我方对记录过的机甲攻击命中时，可额外对其造成3伤害，并回复我方3生命。"
	p034e2b.mode = _TC.MODE_LISTEN
	p034e2b.priority = 10
	p034e2b.listen_timing = _TC.ATTACK_AFTER
	p034e2b.listen_action_type = &"attack"
	p034e2b.hide_button = true
	p034e2b.merge_desc_into_index = 2
	p034e2b.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HIT"},
		{"op": &"ATTACK_TARGET_IN_PILOT_034_RECORDED"},
	])
	p034e2b.set_target_rules([{"rule": &"NO_TARGET"}])
	p034e2b.set_costs([])
	p034e2b.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"title": "塞万提斯：复仇反击",
			"description": "命中曾伤害我方的机甲，是否额外造成3伤害并回复我方3生命？",
			"options": [{
				"label": "发动：额外造成3伤害并回复我方3生命",
				"actions": [
					{"type": &"EXECUTE_HP_CHANGE", "params": {
						"mech_ids": ["$payload.target_id"],
						"value": 3,
						"method": &"decrease",
						"reason": &"effect_damage",
						"source_mech_id": "$binding_context.mech_id",
					}},
					{"type": &"EXECUTE_HP_CHANGE", "params": {
						"mech_ids": ["$binding_context.mech_id"],
						"value": 3,
						"method": &"restore",
						"reason": &"pilot_034_heal",
					}},
				],
			}],
		},
	}])
	effects[p034e2b.effect_id] = p034e2b

	# ═══════════════════════════════════════════
	# pilot_035 库马斯（联邦 R，cost 6）
	# ═══════════════════════════════════════════
	# 效果："每轮开始时，可以选择1台其他机甲，本轮中该机甲每次抽取行动牌时，我方抽1张行动牌。"
	# 1 按钮（effect_02）+ 2 隐藏效果：
	#   effect_01（隐藏 reset，ROUND_START priority 20 先于选择清上轮标记）——取消选择/本轮不选
	#     = 本轮不监听，上轮选择不延续。
	#   effect_02（按钮，ROUND_START priority 10）——选1台其他机甲设为本轮标记（可取消）。
	#   effect_03（隐藏 listen，GAIN_CARD_AFTER）——标记机甲抽取行动牌时（统一 draw 标+行动牌来源），
	#     库马斯拥有者自动抽1张行动牌（EXECUTE_GAIN_CARD，强制）。
	# 判定"抽取"用 gain_card 内部统一 draw 标（card_ids 空 + 牌堆/弃牌堆来源）：
	#   觉醒（选牌获取）、识破偷牌、给予转移天然不触发；塔莉娅赐予/策略回收已统一走 gain_card。
	var p035e1 := _ActionEffect.new()
	p035e1.effect_id = &"pilot_035_effect_01"
	p035e1.display_name = "库马斯·轮始清标"
	p035e1.hide_button = true
	p035e1.merge_desc_into_index = 1
	p035e1.description = "每轮开始时清除上一轮选择的机甲（本轮重新选择；取消选择则本轮不生效）。"
	p035e1.mode = _TC.MODE_LISTEN
	p035e1.priority = 20
	p035e1.listen_timing = _TC.ROUND_START
	p035e1.listen_action_type = &"turn"
	p035e1.set_conditions([])
	p035e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p035e1.set_costs([])
	p035e1.set_actions([{"type": &"PILOT_035_CLEAR_MARK", "params": {}}])
	effects[p035e1.effect_id] = p035e1

	var p035e2 := _ActionEffect.new()
	p035e2.effect_id = &"pilot_035_effect_02"
	p035e2.display_name = "库马斯·狩猎契约"
	p035e2.description = "每轮开始时，可以选择1台其他机甲。本轮该机甲每次抽取行动牌时，我方抽1张行动牌。"
	p035e2.mode = _TC.MODE_LISTEN
	p035e2.priority = 10
	p035e2.listen_timing = _TC.ROUND_START
	p035e2.listen_action_type = &"turn"
	p035e2.set_conditions([
		{"op": &"HAS_OTHER_MECH_ON_FIELD"},
	])
	p035e2.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	p035e2.set_costs([])
	p035e2.set_actions([{"type": &"PILOT_035_SET_MARK", "params": {}}])
	effects[p035e2.effect_id] = p035e2

	var p035e3 := _ActionEffect.new()
	p035e3.effect_id = &"pilot_035_effect_03"
	p035e3.display_name = "库马斯·抽取联动"
	p035e3.hide_button = true
	p035e3.merge_desc_into_index = 1
	p035e3.description = "本轮所选机甲每次抽取行动牌时，我方抽1张行动牌。"
	p035e3.mode = _TC.MODE_LISTEN
	p035e3.priority = 10
	p035e3.listen_timing = _TC.GAIN_CARD_AFTER
	p035e3.listen_action_type = &"gain_card"
	p035e3.set_conditions([
		{"op": &"PILOT_035_MARK_ACTIVE"},
		{"op": &"GAIN_CARD_IS_DRAW"},
		{"op": &"GAIN_CARD_IS_ACTION_DRAW"},
		{"op": &"PILOT_035_DRAW_MECH_IS_MARKED"},
	])
	p035e3.set_target_rules([{"rule": &"NO_TARGET"}])
	p035e3.set_costs([])
	p035e3.set_actions([{
		"type": &"EXECUTE_GAIN_CARD",
		"params": {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
			"player_id": "$binding_context.player_id",
			"mech_ids": ["$binding_context.mech_id"],
			"reason": &"pilot_035_draw",
		},
	}])
	effects[p035e3.effect_id] = p035e3

	# ═══════════════════════════════════════════
	# pilot_036 菲丽丝（联邦 R，cost 5, attack_limit 1, action_card_limit 4）
	# 2 个主动 DIRECT 按钮（通用机制组装，不新增底层）：
	#   effect_01「消耗2金币抽1张行动牌」我方回合2次：金币≥2 才可点（GOLD_ABOVE），
	#     动作链 SPEND_GOLD(2) -> EXECUTE_GAIN_CARD(action_deck,1)。独立于基础 paid_draw 每回合1次额度。
	#   effect_02「弃置2张行动牌获得4金币」我方回合1次：手牌≥2 才可点（HAS_ACTION_CARD_IN_HAND count=2），
	#     动作链 CHOOSE_MANY_CARDS(OWNER_ACTION_HAND, min/max=2, store_result_key) -> EXECUTE_DISCARD -> GAIN_GOLD(4)。
	#     取消选择不计次数（store_result_key 确认路径才 mark once_per_turn）。
	var p036e1 := _ActionEffect.new()
	p036e1.effect_id = &"pilot_036_effect_01"
	p036e1.display_name = "消耗2金币抽1"
	p036e1.description = "我方回合2次，可以消耗2金币抽1张行动牌。"
	p036e1.mode = _TC.MODE_DIRECT
	p036e1.priority = 10
	p036e1.once_per_turn_key = &"pilot_036_effect_01"
	p036e1.once_per_turn_max = 2
	p036e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"GOLD_ABOVE", "threshold": 1},
	])
	p036e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p036e1.set_costs([{"cost_type": &"SPEND_GOLD", "amount": 2}])
	p036e1.set_actions([
		{
			"type": &"EXECUTE_GAIN_CARD",
			"params": {
				"from_zone": &"action_deck",
				"card_kind": &"action",
				"count": 1,
				"player_id": "$binding_context.player_id",
				"reason": &"pilot_036_paid_draw",
			}
		},
	])
	effects[p036e1.effect_id] = p036e1

	var p036e2 := _ActionEffect.new()
	p036e2.effect_id = &"pilot_036_effect_02"
	p036e2.display_name = "弃2行动获4金"
	p036e2.description = "我方回合1次，可以弃置2张行动牌获得4金币。"
	p036e2.mode = _TC.MODE_DIRECT
	p036e2.priority = 10
	p036e2.once_per_turn_key = &"pilot_036_effect_02"
	p036e2.once_per_turn_max = 1
	p036e2.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}},
	])
	p036e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p036e2.set_costs([])
	p036e2.set_actions([
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"OWNER_ACTION_HAND",
				"min_count": 2,
				"max_count": 2,
				"store_result_key": &"pilot_036_discard_ids",
				"discard_selected": false,
				"label": "选择要弃置的2张行动牌",
				"confirm_verb": "弃置",
				"cancel_label": "取消",
			}
		},
		{
			"type": &"EXECUTE_DISCARD",
			"params": {
				"card_ids": "$runtime.pilot_036_discard_ids",
				"reason": &"pilot_036_discard",
			}
		},
		{
			"type": &"GAIN_GOLD",
			"params": {
				"amount": 4,
				"player_id": "$binding_context.player_id",
			}
		},
	])
	effects[p036e2.effect_id] = p036e2

	# ═══════════════════════════════════════════
	# pilot_037 青瞳（联邦 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_037_effect_01 窥心夺牌（被动） ──
	# 每玩家回合2次（按座位计回合）。对方攻击我方（含双连目标之一）时
	# (ATTACK_PRE priority10)：查看攻击方所持行动牌，明牌选1张获得（face_up=true 展示牌面，
	# no_cancel=true 强制获得不可取消；攻击方无行动牌则自动跳过弹窗）。偷牌结算后若我方行动手牌数
	# > 攻击方行动手牌数（等于不算），本次攻击威力-4（MODIFY_ATTACK_MIGHT 写入 attack record extra_might）。
	# 双连多目标算同一攻击只触发1次（listener 每次 ATTACK_PRE fire 只跑一次动作链）。
	# 次数限制用通用「额度」机制（EFFECT_ONCE_PER_TURN_AVAILABLE 条件 + MARK_EFFECT_ONCE_PER_TURN_USED
	# 动作，布鲁克 pilot_030 同款）：不在 ActionEffect 上设 once_per_turn_key，避免 EXECUTE_STEAL 子动作
	# 挂起时 _execute_effect 提前 return（未走末尾自动 mark）导致额度永不消耗、或同步路径重复 mark。
	# 触发即消耗1次（无论攻击方有无牌——无牌跳过弹窗仍算本次触发）。
	var p037e1 := _ActionEffect.new()
	p037e1.effect_id = &"pilot_037_effect_01"
	p037e1.display_name = "窥心夺牌"
	p037e1.description = "每回合2次，被攻击时查看攻击方行动牌选1张获得；若之后我方行动牌数大于攻击方，本次攻击威力-4。"
	p037e1.mode = _TC.MODE_LISTEN
	p037e1.priority = 10
	p037e1.listen_timing = _TC.ATTACK_PRE
	p037e1.listen_action_type = &"attack"
	p037e1.set_conditions([
		{"op": &"SELF_MECH_IS_AMONG_ATTACK_TARGETS"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_037_effect_01",
			"once_per_turn_max": 2,
		}},
	])
	p037e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p037e1.set_costs([])
	p037e1.set_actions([
		# ① 消耗本次额度（触发即消耗，防挂起路径额度永不 mark）
		{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_037_effect_01"}},
		# ② 偷牌：from_attacker=true 从攻击方手牌取；to_target_id=青瞳机甲（获得方=青瞳玩家）；
		# 明牌选1张（face_up）+ 不可取消（no_cancel）；攻击方无牌时 steal 动作自动空转跳过。
		{"type": &"EXECUTE_STEAL", "params": {
			"from_attacker": true,
			"to_target_id": "$binding_context.mech_id",
			"chooser_id": "$binding_context.player_id",
			"count": 1,
			"choose": true,
			"face_up": true,
			"no_cancel": true,
			"optional": false,
			"card_kind": &"ACTION",
			"reason": &"pilot_037_steal",
		}},
		# ③ 偷后比较：我方（binding_context.mech_id 玩家）行动手牌数 > 攻击方（$payload.attacker_id 玩家）
		# → 本次攻击威力-4。顶层 CONDITIONAL_ACTIONS（TimingEngine 支持），条件满足才减威力。
		{"type": &"CONDITIONAL_ACTIONS", "params": {
			"conditions": [{"op": &"OWNER_ACTION_HAND_GREATER_THAN_MECH", "params": {"mech_id": "$payload.attacker_id"}}],
			"if_true_actions": [{"type": &"MODIFY_ATTACK_MIGHT", "params": {
				"delta": -4,
				"reason": &"pilot_037_peek_penalty",
			}}],
			"if_false_actions": [],
		}},
	])
	effects[p037e1.effect_id] = p037e1

	# ═══════════════════════════════════════════
	# pilot_038 奥黛尔（联邦，cost 5, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_038_effect_01 战术协同（主动 DIRECT 按钮） ──
	# 我方回合1次，可以选择最多2台4格范围内的机甲（可以包括我方），使其抽2张行动牌、回复3动力。
	# 通用机制组装，不绑定机师：
	#   ① CHOOSE_MANY_MECHS（新增通用多选机甲弹窗）：4格 hex 距离圆内存活机甲多选，
	#      include_self=true 自己可选、min=1/max=2、可中途取消；确认后 target_ids 存
	#      payload["pilot_038_selected_mechs"]。
	#   ② MARK_EFFECT_ONCE_PER_TURN_USED（显式计次）：确认选择才消耗回合额度，取消不计次。
	#      用「额度」机制（pilot_037 同款）：effect 上不设 once_per_turn_key——CHOOSE_MANY_MECHS
	#      挂起时 _execute_effect 提前 return 不走末尾自动 mark，且显式 mark 防重复。
	#   ③ FOR_EACH_TARGET 按选择顺序逐目标：EXECUTE_GAIN_CARD（mech_ids 数组字面量触发
	#      _extract_gain_card_params 的 has_explicit_mech_ids 反查目标玩家抽2张行动牌）+
	#      RESTORE_POWER（回目标 3 动力）。
	# 条件 HAS_OTHER_MECH_IN_HEX_RANGE include_self=true：自己距离0恒在范围内，条件实际等价于
	# 「4格内存在存活机甲」（保证按钮可用时必有可选项）。
	var p038e1 := _ActionEffect.new()
	p038e1.effect_id = &"pilot_038_effect_01"
	p038e1.display_name = "战术协同"
	p038e1.description = "我方回合1次，可以选择最多2台4格范围内的机甲（可以包括我方），使其抽2张行动牌，回复3动力。"
	p038e1.mode = _TC.MODE_DIRECT
	p038e1.priority = 10
	p038e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_038_effect_01",
			"once_per_turn_max": 1,
		}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 4, "include_self": true}},
	])
	p038e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p038e1.set_costs([])
	p038e1.set_actions([
		# ① 多选机甲（通用弹窗）：4格 hex 圆内可含自己，min=1/max=2，可中途取消
		{"type": &"CHOOSE_MANY_MECHS", "params": {
			"range": 4,
			"min_count": 1,
			"max_count": 2,
			"include_self": true,
			"store_result_key": &"pilot_038_selected_mechs",
			"label": "选择最多2台4格范围内的机甲（含我方）",
		}},
		# ② 确认后消耗本次回合额度（取消选择则不计次）
		{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_038_effect_01"}},
		# ③ 按选择顺序逐目标：抽2张行动牌 + 回复3动力
		{"type": &"FOR_EACH_TARGET", "params": {
			"targets": "$runtime.pilot_038_selected_mechs",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"EXECUTE_GAIN_CARD", "params": {
					"from_zone": &"action_deck",
					"card_kind": &"action",
					"count": 2,
					"mech_ids": ["$current_target.mech_id"],
					"reason": &"pilot_038_draw",
				}},
				{"type": &"RESTORE_POWER", "params": {
					"mech_id": "$current_target.mech_id",
					"amount": 3,
				}},
			],
		}},
	])
	effects[p038e1.effect_id] = p038e1

	# pilot_039 铠威（联邦，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 1 个效果按钮（被动+主动结合）：
	#   「若发动的攻击被响应，则此攻击结算后可以抽1张行动牌，之后再立即发动1次攻击。」
	# 被动 LISTEN ATTACK_SETTLE priority 30（最高，先于反击 effect2(20)/闪击 effect2(10)）：
	#   我方发动的每次攻击（含迎击/反击/效果触发攻击/双连各 fork/闪击附加攻击）结算时，
	#   若本次攻击被响应（responded=true，含迎击/装备响应/机师牌任意响应）则登记一次触发。
	# 攻击动作（action_completed）完成后：弹「抽1张行动牌并立即发动1次攻击/取消」确认窗；
	# 确认 -> 抽1张行动牌 + 打开攻击窗口；窗口期间只允许发动攻击（攻击牌/攻击类主动效果/
	# 投掷式飞弹），不依赖回合攻击次数、不消耗攻击次数；发动攻击即关闭窗口。
	# 被响应攻击若为窗口发动的攻击，会再次触发本效果（递归是铠威的玩法，每轮弹窗确认=安全阀）。
	# 通用攻击窗口机制（attack_window_* helpers）不绑定机师：任何带 PILOT_039_SCHEDULE_AFTER_ATTACK
	# 动作的效果都可复用。流程全部 PvP 锁步确定性一致。
	var p039e1 := _ActionEffect.new()
	p039e1.effect_id = &"pilot_039_effect_01"
	p039e1.display_name = "被响应后抽牌再攻"
	p039e1.description = "若发动的攻击被响应，则此攻击结算后可以抽1张行动牌，之后再立即发动1次攻击。"
	p039e1.mode = _TC.MODE_LISTEN
	p039e1.priority = 30
	p039e1.listen_timing = _TC.ATTACK_SETTLE
	p039e1.listen_action_type = &"attack"
	p039e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		# ATTACK_WAS_RESPONDED 读 attack.record.responded（迎击/装备/机师牌任意响应均置 true）。
		# 不能用 ATTACK_RECORD_FLAG_IS_SET——那是读 _effect_flags 结构（pilot_018 专用），
		# 不读 responded 布尔字段。
		{"op": &"ATTACK_WAS_RESPONDED"},
	])
	p039e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p039e1.set_costs([])
	p039e1.set_actions([
		{"type": &"PILOT_039_SCHEDULE_AFTER_ATTACK", "params": {}},
	])
	effects[p039e1.effect_id] = p039e1

	# ═══════════════════════════════════════════
	# pilot_040 泰格（帝国，cost 6，R 稀有度，attack_limit 1）
	# ═══════════════════════════════════════════

	# ── pilot_040_effect_01 近战锁定（被动 LISTEN，攻击时弃牌对目标施加锁定） ──
	# 「使用近战武器攻击时，可弃置1张行动牌对目标施加锁定效果（目标可以弃置1张正面设置的装备牌取消此效果）。」
	# 触发：我方近战武器攻击的 ATTACK_PRE（priority 30；我方无行动牌则条件不满足，不触发）。
	# 流程（合并式弹窗：选1张行动牌即发动；取消=不发动）：
	#   ① CHOOSE_MANY_CARDS（OWNER_ACTION_HAND, min=max=1, 可取消, store_result_key）：
	#     选1张行动牌=确认发动；取消=不发动（store 路径 resume 经 _seq 续跑剩余动作）。
	#   ② EXECUTE_DISCARD：弃置所选行动牌。
	#   ③ FOR_EACH_TARGET（$payload.target_ids）：对攻击所有目标施加锁定（duration=1，
	#     skip_clear_on_hit=true：攻击命中不清除，持续到回合末自然清除——否则目标白挨一下锁自动
	#     消失，「目标可弃装备解除锁」形同虚设）。source_card_id=泰格 pilot 卡实例，
	#     供弃装解锁按来源精确移除（不误删拘束钩爪/其他机师施加的 LOCKED）。
	#   ④ FOR_EACH_TARGET（$payload.target_ids）：逐目标弹窗——目标玩家可弃置1张正面设置的
	#     装备牌（face_up，含部件/武器；不含背面备用区/手牌/机师/事件牌）取消锁住自己的锁；
	#     取消弹窗=不弃置=锁保留。chooser_mech_id=$current_target.mech_id 把弹窗路由给目标玩家
	#     （多目标各自独立弹窗，PvP/PvP3 任意数量人类玩家通用；AI 暂不处理）。
	#     per_card_actions=REMOVE_STATUS（按 status_type=LOCKED + source_card_id 精确移除本来源的锁）。
	# 引擎支撑：TimingEngine FOR_EACH_TARGET 内嵌 CHOOSE_MANY_CARDS（_flat_item_choose_many_cards，
	# _fet_cm_executed 逐目标守卫）+ _seq 中 FOR_EACH_TARGET 分支 + chooser_mech_id 路由。
	# 该效果不封装通用组件——效果本身即组件，他人复用直接复制+修改。
	var p040e1 := _ActionEffect.new()
	p040e1.effect_id = &"pilot_040_effect_01"
	p040e1.display_name = "近战锁定"
	p040e1.description = "使用近战武器攻击时，可弃置1张行动牌对目标施加锁定效果（目标可以弃置1张正面设置的装备牌取消此效果）。"
	p040e1.mode = _TC.MODE_LISTEN
	p040e1.priority = 30
	p040e1.listen_timing = _TC.ATTACK_PRE
	p040e1.listen_action_type = &"attack"
	p040e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p040e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p040e1.set_costs([])
	p040e1.set_actions([
		# ① 选1张行动牌弃置（合并式：选牌即确认发动；取消=不发动，无事发生）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"store_result_key": &"pilot_040_discard_action",
			"label": "选择1张要弃置的行动牌（弃置后对目标施加锁定）",
			"confirm_verb": "弃置并发动",
			"cancel_label": "不发动",
		}},
		# ② 弃置所选行动牌（card_ids 裸字符串引用 store_result_key 数组，勿用 [] 包裹成嵌套数组）
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.pilot_040_discard_action",
			"reason": &"pilot_040_discard_action",
		}},
		# ③ 对攻击所有目标施加预判式锁定（duration=1）
		{"type": &"FOR_EACH_TARGET", "params": {
			"targets": "$payload.target_ids",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"APPLY_OR_CHECK_LOCKED", "params": {
					"mode": &"apply",
					"duration": 1,
					# 规则：锁定持续到目标下一次被攻击命中时结束（命中即清除）。
					# false=注册命中清除监听器，与预判(ADD_STATUS 默认)一致。
					"skip_clear_on_hit": false,
					"target_id": "$current_target.mech_id",
					"source_player_id": "$binding_context.player_id",
					"source_card_id": "$binding_context.card_instance_id",
				}},
			],
		}},
		# ④ 逐目标弹窗：目标可弃1张正面设置装备牌取消锁住自己的锁（取消=锁保留）
		{"type": &"FOR_EACH_TARGET", "params": {
			"targets": "$payload.target_ids",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {
					"source": &"ATTACK_TARGET_EQUIPMENT",
					"chooser_mech_id": "$current_target.mech_id",
					"min_count": 0,
					"max_count": 1,
					"discard_selected": true,
					"discard_reason": &"pilot_040_equip_unlock",
					"per_card_actions": [
						{"type": &"REMOVE_STATUS", "params": {
							"target_id": "$current_target.mech_id",
							"status_type": &"LOCKED",
							"source_card_id": "$binding_context.card_instance_id",
						}},
					],
					"label": "选择1张要弃置的装备牌（弃置后取消锁定）",
					"confirm_verb": "弃置",
					"cancel_label": "不弃置",
				}},
			],
		}},
	])
	effects[p040e1.effect_id] = p040e1

	# ═══════════════════════════════════════════
	# pilot_041 盖奇特（帝国 R，cost 8, attack_limit 2, action_card_limit 2）
	# ═══════════════════════════════════════════

	# ── pilot_041_effect_01 花费3金抽2（主动 DIRECT） ──
	# 我方回合1次：金币≥3 才可点（GOLD_ABOVE threshold=2），
	# 动作链 SPEND_GOLD(3) -> EXECUTE_GAIN_CARD(action_deck,2)。
	# 独立于基础 paid_draw（每回合1次）额度。复用通用付费抽牌机制（菲丽丝 pilot_036 同款结构），
	# 与效果绑定：任意卡牌 effect_ids 含 pilot_041_effect_01 即自动获得该按钮/行为，无机师硬编码。
	var p041e1 := _ActionEffect.new()
	p041e1.effect_id = &"pilot_041_effect_01"
	p041e1.display_name = "花费3金抽2"
	p041e1.description = "我方回合1次，可以花费3金币抽2张行动牌。"
	p041e1.mode = _TC.MODE_DIRECT
	p041e1.priority = 10
	p041e1.once_per_turn_key = &"pilot_041_effect_01"
	p041e1.once_per_turn_max = 1
	p041e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"GOLD_ABOVE", "threshold": 2},
	])
	p041e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p041e1.set_costs([{"cost_type": &"SPEND_GOLD", "amount": 3}])
	p041e1.set_actions([
		{
			"type": &"EXECUTE_GAIN_CARD",
			"params": {
				"from_zone": &"action_deck",
				"card_kind": &"action",
				"count": 2,
				"player_id": "$binding_context.player_id",
				"reason": &"pilot_041_paid_draw",
			}
		},
	])
	effects[p041e1.effect_id] = p041e1

	# ═══════════════════════════════════════════
	# pilot_042 德伦迪（帝国 SR，cost 8, attack_limit 2, action_card_limit 3）
	# ═══════════════════════════════════════════

	# ── pilot_042_effect_01 弃牌回补（被动 LISTEN） ──
	# 每次弃置自己的行动牌后（DISCARD_AFTER），强制抽1张行动牌。
	# 触发范围（用户裁定）：仅从行动手牌（from_zone=action_hand）弃置的行动牌算；
	# 转化临时区弃置、他人弃的牌不算。按「次」触发：一次弃置动作（无论弃几张）
	# 只 fire 一次 DISCARD_AFTER，故抽1张。触发源覆盖：主动/被动效果弃牌、
	# 回合结束超限弃牌（DeckService.discard_card 走 discard_card 动作发时点）等。
	# 时序：DISCARD_AFTER 在弃置动作结算（DISCARD_SETTLE）之前，天然先于
	# 肯耳忒（pilot_019）的「弃后 0 张行动牌」检查抽牌。
	# 通用机制：LISTEN 时点 + DISCARD_INCLUDED_OWNER_ACTION_CARD 条件（通用条件，
	# 与效果绑定，任意卡 effect_ids 含此 id 即生效）+ EXECUTE_GAIN_CARD（mech_ids
	# 挂到持有者机甲，保证后续再弃置时 from_mech_id 归属正确）。
	var p042e1 := _ActionEffect.new()
	p042e1.effect_id = &"pilot_042_effect_01"
	p042e1.display_name = "弃牌回补"
	p042e1.description = "每次弃置自己的行动牌后，抽1张行动牌。"
	p042e1.mode = _TC.MODE_LISTEN
	p042e1.priority = 10
	p042e1.listen_timing = _TC.DISCARD_AFTER
	p042e1.listen_action_type = &"discard_card"
	p042e1.set_conditions([
		{"op": &"DISCARD_INCLUDED_OWNER_ACTION_CARD", "params": {"from_zone": &"action_hand"}},
	])
	p042e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p042e1.set_costs([])
	p042e1.set_actions([
		{
			"type": &"EXECUTE_GAIN_CARD",
			"params": {
				"from_zone": &"action_deck",
				"card_kind": &"action",
				"count": 1,
				"player_id": "$binding_context.player_id",
				"mech_ids": ["$binding_context.mech_id"],
				"reason": &"pilot_042_refill",
			}
		},
	])
	effects[p042e1.effect_id] = p042e1

	# ── pilot_042_effect_02 弃牌换牌（主动 DIRECT） ──
	# 我方回合2次，可以弃置1张行动牌，或弃置所有行动牌之后再抽1张行动牌。
	# 次数用通用「额度」机制（EFFECT_ONCE_PER_TURN_AVAILABLE 条件 + MARK_EFFECT_ONCE_PER_TURN_USED
	# 动作，pilot_037/038 同款）：效果挂起于 CHOOSE_ONE/子动作时末尾自动 mark 可能不执行，
	# 显式 mark 保证选分支即消耗；取消首层弹窗不计次数。
	# 分支1（弃1张）：CHOOSE_MANY_CARDS(OWNER_ACTION_HAND, min/max=1, no_cancel) 恰好选1张
	#   -> MARK 计次 -> EXECUTE_DISCARD 弃置（触发效果1抽1）。
	# 分支2（弃所有）：MARK 计次 -> EXECUTE_DISCARD(discard_all_action_hand 通用参数，弃全部手牌
	#   行动牌，触发效果1抽1) -> EXECUTE_GAIN_CARD 之后抽1张（子动作等弃置完整结算即 DISCARD_SETTLE 之后）。
	# 空手时 HAS_ACTION_CARD_IN_HAND(minimum=1) 条件不满足按钮置灰（避免「弃所有」空手免费抽1）。
	var p042e2 := _ActionEffect.new()
	p042e2.effect_id = &"pilot_042_effect_02"
	p042e2.display_name = "弃牌换牌"
	p042e2.description = "我方回合2次，可以弃置1张行动牌，或弃置所有行动牌之后再抽1张行动牌。"
	p042e2.mode = _TC.MODE_DIRECT
	p042e2.priority = 10
	p042e2.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_042_effect_02",
			"once_per_turn_max": 2,
		}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
	])
	p042e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p042e2.set_costs([])
	p042e2.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "title": "德伦迪·弃牌换牌", "description": "选择弃牌方式", "options": [
				{
					"label": "弃置1张行动牌",
					"actions": [
						{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": 1, "store_result_key": &"pilot_042_discard_one", "discard_selected": false, "no_cancel": true, "label": "选择要弃置的1张行动牌", "confirm_verb": "弃置"}},
						{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_042_effect_02"}},
						{"type": &"EXECUTE_DISCARD", "params": {"card_ids": "$runtime.pilot_042_discard_one", "reason": &"pilot_042_discard_one"}},
					]
				},
				{
					"label": "弃置所有行动牌，之后再抽1张行动牌",
					"actions": [
						{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_042_effect_02"}},
						{"type": &"EXECUTE_DISCARD", "params": {"discard_all_action_hand": true, "reason": &"pilot_042_discard_all"}},
						{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1, "player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"], "reason": &"pilot_042_discard_all_draw"}},
					]
				},
			]},
		},
	])
	effects[p042e2.effect_id] = p042e2

	# ═══════════════════════════════════════════
	# pilot_043 格温（帝国 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1「宣言抽取」（1 按钮 + 1 隐藏，全通用机制组装，复用=整段复制改参数）：
	#   effect_01（按钮，LISTEN GAIN_CARD_BEFORE）——我方"抽取行动牌"的获取牌动作发出获取牌前
	#     时点时弹单选（攻击/迎击/辅助，可取消）。选择后经 CHOOSE_ONE 的通用 store_record_key
	#     机制，把宣言类型写入本次 gain_card 动作 record 的 declared_action_type 键；
	#     取消则不写（无后续）。
	#   effect_02（隐藏，LISTEN GAIN_CARD_AFTER）——本次抽到的牌（drawn_card_ids）中含宣言类型
	#     的行动牌时（复数抽到只要含1张即生效），立即再抽 1 张行动牌（EXECUTE_GAIN_CARD）。
	#     新动作会再次触发本效果（可连续宣言，直到抽空牌堆/取消/不含类型）。
	# "抽取行动牌"判定用 gain_card 统一抽取标（gain_card_action extract_info 预打 draw/draw_card_kind，
	#   回合开始抽牌/2金币抽牌/效果抽牌/回忆弃牌堆抽均命中）+ 抽取方==格温拥有者
	#   （GAIN_CARD_DRAW_OWNER_IS_BINDING）。
	var p043e1 := _ActionEffect.new()
	p043e1.effect_id = &"pilot_043_effect_01"
	p043e1.display_name = "宣言抽取"
	p043e1.description = "即将抽取行动牌时，可以宣言1种行动牌类型(攻击，迎击，辅助)，若之后抽到的牌中存在宣言类型，则可以再抽1张行动牌。"
	p043e1.mode = _TC.MODE_LISTEN
	p043e1.priority = 10
	p043e1.listen_timing = _TC.GAIN_CARD_BEFORE
	p043e1.listen_action_type = &"gain_card"
	p043e1.set_conditions([
		{"op": &"GAIN_CARD_IS_DRAW"},
		{"op": &"GAIN_CARD_IS_ACTION_DRAW"},
		{"op": &"GAIN_CARD_DRAW_OWNER_IS_BINDING"},
	])
	p043e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p043e1.set_costs([])
	p043e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"store_record_key": &"declared_action_type",
			"options": [
				{"label": "宣言攻击", "value": &"攻击", "actions": []},
				{"label": "宣言迎击", "value": &"迎击", "actions": []},
				{"label": "宣言辅助", "value": &"辅助", "actions": []},
			],
		},
	}])
	effects[p043e1.effect_id] = p043e1

	var p043e2 := _ActionEffect.new()
	p043e2.effect_id = &"pilot_043_effect_02"
	p043e2.display_name = "宣言抽牌"
	p043e2.hide_button = true
	p043e2.merge_desc_into_index = 1
	p043e2.description = "宣言后，若本次抽到的行动牌中存在宣言类型，则立即再抽1张行动牌。"
	p043e2.mode = _TC.MODE_LISTEN
	p043e2.priority = 10
	p043e2.listen_timing = _TC.GAIN_CARD_AFTER
	p043e2.listen_action_type = &"gain_card"
	p043e2.set_conditions([
		{"op": &"GAIN_CARD_IS_DRAW"},
		{"op": &"GAIN_CARD_IS_ACTION_DRAW"},
		{"op": &"GAIN_CARD_DRAW_OWNER_IS_BINDING"},
		{"op": &"GAIN_CARD_DRAWN_INCLUDE_RECORD_ACTION_TYPE", "params": {"record_key": &"declared_action_type"}},
	])
	p043e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p043e2.set_costs([])
	p043e2.set_actions([{
		"type": &"EXECUTE_GAIN_CARD",
		"params": {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
			"player_id": "$binding_context.player_id",
			"mech_ids": ["$binding_context.mech_id"],
			"reason": &"pilot_043_declared_draw",
		},
	}])
	effects[p043e2.effect_id] = p043e2

	# ═══════════════════════════════════════════
	# pilot_044 索伦（帝国 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（1 个显示按钮 + 1 个隐藏监听，描述合并到按钮1）：
	# 每个我方回合开始时（TURN_START，抽牌前）与回合结束后（TURN_AFTER_END，已弃超上限牌），
	# 记录我方机甲所有区域损伤总数 X，之后抽 X+1 张行动牌，再弹窗列出手牌必须选 X 张弃置（不能取消）。
	# 组件全部通用：PILOT_044_COMPUTE_DAMAGE（效果专属 act_type 但参数化可复制：算损伤数 X 写
	#   payload[store_key]、可选写 X+1） + EXECUTE_GAIN_CARD（dynamic count $runtime）+ EXECUTE_DISCARD
	#   （choose+dynamic count+no_cancel：持有者自选弃置）。复用=整段复制改 store_key 即可，与效果绑定。
	# 时点优先级均 10（IS_OWNER_TURN 过滤「每个我方回合」）。

	# ── effect_01 显示按钮，监听 TURN_START（回合开始时，抽牌前）──
	var p044e1 := _ActionEffect.new()
	p044e1.effect_id = &"pilot_044_effect_01"
	p044e1.display_name = "损伤X抽X+1弃X"
	p044e1.description = "每个我方回合开始时与回合结束后，记录机甲所有区域的损伤数为X，之后抽X+1张行动牌，再弃置X张行动牌。"
	p044e1.mode = _TC.MODE_LISTEN
	p044e1.priority = 10
	p044e1.listen_timing = _TC.TURN_START
	p044e1.listen_action_type = &"turn"
	p044e1.set_conditions([{"op": &"IS_OWNER_TURN"}])
	p044e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p044e1.set_costs([])
	p044e1.set_actions([
		{"type": &"PILOT_044_COMPUTE_DAMAGE", "params": {
			"mech_id": "$binding_context.mech_id",
			"store_key": &"pilot_044_discard_x",
			"plus_one_store_key": &"pilot_044_draw_x",
		}},
		{"type": &"EXECUTE_GAIN_CARD", "params": {
			"from_zone": &"action_deck", "card_kind": &"action",
			"count": "$runtime.pilot_044_draw_x",
			"player_id": "$binding_context.player_id",
			"mech_ids": ["$binding_context.mech_id"],
			"reason": &"pilot_044_draw",
		}},
		{"type": &"EXECUTE_DISCARD", "params": {
			"from_target": false, "choose": true,
			"count": "$runtime.pilot_044_discard_x",
			"face_up": true, "no_cancel": true,
			"reason": &"pilot_044_discard",
		}},
	])
	effects[p044e1.effect_id] = p044e1

	# ── effect_02 隐藏（描述合并到按钮1），监听 TURN_AFTER_END（回合结束后，已弃超上限）──
	var p044e2 := _ActionEffect.new()
	p044e2.effect_id = &"pilot_044_effect_02"
	p044e2.display_name = "损伤X抽X+1弃X(回合末)"
	p044e2.hide_button = true
	p044e2.merge_desc_into_index = 1
	p044e2.description = "每个我方回合结束后，同样记录机甲所有区域损伤数X，抽X+1张行动牌，再弃置X张行动牌。"
	p044e2.mode = _TC.MODE_LISTEN
	p044e2.priority = 10
	p044e2.listen_timing = _TC.TURN_AFTER_END
	p044e2.listen_action_type = &"turn"
	p044e2.set_conditions([{"op": &"IS_OWNER_TURN"}])
	p044e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p044e2.set_costs([])
	p044e2.set_actions([
		{"type": &"PILOT_044_COMPUTE_DAMAGE", "params": {
			"mech_id": "$binding_context.mech_id",
			"store_key": &"pilot_044_discard_x",
			"plus_one_store_key": &"pilot_044_draw_x",
		}},
		{"type": &"EXECUTE_GAIN_CARD", "params": {
			"from_zone": &"action_deck", "card_kind": &"action",
			"count": "$runtime.pilot_044_draw_x",
			"player_id": "$binding_context.player_id",
			"mech_ids": ["$binding_context.mech_id"],
			"reason": &"pilot_044_draw",
		}},
		{"type": &"EXECUTE_DISCARD", "params": {
			"from_target": false, "choose": true,
			"count": "$runtime.pilot_044_discard_x",
			"face_up": true, "no_cancel": true,
			"reason": &"pilot_044_discard",
		}},
	])
	effects[p044e2.effect_id] = p044e2

	# ═══════════════════════════════════════════
	# pilot_059 薇尔（联邦 N，cost 3, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（1 个显示按钮，被动 LISTEN，监听 TURN_START 抽牌前）：
	#   我方回合开始时，可以移除或设置我方1损伤（弹损伤调整面板：每槽位 +1/-1+取消，
	#   +1 走标准规则优先放有装备牌区域，仅1次机会，也可取消不调整）；
	#   之后统计我方机甲所有区域损伤数 N：
	#     N<threshold → 获得 gold_amount 金币
	#     N==threshold → 视为使用 1 张补给（抽 2 行动 + 1 装备，纯虚拟，复用补给牌逻辑）
	#     N>threshold → 移除我方最多 max_remove 损伤（弹最多移除面板，可中途取消）
	# 流程 handler PILOT_059_TURN_START_FLOW 多阶段挂起（首次弹调整面板 →
	#   resume 应用调整+算 N → _seq 串行跑分支动作链）；N 复用 PILOT_044_COMPUTE_DAMAGE
	#   （store_key 由 params 指定）。通用可复用：threshold/gold_amount/max_remove/
	#   store_key/source_label 全由 params 决定，效果绑定 effect 而非机师。
	var p059e1 := _ActionEffect.new()
	p059e1.effect_id = &"pilot_059_effect_01"
	p059e1.display_name = "损伤调整+分支"
	p059e1.description = "我方回合开始时，可以移除或设置我方1损伤，之后若机甲损伤数低于4则可以获得3金币/等于4则可以视为使用出1张补给/大于4则可以移除我方最多2损伤。"
	p059e1.mode = _TC.MODE_LISTEN
	p059e1.priority = 10
	p059e1.listen_timing = _TC.TURN_START
	p059e1.listen_action_type = &"turn"
	p059e1.set_conditions([{"op": &"IS_OWNER_TURN"}])
	p059e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p059e1.set_costs([])
	p059e1.set_actions([
		{"type": &"PILOT_059_TURN_START_FLOW", "params": {
			"threshold": 4,
			"gold_amount": 3,
			"max_remove": 2,
			"store_key": &"pilot_059_damage_x",
			"source_label": "薇尔·损伤调整",
		}},
	])
	effects[p059e1.effect_id] = p059e1

	# ═══════════════════════════════════════════
	# pilot_045 肯兹尔（帝国 R，cost 7, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果1「遗弃回收」（1 个按钮，主动 DIRECT，全通用机制组装，复用=整段复制改参数）：
	#   我方回合1次，点击按钮弹确认（CHOOSE_ONE optional，取消不计次），确认后：
	#     a. MARK 计次（显式 mark，确认发动才消耗次数）
	#     b. FOR_EACH_TARGET 逐目标（目标源 targets={"range":4,"include_self":false} 通用范围扫描，
	#        收集距源机甲 4 格内所有存活机甲，不分敌我）：RANDOM_DISCARD_ACTION_CARD 随机弃置该
	#        机甲 3 张行动牌（不足3张全弃），经 capture_store_key/capture_attack_only 捕获其中攻击牌。
	#     c. EXECUTE_GAIN_CARD 统一获取被弃的攻击牌（进我方手牌）
	#     d. MODIFY_ATTACK_COUNT 本回合攻击数+1
	#     e. EXECUTE_HP_CHANGE 我方受到3伤害（来源我方）
	# 基础设施（均通用可复用，非 pilot 专属）：_resolve_fet_targets 支持 range 字典目标源 +
	#   RANDOM_DISCARD_ACTION_CARD 支持 capture_store_key/capture_attack_only 捕获被弃牌。
	var p045e1 := _ActionEffect.new()
	p045e1.effect_id = &"pilot_045_effect_01"
	p045e1.display_name = "遗弃回收"
	p045e1.description = "我方回合1次，可以弃置4格范围内所有其他机甲随机3张行动牌，之后获得被弃置牌中的所有攻击牌，本回合攻击数+1，我方也将受到3伤害。"
	p045e1.mode = _TC.MODE_DIRECT
	p045e1.priority = 10
	p045e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_045_effect_01",
			"once_per_turn_max": 1,
		}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 4}},
	])
	p045e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p045e1.set_costs([])
	p045e1.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "title": "肯兹尔·遗弃回收", "description": "是否发动效果？", "options": [
				{
					"label": "发动",
					"actions": [
						{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_045_effect_01"}},
						{"type": &"FOR_EACH_TARGET", "params": {
							"targets": {"range": 4, "include_self": false},
							"actions": [
								{"type": &"RANDOM_DISCARD_ACTION_CARD", "params": {
									"count": 3,
									"owner_id": "$current_target.mech_id",
									"reason": &"pilot_045_discard",
									"capture_store_key": &"pilot_045_captured_attacks",
									"capture_attack_only": true,
								}},
							],
						}},
						{"type": &"EXECUTE_GAIN_CARD", "params": {
							"card_ids": "$runtime.pilot_045_captured_attacks",
							"mech_ids": ["$binding_context.mech_id"],
							"reason": &"pilot_045_gain",
						}},
						{"type": &"MODIFY_ATTACK_COUNT", "params": {
							"mech_id": "$binding_context.mech_id",
							"delta": 1,
							"duration": &"THIS_TURN",
						}},
						{"type": &"EXECUTE_HP_CHANGE", "params": {
							"mech_ids": ["$binding_context.mech_id"],
							"value": 3,
							"method": &"decrease",
							"source_mech_id": "$binding_context.mech_id",
							"reason": &"pilot_045_self_damage",
						}},
					],
				},
				{"label": "取消", "actions": []},
			]},
		},
	])
	effects[p045e1.effect_id] = p045e1

	# ── pilot_046 霍恩 查看获取隐藏装（1 个按钮，主动 DIRECT，通用 HIDDEN_VIEW_AND_ACQUIRE act_type）──
	# 效果文本：我方可以无条件查看商店和其他机甲备用区内的隐藏装备牌（背面朝上）。我方回合1次，
	#   可以消耗隐藏装备牌其上记述的金币获得该牌，之后将其背面朝上置于我方或其他机甲的备用区域上。
	# 通用机制（不绑机师，复用=整段复制改参数；逻辑实现见 TimingEngine）：
	#   - HIDDEN_VIEW_AND_ACQUIRE：
	#       Phase A 打开 hidden_card_view_panel（阻塞、可关闭=取消效果可反复再点；打开即给商店隐藏牌
	#       known_to 追加本玩家，幂等）。面板候选 = 商店隐藏高级槽 + 所有其他玩家机甲 RESERVE 槽白板。
	#       Phase B 选中牌点「花费获取」→ 校验金够/每回合未用 → 弹 choice_panel(allow_cancel=false)
	#       选目标 RESERVE 槽（全部玩家，显示槽位+当前牌）→ 清来源 + 重置卡归属 + 追加目标手牌 →
	#       _seq[SPEND_GOLD(原价), MARK_EFFECT_ONCE_PER_TURN_USED, EXECUTE_SET_EQUIP(card,mech,slot)]。
	#   - 查看无条件：effect 不设 once_per_turn_key（按钮常亮，仅 IS_OWNER_MAIN_PHASE 门槛）；
	#     获取每回合1次由 act_type 内部 is_once_per_turn_key_available(once_per_turn_key, binding 实例)
	#     校验 + 面板「花费获取」置灰。费用=牌面原价（price_mode=face）。
	#   - 商店隐藏牌每玩家独立得知：known_to（CardInstance.known_to）。商店面板/买价按
	#     (shop.hidden_revealed 或 known_to 含查看者) 显示真名+1.5x 价；否则 ★★★ 隐藏卡 ★★★ + 10金盲买。
	var p046e1 := _ActionEffect.new()
	p046e1.effect_id = &"pilot_046_effect_01"
	p046e1.display_name = "查看获取隐藏装"
	p046e1.description = "我方可以无条件查看商店和其他机甲备用区内的隐藏装备牌。我方回合1次，可以消耗隐藏装备牌其上记述的金币获得该牌，之后将其背面朝上置于我方或其他机甲的备用区域上。"
	p046e1.mode = _TC.MODE_DIRECT
	p046e1.priority = 10
	p046e1.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}])
	p046e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p046e1.set_costs([])
	p046e1.set_actions([
		{
			"type": &"HIDDEN_VIEW_AND_ACQUIRE",
			"params": {
				"once_per_turn_key": &"pilot_046_effect_01",
				"price_mode": &"face",
			},
		},
	])
	effects[p046e1.effect_id] = p046e1

	# ── pilot_047 里欧娜 战后威逼交牌（1 个按钮，被动 LISTEN，阻塞式 ATTACK_SETTLE）──
	# 效果文本：我方攻击结算后，可以选择1台4格范围内的其他机甲，其选择立即使用1张攻击牌，
	#   否则必须交给我方3张行动牌，若数量不足则每少1张该机甲将受到2伤害。
	# 通用机制（全部复用已有模块，不新增原子动作；复用=整段复制改参数；逻辑实现见 TimingEngine）：
	#   - 触发：LISTEN ATTACK_SETTLE priority 30 阻塞式（同 pilot_006 e3 战后逼迫）。每次我方攻击
	#     （含闪击/反击额外攻击）结算后触发，无每回合次数限制；confirm_before_target 先弹确认窗
	#     （可选发动，可取消）。force_select=true：攻击方触发的 payload.target_id 被被攻击目标污染，
	#     须强制清空重新选择（同 pilot_006）。
	#   - 选目标：CHOOSE_OTHER_MECH + TARGET_IN_RANGE(4, hex_distance)，范围 4 内的其他机甲。
	#   - 二选一（CHOOSE_ONE chooser_mech_id=$payload.target_id 路由到被选机甲，不可取消）：
	#       「立即使用1张攻击牌」（MECH_HAS_USABLE_ATTACK_CARD 置灰：无真实攻击牌或武器射程无目标）
	#         → PILOT_047_FORCE_USE_ATTACK：被选机甲选1张攻击牌被动使用（选牌窗 no_cancel 不可取消）。
	#       「交给我方3张行动牌」→ PILOT_047_FORCE_HANDOVER：手牌>3 弹交给牌窗（thrust_select
	#         min=max=3 no_cancel 目标玩家选）；手牌≤3 不弹窗直接全部交出；差额 2*少交张数 直接扣 HP。
	var p047e1 := _ActionEffect.new()
	p047e1.effect_id = &"pilot_047_effect_01"
	p047e1.display_name = "战后威逼交牌"
	p047e1.description = "我方攻击结算后，可以选择1台4格范围内的其他机甲，其选择立即使用1张攻击牌，否则必须交给我方3张行动牌，若数量不足则每少1张该机甲将受到2伤害。"
	p047e1.mode = _TC.MODE_LISTEN
	p047e1.priority = 30
	p047e1.listen_timing = _TC.ATTACK_SETTLE
	p047e1.listen_action_type = &"attack"
	p047e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 4}},
	])
	p047e1.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH", "force_select": true},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 4, "metric": &"hex_distance"}},
	])
	p047e1.set_costs([])
	p047e1.confirm_before_target = true
	p047e1.confirm_label = "发动战后威逼交牌"
	p047e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": false,
			"chooser_mech_id": "$payload.target_id",
			"options": [
				{"label": "立即使用1张攻击牌", "condition": {"op": &"MECH_HAS_USABLE_ATTACK_CARD"}, "actions": [
					{"type": &"PILOT_047_FORCE_USE_ATTACK", "params": {
						"target_mech_id": "$payload.target_id",
						"to_mech_id": "$binding_context.mech_id",
						"count": 3,
						"damage_per_missing": 2,
					}},
				]},
				{"label": "交给我方3张行动牌", "actions": [
					{"type": &"PILOT_047_FORCE_HANDOVER", "params": {
						"target_mech_id": "$payload.target_id",
						"to_mech_id": "$binding_context.mech_id",
						"count": 3,
						"damage_per_missing": 2,
					}},
				]},
			],
		},
	}])
	effects[p047e1.effect_id] = p047e1

	# ═══════════════════════════════════════════
	# pilot_048 赤牙（帝国 R，cost 8, attack_limit 2, action_card_limit 3）
	# ═══════════════════════════════════════════
	# ── pilot_048_effect_01 攻击损伤+1·损伤位置由我方指定（按钮1，被动）──
	# 被动持续效果（纯通用机制组装，不新增原子动作、不绑定机师ID）：
	#   ① 我方攻击命中时造成的损伤+1：MODIFY_ATTACK_MARKERS delta=+1 —— 与破甲/塞万提斯同一
	#      通用机制，写攻击 record.extra_markers，由 attack_action._step_apply_damage 在
	#      ATTACK_AFTER fire 后合并入 markers 一次放置（未命中 _step_apply_damage 直接 return）。
	#   ② 我方发动的攻击即使被目标响应，也由我方决定损伤设置位置：SET_ACTION_RECORD_FLAG 写
	#      通用flag attacker_always_places_damage_tokens=true，attack_action 第⑦步读该flag：
	#      被响应但带flag→仍由攻击方设置损伤（默认规则被响应则由目标方设置）。
	#      该flag为通用机制，任何效果设置即生效；双连 fork 深拷贝 record 自动继承。
	# 条件 SELF_MECH_IS_ATTACKER（我方为攻击方）+ ATTACK_HIT（命中才产损伤）。
	var p048e1 := _ActionEffect.new()
	p048e1.effect_id = &"pilot_048_effect_01"
	p048e1.display_name = "赤牙·攻击损伤+1·损伤由我方指定"
	p048e1.description = "我方攻击造成的损伤+1。我方发动的攻击即使被目标响应，也依然由我方来决定损伤设置的位置。"
	p048e1.mode = _TC.MODE_LISTEN
	p048e1.priority = 10
	p048e1.listen_timing = _TC.ATTACK_AFTER
	p048e1.listen_action_type = &"attack"
	p048e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HIT"},
	])
	p048e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p048e1.set_costs([])
	p048e1.set_actions([
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 1}},
		{"type": &"SET_ACTION_RECORD_FLAG", "params": {"flag": &"attacker_always_places_damage_tokens", "value": true}},
	])
	effects[p048e1.effect_id] = p048e1

	# ═══════════════════════════════════════════
	# pilot_049 杰狞（混乱 SR）
	# ═══════════════════════════════════════════
	# ── pilot_049_effect_01 伤害转移（按钮1，被动）──
	# 文本：4格范围内其他机甲即将受到伤害时，可以将该伤害转移由我方承受。
	# 通用机制（全部复用已有模块 + 4个新通用条件 + 1个新通用机制，不新增原子动作；复用=整段复制改参数）：
	#   - 触发：LISTEN HP_CHANGE_BEFORE priority -1（最低，最后执行）。此时高优先级效果
	#     （安德洛美达反转 priority30 已改写 record.method/清 source）已执行完，故条件读"活 record"
	#     （_live_action_record 经 action_id 查 action_registry）而非 fire 时快照 payload。
	#   - 条件：HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE(4) 其他机甲4格内；HP_CHANGE_LIVE_METHOD_IS
	#     decrease 是伤害；HP_CHANGE_AMOUNT_ABOVE(0) 伤害>0；HP_CHANGE_SOURCE_MECH_IS_BINDING(negate)
	#     排除"我方自己造成的伤害"（我方效果/我方攻击打他人不询问转移；陷阱无来源不匹配绑定仍可转移）。
	#   - 确认：CHOOSE_ONE optional 弹"是否执行此效果"（可取消），确认后 REDIRECT_HP_CHANGE_TARGET
	#     把本次 hp_change 的 mech_ids 改为我方机甲（损伤标记不转移，只转HP伤害）。
	var p049e1 := _ActionEffect.new()
	p049e1.effect_id = &"pilot_049_effect_01"
	p049e1.display_name = "杰狞·伤害转移"
	p049e1.description = "4格范围内其他机甲即将受到伤害时，可以将该伤害转移由我方承受。"
	p049e1.mode = _TC.MODE_LISTEN
	p049e1.priority = -1
	p049e1.listen_timing = _TC.HP_CHANGE_BEFORE
	p049e1.listen_action_type = &"hp_change"
	p049e1.set_conditions([
		{"op": &"HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE", "params": {"base_range": 4}},
		{"op": &"HP_CHANGE_LIVE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"HP_CHANGE_AMOUNT_ABOVE", "params": {"threshold": 0}},
		{"op": &"HP_CHANGE_SOURCE_MECH_IS_BINDING", "params": {"negate": true}},
	])
	p049e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p049e1.set_costs([])
	p049e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"title": "杰狞：伤害转移",
			"description": "4格范围内其他机甲即将受到伤害，是否将该伤害转移由我方承受？",
			"options": [{
				"label": "转移：由我方承受该伤害",
				"actions": [
					{"type": &"REDIRECT_HP_CHANGE_TARGET", "params": {}},
				],
			}],
		},
	}])
	effects[p049e1.effect_id] = p049e1

	# ── pilot_049_effect_02 受伤加伤（按钮2，被动）──
	# 文本：我方受到伤害后，使下次我方造成的伤害+4（可叠加）。
	# 触发：LISTEN HP_CHANGE_BEFORE priority 10，我方造成伤害时（来源=我方）按受伤计数 X 加伤 +4*X
	#   并清零 X。通用机制 MODIFY_HP_CHANGE_VALUE_BY_VARIABLE 改本次 hp_change value；若该 hp_change
	#   由攻击步骤7发起，同步回写父 attack.record.damage（加成计入攻击伤害，巴托洛夫非攻击免疫不触发）。
	# 条件：HP_CHANGE_SOURCE_MECH_IS_BINDING 来源是我方（含攻击伤害 source_action_id->attack.attacker_id
	#   回溯）；HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE(base_range=999) 排除自身目标（伤害打他人）；
	#   HP_CHANGE_LIVE_METHOD_IS decrease 是伤害；HP_CHANGE_AMOUNT_ABOVE(0) 伤害>0才加成；
	#   BINDING_CARD_COUNTER_ABOVE(pilot_049_x > 0) 有受伤计数才加成（X=0 自动跳过，双连只加一次：
	#   首个目标加成后 X 清零，后续目标条件不满足）。
	var p049e2 := _ActionEffect.new()
	p049e2.effect_id = &"pilot_049_effect_02"
	p049e2.display_name = "杰狞·受伤加伤"
	p049e2.description = "我方受到伤害后，使下次我方造成的伤害+4（可叠加）。"
	p049e2.mode = _TC.MODE_LISTEN
	p049e2.priority = 10
	p049e2.listen_timing = _TC.HP_CHANGE_BEFORE
	p049e2.listen_action_type = &"hp_change"
	p049e2.set_conditions([
		{"op": &"HP_CHANGE_SOURCE_MECH_IS_BINDING"},
		{"op": &"HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE", "params": {"base_range": 999}},
		{"op": &"HP_CHANGE_LIVE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"HP_CHANGE_AMOUNT_ABOVE", "params": {"threshold": 0}},
		{"op": &"BINDING_CARD_COUNTER_ABOVE", "params": {"counter_key": &"pilot_049_x", "threshold": 0}},
	])
	p049e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p049e2.set_costs([])
	p049e2.set_actions([
		{"type": &"MODIFY_HP_CHANGE_VALUE_BY_VARIABLE", "params": {"variable": &"pilot_049_x", "multiplier": 4}},
	])
	effects[p049e2.effect_id] = p049e2

	# ── pilot_049_effect_02b 受伤计数（隐藏被动，描述合并到按钮2 hover）──
	# 我方每受到1次伤害（实际掉血：HP_CHANGE_SETTLE decrease 且 value>0）→ 受伤计数 X+1
	# （写本卡实例 card.counters["var_pilot_049_x"]，换机师不转移）。陷阱无来源同样计入（target 是我方即算）。
	# 由 effect_02 在下次造成伤害时消耗（+4*X 后清零）。hide_button 隐藏第3按钮，
	# merge_desc_into_index=2 描述合并到按钮2（effect_02）hover。
	var p049e2b := _ActionEffect.new()
	p049e2b.effect_id = &"pilot_049_effect_02b"
	p049e2b.display_name = "杰狞·受伤计数"
	p049e2b.description = "受伤计数：我方每受到1次伤害（实际掉血），下次我方造成的伤害+4（可叠加）。"
	p049e2b.mode = _TC.MODE_LISTEN
	p049e2b.priority = 10
	p049e2b.listen_timing = _TC.HP_CHANGE_SETTLE
	p049e2b.listen_action_type = &"hp_change"
	p049e2b.hide_button = true
	p049e2b.merge_desc_into_index = 2
	p049e2b.set_conditions([
		{"op": &"HP_CHANGE_TARGET_IS_SELF"},
		{"op": &"HP_CHANGE_LIVE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"HP_CHANGE_AMOUNT_ABOVE", "params": {"threshold": 0}},
	])
	p049e2b.set_target_rules([{"rule": &"NO_TARGET"}])
	p049e2b.set_costs([])
	p049e2b.set_actions([
		{"type": &"INCREMENT_VARIABLE", "params": {
			"variable_name": &"pilot_049_x",
			"delta": 1,
			"source_card_instance_id": "$binding_context.card_instance_id",
		}},
	])
	effects[p049e2b.effect_id] = p049e2b

	# ═══════════════════════════════════════════
	# pilot_050 杰西卡（帝国 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# ── pilot_050_effect_01/01b 动力税（按钮1，被动）──
	# 文本：其他机甲在我方4+X格范围内每消耗2动力，可以使该机甲和我方各受到2伤害（X初始为0）。
	# 通用机制 POWER_SPEND_TAX（全部复用已有模块，不新增原子动作；复用=整段复制改参数；
	# 逻辑实现见 TimingEngine._handle_power_spend_tax）：
	#   - e01 监听 BASIC_MOVE_AT（移动消耗：basic_move step② 扣动力后、step③ 移位前触发，
	#     天然"先消耗再移动"——范围判定用消耗时位置（范围外消耗后移入不计、范围内消耗后移出
	#     仍计入）；single_move 逐格 fork basic_move 子动作 -> 逐格中断阻塞）。
	#   - e01b 监听 power_spent 虚拟时点（全部非移动消耗：玛沙、装备牌发动效果等，由
	#     GameActions.spend_power 统一通知，消耗时立即阻塞宿主动作）。玛丽尔/巴托洛夫"减动力"
	#     走 modify_mech_power 不经 spend_power，天然不计入。移动消耗 spend_power 打
	#     reason=BASIC_MOVE 标记跳过通知，与 e01 不双计。免费移动（free_move）未实际消耗不计。
	#   - 范围内其他机甲每累计消耗 threshold(2) 点 -> 弹确认窗（chooser=我方玩家，可取消）；
	#     确认 -> 两次独立 hp_change 子动作（先该机甲后我方，来源均为我方，顺序结算：
	#     双方同濒死该机甲先死）；确认/拒绝都清这 2 点累计（余数留存继续记）；
	#     一次消耗 N 点 = floor(N/2) 次询问串行执行。累计存本卡实例
	#     counters["power_tax_accum_<消耗方mech_id>"]，X 存 counters["var_pilot_050_x"]（e2 写入）。
	var p050e1 := _ActionEffect.new()
	p050e1.effect_id = &"pilot_050_effect_01"
	p050e1.display_name = "杰西卡·动力税"
	p050e1.description = "其他机甲在我方4+X格范围内每消耗2动力，可以使该机甲和我方各受到2伤害（X初始为0）。"
	p050e1.mode = _TC.MODE_LISTEN
	p050e1.priority = 20
	p050e1.listen_timing = _TC.BASIC_MOVE_AT
	p050e1.listen_action_type = &"basic_move"
	p050e1.set_conditions([])
	p050e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p050e1.set_costs([])
	p050e1.set_actions([{
		"type": &"POWER_SPEND_TAX",
		"params": {"base_range": 4, "counter_key": &"pilot_050_x", "damage": 2, "threshold": 2},
	}])
	effects[p050e1.effect_id] = p050e1

	# e01b：非移动消耗监听（隐藏，描述合并到按钮1 hover）。listen_action_type 留空=任意宿主动作。
	var p050e1b := _ActionEffect.new()
	p050e1b.effect_id = &"pilot_050_effect_01b"
	p050e1b.display_name = "杰西卡·动力税（非移动消耗）"
	p050e1b.description = "（含玛沙、装备牌发动效果等全部非移动动力消耗；移动消耗由效果1的移动监听覆盖。）"
	p050e1b.mode = _TC.MODE_LISTEN
	p050e1b.priority = 20
	p050e1b.listen_timing = _TC.POWER_SPENT
	p050e1b.hide_button = true
	p050e1b.merge_desc_into_index = 1
	p050e1b.set_conditions([])
	p050e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p050e1b.set_costs([])
	p050e1b.set_actions([{
		"type": &"POWER_SPEND_TAX",
		"params": {"base_range": 4, "counter_key": &"pilot_050_x", "damage": 2, "threshold": 2},
	}])
	effects[p050e1b.effect_id] = p050e1b

	# ── pilot_050_effect_02 受伤X+1弃牌（按钮2，被动）──
	# 文本：每回合1次，我方受到伤害后，可以使X+1，并弃置我方和4+X格范围内的1台其他机甲各2张行动牌。
	# 通用机制 POWER_TAX_TRIBUTE 状态机（不新增原子动作；复用=整段复制改参数；实现见
	# TimingEngine._handle_power_tax_tribute / resume phase=power_tax_tribute_*）：
	#   - 触发：LISTEN HP_CHANGE_SETTLE（我方实际掉血：decrease 且 value>0，回复不触发）。
	#     once_per_turn_key 门控（每个玩家回合各1次）。
	#   - 确认弹窗可取消（取消=不发动，不 mark，不消耗次数）。
	#   - 确认 -> mark + X+1（写 counters["var_pilot_050_x"]，先于范围计算）-> 按新 X 选
	#     base_range+X 范围内 1 台其他机甲（常规目标UI，无候选=仅 X+1 跳过弃牌）。
	#   - 连续两次独立弃置（先我方后目标，chooser 均为我方）：我方牌信息可见；目标牌牌背
	#     （hide_card_info）不可见；手牌 <=2 直接全选不弹窗（0 张不弃）。
	var p050e2 := _ActionEffect.new()
	p050e2.effect_id = &"pilot_050_effect_02"
	p050e2.display_name = "杰西卡·受伤X+1弃牌"
	p050e2.description = "每回合1次，我方受到伤害后，可以使X+1，并弃置我方和4+X格范围内的1台其他机甲各2张行动牌。"
	p050e2.mode = _TC.MODE_LISTEN
	p050e2.priority = 20
	p050e2.listen_timing = _TC.HP_CHANGE_SETTLE
	p050e2.listen_action_type = &"hp_change"
	p050e2.once_per_turn_key = &"pilot_050_effect_02"
	p050e2.set_conditions([
		{"op": &"HP_CHANGE_TARGET_IS_SELF"},
		{"op": &"HP_CHANGE_LIVE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"HP_CHANGE_AMOUNT_ABOVE", "params": {"threshold": 0}},
	])
	p050e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p050e2.set_costs([])
	p050e2.set_actions([{
		"type": &"POWER_TAX_TRIBUTE",
		"params": {
			"base_range": 4,
			"counter_key": &"pilot_050_x",
			"discard_count": 2,
			"once_per_turn_key": &"pilot_050_effect_02",
			"confirm_text": "每回合1次，我方受到伤害后：X+1，并弃置我方和4+X格范围内的1台其他机甲各2张行动牌。",
		},
	}])
	effects[p050e2.effect_id] = p050e2

	# ── pilot_054 萨伊 弃1行动抽1装备（我方回合2次，DIRECT 主动按钮）──
	# 完全复用 pilot_033「弃装抽装」通用机制，仅替换弃置来源为行动牌：
	#   我方回合2次（once_per_turn_max=2）：点击弹"选1张行动牌"窗（OWNER_ACTION_HAND 枚举
	#   持有者所有行动牌；min_count=1 必选、可取消=中止不消耗次数，确认即 mark once_per_turn），
	#   弃置所选行动牌后抽1张装备牌（equipment_deck）。
	# 无行动牌可弃时按钮置灰（HAS_ACTION_CARD_IN_HAND count=1）。
	var p052e1 := _ActionEffect.new()
	p052e1.effect_id = &"pilot_054_effect_01"
	p052e1.display_name = "弃1行动抽1装"
	p052e1.description = "我方回合2次，可以弃置1张行动牌，之后抽1张装备牌。"
	p052e1.mode = _TC.MODE_DIRECT
	p052e1.priority = 10
	p052e1.once_per_turn_key = &"pilot_054_effect_01"
	p052e1.once_per_turn_max = 2
	p052e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p052e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p052e1.set_costs([])
	p052e1.set_actions([
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"OWNER_ACTION_HAND",
				"max_count": 1,
				"min_count": 1,
				"store_result_key": &"pilot_054_discard_ids",
				"discard_selected": false,
				"label": "选择1张要弃置的行动牌",
				"confirm_verb": "弃置",
				"cancel_label": "取消",
			}
		},
		{
			"type": &"EXECUTE_DISCARD",
			"params": {
				"card_ids": "$runtime.pilot_054_discard_ids",
				"reason": &"pilot_054_discard",
			}
		},
		{
			"type": &"EXECUTE_GAIN_CARD",
			"params": {
				"from_zone": &"equipment_deck",
				"card_kind": &"equipment",
				"count": 1,
				"player_id": "$binding_context.player_id",
				"reason": &"pilot_054_draw",
			}
		},
	])
	effects[p052e1.effect_id] = p052e1

	# ═══════════════════════════════════════════
	# pilot_052 亚林（秩序 R，cost 6, attack_limit 1, action_card_limit 4）
	# 权威文本：每回合2次，我方区域有正面朝上的装备牌被设置/弃置时，可以抽2张行动牌，
	#   行动牌上限+1（效果持续到下个我方回合开始）。
	# 通用化（纯通用组件组装，不新增原子动作底层、不绑定机师——任何 effect_ids 含
	#   pilot_052_effect_01/01b 的卡即生效，复用=整段复制改 key）：
	#   · 双监听共享每回合2次额度：effect_01（显示按钮1）监听 SET_EQUIP_AT（正面设置），
	#     effect_01b（hide_button 描述合并到按钮1）监听 DISCARD_AFTER（我方机甲正面装备被弃置，
	#     含敌方回合损伤损坏弃置）。条件均走通用 SET_EQUIP_INCLUDES_OWNER_FACE_UP /
	#     DISCARD_INCLUDES_OWNER_FACE_UP_EQUIPMENT + EFFECT_ONCE_PER_TURN_AVAILABLE(key,max2)。
	#   · 触发后 CHOOSE_ONE optional:true 确认弹窗（可取消不计次）；发动分支显式
	#     MARK_EFFECT_ONCE_PER_TURN_USED（确认才计数）+ EXECUTE_GAIN_CARD 抽2行动牌 +
	#     APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS（行动牌上限+1 立即生效、下个我方回合开始
	#     到期清除，可叠加，平行布鲁克攻击数机制）。效果级不设 once_per_turn_key，
	#     避免取消分支同步完成被 auto-mark 误计次。
	# ═══════════════════════════════════════════

	# ── effect_01 显示按钮1，监听 SET_EQUIP_AT（我方区域正面设置装备牌）──
	var p053e1 := _ActionEffect.new()
	p053e1.effect_id = &"pilot_052_effect_01"
	p053e1.display_name = "亚林·装备联动"
	p053e1.description = "每回合2次，我方区域有正面朝上的装备牌被设置/弃置时，可以抽2张行动牌，行动牌上限+1（效果持续到下个我方回合开始）。"
	p053e1.mode = _TC.MODE_LISTEN
	p053e1.priority = 10
	p053e1.listen_timing = _TC.SET_EQUIP_AT
	p053e1.listen_action_type = &"set_equipment"
	p053e1.set_conditions([
		{"op": &"SET_EQUIP_INCLUDES_OWNER_FACE_UP"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_052_effect_01",
			"once_per_turn_max": 2,
		}},
	])
	p053e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p053e1.set_costs([])
	p053e1.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "title": "亚林·装备联动", "description": "是否发动效果？（抽2张行动牌，行动牌上限+1，持续到下个我方回合开始）", "options": [
				{
					"label": "发动",
					"actions": [
						{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_052_effect_01"}},
						{"type": &"EXECUTE_GAIN_CARD", "params": {
							"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
							"player_id": "$binding_context.player_id",
							"mech_ids": ["$binding_context.mech_id"],
							"reason": &"pilot_052_draw",
						}},
						{"type": &"APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS", "params": {
							"player_id": "$binding_context.player_id",
							"stacks": 1,
						}},
					],
				},
				{"label": "取消", "actions": []},
			]},
		},
	])
	effects[p053e1.effect_id] = p053e1

	# ── effect_01b 隐藏（描述合并到按钮1），监听 DISCARD_AFTER（我方机甲正面装备被弃置）──
	var p053e1b := _ActionEffect.new()
	p053e1b.effect_id = &"pilot_052_effect_01b"
	p053e1b.display_name = "亚林·装备联动(弃置)"
	p053e1b.hide_button = true
	p053e1b.merge_desc_into_index = 1
	p053e1b.description = "我方区域有正面朝上的装备牌被弃置时，可以抽2张行动牌，行动牌上限+1（每回合2次与设置触发共享额度）。"
	p053e1b.mode = _TC.MODE_LISTEN
	p053e1b.priority = 10
	p053e1b.listen_timing = _TC.DISCARD_AFTER
	p053e1b.listen_action_type = &"discard_card"
	p053e1b.set_conditions([
		{"op": &"DISCARD_INCLUDES_OWNER_FACE_UP_EQUIPMENT"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_052_effect_01",
			"once_per_turn_max": 2,
		}},
	])
	p053e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p053e1b.set_costs([])
	p053e1b.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "title": "亚林·装备联动", "description": "是否发动效果？（抽2张行动牌，行动牌上限+1，持续到下个我方回合开始）", "options": [
				{
					"label": "发动",
					"actions": [
						{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_052_effect_01"}},
						{"type": &"EXECUTE_GAIN_CARD", "params": {
							"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
							"player_id": "$binding_context.player_id",
							"mech_ids": ["$binding_context.mech_id"],
							"reason": &"pilot_052_draw",
						}},
						{"type": &"APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS", "params": {
							"player_id": "$binding_context.player_id",
							"stacks": 1,
						}},
					],
				},
				{"label": "取消", "actions": []},
			]},
		},
	])
	effects[p053e1b.effect_id] = p053e1b

	# ═══════════════════════════════════════════
	# pilot_051 莉卡尔（秩序 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 权威文本：我方回合2次，从商店购买装备牌后可以获得3金币，若购买的是高级装备牌，则可再抽2张行动牌。
	# 通用化（纯通用组件组装，不新增原子动作底层、不绑定机师——任何 effect_ids 含
	#   pilot_051_effect_01 的卡即生效，复用=整段复制改 key）：
	#   · LISTEN 监听通用商店购买时点 SHOP_BUY_AFTER（ShopService 三条购买路径统一 fire）。
	#     条件走通用 SHOP_BUYER_IS_SELF（购买者==效果拥有者，其他玩家购买不触发）+
	#     EFFECT_ONCE_PER_TURN_AVAILABLE(key, max2)（每回合2次，额度独立按卡实例）。
	#   · 触发后 CHOOSE_ONE optional:true 确认弹窗（可取消不计次）；发动分支显式
	#     MARK_EFFECT_ONCE_PER_TURN_USED（确认才计数）+ GAIN_GOLD 统一获金3 +
	#     EXECUTE_GAIN_CARD 抽2行动牌（带 condition PAYLOAD_BOOL_IS_TRUE(is_advanced)，
	#     仅当本次购买的是高级装备牌时执行——分支动作 condition 通用机制，条件不满足跳过）。
	#   · 效果级不设 once_per_turn_key，避免取消分支同步完成被 auto-mark 误计次（同亚林 p053）。
	var p054e1 := _ActionEffect.new()
	p054e1.effect_id = &"pilot_051_effect_01"
	p054e1.display_name = "莉卡尔·购买返利"
	p054e1.description = "每回合2次，我方从商店购买装备牌后可以获得3金币，若购买的是高级装备牌，则可再抽2张行动牌。"
	p054e1.mode = _TC.MODE_LISTEN
	p054e1.priority = 10
	p054e1.listen_timing = _TC.SHOP_BUY_AFTER
	p054e1.listen_action_type = &"shop"
	p054e1.set_conditions([
		{"op": &"SHOP_BUYER_IS_SELF"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_051_effect_01",
			"once_per_turn_max": 2,
		}},
	])
	p054e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p054e1.set_costs([])
	p054e1.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "title": "莉卡尔·购买返利", "description": "是否发动效果？（获得3金币，若购买的是高级装备牌则再抽2张行动牌）", "options": [
				{
					"label": "发动",
					"actions": [
						{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_051_effect_01"}},
						{"type": &"GAIN_GOLD", "params": {
							"amount": 3,
							"player_id": "$binding_context.player_id",
						}},
						{"type": &"EXECUTE_GAIN_CARD", "params": {
							"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
							"player_id": "$binding_context.player_id",
							"mech_ids": ["$binding_context.mech_id"],
							"reason": &"pilot_051_draw",
						}, "condition": [{"op": &"PAYLOAD_BOOL_IS_TRUE", "params": {"key": "is_advanced"}}]},
					],
				},
				{"label": "取消", "actions": []},
			]},
		},
	])
	effects[p054e1.effect_id] = p054e1

	# ═══════════════════════════════════════════
	# pilot_055 霍克（混乱 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 权威文本：我方回合1次，可以使卖出装备牌获得的金币*2，若卖出的是高级装备牌，则再获得3金币。
	# 通用化（纯通用组件组装，不新增原子动作底层、不绑定机师——任何 effect_ids 含
	#   pilot_055_effect_01 的卡即生效，复用=整段复制改 key）：
	#   · LISTEN 监听通用弃置时点 DISCARD_BEFORE（卖出弃牌统一走 discard_card 动作发此时点）。
	#     条件走通用 DISCARD_REASON_IS(reason=[sell,sell_set_equipment])（"必须是卖出"：手牌卖出=
	#     sell，备用区/已设置卖出=sell_set_equipment）+ DISCARD_INCLUDED_OWNER_ACTION_CARD
	#     (card_kind=equipment)（被弃装备归属效果持有者，他人卖出不触发）+
	#     EFFECT_ONCE_PER_TURN_AVAILABLE(key,1)（每回合1次，额度独立按卡实例）。
	#   · 触发后 CHOOSE_ONE optional:true 确认弹窗（可取消不计次）；发动分支显式
	#     MARK_EFFECT_ONCE_PER_TURN_USED（确认才计数）+ GAIN_GOLD 统一获金（amount=卖价，
	#     通用表达式 $discard_equipment_cost 取被弃装备牌 cost——卖出金币已由 sell_equipment
	#     先行发放，此处补发1倍卖价即实现×2）+ GAIN_GOLD(3)（带 condition
	#     DISCARD_EQUIPMENT_IS_ADVANCED，仅当本次卖出的装备牌为 SR/SSR 高级时执行）。
	#   · 效果级不设 once_per_turn_key，避免取消分支同步完成被 auto-mark 误计次（同莉卡尔 p054）。
	var p055e1 := _ActionEffect.new()
	p055e1.effect_id = &"pilot_055_effect_01"
	p055e1.display_name = "霍克·卖出翻倍"
	p055e1.description = "每回合1次，卖出装备牌获得的金币×2，若卖出的是高级装备牌，则再获得3金币。"
	p055e1.mode = _TC.MODE_LISTEN
	p055e1.priority = 10
	p055e1.listen_timing = _TC.DISCARD_BEFORE
	p055e1.listen_action_type = &"discard_card"
	p055e1.set_conditions([
		{"op": &"DISCARD_REASON_IS", "params": {"reason": [&"sell", &"sell_set_equipment"]}},
		{"op": &"DISCARD_INCLUDED_OWNER_ACTION_CARD", "params": {"card_kind": &"equipment"}},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_055_effect_01",
			"once_per_turn_max": 1,
		}},
	])
	p055e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p055e1.set_costs([])
	p055e1.set_actions([
		{
			"type": &"CHOOSE_ONE",
			"params": {"optional": true, "title": "霍克·卖出翻倍", "description": "是否发动效果？（本次卖出获得的金币×2，若卖出的是高级装备牌则再获得3金币）", "options": [
				{
					"label": "发动",
					"actions": [
						{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_055_effect_01"}},
						{"type": &"GAIN_GOLD", "params": {
							"amount": "$discard_equipment_cost",
							"player_id": "$binding_context.player_id",
						}},
						{"type": &"GAIN_GOLD", "params": {
							"amount": 3,
							"player_id": "$binding_context.player_id",
						}, "condition": [{"op": &"DISCARD_EQUIPMENT_IS_ADVANCED"}]},
					],
				},
				{"label": "取消", "actions": []},
			]},
		},
	])
	effects[p055e1.effect_id] = p055e1

	# ═══════════════════════════════════════════
	# pilot_056 铠厉（混乱 R，cost 6, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 权威文本：若发动的攻击被响应，则可以抽2张装备牌，若不立即设置，则需要直接弃置并获得牌面记述数量的金币。
	# 通用化（纯通用组件组装，不新增原子动作、不绑定机师——任何 effect_ids 含
	#   pilot_056_effect_01 的卡即生效，复用=整段复制改 key）：
	#   · LISTEN 监听 ATTACK_SETTLE（凯威同款时点），优先级 30 先于反击 effect2(20)/闪击 effect2(10)。
	#     条件 SELF_MECH_IS_ATTACKER（我方为攻击方）+ ATTACK_WAS_RESPONDED（本次攻击被响应：
	#     迎击/装备/机师任意响应均置 attack.record.responded=true）。
	#   · 动作 RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK：非阻塞调度——攻击动作完全结算（action_completed）
	#     后由 ActionService 派发 responded_equip_after_attack_completed（入队触发+弹确认），
	#     保证「攻击结算后」= 攻击动作完全清理后才提示；同一攻击只登记一次（去重守卫）。
	#   · 通用链式模块 responded_equip_chain_*（本文件底部，不绑机师）实现：
	#     确认→gain_card 抽2装备→逐张弹「立即设置/弃置获金(cost)」面板→全部处理完结束。
	#     面板复用 immediate_set_equipment_panel（allow_sell=true 且 sell_price=牌面cost=「弃置获金」，
	#     sell 与 cancel 同语义=弃牌+获金，隐藏 cancel 只留「弃置此牌(+X金币)」）。
	var p056e1 := _ActionEffect.new()
	p056e1.effect_id = &"pilot_056_effect_01"
	p056e1.display_name = "被响应抽装设或弃"
	p056e1.description = "若发动的攻击被响应，则可以抽2张装备牌，若不立即设置，则需要直接弃置并获得牌面记述数量的金币。"
	p056e1.mode = _TC.MODE_LISTEN
	p056e1.priority = 30
	p056e1.listen_timing = _TC.ATTACK_SETTLE
	p056e1.listen_action_type = &"attack"
	p056e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_WAS_RESPONDED"},
	])
	p056e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p056e1.set_costs([])
	p056e1.set_actions([
		{"type": &"RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK", "params": {}},
	])
	effects[p056e1.effect_id] = p056e1

	# ── pilot_062 铠德：被响应三选一（非阻塞调度，复刻铠威/铠厉）──
	# 效果1「被响应三选一」（MODE_LISTEN 被动按钮，置灰+悬停描述）：我方发动的攻击被响应时，
	#   ATTACK_SETTLE（priority 30，条件 SELF_MECH_IS_ATTACKER + responded）触发 →
	#   PILOT_060_SCHEDULE_AFTER_ATTACK 登记「攻击动作完成」钩子（非阻塞，攻击完全结算后才提示），
	#   攻击结算后由 _ActionPilotEffects.pilot_062_after_attack_completed 入队 → 弹三选一
	#   （抽2张行动牌/回复3动力/获得4金币，底部「取消」=放弃）。通用模块 pilot_062_*（本文件底部，
	#   不绑机师）：任意含本效果的动作复用，分支原子动作走现有 EXECUTE_GAIN_CARD/RESTORE_POWER/GAIN_GOLD。
	var p060e1 := _ActionEffect.new()
	p060e1.effect_id = &"pilot_062_effect_01"
	p060e1.display_name = "被响应三选一"
	p060e1.description = "若发动的攻击被响应，则可以选择其一：抽2张行动牌/回复3动力/获得4金币。"
	p060e1.mode = _TC.MODE_LISTEN
	p060e1.priority = 30
	p060e1.listen_timing = _TC.ATTACK_SETTLE
	p060e1.listen_action_type = &"attack"
	p060e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_WAS_RESPONDED"},
	])
	p060e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p060e1.set_costs([])
	p060e1.set_actions([
		{"type": &"PILOT_060_SCHEDULE_AFTER_ATTACK", "params": {}},
	])
	effects[p060e1.effect_id] = p060e1

	# ── pilot_061 艾希（联邦 N，cost 3, attack_limit 1, action_card_limit 3）──
	# 效果1（1个显示按钮，被动 LISTEN TURN_AFTER_START）+ 效果2（隐藏，描述合并进按钮1 hover）：
	#   我方回合开始时抽牌数+2（效果2 在 TURN_START 时点写 turn_start_action_draw_bonus，
	#   TurnService 回合开始抽牌 count=2+2=4，单次 gain_card）；
	#   之后（TURN_AFTER_START，手牌已含刚抽的4张）若我方有行动牌且3格内有其他机甲，
	#   选1台3格内其他机甲（CHOOSE_OTHER_MECH，可取消不发动）→ 复选框选我方任意张行动牌
	#   （CHOOSE_MANY_CARDS ≥1张、no_cancel 无取消键）→ TRANSFER_ACTION_CARDS 交给该机甲。
	# 通用复用：SET_TURN_START_DRAW_BONUS（任意"回合开始抽牌+X"效果）+ 交牌流程整段复制 pilot_031。
	var p061e1 := _ActionEffect.new()
	p061e1.effect_id = &"pilot_061_effect_01"
	p061e1.display_name = "艾希-交牌"
	p061e1.description = "我方回合开始时抽取行动牌数+2，之后可以将我方任意张行动牌交给3格范围内的其他机甲。"
	p061e1.mode = _TC.MODE_LISTEN
	p061e1.priority = 10
	p061e1.listen_timing = _TC.TURN_AFTER_START
	p061e1.listen_action_type = &"turn"
	p061e1.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 3}},
	])
	p061e1.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 3, "metric": &"hex_distance"}},
	])
	p061e1.set_costs([])
	p061e1.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": -1,
			"label": "选择要交给目标的行动牌",
			"confirm_verb": "交给",
			"cancel_label": "取消",
			"discard_selected": false,
			"no_cancel": true,
			"post_actions": [
				{"type": &"TRANSFER_ACTION_CARDS", "params": {"card_ids": "$choice.card_ids", "target_mech_id": "$payload.target_id", "from_player_id": "$binding_context.player_id"}},
			],
		},
	}])
	effects[p061e1.effect_id] = p061e1

	# ── effect_02（隐藏，描述合并到按钮1 hover）──
	var p061e2 := _ActionEffect.new()
	p061e2.effect_id = &"pilot_061_effect_02"
	p061e2.display_name = "艾希-抽牌数+2"
	p061e2.hide_button = true
	p061e2.merge_desc_into_index = 1
	p061e2.description = "我方回合开始时，抽取行动牌数+2（原抽2张改为抽4张）。"
	p061e2.mode = _TC.MODE_LISTEN
	p061e2.priority = 10
	p061e2.listen_timing = _TC.TURN_START
	p061e2.listen_action_type = &"turn"
	p061e2.set_conditions([{"op": &"IS_OWNER_TURN"}])
	p061e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p061e2.set_costs([])
	p061e2.set_actions([
		{"type": &"SET_TURN_START_DRAW_BONUS", "params": {"add": 2}},
	])
	effects[p061e2.effect_id] = p061e2

	# ── pilot_057 格雷厄姆（混乱 R，cost 6, attack_limit 1, action_card_limit 4）──
	# 效果1「当作设陷」（DIRECT 按钮1，每我方回合1次）：选1张行动牌（可取消=中止不计次），
	#   移入临时区（复用通用 MOVE_ACTION_CARDS_TO_TEMP_ZONE，不触发弃牌时点），
	#   执行标准设陷效果（ADD_STATUS SET_TRAP 2层，与实体设陷牌 action_017 完全一致，可叠加），
	#   链末 DISCARD_TEMP_ZONE_CARDS 把燃料牌入弃牌堆（迪恩/布鲁克转化同款管线）。
	#   次数走 store_result_key 确认路径自动 mark（取消不计次）；无行动牌按钮置灰。
	# 效果2「移陷」（DIRECT 按钮2，每我方回合1次）：选4格内1个陷阱标记（CHOOSE_MAP_CELL
	#   markers 源，可取消=中止不计次）-> MARK 显式计次（选定陷阱即算发动）-> 弃任意张行动牌
	#   （CHOOSE_MANY_CARDS OWNER_ACTION_HAND min=1 不限上限 no_cancel）-> EXECUTE_DISCARD
	#   -> 以陷阱为起点 BFS 连续移动 预算=4×弃牌数 的可选格（CHOOSE_MAP_CELL path 源：
	#   机甲格可作终点=落格引爆但不可穿过、红格排除、绿格耗2，no_cancel）
	#   -> MOVE_MAP_MARKER 迁移（落格有机甲则标准陷阱爆炸）。
	#   全部为通用件组装（CHOOSE_MAP_CELL cells 源/ MOVE_MAP_MARKER / MAP_MARKER_IN_RANGE
	#   均为效果绑定参数驱动，不绑机师）。
	var p057e1 := _ActionEffect.new()
	p057e1.effect_id = &"pilot_057_effect_01"
	p057e1.display_name = "当作设陷"
	p057e1.description = "我方回合1次，可以将1张行动牌当作设陷使用：该牌移入临时区并弃置，自身获得2层设陷状态（可叠加）。"
	p057e1.mode = _TC.MODE_DIRECT
	p057e1.priority = 10
	p057e1.once_per_turn_key = &"pilot_057_effect_01"
	p057e1.once_per_turn_max = 1
	p057e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p057e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p057e1.set_costs([])
	p057e1.set_actions([
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"OWNER_ACTION_HAND",
				"max_count": 1,
				"min_count": 1,
				"store_result_key": &"pilot_057_transform_ids",
				"discard_selected": false,
				"label": "选择当作设陷使用的1张行动牌",
				"confirm_verb": "设陷",
				"cancel_label": "取消",
			}
		},
		{
			# 燃料牌移入临时区（不触发弃牌时点），链末统一入弃牌堆
			"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE",
			"params": {"card_ids": "$runtime.pilot_057_transform_ids"},
		},
		{
			# 标准设陷效果：与实体设陷牌一致，2层可叠加
			"type": &"ADD_STATUS",
			"params": {"status_type": &"SET_TRAP", "stacks": 2},
		},
		{
			"type": &"DISCARD_TEMP_ZONE_CARDS",
			"params": {"card_ids": "$payload.temp_zone_card_ids", "reason": &"pilot_057_trap_transform"},
		},
	])
	effects[p057e1.effect_id] = p057e1

	var p057e2 := _ActionEffect.new()
	p057e2.effect_id = &"pilot_057_effect_02"
	p057e2.display_name = "移陷"
	p057e2.description = "我方回合1次，选择4格范围内的1个陷阱，弃置任意张行动牌（每弃1张可使该陷阱移动4格），之后沿路径连续移动到范围内任意格子（不能穿过机甲所在的格子，但可以移入该格并立即引爆）。"
	p057e2.mode = _TC.MODE_DIRECT
	p057e2.priority = 10
	p057e2.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
		{"op": &"MAP_MARKER_IN_RANGE", "params": {"marker_type": &"TRAP", "range": 4, "count": 1}},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_057_effect_02",
			"once_per_turn_max": 1,
		}},
	])
	p057e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p057e2.set_costs([])
	p057e2.set_actions([
		{
			# ① 选4格内1个陷阱标记（可取消=中止不计次；取消走 map_cell_select phase 取消路径）
			"type": &"CHOOSE_MAP_CELL",
			"params": {
				"cells": {"markers": {"type": &"TRAP", "range": 4}},
				"store_result_key": &"pilot_057_trap_cell_id",
				"label": "选择4格范围内要移动的陷阱",
			}
		},
		{
			# ② 选定陷阱即算发动：显式计次（取消已在中止路径早退，不会到这）
			"type": &"MARK_EFFECT_ONCE_PER_TURN_USED",
			"params": {"once_per_turn_key": &"pilot_057_effect_02"},
		},
		{
			# ③ 弃任意张行动牌（至少1张，不可取消）
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"OWNER_ACTION_HAND",
				"max_count": 0,
				"min_count": 1,
				"store_result_key": &"pilot_057_discard_ids",
				"discard_selected": false,
				"label": "选择要弃置的行动牌（每弃1张=陷阱可移动4格）",
				"confirm_verb": "弃置",
				"cancel_label": "弃置",
				"no_cancel": true,
			}
		},
		{
			"type": &"EXECUTE_DISCARD",
			"params": {
				"card_ids": "$runtime.pilot_057_discard_ids",
				"reason": &"pilot_057_trap_move",
			}
		},
		{
			# ⑤ 目的地：从陷阱出发 BFS 连续移动 预算=4×弃牌数（机甲格可作终点=落格引爆、
			#    不可穿过；红格排除；绿格与普通格一视同仁各算1格），弃牌已付出，不可取消
			"type": &"CHOOSE_MAP_CELL",
			"params": {
				"cells": {"path": {
					"center": "$runtime.pilot_057_trap_cell_id",
					"per_count_key": "$runtime.pilot_057_discard_ids",
					"per": 4,
					"green_cost": 1,
				}},
				"store_result_key": &"pilot_057_dest_cell_id",
				"label": "选择陷阱移动到的格子（连续移动4×弃牌数格；有机甲的格子会立即引爆）",
				"no_cancel": true,
			}
		},
		{
			# ⑥ 迁移标记（落格有机甲 -> 标准陷阱爆炸，与踩上完全一致）
			"type": &"MOVE_MAP_MARKER",
			"params": {
				"from_cell_id": "$runtime.pilot_057_trap_cell_id",
				"dest_cell_id": "$runtime.pilot_057_dest_cell_id",
				"marker_type": &"TRAP",
				"explode_if_mech": true,
			}
		},
	])
	effects[p057e2.effect_id] = p057e2

	# ═══════════════════════════════════════════
	# pilot_058 卡米拉（混乱 R，cost 7, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（LISTEN 被动按钮1 置灰+悬停）「牌型展示加成」：我方发动攻击的 ATTACK_PRE
	# 时点（priority 30；我方无行动牌则条件不满足、不触发），弹确认框询问是否使用；
	# 确认后 handler PILOT_058_SHOW_COUNT_BONUS：展示我方所有行动牌（只给其他玩家弹
	# 非阻塞浮窗，自己不看自己的牌——参考美杜莎 p009 显示对象）、统计类型数
	# （攻击/迎击/辅助 各计1，1~3）、威力 += 类型数×might_per_type、若类型数
	# >= required_type_count 则范围 += range_bonus。通用可复用：效果本身即模块，
	# 数值/文案由 params 决定，复制定义+改 params 即可复用，不绑定机师。
	var p058e1 := _ActionEffect.new()
	p058e1.effect_id = &"pilot_058_effect_01"
	p058e1.display_name = "卡米拉·牌型展示加成"
	p058e1.description = "发动攻击时可以展示我方所有行动牌，其中每包含1种类型(攻击，迎击，辅助)，则本次攻击威力+2；若包含3种类型，则本次攻击范围+2。"
	p058e1.mode = _TC.MODE_LISTEN
	p058e1.priority = 30
	p058e1.listen_timing = _TC.ATTACK_PRE
	p058e1.listen_action_type = &"attack"
	p058e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p058e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p058e1.set_costs([])
	p058e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "展示所有行动牌，每包含1种类型则本次威力+2；包含3种类型则本次范围+2",
				"actions": [{
					"type": &"PILOT_058_SHOW_COUNT_BONUS",
					"params": {
						"might_per_type": 2,
						"range_bonus": 2,
						"required_type_count": 3,
						"source_label": "卡米拉：展示行动牌",
					},
				}],
			}],
		},
	}])
	effects[p058e1.effect_id] = p058e1

	# ═══════════════════════════════════════════
	# pilot_066 银雪（联邦 N，cost 4, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果（1 个显示按钮 + 1 个隐藏监听，描述合并到按钮1）：
	# · effect_01（DIRECT 显示按钮，开关）：随时按按钮弹"启用/禁用窥牌拦截"二选一（可取消）。
	#   flag 存 card.counters["pilot_066_intercept"]（默认启用=true）。禁用后 effect_02 不再弹窗。
	# · effect_02（LISTEN GAIN_CARD_BEFORE 隐藏，merge_desc_into_index=1）：
	#   3格内机甲（含我方）从行动牌堆抽牌前，若我方有行动牌且开关启用，弹单选窗弃1张行动牌作代价，
	#   再弹多选窗窥行动牌堆顶3张可弃任意（剩余保持原序置顶）。代价/堆顶弃置走 EXECUTE_DISCARD
	#   触发弃置时点。组件全通用：SET_CARD_COUNTER（开关flag）+ CARD_COUNTER_IS（读flag）+
	#   GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE（3格内）+ PEEK_DECK_TOP_AND_DISCARD（2阶段窥牌模块）。
	#   复用=整段复制改 key/timing/range/peek_count 即可，与效果绑定不绑机师。

	# ── effect_01 显示按钮：启用/禁用窥牌拦截开关（DIRECT，随时可按）──
	var p065e1 := _ActionEffect.new()
	p065e1.effect_id = &"pilot_066_effect_01"
	p065e1.display_name = "窥牌拦截·开关"
	p065e1.description = "随时启用或禁用窥牌拦截（默认启用）。禁用后，3格内机甲抽牌前不再弹窗。"
	p065e1.mode = _TC.MODE_DIRECT
	p065e1.set_conditions([])
	p065e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p065e1.set_costs([])
	# CHOOSE_ONE 二选一（optional 可取消）：仅当前状态对应的"翻转"选项可见（CARD_COUNTER_IS 过滤），
	# 选中即 SET_CARD_COUNTER 翻转 flag。默认(absent=true)显示"禁用"选项；禁用后显示"启用"选项。
	p065e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [
				{
					"label": "禁用窥牌拦截（当前：启用）",
					"condition": [{"op": &"CARD_COUNTER_IS", "params": {"key": "pilot_066_intercept", "value": true, "default_when_absent": true}}],
					"actions": [{"type": &"SET_CARD_COUNTER", "params": {"key": "pilot_066_intercept", "value": false}}],
				},
				{
					"label": "启用窥牌拦截（当前：禁用）",
					"condition": [{"op": &"CARD_COUNTER_IS", "params": {"key": "pilot_066_intercept", "value": false, "default_when_absent": true}}],
					"actions": [{"type": &"SET_CARD_COUNTER", "params": {"key": "pilot_066_intercept", "value": true}}],
				},
			],
		},
	}])
	effects[p065e1.effect_id] = p065e1

	# ── effect_02 隐藏监听：GAIN_CARD_BEFORE 窥牌拦截（3格内机甲抽行动牌前）──
	var p065e2 := _ActionEffect.new()
	p065e2.effect_id = &"pilot_066_effect_02"
	p065e2.display_name = "窥牌拦截"
	p065e2.hide_button = true
	p065e2.merge_desc_into_index = 1
	p065e2.description = "每回合1次，3格范围内的机甲抽取行动牌前（包括我方），我方可以弃置1张行动牌，翻开行动牌堆顶3张牌，弃置其中的任意牌，剩下的放回牌堆顶。"
	p065e2.mode = _TC.MODE_LISTEN
	p065e2.priority = 10
	p065e2.listen_timing = _TC.GAIN_CARD_BEFORE
	p065e2.listen_action_type = &"gain_card"
	# 过滤：抽取（非选牌获取）+ 行动牌 + 来自行动牌堆（排除弃牌堆抽取）+ 抽取方机甲3格内（含自身）
	# + 我方有行动牌（无则不触发）+ 开关启用（CARD_COUNTER_IS 默认 true）。
	p065e2.set_conditions([
		{"op": &"GAIN_CARD_IS_DRAW"},
		{"op": &"GAIN_CARD_IS_ACTION_DRAW"},
		{"op": &"PAYLOAD_FROM_ZONE_IS", "params": {"zone": &"action_deck"}},
		{"op": &"GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE", "params": {"range": 3}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
		{"op": &"CARD_COUNTER_IS", "params": {"key": "pilot_066_intercept", "value": true, "default_when_absent": true}},
	])
	p065e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p065e2.set_costs([])
	p065e2.set_actions([{
		"type": &"PEEK_DECK_TOP_AND_DISCARD",
		"params": {
			"deck_zone": &"action_deck",
			"peek_count": 3,
			"cost_label": "银雪：弃置1张行动牌以窥视行动牌堆顶3张（可弃置其中任意牌）",
			"cost_confirm_verb": "弃置发动",
			"cost_cancel_label": "不发动",
			"peek_label": "行动牌堆顶3张（选择要弃置的牌，可不选）",
			"peek_confirm_verb": "弃置选中",
			"peek_cancel_label": "不弃置",
		},
	}])
	effects[p065e2.effect_id] = p065e2

	# ═══════════════════════════════════════════
	# pilot_067 骇客（联邦 N，cost 3, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果（1 个显示按钮 + 1 个隐藏监听，描述合并到按钮1）：
	# · effect_01（DIRECT 显示按钮，开关）：随时按按钮弹"启用/禁用骇客技能"二选一（可取消）。
	#   flag 存 card.counters["pilot_067_hack_switch"]（默认启用=true）。禁用后 effect_02 静默。
	# · effect_02（LISTEN BASIC_MOVE_AFTER 隐藏，merge_desc_into_index=1）：
	#   我方回合2次，我方机甲基础移动后，若3格范围内有持行动牌的其他机甲，直接弹目标选择
	#   （valid_mech_ids 只高亮可选；取消不消耗次数），选定后随机查看其2张行动牌
	#   （VIEW_RANDOM_OTHER_HAND_CARDS 通用模块，context.rng 洗牌保证 PvP 双端同步；
	#   不足2张看全部，0张也弹空窗并结算加成），非阻塞浮窗只给骇客玩家本人看。
	#   类型加成（各计一次可叠加）：含攻击 -> 本回合攻击次数+1（MODIFY_ATTACK_COUNT THIS_TURN）；
	#   含迎击 -> 本回合行动牌上限+1（MODIFY_ACTION_HAND_LIMIT THIS_TURN）；含辅助 -> 回复3动力
	#   （RESTORE_POWER）。条件走通用 EFFECT_ONCE_PER_TURN_AVAILABLE(key,max2)（亚林 p053 同款）+
	#   开关 CARD_COUNTER_IS + IS_OWNER_TURN + SELF_MECH_IS_MOVE_SUBJECT + 新增通用条件
	#   OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE。复用=复制改 key/range/view_count/bonus 即可。

	# ── effect_01 显示按钮：启用/禁用骇客技能开关（DIRECT，随时可按）──
	var p066e1 := _ActionEffect.new()
	p066e1.effect_id = &"pilot_067_effect_01"
	p066e1.display_name = "骇客·开关"
	p066e1.description = "随时启用或禁用骇客技能（默认启用）。禁用后，我方移动后不再弹查看目标选择。"
	p066e1.mode = _TC.MODE_DIRECT
	p066e1.set_conditions([])
	p066e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p066e1.set_costs([])
	# CHOOSE_ONE 二选一（optional 可取消）：仅当前状态对应的"翻转"选项可见（CARD_COUNTER_IS 过滤），
	# 选中即 SET_CARD_COUNTER 翻转 flag。默认(absent=true)显示"禁用"选项；禁用后显示"启用"选项。
	p066e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [
				{
					"label": "禁用骇客技能（当前：启用）",
					"condition": [{"op": &"CARD_COUNTER_IS", "params": {"key": "pilot_067_hack_switch", "value": true, "default_when_absent": true}}],
					"actions": [{"type": &"SET_CARD_COUNTER", "params": {"key": "pilot_067_hack_switch", "value": false}}],
				},
				{
					"label": "启用骇客技能（当前：禁用）",
					"condition": [{"op": &"CARD_COUNTER_IS", "params": {"key": "pilot_067_hack_switch", "value": false, "default_when_absent": true}}],
					"actions": [{"type": &"SET_CARD_COUNTER", "params": {"key": "pilot_067_hack_switch", "value": true}}],
				},
			],
		},
	}])
	effects[p066e1.effect_id] = p066e1

	# ── effect_02 隐藏监听：BASIC_MOVE_AFTER 移动窥牌（我方回合2次）──
	var p066e2 := _ActionEffect.new()
	p066e2.effect_id = &"pilot_067_effect_02"
	p066e2.display_name = "骇客·移动窥牌"
	p066e2.hide_button = true
	p066e2.merge_desc_into_index = 1
	p066e2.description = "我方回合2次，我方机甲基础移动后，若3格范围内有持有行动牌的其他机甲，可以选择1台并随机查看其2张行动牌（不足2张看全部；0张也结算加成）：含攻击牌则本回合攻击次数+1；含迎击牌则本回合行动牌上限+1；含辅助牌则回复3动力。类型各计一次，可同时触发。"
	p066e2.mode = _TC.MODE_LISTEN
	p066e2.priority = 10
	p066e2.listen_timing = _TC.BASIC_MOVE_AFTER
	p066e2.listen_action_type = &"basic_move"
	# 过滤：我方回合 + 移动主体是本机师所属机甲 + 开关启用 + 每回合2次未用满 +
	# 3格范围内存在持行动牌的其他机甲（候选由通用条件计算，供模块选目标用）。
	p066e2.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"SELF_MECH_IS_MOVE_SUBJECT"},
		{"op": &"CARD_COUNTER_IS", "params": {"key": "pilot_067_hack_switch", "value": true, "default_when_absent": true}},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_067_effect_02",
			"once_per_turn_max": 2,
		}},
		{"op": &"OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE", "params": {"range": 3}},
	])
	p066e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p066e2.set_costs([])
	p066e2.set_actions([
		{
			"type": &"VIEW_RANDOM_OTHER_HAND_CARDS",
			"params": {
				"range": 3,
				"view_count": 2,
				"attack_bonus": 1,
				"action_hand_bonus": 1,
				"support_power": 3,
				"once_per_turn_key": &"pilot_067_effect_02",
				"store_target_key": &"pilot_067_target_id",
				"source_label": "骇客：查看目标行动牌",
			},
		},
	])
	effects[p066e2.effect_id] = p066e2

	# ── pilot_064 布彻尔（联邦 N，cost 3, attack_limit 1, action_card_limit 3）──
	# 效果1「当作进攻」（主动 DIRECT 按钮，每玩家回合1次）：我方主阶段，可以将1张行动牌当作进攻使用。
	# 使用条件 = 普通进攻行动牌的使用条件：本回合可攻击（CAN_ACTIVE_ATTACK：攻击数>0，凯威攻击窗口
	# 期间豁免次数）+ 范围内有可攻击目标 + 手牌≥1张行动牌 + 每回合1次未用（EFFECT_ONCE_PER_TURN_AVAILABLE
	# + 确认后 MARK_EFFECT_ONCE_PER_TURN_USED，取消不计次数）。
	# 点击后弹我方行动牌单选框（必须选1张）→ 选中牌入临时区 → 消耗额度 → PLAY_AS_NAMED 当作进攻
	# （虚拟转化消耗1次攻击数，窗口攻击由 use_action_card 窗口豁免）→ 链末 DISCARD_TEMP_ZONE_CARDS。
	# 通用机制（不绑机师）：CHOOSE_MANY_CARDS + MOVE_ACTION_CARDS_TO_TEMP_ZONE + PLAY_AS_NAMED +
	# DISCARD_TEMP_ZONE_CARDS（布鲁克 pilot_030 / 诺拉 pilot_015 同款）。
	var p063e1 := _ActionEffect.new()
	p063e1.effect_id = &"pilot_064_effect_01"
	p063e1.display_name = "当作进攻"
	p063e1.description = "每回合1次，可以将1张行动牌当作进攻使用（选1张行动牌当作进攻牌打出，消耗1次攻击数；凯威攻击窗口期间攻击数豁免）。"
	p063e1.mode = _TC.MODE_DIRECT
	p063e1.priority = 10
	p063e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_064_effect_01",
			"once_per_turn_max": 1,
		}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_ATTACK_TARGET_IN_RANGE"},
		{"op": &"CAN_ACTIVE_ATTACK"},
	])
	p063e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p063e1.set_costs([])
	p063e1.set_actions([
		# ① 选1张我方行动牌（必须选1张；取消则不计次数）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"store_result_key": &"pilot_064_fuel_ids",
			"label": "选择当作进攻使用的1张行动牌",
			"confirm_verb": "当作进攻",
			"cancel_label": "取消",
		}},
		# ② 选中的牌移入临时区
		{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_064_fuel_ids"}},
		# ③ 确认后消耗本次回合额度（取消选择则不计次）
		{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_064_effect_01"}},
		# ④ 当作进攻牌打出（虚拟转化，消耗1次攻击数）
		{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_001_进攻", "attack_is_active": true}},
		# ⑤ 链末：临时区牌入弃牌堆
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p063e1.effect_id] = p063e1

	# 效果2「进攻加成」（LISTEN 被动，ATTACK_AT 优先级-1，响应判定后发动）：我方使用的进攻获得以下效果：
	# 本次攻击被响应则我方抽2张行动牌，未被响应则弃置目标2张行动牌。
	# 「进攻类」判定 ATTACK_IS_ASSAULT_CLASS：原版进攻牌（def.card_id==action_001_进攻）/ 转化进攻
	# （counters.virtual_as_def_id==action_001_进攻，PLAY_AS_NAMED 写入）/ 诺拉视为纯进攻
	# （_effect_flags.pilot_015_force_pure_assault）都算；强袭/猛击/破甲/掩护/闪击/反击等非进攻不算。
	# 弃牌通用参数 auto_discard_all_if_covered：目标行动牌总数≤2 时不弹窗直接全部弃置。
	var p063e2 := _ActionEffect.new()
	p063e2.effect_id = &"pilot_064_effect_02"
	p063e2.display_name = "进攻加成"
	p063e2.description = "我方使用的进攻获得以下效果：本次攻击被响应则我方抽2张行动牌，未被响应则弃置目标2张行动牌。"
	p063e2.mode = _TC.MODE_LISTEN
	p063e2.priority = -1  # 最低优先级：响应窗口关闭、responded 判定完成后发动（强袭 e2 同模式）
	p063e2.listen_timing = _TC.ATTACK_AT
	p063e2.listen_action_type = &"attack"
	p063e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_IS_ASSAULT_CLASS"},
	])
	p063e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p063e2.set_costs([])
	p063e2.set_actions([
		{"type": &"CONDITIONAL_ACTIONS", "params": {
			"conditions": [{"op": &"ATTACK_WAS_RESPONDED"}],
			"if_true_actions": [
				# 被响应：我方抽2张行动牌
				{"type": &"EXECUTE_GAIN_CARD", "params": {
					"from_zone": &"action_deck",
					"card_kind": &"action",
					"count": 2,
					"mech_ids": ["$binding_context.mech_id"],
					"reason": &"pilot_064_draw_on_responded",
				}},
			],
			"if_false_actions": [
				# 未被响应：我方弹目标行动牌选框（暗牌必选2张；目标≤2张直接全部弃置）
				{"type": &"EXECUTE_DISCARD", "params": {
					"from_target": true,
					"target_id": "$payload.target_id",
					"count": 2,
					"choose": true,
					"face_up": false,
					"auto_discard_all_if_covered": true,
					"reason": &"pilot_064_discard_target",
				}},
			],
		}},
	])
	effects[p063e2.effect_id] = p063e2

	# ── pilot_087 征服（混乱 N，cost 3, attack_limit 1, action_card_limit 3）──
	# 效果1（DIRECT 主动按钮，每我方回合1次）「征服-宣言弃置」：
	#   我方主阶段点击按钮（3格范围内无持有行动牌的其他机甲则置灰不可点，条件
	#   OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE range3）→ PILOT_088_CONQUER 模块
	#   （TimingEngine 特判，多阶段挂起）：
	#   ① 选3格内持有行动牌的其他机甲（select_mech_target，valid_mech_ids 过滤；取消=不计次不消耗）
	#   ② 选定目标即消耗本回合1次（_mark_once_per_turn_used）→ 弹三选一类型（攻击/迎击/辅助，
	#      不可取消）→ 记录宣言类型
	#   ③ synced_shuffle 目标手牌随机取1张 → 非阻塞浮窗（所有玩家端显示：宣言类型+随机展示的牌）
	#      → 类型匹配：相同→弃目标除展示牌外全部行动牌；不同→弃展示牌（EXECUTE_DISCARD card_ids 显式）
	#   按钮悬框说明 = description（主动与被动合一的单一按钮）。
	var p088e1 := _ActionEffect.new()
	p088e1.effect_id = &"pilot_087_effect_01"
	p088e1.display_name = "征服-宣言弃置"
	p088e1.description = "我方回合1次，可以宣言1种行动牌类型(攻击，迎击，辅助)，并展示3格范围内1台其他机甲的1张随机行动牌。若该牌类型与宣言相同，则弃置该机甲其余未展示的牌；否则弃置该展示的牌。"
	p088e1.mode = _TC.MODE_DIRECT
	p088e1.priority = 10
	# once_per_turn_key 字段（_mark_once_per_turn_used 读 effect 字段，与条件里的 key 一致才能
	# 检查可用+确认消耗；p062 同款说明）。条件 EFFECT_ONCE_PER_TURN_AVAILABLE 读条件 params。
	p088e1.once_per_turn_key = &"pilot_087_effect_01"
	p088e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_087_effect_01",
			"once_per_turn_max": 1,
		}},
		{"op": &"OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE", "params": {"range": 3}},
	])
	p088e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p088e1.set_costs([])
	p088e1.set_actions([
		{"type": &"PILOT_088_CONQUER", "params": {}},
	])
	effects[p088e1.effect_id] = p088e1

	# ── pilot_063 洛尔恩（联邦 N，cost 3, attack_limit 1, action_card_limit 3）──
	# 效果1「转化掩护」（被动，出现在掩护窗口，每任意玩家回合1次）：可以1张行动牌当作掩护使用。
	# 通用时点机制 COVER_WINDOW_EXTRA（虚拟时点，不 fire_timing）：掩护多选窗（cover_effect1
	# CHOOSE_MANY_CARDS collect_cover_window_extras=true）扫描窗口拥有玩家注册在此虚拟时点的
	# 永久监听效果，条件满足（次数可用+手牌≥1行动牌）时作为复选框「洛尔恩--掩护」展示，可与真实
	# 掩护牌复选。确认后：真实掩护先按顺序执行（cover_effect1 use_action_card 批量），然后洛尔恩
	# 转化流程：弹行动牌单选窗（必须选1张，取消=不计次数）→ 选中牌移入临时区 → PLAY_AS_NAMED
	# 当作掩护（attack_is_active=false 不耗攻击数，attack_action_id 从 payload 注入使 -5/后续效果
	# 定位原攻击）→ 链末 DISCARD_TEMP_ZONE_CARDS。无行动牌时单选窗空候选跳过，效果直接结束不计次。
	# 每回合1次计数走标准 once_per_turn（EFFECT_ONCE_PER_TURN_AVAILABLE 条件 + store_result_key
	# 确认路径自动 _mark_once_per_turn_used：确认非空选消耗、取消/空选不计次）。
	var p062e1 := _ActionEffect.new()
	p062e1.effect_id = &"pilot_063_effect_01"
	# display_name 即掩护窗口复选框标签（_collect_cover_window_extras 用 eff.display_name）：
	# 规则要求显示「洛尔恩--掩护」。
	p062e1.display_name = "洛尔恩--掩护"
	p062e1.description = "每回合1次，可以1张行动牌当作掩护使用（选1张行动牌当作掩护打出，威力-5）。"
	p062e1.mode = _TC.MODE_LISTEN
	p062e1.priority = 10
	# once_per_turn_key 字段（store_result_key 确认路径 _mark_once_per_turn_used 读 effect 字段；
	# 条件 EFFECT_ONCE_PER_TURN_AVAILABLE 读的是条件 params，两处都要有才能"检查可用+确认消耗"）
	p062e1.once_per_turn_key = &"pilot_063_effect_01"
	p062e1.listen_timing = _TC.COVER_WINDOW_EXTRA
	p062e1.set_conditions([
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_063_effect_01",
			"once_per_turn_max": 1,
		}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
	])
	p062e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p062e1.set_costs([])
	p062e1.set_actions([
		# ① 选1张我方行动牌（必须选1张；取消则不计次数，无候选则跳过）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"store_result_key": &"pilot_063_fuel_ids",
			"label": "选择当作掩护使用的1张行动牌",
			"confirm_verb": "当作掩护",
			"cancel_label": "取消",
		}},
		# ② 选中的牌移入临时区（供 PLAY_AS_NAMED 取首张作虚拟牌）
		{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_063_fuel_ids"}},
		# ③ 当作掩护牌打出（虚拟转化，防御分支不耗攻击数；attack_action_id 注入定位原攻击）
		{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_016_掩护", "attack_is_active": false}},
		# ④ 链末：临时区牌入弃牌堆
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p062e1.effect_id] = p062e1

	# 效果2「掩护加成」（LISTEN 被动，USE_ACTION_AFTER）：我方使用掩护（转化或原版，不含进攻）时，
	# 在掩护效果完成后立即弹出二选一（可取消）：(a) 该攻击损伤-1（MODIFY_ATTACK_MARKERS
	# fork_persist=true 写 fork_extra_markers，双连 fork 深拷贝保留此字段，复制攻击也继承减损）；
	# (b) 该攻击不能被响应（SET_ATTACK_NO_RESPONSE 写 attack record.no_response，fire_timing
	# 响应窗口直接跳过——任何响应包括识破都不弹）。多重掩护逐个结算（每个掩护 use_action_card 的
	# USE_ACTION_AFTER 各触发一次效果2）。
	# 「我方使用掩护」判定 USED_CARD_IS_COVER（card_def_id==action_016_掩护，原版与转化均命中）
	# + USED_CARD_EXECUTOR_IS_SELF（binding_context.mech_id==执行者，排除他人打掩护）。
	var p062e2 := _ActionEffect.new()
	p062e2.effect_id = &"pilot_063_effect_02"
	p062e2.display_name = "掩护加成"
	p062e2.description = "我方使用掩护后二选一：该攻击损伤-1 / 该攻击不能被响应。"
	p062e2.mode = _TC.MODE_LISTEN
	p062e2.priority = 10
	p062e2.listen_timing = _TC.USE_ACTION_AFTER
	p062e2.listen_action_type = &"use_action_card"
	p062e2.set_conditions([
		{"op": &"USED_CARD_IS_COVER"},
		{"op": &"USED_CARD_EXECUTOR_IS_SELF"},
	])
	p062e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p062e2.set_costs([])
	p062e2.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
			{"label": "该攻击损伤-1", "actions": [
				{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -1, "fork_persist": true}},
			]},
			{"label": "该攻击不能被响应", "actions": [
				{"type": &"SET_ATTACK_NO_RESPONSE", "params": {}},
			]},
		]}},
	])
	effects[p062e2.effect_id] = p062e2

	# ═══════════════════════════════════════════
	# pilot_068 丹（联邦 N，cost 3, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_068_effect_01 当作双连（主动 DIRECT 按钮，每玩家回合1次）──
	# 效果1「每回合1次，可以将1张行动牌当作双连使用。」每个玩家的每个回合可用1次；
	# 只在发起者主阶段主动使用（不是我方回合不能主动使用），凯威触发效果（攻击窗口）可用
	# （CAN_ACTIVE_ATTACK：攻击数>0，凯威攻击窗口期间豁免次数）。
	# 使用条件 = 普通双连行动牌（action_005_双连）使用条件：本回合可攻击 + 范围内有可攻击目标
	# + 手牌≥1张行动牌 + 每回合1次未用（EFFECT_ONCE_PER_TURN_AVAILABLE + 确认后
	# MARK_EFFECT_ONCE_PER_TURN_USED，取消不计次数）。
	# 点击后弹我方行动牌单选框（必须选1张）→ 选中牌入临时区 → 消耗额度 → PLAY_AS_NAMED
	# 当作双连（双连为攻击牌 action_type=攻击，attack_is_active=true 消耗1次攻击数；
	# 凯威窗口攻击由 use_action_card 窗口豁免）→ 链末 DISCARD_TEMP_ZONE_CARDS。
	# 通用机制（不绑机师）：CHOOSE_MANY_CARDS + MOVE_ACTION_CARDS_TO_TEMP_ZONE + PLAY_AS_NAMED +
	# DISCARD_TEMP_ZONE_CARDS（布鲁克 pilot_030 / 诺拉 pilot_015 / 布彻尔 pilot_064 同款）。
	var p067e1 := _ActionEffect.new()
	p067e1.effect_id = &"pilot_068_effect_01"
	p067e1.display_name = "当作双连"
	p067e1.description = "每回合1次，可以将1张行动牌当作双连使用（选1张行动牌当作双连牌打出，对1~2台机甲发动攻击，消耗1次攻击数；凯威攻击窗口期间攻击数豁免）。"
	p067e1.mode = _TC.MODE_DIRECT
	p067e1.priority = 10
	p067e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_068_effect_01",
			"once_per_turn_max": 1,
		}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_ATTACK_TARGET_IN_RANGE"},
		{"op": &"CAN_ACTIVE_ATTACK"},
	])
	p067e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p067e1.set_costs([])
	p067e1.set_actions([
		# ① 选1张我方行动牌（必须选1张；取消则不计次数）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"store_result_key": &"pilot_068_fuel_ids",
			"label": "选择当作双连使用的1张行动牌",
			"confirm_verb": "当作双连",
			"cancel_label": "取消",
		}},
		# ② 选中的牌移入临时区
		{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_068_fuel_ids"}},
		# ③ 确认后消耗本次回合额度（取消选择则不计次）
		{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_068_effect_01"}},
		# ④ 当作双连牌打出（虚拟转化，消耗1次攻击数）
		{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_005_双连", "attack_is_active": true}},
		# ⑤ 链末：临时区牌入弃牌堆
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p067e1.effect_id] = p067e1

	# ── pilot_068_effect_02 双连加成（LISTEN 被动，ATTACK_PRE 优先级-1，其后触发）──
	# 效果2「我方使用的双连若指定了2个目标，则威力+3，命中额外产生1损伤。」
	# 被动持续：我方使用的双连（原版双连卡 def.card_id==action_005_双连，或转化双连
	# counters.virtual_as_def_id==action_005_双连，丹当作双连 PLAY_AS_NAMED 写入）都算；
	# 强袭/猛击/破甲/掩护/闪击/反击等非双连不算（ATTACK_IS_NAMED_CARD 通用判定）。
	# ATTACK_PRE 时目标已选定（select_target handler 先写 target_ids 再 fire PRE），
	# 指定了2个目标才触发（ATTACK_TARGET_COUNT_AT_LEAST count=2）。
	# 威力+3：MODIFY_ATTACK_MIGHT 写入 record.extra_might，多目标 fork 深拷贝 record 继承，
	# 2个复制攻击各自威力+3。
	# 命中额外产生1损伤：MODIFY_ATTACK_MARKERS fork_persist=true 写入 record.fork_extra_markers，
	# fork 深拷贝保留（清 extra_markers 不清 fork_extra_markers），每个复制攻击命中时+1损伤
	# （未命中不产生）；与破甲 effect2 同机制。
	var p067e2 := _ActionEffect.new()
	p067e2.effect_id = &"pilot_068_effect_02"
	p067e2.display_name = "双连加成"
	p067e2.description = "我方使用的双连若指定了2个目标，则威力+3，命中额外产生1损伤。"
	p067e2.mode = _TC.MODE_LISTEN
	p067e2.priority = -1  # 最低优先级：在其他效果之后触发（规格指定）
	p067e2.listen_timing = _TC.ATTACK_PRE
	p067e2.listen_action_type = &"attack"
	p067e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_IS_NAMED_CARD", "params": {"card_def_id": &"action_005_双连"}},
		{"op": &"ATTACK_TARGET_COUNT_AT_LEAST", "params": {"count": 2}},
	])
	p067e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p067e2.set_costs([])
	p067e2.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 1, "fork_persist": true}},
	])
	effects[p067e2.effect_id] = p067e2

	# ═══════════════════════════════════════════
	# pilot_065 柏格（联邦 N，cost 3, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_065_effect_01 弃装获金抽装（我方回合1次，DIRECT 主动按钮）──
	# 我方回合1次：点击弹"选1张未设置的装备牌"窗（OWNER_UNEQUIPPED_EQUIPMENT_CARDS 仅装备手牌、
	#   不含已设置槽位；min_count=1 必选、可取消=中止不消耗次数，确认即 mark once_per_turn），
	#   弃置所选牌后 +2金币、抽1张装备牌；若弃置的牌是武器则再抽2张行动牌。
	# 无未设置装备可弃时按钮置灰（HAS_UNEQUIPPED_EQUIPMENT_CARD）。
	# 通用机制（可复用）：CHOOSE_MANY_CARDS(OWNER_UNEQUIPPED_EQUIPMENT_CARDS)+EXECUTE_DISCARD+
	#   GAIN_GOLD+EXECUTE_GAIN_CARD+CONDITIONAL_ACTIONS(PAYLOAD_CARD_IS_WEAPON 条件分支)。
	var p064e1 := _ActionEffect.new()
	p064e1.effect_id = &"pilot_065_effect_01"
	p064e1.display_name = "弃装获金抽装"
	p064e1.description = "我方回合1次，可以弃置1张未设置的装备牌，获得2金币并抽1张装备牌，若弃置的是武器牌则再抽2张行动牌。"
	p064e1.mode = _TC.MODE_DIRECT
	p064e1.priority = 10
	p064e1.once_per_turn_key = &"pilot_065_effect_01"
	p064e1.once_per_turn_max = 1
	p064e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_UNEQUIPPED_EQUIPMENT_CARD"},
	])
	p064e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p064e1.set_costs([])
	p064e1.set_actions([
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"OWNER_UNEQUIPPED_EQUIPMENT_CARDS",
				"max_count": 1,
				"min_count": 1,
				"store_result_key": &"pilot_065_discard_ids",
				"discard_selected": false,
				"label": "选择1张要弃置的未设置装备牌",
				"confirm_verb": "弃置",
				"cancel_label": "取消",
			}
		},
		{
			"type": &"EXECUTE_DISCARD",
			"params": {
				"card_ids": "$runtime.pilot_065_discard_ids",
				"reason": &"pilot_065_discard",
			}
		},
		{
			"type": &"GAIN_GOLD",
			"params": {
				"amount": 2,
				"player_id": "$binding_context.player_id",
			}
		},
		{
			"type": &"EXECUTE_GAIN_CARD",
			"params": {
				"from_zone": &"equipment_deck",
				"card_kind": &"equipment",
				"count": 1,
				"player_id": "$binding_context.player_id",
				"reason": &"pilot_065_draw",
			}
		},
		# 若弃置的装备牌是武器则再抽2张行动牌（PAYLOAD_CARD_IS_WEAPON 读 store 的弃牌 id 查 def）
		{"type": &"CONDITIONAL_ACTIONS", "params": {
			"conditions": [{"op": &"PAYLOAD_CARD_IS_WEAPON", "params": {"key": &"pilot_065_discard_ids"}}],
			"if_true_actions": [{"type": &"EXECUTE_GAIN_CARD", "params": {
				"from_zone": &"action_deck",
				"card_kind": &"action",
				"count": 2,
				"player_id": "$binding_context.player_id",
				"reason": &"pilot_065_weapon_bonus",
			}}],
			"if_false_actions": [],
		}},
	])
	effects[p064e1.effect_id] = p064e1

	# ═══════════════════════════════════════════
	# pilot_060 冰魄（联邦 N，cost 3, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════

	# ── pilot_060_effect_01 迎击范围压制（LISTEN 被动，USE_ACTION_AT 自动，按钮1）──
	# 我方在响应窗口使用迎击牌响应攻击时，先于迎击牌自身效果执行（USE_ACTION_AT 时点早于
	# execute_effects 步），使被响应的攻击范围-2（不低于1），并写 flag 到该 attack.record._effect_flags
	# （供 effect_02 判定）。无每回合限制、无弹窗确认（被动自动）。
	# 触发条件仿 equipment_effect_035：USED_CARD_OWNER_IS_SELF（我方打出的牌）+
	#   USED_COUNTER_CARD（迎击牌）+ USED_ACTION_HAS_LINKED_ATTACK（响应路径绑定原攻击）。
	# MODIFY_ATTACK_RANGE 在 use_action_card 上下文执行，parent 非 attack，
	#   经 payload.attack_action_id 定位原 attack（ActionService 已扩展回退）。
	var p068e1 := _ActionEffect.new()
	p068e1.effect_id = &"pilot_060_effect_01"
	p068e1.display_name = "迎击范围压制"
	p068e1.description = "我方使用迎击牌响应攻击时，该攻击范围-2（不会低于1）。若该攻击没有命中，我方抽2张行动牌。"
	p068e1.mode = _TC.MODE_LISTEN
	p068e1.priority = 10
	p068e1.listen_timing = _TC.USE_ACTION_AT
	p068e1.listen_action_type = &"use_action_card"
	p068e1.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
		{"op": &"USED_ACTION_HAS_LINKED_ATTACK"},
	])
	p068e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p068e1.set_costs([])
	p068e1.set_actions([
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "min_value": 1}},
		{"type": &"SET_ACTION_RECORD_FLAG", "params": {"flag": &"pilot_060_range_reduced", "value": true}},
	])
	effects[p068e1.effect_id] = p068e1

	# ── pilot_060_effect_02 未命中抽牌（LISTEN 被动，ATTACK_AFTER，隐藏合并到按钮1）──
	# effect_01 已设 flag（我方迎击并减过范围）+ 该攻击未命中（payload.miss=true）时，我方抽2张行动牌。
	# 挂 ATTACK_AFTER：check_hit 步已写 hit/miss；flag 经 fork 深拷贝 record 继承（双连多目标亦然）。
	var p068e2 := _ActionEffect.new()
	p068e2.effect_id = &"pilot_060_effect_02"
	p068e2.display_name = "未命中抽牌"
	p068e2.description = "若该攻击没有命中，我方抽2张行动牌。"
	p068e2.mode = _TC.MODE_LISTEN
	p068e2.priority = 10
	p068e2.listen_timing = _TC.ATTACK_AFTER
	p068e2.listen_action_type = &"attack"
	p068e2.set_conditions([
		{"op": &"ATTACK_RECORD_FLAG_IS_SET", "params": {"flag": &"pilot_060_range_reduced"}},
		{"op": &"PAYLOAD_ATTACK_MISS"},
	])
	p068e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p068e2.set_costs([])
	p068e2.set_actions([{
		"type": &"EXECUTE_GAIN_CARD",
		"params": {
			"from_zone": &"action_deck",
			"card_kind": &"action",
			"count": 2,
			"player_id": "$binding_context.player_id",
			"reason": &"pilot_060_miss_draw",
		},
	}])
	p068e2.hide_button = true
	p068e2.merge_desc_into_index = 1
	effects[p068e2.effect_id] = p068e2

	# ═══════════════════════════════════════════
	# pilot_069 影刹（帝国 N，cost 4, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════

	# ── pilot_069_effect_01 静候猎杀（LISTEN TURN_END，按钮1）──
	# 我方回合结束时（IS_OWNER_TURN 过滤）：本回合未发动攻击（mech.has_attacked_this_turn==false，
	# 攻击动作启动即置位，含铠威窗口/联合/迎击）→ 下次攻击威力+3；本回合移动未超过4格
	# （cells_moved_this_turn<=4）→ 下次攻击范围+1。可叠加、无时间限制。
	# 累加走通用 ACCUMULATE_NEXT_ATTACK_BONUS：读机甲状态累加两张牌计数器（跨回合叠加）。
	# 不在此时清空——取消攻击时加成保留；由 effect_03 在攻击完全结算后 SET_CARD_COUNTER 置 0。
	var p069e1 := _ActionEffect.new()
	p069e1.effect_id = &"pilot_069_effect_01"
	p069e1.display_name = "静候猎杀"
	p069e1.description = "我方回合结束时，若本回合未发动攻击，则下次攻击威力+3；若本回合移动未超过4格，则下次攻击范围+1。上述效果可叠加。"
	p069e1.mode = _TC.MODE_LISTEN
	p069e1.priority = 10
	p069e1.listen_timing = _TC.TURN_END
	p069e1.listen_action_type = &"turn"
	p069e1.set_conditions([
		{"op": &"IS_OWNER_TURN"},
	])
	p069e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p069e1.set_costs([])
	p069e1.set_actions([
		{"type": &"ACCUMULATE_NEXT_ATTACK_BONUS", "params": {
			"mech_id": "$binding_context.mech_id",
			"card_instance_id": "$binding_context.card_instance_id",
			"might_key": &"pilot_069_next_might", "might_delta": 3,
			"range_key": &"pilot_069_next_range", "range_delta": 1, "range_when_moved_at_most": 4,
		}},
	])
	effects[p069e1.effect_id] = p069e1

	# ── pilot_069_effect_02 下次攻击加成应用（LISTEN ATTACK_BEFORE，隐藏合并到按钮1）──
	# 我方发动攻击时（ATTACK_BEFORE，早于选目标/双连 fork），读两张牌计数器累加进
	# attack.record.extra_might/extra_range。不清空：攻击被取消（选目标取消/响应取消）时加成保留；
	# 双连多目标 fork 深拷贝 record 自动继承（每个复制攻击都带加成）。
	var p069e2 := _ActionEffect.new()
	p069e2.effect_id = &"pilot_069_effect_02"
	p069e2.display_name = "下次攻击加成"
	p069e2.description = "加成在我方下次攻击选目标前生效，攻击完全结算后消失（取消攻击不消耗）。"
	p069e2.mode = _TC.MODE_LISTEN
	p069e2.priority = 10
	p069e2.listen_timing = _TC.ATTACK_BEFORE
	p069e2.listen_action_type = &"attack"
	p069e2.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	p069e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p069e2.set_costs([])
	p069e2.set_actions([
		{"type": &"APPLY_NEXT_ATTACK_BONUS", "params": {
			"card_instance_id": "$binding_context.card_instance_id",
			"might_key": &"pilot_069_next_might",
			"range_key": &"pilot_069_next_range",
		}},
	])
	p069e2.hide_button = true
	p069e2.merge_desc_into_index = 1
	effects[p069e2.effect_id] = p069e2

	# ── pilot_069_effect_03 攻击结算后清空加成（LISTEN ATTACK_SETTLE，隐藏合并到按钮1）──
	# 攻击完全结算（含双连所有 fork）后置 0 两张牌计数器——「下次攻击」用完即消失。
	# fork 情况：各 fork 已在 fork 时深拷贝 record 带上加成，任一枚 fork SETTLE 清空不影响其他枚；
	# 攻击被取消时 SETTLE 不触发，计数器保留到真正完成的攻击。
	var p069e3 := _ActionEffect.new()
	p069e3.effect_id = &"pilot_069_effect_03"
	p069e3.display_name = "结算清空"
	p069e3.description = ""
	p069e3.mode = _TC.MODE_LISTEN
	p069e3.priority = 10
	p069e3.listen_timing = _TC.ATTACK_SETTLE
	p069e3.listen_action_type = &"attack"
	p069e3.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	p069e3.set_target_rules([{"rule": &"NO_TARGET"}])
	p069e3.set_costs([])
	p069e3.set_actions([
		{"type": &"SET_CARD_COUNTER", "params": {"card_instance_id": "$binding_context.card_instance_id", "key": &"pilot_069_next_might", "value": 0}},
		{"type": &"SET_CARD_COUNTER", "params": {"card_instance_id": "$binding_context.card_instance_id", "key": &"pilot_069_next_range", "value": 0}},
	])
	p069e3.hide_button = true
	p069e3.merge_desc_into_index = 1
	effects[p069e3.effect_id] = p069e3

	# ═══════════════════════════════════════════
	# pilot_070 烈火（帝国 N，cost 3, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1（LISTEN 被动按钮1 置灰+悬停）「命中抽燃牌」：我方发动的攻击命中后，
	# 抽3张行动牌并打"燃"标签（本回合不占行动牌上限、弃超上限选框不含、回合结束后清除）。
	# 通用模块：build_attack_hit_draw_and_tag_effect(params) 参数化构建（count/tag_name/reason/文案），
	# 复用=改 params 即可，与效果绑定不绑机师。燃标签生命周期帮助函数见本文件"燃"标签段。
	var p070e1 := build_attack_hit_draw_and_tag_effect({
		"effect_id": &"pilot_070_effect_01",
		"display_name": "命中抽燃牌",
		"description": "若发动的攻击命中，则可以抽3张行动牌（这些牌本回合不占行动牌上限）。",
		"count": 3,
		"reason": &"pilot_070_ran_draw",
		"tag_name": RAN_TAG,
	})
	effects[p070e1.effect_id] = p070e1

	# ═══════════════════════════════════════════
	# pilot_071 弥雅（帝国 N，cost 3, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果1（1个显示按钮，被动 LISTEN TURN_AFTER_END）「回合后选机甲抽3弃1」：
	#   我方回合结束后（IS_OWNER_TURN 过滤），选1台3格范围内机甲（含我方，正常目标UI，
	#   可取消=不发动，不抽不弃）→ 被选机甲抽3张行动牌（EXECUTE_GAIN_CARD 走 mech_ids
	#   反查目标玩家，GAIN_CARD 时点完整触发）→ 之后被选机甲玩家弹窗选弃自己1张行动牌
	#   （EXECUTE_DISCARD，executor/player_id=目标玩家，choose=true 弹自己手牌、no_cancel
	#   必弃、空手自动跳过，与索伦 pilot_044 自弃同款但归属被选机甲）。
	# 通用模块：build_turn_end_choose_mech_draw_discard_effect(params) 参数化构建
	# （range/draw_count/discard_count/reason_prefix/文案），复用=改 params 即可，与效果绑定不绑机师。
	var p071e1 := build_turn_end_choose_mech_draw_discard_effect({
		"effect_id": &"pilot_071_effect_01",
		"display_name": "弥雅-回合后选机甲抽3弃1",
		"description": "每个我方回合结束后，可以选择1台3格范围内的机甲（包括我方）使其抽3张行动牌，之后其再弃置1张牌。",
		"range": 3,
		"draw_count": 3,
		"discard_count": 1,
		"reason_prefix": &"pilot_071",
	})
	effects[p071e1.effect_id] = p071e1

	# ═══════════════════════════════════════════
	# pilot_077 卡修（帝国 N，cost 3, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果「每个效果每回合1次：使用攻击牌时，回复5动力；使用迎击牌时，回复4动力；使用辅助牌时，回复3动力。」
	# 拆为 3 个 LISTEN 效果（按钮1 + 两个隐藏合并描述），共用通用模块
	# build_use_action_type_restore_power_effect：USE_ACTION_AT（使用行动牌时时点，先于迎击牌等
	# 自身效果执行）+ USED_CARD_OWNER_IS_SELF（持有者本人出牌）+ USED_CARD_TYPE_IS（按实体牌
	# action_type 判定攻击/迎击/辅助）+ RESTORE_POWER（method=restore 不超上限）。
	# 强制自动发动、无选择。每分支各自 once_per_turn_key（attack/counter/support_restore），
	# 3 分支每回合各 1 次互不影响。01a 建按钮1，01b/01c 隐藏合并描述。
	var p072e1a := build_use_action_type_restore_power_effect({
		"effect_id": &"pilot_077_effect_01a",
		"display_name": "使用攻击牌回动力",
		"description": "每个效果每回合1次：使用攻击牌时回复5动力；使用迎击牌时回复4动力；使用辅助牌时回复3动力。",
		"card_type": "攻击",
		"power_amount": 5,
		"once_per_turn_key": &"pilot_077_attack_restore",
	})
	effects[p072e1a.effect_id] = p072e1a
	var p072e1b := build_use_action_type_restore_power_effect({
		"effect_id": &"pilot_077_effect_01b",
		"display_name": "使用迎击牌回动力",
		"description": "使用迎击牌时回复4动力。",
		"card_type": "迎击",
		"power_amount": 4,
		"once_per_turn_key": &"pilot_077_counter_restore",
	})
	p072e1b.hide_button = true
	p072e1b.merge_desc_into_index = 1
	effects[p072e1b.effect_id] = p072e1b
	var p072e1c := build_use_action_type_restore_power_effect({
		"effect_id": &"pilot_077_effect_01c",
		"display_name": "使用辅助牌回动力",
		"description": "使用辅助牌时回复3动力。",
		"card_type": "辅助",
		"power_amount": 3,
		"once_per_turn_key": &"pilot_077_support_restore",
	})
	p072e1c.hide_button = true
	p072e1c.merge_desc_into_index = 1
	effects[p072e1c.effect_id] = p072e1c

	# ═══════════════════════════════════════════
	# pilot_078 法尔科（帝国 N，cost 4, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果1（1个主动 DIRECT 按钮）「弃2行动抽1高级装备背面置备用区」：
	#   我方回合1次，弃置2张行动牌（CHOOSE_MANY_CARDS 选2可取消，取消不消耗次数，
	#   确认即 mark once_per_turn）→ 弃置（EXECUTE_DISCARD）→ 抽1张高级装备牌
	#   （EXECUTE_GAIN_CARD advanced_equipment_deck + _tag_on_draw 打"禁"标签 +
	#   _draw_result_sink 回写父 record）→ 弹备用区选择（新 act_type
	#   CHOOSE_RESERVE_SLOT_AND_SET_EQUIP，TimingEngine 处理；仅显示占位不翻牌，
	#   复用 hidden_reserve_slot 弹窗，强制选择不可取消）→ 效果驱动设置到目标备用区
	#   （EXECUTE_SET_EQUIP，RESERVE 槽自动 face_down，绕过主动设置/卖出拦截）。
	#   "禁"标签：装备牌带禁标签期间不能【主动】设置与卖出（CardSetService.set_equipment /
	#   sell_equipment 拦截 + UI 置灰；效果驱动的设置如约书亚/霍恩不受影响），标签在
	#   打标签玩家的下个回合开始后（TurnService TURN_AFTER_START）清除。
	# 通用模块：build_discard_draw_advanced_equip_set_reserve_effect(params) 参数化构建
	# （discard_count/draw_count/from_zone/tag_name/reason_prefix/文案），复用=改 params 即可，
	# 与效果绑定不绑机师。禁标签生命周期帮助函数见本文件"禁"标签段。
	var p073e1 := build_discard_draw_advanced_equip_set_reserve_effect({
		"effect_id": &"pilot_078_effect_01",
		"display_name": "弃2抽高级装置备用区",
		"description": "我方回合1次，可以弃置2张行动牌，之后抽取1张高级装备牌，并背面朝上置于我方或其他机甲的备用区，直到下个我方回合开始后，该高级装备牌不能主动设置与卖出。",
		"discard_count": 2,
		"draw_count": 1,
		"from_zone": &"advanced_equipment_deck",
		"tag_name": EQUIP_FORBID_TAG,
		"reason_prefix": &"pilot_078",
	})
	effects[p073e1.effect_id] = p073e1

	# ═══════════════════════════════════════════
	# pilot_073 泰特（帝国 N，cost 4, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果1（按钮1 DIRECT 主动）「近战弃1+3威力」：我方回合3次，可以弃置1张行动牌，
	#   使本回合下次使用近战武器攻击时威力+3（可叠加）。
	#   条件：IS_OWNER_MAIN_PHASE + HAS_ACTION_CARD_IN_HAND(count=1)。
	#   动作链：CHOOSE_MANY_CARDS(选1行动牌,可取消,确认即 mark once_per_turn)
	#     → EXECUTE_DISCARD(弃选中) → ACCUMULATE_MELEE_MIGHT(本机甲 +3)。
	#   待发威力按 (来源牌实例, 机甲) 存 _melee_buff（泰特自己与他机各自独立）。
	#   隐藏 LISTEN（并入按钮1悬停）：
	#     · apply（ATTACK_BEFORE）：自己近战攻击（ATTACK_EFFECTIVE_WEAPON_KIND=近战，
	#       含近战装头部转换）应用待发威力到 attack.record.extra_might。
	#     · consume（ATTACK_SETTLE）：近战攻击结算后消耗（清空；取消攻击保留）。
	#     · turnend（TURN_AFTER_END）：自己回合结束后清空（"本回合"限定）。
	# 效果2（按钮2 DIRECT 主动）「授予他机获效」：我方回合1次，选择1台其他机甲获得上述效果，
	#   直到下个我方回合开始（EX 按钮）。
	#   条件：IS_OWNER_MAIN_PHASE；目标：CHOOSE_OTHER_MECH（标准目标选择 UI，无范围，
	#   可取消不计次）；动作：GRANT_MELEE_MIGHT(注册目标机甲 DIRECT+隐藏 LISTEN，binding granted=true)。
	#   隐藏 LISTEN（并入按钮2悬停）：expire（TURN_AFTER_START）：自己回合开始后到期，
	#     注销目标机甲效果1 + 清空其待发威力（EX 消失）。
	# 通用模块：_melee_buff/_melee_grant_mechs registry + add/get/clear_melee_buff +
	#   grant_melee_might_to_mech/expire_melee_might_grants 帮助函数（见本文件"近战弃牌威力"模块），
	#   与效果绑定不绑机师；复用=改 params 复制即可。

	# ── pilot_073_effect_01 近战弃1+3威力（DIRECT 按钮1）──
	var p074e1 := _ActionEffect.new()
	p074e1.effect_id = &"pilot_073_effect_01"
	p074e1.display_name = "近战弃1+3威力"
	p074e1.description = "我方回合3次，可以弃置1张行动牌，使本回合下次使用近战武器攻击时威力+3（可叠加）。"
	p074e1.mode = _TC.MODE_DIRECT
	p074e1.priority = 10
	p074e1.once_per_turn_key = &"pilot_073_effect_01"
	p074e1.once_per_turn_max = 3
	p074e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p074e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p074e1.set_costs([])
	p074e1.set_actions([
		# ① 选1张行动牌弃置（可取消；取消不消耗次数，确认即 mark once_per_turn）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"store_result_key": &"pilot_073_discard_ids",
			"discard_selected": false,
			"label": "选择要弃置的1张行动牌",
			"confirm_verb": "弃置",
			"cancel_label": "取消",
		}},
		# ② 弃置选中行动牌
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.pilot_073_discard_ids",
			"reason": &"pilot_073_discard",
		}},
		# ③ 本机甲累积待发近战威力 +3（可叠加）
		{"type": &"ACCUMULATE_MELEE_MIGHT", "params": {
			"source_cid": "$binding_context.card_instance_id",
			"mech_id": "$binding_context.mech_id",
			"delta": 3,
		}},
	])
	effects[p074e1.effect_id] = p074e1

	# ── pilot_073_effect_01_apply 近战攻击应用（LISTEN ATTACK_BEFORE，隐藏合并到按钮1）──
	# 自己发动近战攻击时（ATTACK_BEFORE，早于选目标/双连 fork），读 _melee_buff 累加进
	# attack.record.extra_might。不清空——取消攻击保留；近战结算由 consume 消耗。
	var p074e1a := _ActionEffect.new()
	p074e1a.effect_id = &"pilot_073_effect_01_apply"
	p074e1a.display_name = "近战加成应用"
	p074e1a.description = "加成在我方近战攻击选目标前生效，近战攻击完全结算后消失（取消攻击不消耗）。"
	p074e1a.mode = _TC.MODE_LISTEN
	p074e1a.priority = 10
	p074e1a.listen_timing = _TC.ATTACK_BEFORE
	p074e1a.listen_action_type = &"attack"
	p074e1a.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
	])
	p074e1a.set_target_rules([{"rule": &"NO_TARGET"}])
	p074e1a.set_costs([])
	p074e1a.set_actions([
		{"type": &"APPLY_MELEE_MIGHT", "params": {
			"source_cid": "$binding_context.card_instance_id",
			"mech_id": "$binding_context.mech_id",
		}},
	])
	p074e1a.hide_button = true
	p074e1a.merge_desc_into_index = 1
	effects[p074e1a.effect_id] = p074e1a

	# ── pilot_073_effect_01_consume 近战结算消耗（LISTEN ATTACK_SETTLE，隐藏合并到按钮1）──
	# 近战攻击完全结算后清空待发威力——「本回合下次近战攻击」用完即消失。
	# 取消攻击时 SETTLE 不触发，加成保留；双连 fork 深拷贝 record 各带加成，任一枚结算清空不影响其他。
	var p074e1c := _ActionEffect.new()
	p074e1c.effect_id = &"pilot_073_effect_01_consume"
	p074e1c.display_name = "近战结算消耗"
	p074e1c.description = ""
	p074e1c.mode = _TC.MODE_LISTEN
	p074e1c.priority = 10
	p074e1c.listen_timing = _TC.ATTACK_SETTLE
	p074e1c.listen_action_type = &"attack"
	p074e1c.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
	])
	p074e1c.set_target_rules([{"rule": &"NO_TARGET"}])
	p074e1c.set_costs([])
	p074e1c.set_actions([
		{"type": &"CLEAR_MELEE_MIGHT", "params": {
			"source_cid": "$binding_context.card_instance_id",
			"mech_id": "$binding_context.mech_id",
		}},
	])
	p074e1c.hide_button = true
	p074e1c.merge_desc_into_index = 1
	effects[p074e1c.effect_id] = p074e1c

	# ── pilot_073_effect_01_turnend 回合后清空（LISTEN TURN_AFTER_END，隐藏合并到按钮1）──
	# 持有者自己回合结束后清空待发威力——"本回合"限定，未使用的加成不带到下回合。
	# 泰特自己的 buff 在泰特回合后清空；被授予机甲 A 的 buff 在 A 回合后清空（各自独立）。
	var p074e1t := _ActionEffect.new()
	p074e1t.effect_id = &"pilot_073_effect_01_turnend"
	p074e1t.display_name = "回合后清空"
	p074e1t.description = "待发的近战威力加成在本回合结束后消失（未使用不带到下回合）。"
	p074e1t.mode = _TC.MODE_LISTEN
	p074e1t.priority = 10
	p074e1t.listen_timing = _TC.TURN_AFTER_END
	p074e1t.listen_action_type = &"turn"
	p074e1t.set_conditions([
		{"op": &"IS_OWNER_TURN"},
	])
	p074e1t.set_target_rules([{"rule": &"NO_TARGET"}])
	p074e1t.set_costs([])
	p074e1t.set_actions([
		{"type": &"CLEAR_MELEE_MIGHT", "params": {
			"source_cid": "$binding_context.card_instance_id",
			"mech_id": "$binding_context.mech_id",
		}},
	])
	p074e1t.hide_button = true
	p074e1t.merge_desc_into_index = 1
	effects[p074e1t.effect_id] = p074e1t

	# ── pilot_073_effect_02 授予他机获效（DIRECT 按钮2）──
	var p074e2 := _ActionEffect.new()
	p074e2.effect_id = &"pilot_073_effect_02"
	p074e2.display_name = "授予近战弃牌加成"
	p074e2.description = "我方回合1次，选择1台其他机甲获得效果「近战弃1+3威力」，直到下个我方回合开始。"
	p074e2.mode = _TC.MODE_DIRECT
	p074e2.priority = 10
	p074e2.once_per_turn_key = &"pilot_073_effect_02"
	p074e2.once_per_turn_max = 1
	p074e2.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
	])
	p074e2.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	p074e2.set_costs([])
	p074e2.set_actions([
		{"type": &"GRANT_MELEE_MIGHT", "params": {
			"source_cid": "$binding_context.card_instance_id",
			"target_mech_id": "$payload.target_id",
		}},
	])
	effects[p074e2.effect_id] = p074e2

	# ── pilot_073_effect_02_expire 授予到期（LISTEN TURN_AFTER_START，隐藏合并到按钮2）──
	# 泰特自己下个回合开始后（TURN_AFTER_START）注销全部授予 + 清待发威力（EX 按钮消失）。
	var p074e2x := _ActionEffect.new()
	p074e2x.effect_id = &"pilot_073_effect_02_expire"
	p074e2x.display_name = "授予到期"
	p074e2x.description = "授予的效果在我方下个回合开始后到期（EX 按钮消失）。"
	p074e2x.mode = _TC.MODE_LISTEN
	p074e2x.priority = 10
	p074e2x.listen_timing = _TC.TURN_AFTER_START
	p074e2x.listen_action_type = &"turn"
	p074e2x.set_conditions([
		{"op": &"IS_OWNER_TURN"},
	])
	p074e2x.set_target_rules([{"rule": &"NO_TARGET"}])
	p074e2x.set_costs([])
	p074e2x.set_actions([
		{"type": &"EXPIRE_MELEE_MIGHT", "params": {
			"source_cid": "$binding_context.card_instance_id",
		}},
	])
	p074e2x.hide_button = true
	p074e2x.merge_desc_into_index = 2
	effects[p074e2x.effect_id] = p074e2x

	# ═══════════════════════════════════════════
	# pilot_072 肯尼斯（帝国 N，cost 4, attack_limit 1, action_card_limit 3）
	# ═══════════════════════════════════════════
	# 效果1（按钮1 DIRECT 主动）「弃1行动牌」：我方回合1次，可以弃置1张行动牌。
	#   弃置本身无直接奖励——目的是喂给效果2（每次弃牌后二选一）及其他弃牌类效果。
	#   条件：IS_OWNER_MAIN_PHASE + EFFECT_ONCE_PER_TURN_AVAILABLE(max=1) + HAS_ACTION_CARD_IN_HAND(count=1)
	#   （次数用满/空手按钮自动置灰）。动作链：CHOOSE_MANY_CARDS(选1行动牌,可取消)
	#     → MARK_EFFECT_ONCE_PER_TURN_USED(确认计次，每回合1次) → EXECUTE_DISCARD(弃选中，触发效果2)。
	#   取消选牌不计次数：CHOOSE_MANY_CARDS 取消会中止整个效果，MARK 不执行（德伦迪 042 显式计次同款）。
	# 效果2（按钮2 LISTEN 被动置灰+悬停）「弃置加成」：每次自己行动手牌（action_hand）被弃置后，
	#   可弹窗选择：抽1张行动牌 或 本回合下次攻击威力+2（可叠加），也可取消不发动；
	#   若本次弃置的牌中包含辅助牌则自动执行两个效果（不弹窗）。
	#   两个互斥 LISTEN 共享 DISCARD_AFTER 时点（条件互斥，只命中其一）：
	#     · effect_02（按钮2）：本次弃置含辅助牌时被 negate 拦截——仅在不含辅助牌时弹
	#       CHOOSE_ONE optional 二选一（抽1 / 下次攻击威力+2），取消则无事发生。
	#     · effect_02_auto（隐藏并入按钮2）：本次弃置含辅助牌（DISCARD_INCLUDED_OWNER_ACTION_CARD
	#       action_type=辅助）→ 自动 抽1 + 威力+2（两效果都执行，不弹窗）。
	#   待发威力用来源牌实例计数器（var_p075_next_might）累积，复用影刹 069"下次攻击加成"通用件
	#   （APPLY_NEXT_ATTACK_BONUS 应用 / SET_CARD_COUNTER 清零，零新增原子动作）：
	#     · 累积：INCREMENT_VARIABLE(source_card_instance_id, variable_name=p075_next_might, delta=2)
	#       → card.counters[var_p075_next_might]+=2（increment_variable 自带 var_ 前缀，回退 binding_context）。
	#     · _apply（LISTEN ATTACK_BEFORE，SELF_MECH_IS_ATTACKER，任意武器）：
	#       APPLY_NEXT_ATTACK_BONUS(might_key=var_p075_next_might) → attack.record.extra_might+。
	#     · _consume（LISTEN ATTACK_SETTLE，SELF_MECH_IS_ATTACKER）：SET_CARD_COUNTER 置0——
	#       攻击完全结算后清空（取消攻击保留；双连 fork 深拷贝 record 各带加成，任一枚结算清空不影响其他）。
	#     · _turnend（LISTEN TURN_AFTER_END，IS_OWNER_TURN）：SET_CARD_COUNTER 置0——"本回合"限定。
	#   通用：效果与效果id绑定不绑机师；威力累积走牌实例计数器（非静态 registry，换机师/跨测试无泄漏）；
	#   "弃置含辅助牌"判定复用 DISCARD_INCLUDED_OWNER_ACTION_CARD 的 action_type+negate 参数
	#   （ConditionChecker 通用扩展，任何"弃置含X类型牌"效果可复制复用）。

	# ── pilot_072_effect_01 弃1行动牌（DIRECT 按钮1）──
	var p075e1 := _ActionEffect.new()
	p075e1.effect_id = &"pilot_072_effect_01"
	p075e1.display_name = "弃1行动牌"
	p075e1.description = "我方回合1次，可以弃置1张行动牌。弃置后触发被动效果的选择（抽1张行动牌或本回合下次攻击威力+2）。"
	p075e1.mode = _TC.MODE_DIRECT
	p075e1.priority = 10
	p075e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {"once_per_turn_key": &"pilot_072_effect_01", "once_per_turn_max": 1}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	p075e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p075e1.set_costs([])
	p075e1.set_actions([
		# ① 选1张行动牌弃置（可取消；取消中止整个效果，不消耗次数）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"store_result_key": &"pilot_072_discard_ids",
			"discard_selected": false,
			"label": "选择要弃置的1张行动牌",
			"confirm_verb": "弃置",
			"cancel_label": "取消",
		}},
		# ② 确认即计次（显式 mark——效果挂起于子动作末尾自动 mark 可能不执行，德伦迪同款）
		{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_072_effect_01"}},
		# ③ 弃置选中行动牌（触发效果2：含辅助牌自动双效果 / 否则弹窗二选一）
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.pilot_072_discard_ids",
			"reason": &"pilot_072_discard",
		}},
	])
	effects[p075e1.effect_id] = p075e1

	# ── pilot_072_effect_02 弃置加成（LISTEN DISCARD_AFTER，按钮2被动置灰）──
	# 仅在不含辅助牌时弹窗（含辅助牌由 effect_02_auto 自动双效果，两个监听条件互斥）。
	var p075e2 := _ActionEffect.new()
	p075e2.effect_id = &"pilot_072_effect_02"
	p075e2.display_name = "弃置加成"
	p075e2.description = "每次弃置自己的行动牌后，可以选择抽1张行动牌或使本回合下一次攻击威力+2（可叠加），也可取消不发动。若弃置的牌中包含辅助牌，则两个效果都自动执行。"
	p075e2.mode = _TC.MODE_LISTEN
	p075e2.priority = 10
	p075e2.listen_timing = _TC.DISCARD_AFTER
	p075e2.listen_action_type = &"discard_card"
	p075e2.set_conditions([
		{"op": &"DISCARD_INCLUDED_OWNER_ACTION_CARD", "params": {"from_zone": &"action_hand"}},
		{"op": &"DISCARD_INCLUDED_OWNER_ACTION_CARD", "params": {"from_zone": &"action_hand", "action_type": &"辅助", "negate": true}},
	])
	p075e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p075e2.set_costs([])
	p075e2.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "title": "肯尼斯·弃置加成", "description": "选择要执行的加成", "options": [
			{
				"label": "抽1张行动牌",
				"actions": [
					{"type": &"EXECUTE_GAIN_CARD", "params": {
						"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
						"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
						"reason": &"pilot_072_draw",
					}},
				]
			},
			{
				"label": "本回合下次攻击威力+2",
				"actions": [
					{"type": &"INCREMENT_VARIABLE", "params": {
						"source_card_instance_id": "$binding_context.card_instance_id",
						"variable_name": &"p075_next_might", "delta": 2,
					}},
				]
			},
		]},
	}])
	effects[p075e2.effect_id] = p075e2

	# ── pilot_072_effect_02_auto 含辅助牌自动双效果（LISTEN DISCARD_AFTER，隐藏并入按钮2）──
	var p075e2a := _ActionEffect.new()
	p075e2a.effect_id = &"pilot_072_effect_02_auto"
	p075e2a.display_name = "辅助双效果"
	p075e2a.description = "弃置的行动牌中包含辅助牌时，自动执行抽1张行动牌 + 本回合下次攻击威力+2（不弹窗）。"
	p075e2a.mode = _TC.MODE_LISTEN
	p075e2a.priority = 10
	p075e2a.listen_timing = _TC.DISCARD_AFTER
	p075e2a.listen_action_type = &"discard_card"
	p075e2a.set_conditions([
		{"op": &"DISCARD_INCLUDED_OWNER_ACTION_CARD", "params": {"from_zone": &"action_hand", "action_type": &"辅助"}},
	])
	p075e2a.set_target_rules([{"rule": &"NO_TARGET"}])
	p075e2a.set_costs([])
	p075e2a.set_actions([
		{"type": &"EXECUTE_GAIN_CARD", "params": {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
			"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
			"reason": &"pilot_072_auto_draw",
		}},
		{"type": &"INCREMENT_VARIABLE", "params": {
			"source_card_instance_id": "$binding_context.card_instance_id",
			"variable_name": &"p075_next_might", "delta": 2,
		}},
	])
	p075e2a.hide_button = true
	p075e2a.merge_desc_into_index = 2
	effects[p075e2a.effect_id] = p075e2a

	# ── pilot_072_effect_02_apply 下次攻击威力应用（LISTEN ATTACK_BEFORE，隐藏并入按钮2）──
	# 自己发动攻击时（ATTACK_BEFORE，早于选目标/双连 fork），读牌计数器累加进
	# attack.record.extra_might（任意武器，近战/远程均生效）。不清空——取消攻击保留；
	# 攻击完全结算由 _consume 消耗，回合末由 _turnend 清空"本回合"待发。
	var p075e2b := _ActionEffect.new()
	p075e2b.effect_id = &"pilot_072_effect_02_apply"
	p075e2b.display_name = "攻击威力应用"
	p075e2b.description = "待发的攻击威力加成在本方下次攻击选目标前生效（任意武器），攻击完全结算后消失（取消攻击不消耗）。"
	p075e2b.mode = _TC.MODE_LISTEN
	p075e2b.priority = 10
	p075e2b.listen_timing = _TC.ATTACK_BEFORE
	p075e2b.listen_action_type = &"attack"
	p075e2b.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	p075e2b.set_target_rules([{"rule": &"NO_TARGET"}])
	p075e2b.set_costs([])
	p075e2b.set_actions([
		{"type": &"APPLY_NEXT_ATTACK_BONUS", "params": {
			"card_instance_id": "$binding_context.card_instance_id",
			"might_key": &"var_p075_next_might",
		}},
	])
	p075e2b.hide_button = true
	p075e2b.merge_desc_into_index = 2
	effects[p075e2b.effect_id] = p075e2b

	# ── pilot_072_effect_02_consume 攻击结算消耗（LISTEN ATTACK_SETTLE，隐藏并入按钮2）──
	# 攻击完全结算后清空待发威力——「本回合下次攻击」用完即消失。取消攻击时 SETTLE 不触发，
	# 加成保留；双连 fork 深拷贝 record 各带加成，任一枚结算清空不影响其他。
	var p075e2c := _ActionEffect.new()
	p075e2c.effect_id = &"pilot_072_effect_02_consume"
	p075e2c.display_name = "攻击结算消耗"
	p075e2c.description = ""
	p075e2c.mode = _TC.MODE_LISTEN
	p075e2c.priority = 10
	p075e2c.listen_timing = _TC.ATTACK_SETTLE
	p075e2c.listen_action_type = &"attack"
	p075e2c.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	p075e2c.set_target_rules([{"rule": &"NO_TARGET"}])
	p075e2c.set_costs([])
	p075e2c.set_actions([
		{"type": &"SET_CARD_COUNTER", "params": {"card_instance_id": "$binding_context.card_instance_id", "key": &"var_p075_next_might", "value": 0}},
	])
	p075e2c.hide_button = true
	p075e2c.merge_desc_into_index = 2
	effects[p075e2c.effect_id] = p075e2c

	# ── pilot_072_effect_02_turnend 回合后清空（LISTEN TURN_AFTER_END，隐藏并入按钮2）──
	# 持有者自己回合结束后清空待发威力——"本回合"限定，未使用的加成不带到下回合。
	var p075e2d := _ActionEffect.new()
	p075e2d.effect_id = &"pilot_072_effect_02_turnend"
	p075e2d.display_name = "回合后清空"
	p075e2d.description = "待发的攻击威力加成在本方回合结束后消失（本回合限定，未使用不带到下回合）。"
	p075e2d.mode = _TC.MODE_LISTEN
	p075e2d.priority = 10
	p075e2d.listen_timing = _TC.TURN_AFTER_END
	p075e2d.listen_action_type = &"turn"
	p075e2d.set_conditions([
		{"op": &"IS_OWNER_TURN"},
	])
	p075e2d.set_target_rules([{"rule": &"NO_TARGET"}])
	p075e2d.set_costs([])
	p075e2d.set_actions([
		{"type": &"SET_CARD_COUNTER", "params": {"card_instance_id": "$binding_context.card_instance_id", "key": &"var_p075_next_might", "value": 0}},
	])
	p075e2d.hide_button = true
	p075e2d.merge_desc_into_index = 2
	effects[p075e2d.effect_id] = p075e2d

	# ════════════════════════════════════════════════════════════
	# pilot_076 疾风（帝国 N，cost 3, attack_limit 1, action_card_limit 3）
	# ════════════════════════════════════════════════════════════
	# 1 个效果按钮（被动+被动合并，悬框显示 A/B 全文；参考里昂 pilot_006 两按钮范式）：
	#   A：我方发动的攻击被迎击牌响应时，消耗响应方3动力，该迎击牌结算后获得该牌。
	#   B：我方响应攻击牌发动的攻击时，消耗攻击方3动力，该攻击牌结算后获得该牌。
	# 必须是实体迎击牌（转化迎击不生效--ATTACK_SOURCE_ACTION_CARD_TYPE_IS(迎击) 读 def.action_type，
	#   转化牌原 def.action_type≠迎击故不触发；迪恩/布鲁克转化响应不生效）。
	# 消耗动力强制（被迎击响应即触发，不可放弃），在迎击牌真正效果执行前（USE_ACTION_BEFORE）；
	# 获牌自动强制（条件满足即 CLAIM 无弹窗），在该牌结算后（USE_ACTION_SETTLE，复用珀修斯
	#   pilot_007 CLAIM_RESOLVED_ATTACK_SOURCE_CARD 从弃牌堆回收）。clamp 到 0（MODIFY_MECH_POWER min_value:0）。
	# 通用件不绑机师：COUNTER_POWER_DRAIN_TARGET（TargetChecker，按 self 角色返回消耗对象 mech）+
	#   COUNTER_HAS_ATTACK_ACTION_ID / COUNTER_CLAIM_TRIGGERED（ConditionChecker，获牌A/B 分支判定）。
	var p076e1 := _ActionEffect.new()
	p076e1.effect_id = &"pilot_076_effect_01"
	p076e1.display_name = "疾风·获响应牌"
	p076e1.description = "我方发动的攻击被迎击牌响应时，消耗响应方3动力，该迎击牌结算后获得该牌。我方响应攻击牌发动的攻击时，消耗攻击方3动力，该攻击牌结算后获得该牌。"
	p076e1.mode = _TC.MODE_LISTEN
	p076e1.priority = 30
	p076e1.listen_timing = _TC.USE_ACTION_BEFORE
	p076e1.listen_action_type = &"use_action_card"
	p076e1.set_conditions([
		{"op": &"ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"ATTACK_SOURCE_ACTION_CARD_TYPE_IS", "params": {"card_type": &"迎击"}},
		{"op": &"COUNTER_HAS_ATTACK_ACTION_ID"},
	])
	p076e1.set_target_rules([{"rule": &"COUNTER_POWER_DRAIN_TARGET"}])
	p076e1.set_costs([])
	p076e1.set_actions([{
		"type": &"FOR_EACH_TARGET",
		"params": {
			"targets": "$selected_targets",
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"MODIFY_MECH_POWER", "params": {
					"mech_id": "$current_target.mech_id",
					"delta": -3,
					"value_scope": &"CURRENT",
					"method": &"decrease",
					"min_value": 0,
					"reason": &"pilot_076_power_drain",
				}}
			]
		}
	}])
	effects[p076e1.effect_id] = p076e1

	# ── pilot_076_effect_02 获响应牌（隐藏，LISTEN USE_ACTION_SETTLE，自动 CLAIM 无弹窗）──
	# 该迎击牌/攻击牌结算弃置后，从弃牌堆回收到疾风所属玩家手牌（复用珀修斯 CLAIM）。
	# COUNTER_CLAIM_TRIGGERED 内部按牌类型 + self 角色分支：获牌A（迎击牌+我方=被响应攻击的攻击方）
	# / 获牌B（攻击牌+我方=响应方；responded/response_card_id 由 attack_action._propagate_response_info_to_parent 回写）。
	# hide_button + merge_desc_into_index=1：描述合并到按钮1 hover。
	var p076e2 := _ActionEffect.new()
	p076e2.effect_id = &"pilot_076_effect_02"
	p076e2.display_name = "获响应牌"
	p076e2.description = "迎击牌/攻击牌结算后获得该牌（自动）。"
	p076e2.hide_button = true
	p076e2.merge_desc_into_index = 1
	p076e2.mode = _TC.MODE_LISTEN
	p076e2.priority = 30
	p076e2.listen_timing = _TC.USE_ACTION_SETTLE
	p076e2.listen_action_type = &"use_action_card"
	p076e2.set_conditions([{"op": &"COUNTER_CLAIM_TRIGGERED"}])
	p076e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p076e2.set_costs([])
	p076e2.set_actions([{"type": &"CLAIM_RESOLVED_ATTACK_SOURCE_CARD", "params": {}}])
	effects[p076e2.effect_id] = p076e2

	# ═══════════════════════════════════════════════════════════
	# pilot_081 汀兰（秩序 N，cost 2, attack_limit 1, action_card_limit 4）
	# 绿格光环（被动，按需派生，不存状态）：
	#   - 我方（持有者玩家）机甲移动时，全地图绿格（自然绿格 + 光环转化绿格）只耗1动力
	#     （只算移动，武器范围照常计算）。
	#   - 持有者所在格 + 6 邻居（红格除外）视为绿格（光环）：改变移动消耗 + 地图UI绿格。
	#   - 光环按持有者当前位置实时派生（MapService.resolve_move_cost_params 通用查询），持有者移动/
	#     死亡/卸下后自动跟随/消失，无需监听器/恢复/死亡清理。
	#   - 光环转化绿格上的机甲（含持有者自身）在其自己回合内1次，可点 RE 请求持有者回复
	#     2生命 + 获2金。请求弹给持有者玩家确认（可拒绝；拒绝仍消耗本回合次数，同琳RE）。
	# 唯一1个按钮（effect_01）：被动展示按钮（LISTEN，置灰+悬停说明）。RE 请求按钮在光环格
	#   上机甲的 equipment_panel 机师槽行动态渲染（仿琳 RE，见 equipment_panel）。
	# ── pilot_081_effect_01 绿格光环（LISTEN 显示按钮，不注册 listener：光环按需派生） ──
	var p081e1 := _ActionEffect.new()
	p081e1.effect_id = &"pilot_081_effect_01"
	p081e1.display_name = "绿格光环"
	p081e1.description = "绿格子对我方仅消耗1动力。我方所在的格子与周围相邻的所有格子（红格子除外）视为绿格子。处在该格子上的机甲在其回合内1次，可以请求我方使其回复2点生命，获得2金币。"
	p081e1.mode = _TC.MODE_LISTEN  # 被动展示按钮（置灰+悬停，不可点）
	p081e1.priority = 10
	p081e1.listen_timing = &""  # 不注册监听器：光环按位置实时派生，无时点触发
	# 通用移动消耗修正元数据：MapService.resolve_move_cost_params 扫描场上效果持有牌聚合。
	# 任何牌的效果声明同元数据即自动生效（不绑机师ID）。
	p081e1.move_cost_mod = {"green_cost": 1, "aura_shape": &"adjacent_6"}
	p081e1.set_conditions([])
	p081e1.set_target_rules([])
	p081e1.set_costs([])
	p081e1.set_actions([])
	effects[p081e1.effect_id] = p081e1

	# ── pilot_081_re_request：光环格上机甲点 RE 时触发的 DIRECT 效果（不注册 listener，
	#    由 app_root RE 点击经 _net_granted_effect -> effect_fire 触发）。
	#    动作1 PILOT_081_RE_MARK_USED 原子标记 RE 已用（点击即消耗，持有者拒绝也不刷新）；
	#    动作2 PILOT_081_RE_CONFIRM 弹确认窗给持有者（TimingEngine _execute_actions 特判）：
	#    持有者同意 -> 请求方回2血(来源=持有者) + 获2金；取消 -> 无事发生（RE 已消耗）。
	#    binding.mech_id = 请求方；binding.card_instance_id = 汀兰持有者 pilot 牌实例
	#    （equipment_panel 渲染时按覆盖的持有者逐个注入），据此 _prompt 定位持有者玩家弹窗。
	var p081re := _ActionEffect.new()
	p081re.effect_id = &"pilot_081_re_request"
	p081re.display_name = "请求回复"
	p081re.description = "请求汀兰回复2点生命、获得2金币。"
	p081re.mode = _TC.MODE_DIRECT
	p081re.priority = 10
	p081re.set_conditions([
		{"op": &"PILOT_081_RE_AVAILABLE"},
	])
	p081re.set_target_rules([{"rule": &"NO_TARGET"}])
	p081re.set_costs([])
	p081re.set_actions([
		{"type": &"PILOT_081_RE_MARK_USED", "params": {}},
		{"type": &"PILOT_081_RE_CONFIRM", "params": {}},
	])
	effects[p081re.effect_id] = p081re

	# ═══════════════════════════════════════════════════════════
	# pilot_083 瓦恩（秩序 N，cost 2, attack_limit 1, action_card_limit 4）
	# 2 个效果按钮（主动+被动各1，参考里昂两按钮范式）：
	#   effect_01 主动（按钮1）：每回合1次，将场上1把武器名称附加热能/光束、类型转变近战/远程、
	#     威力+3或范围+1（三横排每行可独立多选，取消不计次数；持续到下个我方回合结束）。
	#   effect_02 被动（按钮2，置灰+悬停）：3格内其他机甲可在其回合内请求我方对其武器使用上述效果
	#     （RE 按钮在请求方 equipment_panel 机师槽行动态渲染，仿琳/汀兰）。
	# 应用数据存武器牌 counters["pilot_083_apps"]（每次施加1条独立记录：owner_pid/applied_turn/
	# name_suffix/type_override/might/range），get_effective_weapon_stats 聚合（数值叠加、
	# 名称后缀累积、类型最新施加生效）。过期：瓦恩持有者玩家「下个我方回合结束」清
	# applied_turn < 当前回合号；ROUND_START 清理 owner 已无存活瓦恩的应用（孤儿，换下/机甲毁）。
	# ── pilot_083_effect_01 武器修改（DIRECT 主动，按钮1）──
	# 不设 once_per_turn_key（取消不计次数）：按钮条件用 EFFECT_ONCE_PER_TURN_AVAILABLE 查额度，
	# 额度在最终应用时才经 MARK_EFFECT_ONCE_PER_TURN_USED 标记（PILOT_083_MODIFY_FLOW 内）。
	var p083e1 := _ActionEffect.new()
	p083e1.effect_id = &"pilot_083_effect_01"
	p083e1.display_name = "瓦恩-武器修改"
	p083e1.description = "每回合1次，可以将场上1把武器名称加上热能或光束，类型转变为近战或远程，并使威力+3或范围+1（持续到下个我方回合结束）。"
	p083e1.mode = _TC.MODE_DIRECT
	p083e1.priority = 100
	p083e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_FIELD_WEAPON"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {"once_per_turn_key": &"pilot_083_effect_01", "once_per_turn_max": 1}},
	])
	p083e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p083e1.set_costs([])
	p083e1.set_actions([{"type": &"PILOT_083_MODIFY_FLOW", "params": {"mode": &"owner"}}])
	effects[p083e1.effect_id] = p083e1

	# ── pilot_083_effect_02 他方获效（LISTEN 被动展示按钮，按钮2，不注册 listener）──
	var p083e2 := _ActionEffect.new()
	p083e2.effect_id = &"pilot_083_effect_02"
	p083e2.display_name = "瓦恩-武器修改请求"
	p083e2.description = "在3格内的其他机甲可以在其回合内，请求我方对其持有的武器使用上述效果（每台机甲每回合1次）。"
	p083e2.mode = _TC.MODE_LISTEN  # 被动展示按钮（置灰+悬停，不可点）
	p083e2.priority = 10
	p083e2.listen_timing = &""  # 不注册监听器：RE 请求由 equipment_panel 动态渲染
	p083e2.set_conditions([])
	p083e2.set_target_rules([])
	p083e2.set_costs([])
	p083e2.set_actions([])
	effects[p083e2.effect_id] = p083e2

	# ── pilot_083_re_request：3格内机甲点 RE 时触发的 DIRECT 效果（隐藏，不建按钮）。
	#    绑定 pilot 牌实例 = 瓦恩持有者（弹窗给持有者）；payload.mech_id/source_mech_id = 请求方。
	#    动作1 PILOT_083_RE_MARK_USED 标记请求方本回合已用（点击即耗，持有者拒绝也不刷新）；
	#    动作2 PILOT_083_MODIFY_FLOW(mode=re) 弹持有者选请求方武器 -> 3横排选项 -> 应用
	#    （接受请求不消耗瓦恩效果1每回合1次，独立资源）。
	var p083re := _ActionEffect.new()
	p083re.effect_id = &"pilot_083_re_request"
	p083re.display_name = "请求武器修改"
	p083re.description = "请求瓦恩对我方持有的武器使用武器修改效果（每回合1次）。"
	p083re.mode = _TC.MODE_DIRECT
	p083re.priority = 10
	p083re.hide_button = true  # 不在瓦恩机师卡上建按钮（RE 按钮在请求方处渲染）
	p083re.set_conditions([
		{"op": &"PILOT_083_RE_AVAILABLE"},
	])
	p083re.set_target_rules([{"rule": &"NO_TARGET"}])
	p083re.set_costs([])
	p083re.set_actions([
		{"type": &"PILOT_083_RE_MARK_USED", "params": {}},
		{"type": &"PILOT_083_MODIFY_FLOW", "params": {"mode": &"re"}},
	])
	effects[p083re.effect_id] = p083re

	# ═══════════════════════════════════════════════════════════
	# pilot_074 维奥拉（帝国 N，cost 3, attack_limit 1, action_card_limit 4）
	# 在3格范围内的机甲（包括我方）发动攻击结算后，我方抽1张行动牌；之后每回合1次，可以弃置2张
	# 行动牌使该机甲再立即发动1次攻击。
	# 唯一1个按钮（effect_01）：被动（LISTEN，置灰+悬停说明）。触发走通用
	#   ATTACK_SETTLE_DRAW_REATTACK 状态机：抽牌强制（无次数限制）→ 每回合1次多选弃2张
	#   （取消不计次数）→ 给攻击方开凯威攻击窗口（攻击次数豁免，可中途取消）。
	# ── pilot_074_effect_01 攻击结算抽牌+弃2再攻（通用模块：范围内攻击结算→抽牌→弃X再攻） ──
	effects[&"pilot_074_effect_01"] = build_attack_settle_draw_discard_reattack_effect({
		"effect_id": &"pilot_074_effect_01",
		"display_name": "维奥拉-攻击结算抽牌再攻",
		"description": "在3格范围内的机甲（包括我方）发动攻击结算后，我方抽1张行动牌；之后每回合1次，可以弃置2张行动牌使该机甲再立即发动1次攻击。",
		"base_range": 3,
		"draw_count": 1,
		"discard_count": 2,
		"once_per_turn_key": &"pilot_074_effect_01",
		"priority": 10,
	})

	# ═══════════════════════════════════════════════════════════
	# pilot_075 芮贝卡（帝国 N，cost 3, attack_limit 1, action_card_limit 3）
	# 每回合2次，3格范围内的机甲（包括我方）受到伤害后，可以使其回复2生命并抽1张行动牌。
	# 唯一1个按钮（effect_01）：被动（LISTEN，置灰+悬停说明+剩余次数）；触发走通用
	#   INJURY_HEAL_DRAW 状态机（确认弹窗给持有者；确认发动才消耗1次，取消不消耗）。
	# ── pilot_075_effect_01 受伤回复（通用模块：范围内含自身受伤→确认→回血+抽牌） ──
	effects[&"pilot_075_effect_01"] = build_injury_heal_draw_effect({
		"effect_id": &"pilot_075_effect_01",
		"display_name": "芮贝卡-受伤回复",
		"description": "每回合2次，3格范围内的机甲（包括我方）受到伤害后，可以使其回复2生命并抽1张行动牌。",
		"base_range": 3,
		"heal_amount": 2,
		"draw_count": 1,
		"once_per_turn_key": &"pilot_075_effect_01",
		"once_per_turn_max": 2,
		"priority": 10,
	})

	# ═══════════════════════════════════════════════════════════
	# pilot_079 莉诺（秩序 N，cost 3, attack_limit 1, action_card_limit 3）
	# 每回合2次，可以用原价购买商店里的1张装备牌（独立于折扣状态，互不影响）。
	# 唯一1个按钮（effect_01）：被动（LISTEN，置灰+悬停说明）。触发走通用
	#   FACE_VALUE_BUY 模块：持有者回合开始把机师牌实例计数器 face_value_buy_uses
	#   重置为2（SET_CARD_COUNTER）；商店购买弹窗按剩余次数追加独立"原价"选项
	#   （ShopService.get_face_value_buy_uses 查询），购买时 consume 消耗1次。
	# ── pilot_079_effect_01 原价购买（通用模块：每回合N次原价购买商店装备）──
	effects[&"pilot_079_effect_01"] = build_face_value_buy_effect({
		"effect_id": &"pilot_079_effect_01",
		"display_name": "原价购买",
		"description": "每回合2次，可以用原价购买商店里的1张装备牌。",
		"per_turn": 2,
		"priority": 10,
	})

	# ═══════════════════════════════════════════════════════════
	# pilot_082 温斯顿（帝国 N，cost 3, attack_limit 0, action_card_limit 6）
	# 2个按钮（效果1 主动 + 效果2 主动，各自合并被动部分；悬停看完整说明）。
	# ═══════════════════════════════════════════════════════════
	# 效果1「交牌·联」：我方回合1次，可以将任意张行动牌交给3格范围内的1台其他机甲，
	#   令其下回合的攻击次数+1。被交出的行动牌打上"联"标签；该机甲使用带"联"标签的牌时，
	#   同时对我方（温斯顿）施加联合效果。
	#   - 目标：CHOOSE_OTHER_MECH + TARGET_IN_RANGE(3, hex_distance)（除自己外全部机甲，可取消不消耗次数）。
	#   - 选牌：CHOOSE_MANY_CARDS 整手行动牌多选，no_cancel=true（不可取消，必须选≥1张确认）。
	#   - 交牌：post_actions 里 TRANSFER_ACTION_CARDS + _tag_on_transfer 打"联"标签
	#     （_resolve_atomic_params 递归解析嵌套 dict，$binding_context.player_id 取温斯顿玩家）。
	#   - 下回合攻击+1：APPLY_NEXT_OWNER_TURN_ATTACK_BONUS（目标机甲下个我方回合开始并入攻击上限）。
	#   - 联标签生命周期：转移时打（owner=温斯顿）；牌离开持有者手牌/临时区（再转移/被偷/使用/弃置）
	#     即清除（见 GameActions.transfer_action_cards / steal_action_cards / discard_card_action 钩子）；
	#     温斯顿换下清其名下全部联标签（GameSetupService unset_pilot 钩子）。
	# ── pilot_082_effect_01 交牌·联（主动 DIRECT，每玩家回合1次）──
	var p082e1 := _ActionEffect.new()
	p082e1.effect_id = &"pilot_082_effect_01"
	p082e1.display_name = "交牌·联"
	p082e1.description = "我方回合1次，可以将任意张行动牌交给3格范围内1台其他机甲，令其下回合的攻击次数+1；该机甲使用这些牌时，同时对我方施加联合效果。"
	p082e1.mode = _TC.MODE_DIRECT
	p082e1.priority = 10
	p082e1.once_per_turn_key = &"pilot_082_effect_01"
	p082e1.once_per_turn_max = 1
	p082e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 3}},
	])
	p082e1.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 3, "metric": &"hex_distance"}},
	])
	p082e1.set_costs([])
	p082e1.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": -1,
			"label": "选择要交给目标的行动牌（将打上联标签）",
			"confirm_verb": "交给",
			"cancel_label": "取消",
			"discard_selected": false,  # 不弃置选中牌，交牌由 post_actions 的 TRANSFER_ACTION_CARDS 执行
			"no_cancel": true,
			"post_actions": [
				{"type": &"TRANSFER_ACTION_CARDS", "params": {
					"card_ids": "$choice.card_ids",
					"target_mech_id": "$payload.target_id",
					"from_player_id": "$binding_context.player_id",
					# 打"联"标签（owner=温斯顿玩家），供 USE_ACTION_AT 判定施加联合
					"_tag_on_transfer": {"lian_tag": {"owner": "$binding_context.player_id"}},
				}},
				{"type": &"APPLY_NEXT_OWNER_TURN_ATTACK_BONUS", "params": {
					"mech_id": "$payload.target_id",
					"stacks": 1,
				}},
			],
		},
	}])
	effects[p082e1.effect_id] = p082e1

	# ── pilot_082_unite_apply：联牌被使用 → 对温斯顿施加联合状态（隐藏 LISTEN）──
	# LISTEN USE_ACTION_AT（使用行动牌时时点，牌已进临时区但 owner/mech 保留）：
	# 打出的牌带"联"标签且 owner==温斯顿玩家（USED_CARD_HAS_TAG_FROM_ME）→ 对温斯顿施加 UNITE
	# 状态（unite=出牌者机甲）。之后该机甲攻击结算（ATTACK_SETTLE）时，温斯顿可联合攻击
	# （标准 UNITE 状态机制：unite_status_attack 监听 ATTACK_SETTLE + UNITE_ATTACK_OFFER）。
	# 每张联牌使用各触发一次（无次数限制）。
	var p082ue := _ActionEffect.new()
	p082ue.effect_id = &"pilot_082_unite_apply"
	p082ue.display_name = "联牌使用·联合"
	p082ue.hide_button = true  # 隐藏：监听器注册到 USE_ACTION_AT，不渲染按钮
	p082ue.merge_desc_into_index = 1  # 描述合并到按钮1（效果1交牌）hover
	p082ue.description = "带有联标签的行动牌被使用时，对我方施加联合状态。"
	p082ue.mode = _TC.MODE_LISTEN
	p082ue.priority = 10
	p082ue.listen_timing = _TC.USE_ACTION_AT
	p082ue.listen_action_type = &"use_action_card"
	p082ue.set_conditions([
		{"op": &"USED_CARD_HAS_TAG_FROM_ME", "tag": LIAN_TAG},
	])
	p082ue.set_target_rules([{"rule": &"NO_TARGET"}])
	p082ue.set_costs([])
	p082ue.set_actions([{
		"type": &"ADD_STATUS",
		"params": {
			"status_type": &"UNITE",
			"duration": &"UNTIL_TURN_END",
			# unite = 出牌者机甲（$payload.source_mech_id = use_action_card record 写入的出牌机甲）
			"unite": "$payload.source_mech_id",
			# target_id = 温斯顿机甲（联合状态的 Target，攻击结算后可联合攻击）
			"target_id": "$binding_context.mech_id",
		},
	}])
	effects[p082ue.effect_id] = p082ue

	# ── pilot_082_effect_02：攻击牌当作维修/推进（主动 DIRECT，无次数限制）──
	# 按钮条件：我方主阶段 + 手牌有攻击牌。点击后弹二选一：
	#   - 当作维修：维修无有效目标（REPAIR_HAS_VALID_TARGET）时置灰；
	#   - 当作推进：恒可用。
	# 选定后弹攻击牌单选（必须选1张，不可取消）→ 当作所选类型打出（共用琳 pilot_024 当作维修机制：
	# per_card_actions EXECUTE_USE_ACTION_CARD as_card_def_id + virtual_transform）。
	# 掩护不在主动按钮（掩护只能在掩护窗口被动使用，见 pilot_082_cover_extra）。
	var p082e2 := _ActionEffect.new()
	p082e2.effect_id = &"pilot_082_effect_02"
	p082e2.display_name = "当作维修/推进"
	p082e2.description = "我方可以把攻击牌当作掩护/维修/推进之一使用（主动可当作维修或推进，掩护在掩护窗口使用）。"
	p082e2.mode = _TC.MODE_DIRECT
	p082e2.priority = 10
	p082e2.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_TYPE_IN_HAND", "params": {"card_type": &"攻击"}},
	])
	p082e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p082e2.set_costs([])
	p082e2.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [
			{"label": "当作维修", "condition": [{"op": &"REPAIR_HAS_VALID_TARGET"}], "actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {
					"source": &"OWNER_ACTION_HAND",
					"card_type_filter": &"攻击",
					"min_count": 1,
					"max_count": 1,
					"label": "选择1张攻击牌当作维修使用",
					"confirm_verb": "当作维修",
					"cancel_label": "取消",
					"no_cancel": true,
					"discard_selected": false,
					"per_card_actions": [
						{"type": &"EXECUTE_USE_ACTION_CARD", "params": {
							"card_instance_id": "$chosen_card.card_instance_id",
							"as_card_def_id": &"action_013_维修",
							"consume_original_card": true,
							"virtual_transform": true,
						}},
					],
				}},
			]},
			{"label": "当作推进", "actions": [
				{"type": &"CHOOSE_MANY_CARDS", "params": {
					"source": &"OWNER_ACTION_HAND",
					"card_type_filter": &"攻击",
					"min_count": 1,
					"max_count": 1,
					"label": "选择1张攻击牌当作推进使用",
					"confirm_verb": "当作推进",
					"cancel_label": "取消",
					"no_cancel": true,
					"discard_selected": false,
					"per_card_actions": [
						{"type": &"EXECUTE_USE_ACTION_CARD", "params": {
							"card_instance_id": "$chosen_card.card_instance_id",
							"as_card_def_id": &"action_015_推进",
							"consume_original_card": true,
							"virtual_transform": true,
						}},
					],
				}},
			]},
		]},
	}])
	effects[p082e2.effect_id] = p082e2

	# ── pilot_082_cover_extra：温斯顿--掩护（被动，出现在掩护窗口复选框）──
	# 掩护窗口（cover_effect1 CHOOSE_MANY_CARDS collect_cover_window_extras）扫描窗口拥有玩家
	# 注册在 COVER_WINDOW_EXTRA 的监听效果，条件满足（手牌有攻击牌）时以「温斯顿--掩护」复选框展示。
	# 选中后：攻击牌多选窗（可多选/全选，可取消=不转化）→ 逐张当作掩护打出
	# （as_use_action_card + as_card_def_id=掩护 + virtual_transform，走标准批量转化链）。
	var p082cover := _ActionEffect.new()
	p082cover.effect_id = &"pilot_082_cover_extra"
	p082cover.display_name = "温斯顿--掩护"
	p082cover.hide_button = true  # 隐藏：仅作为掩护窗口复选框出现，不渲染按钮
	p082cover.merge_desc_into_index = 2  # 描述合并到按钮2（效果2）hover
	p082cover.description = "可以选择任意张攻击牌当作掩护使用（逐张执行转化效果）。"
	p082cover.mode = _TC.MODE_LISTEN
	p082cover.priority = 10
	p082cover.listen_timing = _TC.COVER_WINDOW_EXTRA
	p082cover.set_conditions([
		{"op": &"HAS_ACTION_CARD_TYPE_IN_HAND", "params": {"card_type": &"攻击"}},
	])
	p082cover.set_target_rules([{"rule": &"NO_TARGET"}])
	p082cover.set_costs([])
	p082cover.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"card_type_filter": &"攻击",
			"min_count": 1,
			"max_count": -1,
			"label": "选择当作掩护使用的攻击牌（可多选）",
			"confirm_verb": "当作掩护",
			"cancel_label": "取消",
			"as_use_action_card": true,
			"as_card_def_id": &"action_016_掩护",
		},
	}])
	effects[p082cover.effect_id] = p082cover

	# ── pilot_082_thrust_extra：温斯顿--推进（被动，出现在推进窗口复选框）──
	# 推进窗口（thrust_effect2 CHOOSE_MANY_CARDS collect_thrust_window_extras）扫描窗口拥有玩家
	# 注册在 THRUST_WINDOW_EXTRA 的监听效果，条件满足（手牌有攻击牌）时以「温斯顿--推进」复选框展示。
	# 选中后：攻击牌多选窗（可多选/全选，可取消=不转化）→ 逐张当作推进打出。
	var p082thrust := _ActionEffect.new()
	p082thrust.effect_id = &"pilot_082_thrust_extra"
	p082thrust.display_name = "温斯顿--推进"
	p082thrust.hide_button = true  # 隐藏：仅作为推进窗口复选框出现，不渲染按钮
	p082thrust.merge_desc_into_index = 2  # 描述合并到按钮2（效果2）hover
	p082thrust.description = "可以选择任意张攻击牌当作推进使用（逐张执行转化效果）。"
	p082thrust.mode = _TC.MODE_LISTEN
	p082thrust.priority = 10
	p082thrust.listen_timing = _TC.THRUST_WINDOW_EXTRA
	p082thrust.set_conditions([
		{"op": &"HAS_ACTION_CARD_TYPE_IN_HAND", "params": {"card_type": &"攻击"}},
	])
	p082thrust.set_target_rules([{"rule": &"NO_TARGET"}])
	p082thrust.set_costs([])
	p082thrust.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"card_type_filter": &"攻击",
			"min_count": 1,
			"max_count": -1,
			"label": "选择当作推进使用的攻击牌（可多选）",
			"confirm_verb": "当作推进",
			"cancel_label": "取消",
			"as_use_action_card": true,
			"as_card_def_id": &"action_015_推进",
		},
	}])
	effects[p082thrust.effect_id] = p082thrust

	# ═══════════════════════════════════════════════════════════
	# pilot_084 莎菲雅（混乱 N，cost 3, attack_limit 1, action_card_limit 4）
	# 2 个效果按钮（主动+被动各1，参考里昂两按钮范式，悬停看完整说明）：
	#   effect_01 主动（按钮1）「当作联合」：我方回合2次，可以将2张行动牌当作联合使用，
	#     之后抽2张行动牌。
	#   effect_02 被动（按钮2，置灰+悬停）「联合获金」：其他机甲因联合的效果使用攻击牌后，
	#     我方获得2金币。
	# effect_01 走通用"当作X"链（丹 pilot_068 / 布彻尔 pilot_064 同款）：
	#   CHOOSE_MANY_CARDS(必选恰好2张，取消=中止不计次数) -> MOVE_ACTION_CARDS_TO_TEMP_ZONE ->
	#   MARK_EFFECT_ONCE_PER_TURN_USED(确认后计次) -> PLAY_AS_NAMED(as_card_def_id=联合，
	#   attack_is_active=false 辅助不耗攻击数) -> EXECUTE_GAIN_CARD(抽2行动牌) ->
	#   DISCARD_TEMP_ZONE_CARDS。联合效果内部选目标取消（用户确认过）：额度已计次、燃料牌已在
	#   临时区 -> 照常消耗+仍抽2（用户确认的设计）。
	# effect_02 监听 USE_ACTION_AT（使用行动牌时时点），3 条件全满足才触发：
	#   USE_ACTION_IS_UNITE_ORIGIN（联合攻击 offer 出的牌，TimingEngine unite_attack_offer resume
	#   向 use_action_card record 注入 _unite_attack_origin）+ USED_CARD_TYPE_IS 攻击 +
	#   USE_ACTION_BY_OTHER_MECH（出牌机甲≠莎菲雅持有机甲，不管是不是我方阵营）。
	#   动作 GAIN_GOLD(2, player_id=$binding_context.player_id)。

	# ── pilot_084_effect_01 当作联合（DIRECT 主动，按钮1）──
	var p084e1 := _ActionEffect.new()
	p084e1.effect_id = &"pilot_084_effect_01"
	p084e1.display_name = "莎菲雅-当作联合"
	p084e1.description = "我方回合2次，可以将2张行动牌当作联合使用，之后抽2张行动牌。"
	p084e1.mode = _TC.MODE_DIRECT
	p084e1.priority = 10
	p084e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EFFECT_ONCE_PER_TURN_AVAILABLE", "params": {
			"once_per_turn_key": &"pilot_084_effect_01",
			"once_per_turn_max": 2,
		}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 2}},
	])
	p084e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p084e1.set_costs([])
	p084e1.set_actions([
		# ① 弹我方行动牌复选框：必须选恰好2张确认（取消=中止，不计次数）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 2,
			"max_count": 2,
			"store_result_key": &"pilot_084_fuel_ids",
			"label": "选择当作联合使用的2张行动牌",
			"confirm_verb": "当作联合",
			"cancel_label": "取消",
		}},
		# ② 选中的2张牌移入临时区
		{"type": &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", "params": {"card_ids": "$runtime.pilot_084_fuel_ids"}},
		# ③ 确认后消耗本次回合额度（取消选择则不计次）
		{"type": &"MARK_EFFECT_ONCE_PER_TURN_USED", "params": {"once_per_turn_key": &"pilot_084_effect_01"}},
		# ④ 当作联合牌打出（虚拟转化，辅助不消耗攻击次数；联合内部选目标取消不影响后续）
		{"type": &"PLAY_AS_NAMED", "params": {"as_card_def_id": &"action_018_联合", "attack_is_active": false}},
		# ⑤ 之后抽2张行动牌
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 2, "player_id": "$binding_context.player_id", "reason": &"pilot_084_draw_after_unite"}},
		# ⑥ 链末：临时区牌入弃牌堆
		{"type": &"DISCARD_TEMP_ZONE_CARDS", "params": {"card_ids": "$payload.temp_zone_card_ids"}},
	])
	effects[p084e1.effect_id] = p084e1

	# ── pilot_084_effect_02 联合获金（LISTEN 被动，按钮2）──
	var p084e2 := _ActionEffect.new()
	p084e2.effect_id = &"pilot_084_effect_02"
	p084e2.display_name = "莎菲雅-联合获金"
	p084e2.description = "其他机甲因联合的效果使用攻击牌后，我方获得2金币。"
	p084e2.mode = _TC.MODE_LISTEN
	p084e2.priority = 10
	p084e2.listen_timing = _TC.USE_ACTION_AT
	p084e2.listen_action_type = &"use_action_card"
	p084e2.set_conditions([
		{"op": &"USE_ACTION_IS_UNITE_ORIGIN"},
		{"op": &"USED_CARD_TYPE_IS", "card_type": &"攻击"},
		{"op": &"USE_ACTION_BY_OTHER_MECH"},
	])
	p084e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p084e2.set_costs([])
	p084e2.set_actions([
		{"type": &"GAIN_GOLD", "params": {"amount": 2, "player_id": "$binding_context.player_id", "reason": &"pilot_084_unite_attack_gold"}},
	])
	effects[p084e2.effect_id] = p084e2

	# ── pilot_088 莽克（混乱 N，cost 4, attack_limit 1, action_card_limit 3）──
	# ── pilot_088_effect_01 弃装获金（LISTEN 被动，按钮1）──
	# 持续被动：监听所有弃置牌动作的结算时点（DISCARD_SETTLE）。本次弃置中每张「原先正面设置在
	# 机甲上」的装备牌：原先属于我方机甲 → 我方立即获得4金币；其他机甲 → 我方立即获得3金币。
	# 每张都发、按类型累加后一次发放（PILOT_085_DISCARD_GOLD handler 统计）。
	# 覆盖被新牌顶掉(equipment_replace)、损坏弃置(damage_durability)、量产装卖出(sell_set_equipment)等；
	# 手上未设置(from_zone=equipment_hand)/备用区背面(face_down)不计（条件 DISCARD_CONTAINS_FACEUP_EQUIPMENT 已过滤）。
	var p085e1 := _ActionEffect.new()
	p085e1.effect_id = &"pilot_088_effect_01"
	p085e1.display_name = "莽克-装弃获金"
	p085e1.description = "机甲上正面设置的装备牌弃置时，可立即获得4金币；场上其他机甲上正面设置的装备牌弃置时，可立即获得3金币。"
	p085e1.mode = _TC.MODE_LISTEN
	p085e1.priority = 80
	p085e1.listen_timing = _TC.DISCARD_SETTLE
	p085e1.listen_action_type = &"discard_card"
	p085e1.set_conditions([
		{"op": &"DISCARD_CONTAINS_FACEUP_EQUIPMENT"},
	])
	p085e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p085e1.set_costs([])
	p085e1.set_actions([
		{"type": &"PILOT_085_DISCARD_GOLD", "params": {}},
	])
	effects[p085e1.effect_id] = p085e1

	# ── pilot_085 獠鼠（混乱 N，cost 5, attack_limit 2, action_card_limit 1）──
	# ── pilot_085_effect_01 攻击骰子分支（LISTEN 被动，按钮1）──
	# 「指定目标发动攻击时，可以投掷1个骰子：1：我方机甲设置2损伤；2~3：我方抽2张行动牌；
	#  4~5：弃置目标2张行动牌；6：对目标施加锁定效果。」
	# 触发：我方机甲指定目标攻击的 ATTACK_PRE（priority 40；此时 payload.target_ids 已就绪）。
	# 流程（PILOT_086_DICE_BRANCH handler，TimingEngine._pilot_085_dice_branch）：
	#   ① 弹「发动/取消」二选一确认窗（choose_one_effect）；取消=无事发生不耗资源。
	#   ② 确认后掷 1d6（context.synced_randi_range(1,6)，测试可经 payload.pilot_085_forced_dice 注入）。
	#   ③ 按点数分支出 _seq 动作链串行执行：
	#      1  → EXECUTE_DAMAGE_CHANGE 我方机甲+2损伤（逐点弹放置UI，executor=我方）；
	#      2~3→ EXECUTE_GAIN_CARD 我方抽2张行动牌（走 GAIN_CARD 时点）；
	#      4~5→ FOR_EACH_TARGET($payload.target_ids)：EXECUTE_DISCARD from_target count=2 choose
	#            face_up=false auto_discard_all_if_covered（目标行动牌≤2 直接弃不弹窗，
	#            >2 逐目标按目标顺序弹未知选框，多目标迭代通用）；
	#      6  → FOR_EACH_TARGET($payload.target_ids)：APPLY_OR_CHECK_LOCKED 预判样式（duration=1,
	#            skip_clear_on_hit=false：本攻击命中即清除，与预判一致）。
	var p086e1 := _ActionEffect.new()
	p086e1.effect_id = &"pilot_085_effect_01"
	p086e1.display_name = "獠鼠-骰子攻击"
	p086e1.description = "指定目标发动攻击时，可以投掷1个骰子：1：我方机甲设置2损伤；2~3：我方抽2张行动牌；4~5：弃置目标2张行动牌；6：对目标施加锁定效果。"
	p086e1.mode = _TC.MODE_LISTEN
	p086e1.priority = 40
	p086e1.listen_timing = _TC.ATTACK_PRE
	p086e1.listen_action_type = &"attack"
	p086e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	p086e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p086e1.set_costs([])
	p086e1.set_actions([
		{"type": &"PILOT_086_DICE_BRANCH", "params": {}},
	])
	effects[p086e1.effect_id] = p086e1

	# ═══════════════════════════════════════════════════════════
	# pilot_086 塔妮拉（混乱 N，cost 3, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════════════════════
	# 效果1（DIRECT 按钮1，每我方回合2次）「交牌获2金」：
	#   选3格内1台其他机甲（可取消=不扣次数）→ 从我方手牌选1张行动牌（不可取消，必须确定）
	#   → 转移该牌至目标机甲（自动打"交"标签，owner=塔妮拉玩家，GameActions 转移挂钩）。
	#   之后我方获得2金币。
	#   仿 pilot_082 模式：target_rule CHOOSE_OTHER_MECH + TARGET_IN_RANGE:3（弹选机甲框）
	#   + CHOOSE_MANY_CARDS source:OWNER_ACTION_HAND min:1 max:1 no_cancel:true（弹选牌框）
	#   + post_actions TRANSFER_ACTION_CARDS card_ids:choice.card_ids + GAIN_GOLD amount:2。
	# 效果2（LISTEN 按钮2 置灰+悬停，不注册 listener）：其他机甲使用带"交"标签的行动牌（仅当
	#   标签 owner=塔妮拉玩家）后，使用方先抽1张行动牌 + 塔妮拉后抽1张行动牌（两张分开发两个
	#   gain_card 串行，确保各自走 GAIN_CARD 时点）。
	#   实际触发在 discard_card_action._step_transfer_to_pile 挂钩：牌 from_zone==temp_zone
	#   且带"交"标签 → pilot_086_trigger_jiao_draw(context, card) 双方抽1，标签入弃牌堆即消失。
	#   手牌直接弃置（from_zone==action_hand）不触发抽牌，仅清"交"标签。
	# 标签生命周期：转移/偷牌挂钩打"交"标签；牌入弃牌堆（无论使用/直接弃置）标签消失；
	#   塔妮拉离场清其名下全部"交"标签（见 GameSetupService._on_pilot_unset）。
	var p087e1 := _ActionEffect.new()
	p087e1.effect_id = &"pilot_086_effect_01"
	p087e1.display_name = "交牌获2金"
	p087e1.description = "我方回合2次，可以将1张行动牌交给1台3格范围内的其他机甲，之后我方获得2金币。"
	p087e1.mode = _TC.MODE_DIRECT
	p087e1.priority = 10
	p087e1.once_per_turn_key = &"pilot_086_effect_01"
	p087e1.once_per_turn_max = 2
	p087e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 3}},
	])
	p087e1.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 3, "metric": &"hex_distance"}},
	])
	p087e1.set_costs([])
	p087e1.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 1,
			"max_count": 1,
			"label": "选择1张要交给目标的行动牌（将打上交标签）",
			"confirm_verb": "交给",
			"cancel_label": "取消",
			"discard_selected": false,  # 不弃置选中牌，交牌由 post_actions 的 TRANSFER_ACTION_CARDS 执行
			"no_cancel": true,
			"post_actions": [
				{"type": &"TRANSFER_ACTION_CARDS", "params": {
					"card_ids": "$choice.card_ids",
					"target_mech_id": "$payload.target_id",
					"from_player_id": "$binding_context.player_id",
					# 打"交"标签（owner=塔妮拉玩家），供 USE_ACTION_SETTLE 挂钩判定双方各抽1
					"_tag_on_transfer": {"jiao_tag": {"owner": "$binding_context.player_id"}},
				}},
				{"type": &"GAIN_GOLD", "params": {
					"amount": 2,
					"player_id": "$binding_context.player_id",
					"reason": &"pilot_086_effect_01",
				}},
			],
		},
	}])
	effects[p087e1.effect_id] = p087e1

	# 效果2：被动 LISTEN（仅作按钮2展示，actions 为空，实际逻辑在 discard 挂钩）。
	# 不注册 listener（避免 USE_ACTION_SETTLE 监听器与 discard 挂钩双触发）。
	var p087e2 := _ActionEffect.new()
	p087e2.effect_id = &"pilot_086_effect_02"
	p087e2.display_name = "他用交牌各抽1"
	p087e2.description = "其他机甲使用从我方处获得的行动牌后，该机甲和我方各抽1张行动牌。"
	p087e2.mode = _TC.MODE_LISTEN
	p087e2.priority = 10
	p087e2.set_conditions([])
	p087e2.set_target_rules([])
	p087e2.set_costs([])
	p087e2.set_actions([])
	effects[p087e2.effect_id] = p087e2

	# ═══════════════════════════════════════════
	# pilot_053 李（秩序 R，cost 5, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1「抽设事件牌」（DIRECT 按钮1，每我方回合1次）：抽事件牌堆顶1张直接设置到
	#   我方机甲事件区域（事件牌无手牌区，「抽」即设置；完整流程含顶旧牌+注册+instant结算）。
	#   按钮置灰：非我方主阶段 / 事件牌堆耗尽（EVENT_DECK_HAS_CARDS）。
	#   计次：链首 MARK 显式标记（EXECUTE_SET_EVENT_CARD 产生挂起子动作致
	#   _execute_effect 末尾自动 mark 不执行，p057e2 同款），1429 行预检拦截二次点击。
	var p051e1 := _ActionEffect.new()
	p051e1.effect_id = &"pilot_053_effect_01"
	p051e1.display_name = "抽设事件牌"
	p051e1.description = "我方回合1次，可以抽1张事件牌设置到区域上。"
	p051e1.mode = _TC.MODE_DIRECT
	p051e1.priority = 10
	p051e1.once_per_turn_key = &"pilot_053_effect_01"
	p051e1.once_per_turn_max = 1
	p051e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"EVENT_DECK_HAS_CARDS", "params": {"minimum": 1}},
	])
	p051e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p051e1.set_costs([])
	p051e1.set_actions([
		{
			# 无输入环节（点击即发动），链首显式计次防自动 mark 缺失
			"type": &"MARK_EFFECT_ONCE_PER_TURN_USED",
			"params": {"once_per_turn_key": &"pilot_053_effect_01"},
		},
		{
			# event_card_id 省略 = 抽事件牌堆顶1张（set_event_card._step_resolve_card）
			"type": &"EXECUTE_SET_EVENT_CARD",
			"params": {"mech_id": "$binding_context.mech_id"},
		},
	])
	effects[p051e1.effect_id] = p051e1

	# 效果2「拦截事件牌设置」（LISTEN 按钮2 置灰+悬停说明，本局1次）：场上任何一方
	#   设置事件牌时（EVENT_SET_BEFORE：新牌已入区、效果未注册）弹三选一：
	#   弃置（该牌效果不生效）/ 转设到我方区域（完整流程，顶掉我方旧事件牌）/ 取消不计次。
	#   转设内层会再 fire EVENT_SET_BEFORE，但 once_per_game 已标记 -> 1434 行自动跳过，无递归。
	#   OWNER_IS_HUMAN：AI 拥有者不触发（条件先于 handler，不影响本局次数）。
	var p051e2 := _ActionEffect.new()
	p051e2.effect_id = &"pilot_053_effect_02"
	p051e2.display_name = "拦截事件牌设置"
	p051e2.description = "本局游戏1次，当1张事件牌被设置时，可以立即取消其效果，并弃置或设置到我方区域。"
	p051e2.mode = _TC.MODE_LISTEN
	p051e2.priority = 10
	p051e2.listen_timing = _TC.EVENT_SET_BEFORE
	p051e2.once_per_game_key = &"pilot_053_effect_02"
	p051e2.set_conditions([
		{"op": &"OWNER_IS_HUMAN"},
	])
	p051e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p051e2.set_costs([])
	p051e2.set_actions([
		{
			# 拦截弹窗+中止旗+摘牌+分支 _seq 全在 TimingEngine._handle_pilot_053_intercept
			#（挂起模块，resume phase=pilot_053_intercept）
			"type": &"PILOT_051_INTERCEPT_EVENT_SET",
			"params": {},
		},
	])
	effects[p051e2.effect_id] = p051e2

	# ═══════════════════════════════════════════
	# pilot_080 墨尘（秩序 N，cost 2, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════
	# 效果1「相邻标记交互」（DIRECT 按钮，我方回合无次数限制）：选相邻6格中1个带标记的格
	#   （事件/金币/陷阱任意类型，MAP_MARKER_IN_RANGE ANY + CHOOSE_MAP_CELL markers 源，
	#   可取消）-> 弹二选一（移去 / 移至该格后标记再生效2次，可取消）。
	#   移至 = 免费基础移动（free_move 不耗动力）-> 标记第1次生效 -> 完全结束（含事件牌
	#   设置+instant结算/陷阱连锁）-> 第2次独立生效。全链 _seq 串行（TimingEngine
	#   _handle_pilot_080_marker_interact，resume phase=pilot_080_choice）。
	var p080e1 := _ActionEffect.new()
	p080e1.effect_id = &"pilot_080_effect_01"
	p080e1.display_name = "相邻标记交互"
	p080e1.description = "我方回合中，对于相邻格子上存在的地图标记，可以移除该标记或立即移至该格子上，之后该标记生效后使该效果再生效1次。"
	p080e1.mode = _TC.MODE_DIRECT
	p080e1.priority = 10
	p080e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"MAP_MARKER_IN_RANGE", "params": {"marker_type": &"ANY", "range": 1, "min_distance": 1, "count": 1}},
	])
	p080e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p080e1.set_costs([])
	p080e1.set_actions([
		{
			# ① 选相邻6格中带标记的格（不含自身格；可取消=中止）
			"type": &"CHOOSE_MAP_CELL",
			"params": {
				"cells": {"markers": {"type": &"ANY", "range": 1, "min_distance": 1}},
				"store_result_key": &"pilot_080_cell_id",
				"label": "选择相邻格上的标记（事件/金币/陷阱）",
			}
		},
		{
			# ② 移去/移至 弹窗 + _seq 分支链
			"type": &"PILOT_080_MARKER_INTERACT",
			"params": {"cell_key": &"pilot_080_cell_id"},
		},
	])
	effects[p080e1.effect_id] = p080e1

	# ════════════════════════════════════════════════════════════
	# 通用「窗口宿主」效果（机师绑定被动，任意机师 JSON effect_ids 引用即生效）
	# ════════════════════════════════════════════════════════════
	# 问题：掩护/推进多选窗由 cover_effect1 / thrust_effect2（真实牌手牌监听器）驱动，
	# 玩家没有真实掩护/推进牌时窗口不弹，机师的「当作掩护/推进」附加选项
	# （COVER_WINDOW_EXTRA / THRUST_WINDOW_EXTRA 虚拟时点）无处展示（洛尔恩 pilot_063
	# 转化掩护实机 bug：无掩护牌时窗口永不出现）。
	# 本组宿主效果由机师 effect_ids 引用、GameSetupService._register_pilot_effects 注册为
	# permanent listener：ATTACK_PRE / USE_ACTION_AT 触发同款 CHOOSE_MANY_CARDS
	# （collect_*_window_extras=true）——无真实牌也弹窗（仅 extra 选项）；有真实牌时与
	# cover_effect1/thrust_effect2 共存，_choose_many_shown 去重守卫保证每动作只弹一次、
	# 两者窗口内容一致。条件与真实牌监听器完全相同（TARGET_IN_COVER_RANGE /
	# USED_COUNTER_CARD），行为一致。

	# ── cover_window_host：掩护窗口宿主（同 cover_effect1 的触发条件与窗口参数）──
	var cover_host := _ActionEffect.new()
	cover_host.effect_id = &"cover_window_host"
	cover_host.display_name = "掩护窗口"
	cover_host.description = "我方无掩护牌时也弹掩护窗口（使「当作掩护」类附加选项可展示）。"
	cover_host.mode = _TC.MODE_LISTEN
	cover_host.priority = 10
	cover_host.listen_timing = _TC.ATTACK_PRE
	cover_host.listen_action_type = &"attack"
	cover_host.hide_button = true
	cover_host.set_conditions([{"op": &"TARGET_IN_COVER_RANGE"}])
	cover_host.set_target_rules([{"rule": &"NO_TARGET"}])
	cover_host.set_costs([])
	cover_host.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"card_def_id": &"action_016_掩护",
			"label": "选择要使用的掩护",
			"per_card_suffix": "·威力-5",
			"confirm_verb": "使用",
			"cancel_label": "不使用掩护",
			"as_use_action_card": true,
			"collect_cover_window_extras": true,
		},
	}])
	effects[cover_host.effect_id] = cover_host

	# ── thrust_window_host：推进窗口宿主（同 thrust_effect2 的触发条件与窗口参数）──
	var thrust_host := _ActionEffect.new()
	thrust_host.effect_id = &"thrust_window_host"
	thrust_host.display_name = "推进窗口"
	thrust_host.description = "我方无推进牌时也弹推进窗口（使「当作推进」类附加选项可展示）。"
	thrust_host.mode = _TC.MODE_LISTEN
	thrust_host.priority = 10
	thrust_host.listen_timing = _TC.USE_ACTION_AT
	thrust_host.listen_action_type = &"use_action_card"
	thrust_host.hide_button = true
	thrust_host.set_conditions([{"op": &"USED_COUNTER_CARD"}])
	thrust_host.set_target_rules([{"rule": &"NO_TARGET"}])
	thrust_host.set_costs([])
	thrust_host.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"card_def_id": &"action_015_推进",
			"label": "选择要一起打出的推进（可多选）",
			"per_card_suffix": "·动力+4",
			"confirm_verb": "打出",
			"cancel_label": "不打出推进",
			"as_use_action_card": true,
			"collect_thrust_window_extras": true,
		},
	}])
	effects[thrust_host.effect_id] = thrust_host

	return effects


# ════════════════════════════════════════════════════════════
# "燃"标签模块（攻击命中抽行动牌并打标签，本回合不占行动牌上限）
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 效果定义：build_attack_hit_draw_and_tag_effect(params) 参数化构建（改 params 复用）。
#   - 打标签：EXECUTE_GAIN_CARD 的 _tag_on_draw 参数（gain_card_action 通用支持）。
#   - 手牌上限/弃超限排除：list_ran_tagged_hand（app_root/TurnService 用）。
#   - 回合结束清除：clear_all_ran_tags_for_player（TurnService 第7.1步）。
# 用法：list_ran_tagged_hand 返回玩家手牌中带"燃"标签的牌 id 数组（这些牌不计入行动牌上限、
#   弃超上限选框排除）；card_has_ran_tag 供 UI 显示"(燃)"后缀。
const RAN_TAG := &"ran_tag"


## 手牌是否带"燃"标签（任意 owner；燃标签只由拥有者打在自己手牌上，任意判定即可）。
static func card_has_ran_tag(card) -> bool:
	if card == null or not card.has_method(&"has_tag"):
		return false
	return card.has_tag(RAN_TAG)


## 返回玩家手牌中带"燃"标签的牌 id 数组（用于超限计算排除 + 弃牌选框排除）。
static func list_ran_tagged_hand(game_state, player_id: StringName) -> Array:
	if game_state == null or player_id == &"":
		return []
	var player = game_state.players.get(player_id)
	if player == null:
		return []
	var out: Array = []
	for cid: StringName in player.action_hand:
		var c = game_state.get_card(cid)
		if card_has_ran_tag(c):
			out.append(cid)
	return out


## 清指定玩家全部"燃"标签（回合结束后：剩余燃牌恢复正常计上限）。
static func clear_all_ran_tags_for_player(game_state, player_id: StringName) -> void:
	if game_state == null or player_id == &"":
		return
	for card in game_state.cards.values():
		if card == null or not card.has_method(&"remove_tag"):
			continue
		if card.has_tag(RAN_TAG, player_id):
			card.remove_tag(RAN_TAG, player_id)


## 通用"攻击命中抽行动牌并打标签"效果构建器（LISTEN ATTACK_AFTER）。
## params：effect_id / display_name / description / count(抽牌数) / tag_name(标签) /
##         reason(抽牌原因，默认 effect_draw_and_tag) / priority(默认10)。
## 复用：复制构建调用 + 改 params 即可；同一时点同一条件，任何"我方攻击命中→抽N张并打X标签"效果通用。
static func build_attack_hit_draw_and_tag_effect(params: Dictionary) -> _ActionEffect:
	var e := _ActionEffect.new()
	e.effect_id = params.get("effect_id", &"")
	e.display_name = params.get("display_name", "命中抽牌")
	e.description = params.get("description", "")
	e.mode = _TC.MODE_LISTEN
	e.priority = int(params.get("priority", 10))
	e.listen_timing = _TC.ATTACK_AFTER
	e.listen_action_type = &"attack"
	e.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"PAYLOAD_ATTACK_HIT"},
	])
	e.set_target_rules([{"rule": &"NO_TARGET"}])
	e.set_costs([])
	e.set_actions([{
		"type": &"EXECUTE_GAIN_CARD",
		"params": {
			"from_zone": &"action_deck",
			"card_kind": &"action",
			"count": int(params.get("count", 1)),
			"player_id": "$binding_context.player_id",
			"reason": params.get("reason", &"effect_draw_and_tag"),
			# 抽牌后自动给抽到的行动牌打标签（owner 空=抽牌玩家，即效果拥有者）
			"_tag_on_draw": {"tag_name": params.get("tag_name", RAN_TAG)},
		},
	}])
	return e


# ════════════════════════════════════════════════════════════
# 通用「回合结束后选机甲抽N张后其弃置X张」模块
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 效果定义：build_turn_end_choose_mech_draw_discard_effect(params) 参数化构建（改 params 复用）。
#   - 目标选择：复用通用 CHOOSE_MANY_MECHS（范围内机甲单选，含自己，可取消=不发动）。
#   - 抽牌：EXECUTE_GAIN_CARD mech_ids 走被选机甲反查目标玩家（gain_card_action 通用支持）。
#   - 弃牌：EXECUTE_DISCARD executor/player_id="$current_target.owner_player_id"（ActionService
#     _resolve_atomic_value 通用表达式，取当前目标机甲所属玩家）+ choose/no_cancel（被选玩家必弃，
#     空手自动跳过），由 discard_card_action 通用逻辑处理。
# 用法：任何「我方回合结束后→选1台范围内机甲→其抽N张行动牌→其弃X张」效果直接复制构建调用+改 params。
static func build_turn_end_choose_mech_draw_discard_effect(params: Dictionary) -> _ActionEffect:
	var e := _ActionEffect.new()
	e.effect_id = params.get("effect_id", &"")
	e.display_name = params.get("display_name", "回合后选机甲抽牌弃牌")
	e.description = params.get("description", "")
	e.mode = _TC.MODE_LISTEN
	e.priority = int(params.get("priority", 10))
	e.listen_timing = _TC.TURN_AFTER_END
	e.listen_action_type = &"turn"
	var e_range: int = int(params.get("range", 3))
	e.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		# include_self=true：自己距离0恒在范围内，条件等价「范围内存在存活机甲」（自己必在），
		# 效果恒可用、玩家可随时取消不发动（弥雅"可以选择…可以取消"）。
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": e_range, "include_self": true}},
	])
	e.set_target_rules([{"rule": &"NO_TARGET"}])
	e.set_costs([])
	var e_draw_count: int = int(params.get("draw_count", 3))
	var e_discard_count: int = int(params.get("discard_count", 1))
	var e_store_key: String = String(params.get("store_result_key", "%s_selected_mechs" % String(e.effect_id)))
	var e_reason_prefix: StringName = StringName(params.get("reason_prefix", String(e.effect_id)))
	e.set_actions([
		# ① 选1台 range 格内机甲（含自己，可取消；取消=效果不发动，不抽不弃）
		{"type": &"CHOOSE_MANY_MECHS", "params": {
			"range": e_range,
			"min_count": 1,
			"max_count": 1,
			"include_self": true,
			"store_result_key": e_store_key,
			"label": "选择1台%d格范围内的机甲（含我方）" % e_range,
		}},
		# ② 逐目标（仅1台）：抽 draw_count 张行动牌 → 该机甲玩家必弃 discard_count 张
		{"type": &"FOR_EACH_TARGET", "params": {
			"targets": "$runtime.%s" % e_store_key,
			"execution_mode": &"SERIAL",
			"preserve_order": true,
			"current_target_variable": &"current_target",
			"actions": [
				{"type": &"EXECUTE_GAIN_CARD", "params": {
					"from_zone": &"action_deck",
					"card_kind": &"action",
					"count": e_draw_count,
					"mech_ids": ["$current_target.mech_id"],
					"reason": StringName("%s_draw" % String(e_reason_prefix)),
				}},
				{"type": &"EXECUTE_DISCARD", "params": {
					"player_id": "$current_target.owner_player_id",
					"executor": "$current_target.owner_player_id",
					"count": e_discard_count,
					"choose": true,
					"no_cancel": true,
					"face_up": true,
					"reason": StringName("%s_discard" % String(e_reason_prefix)),
				}},
			],
		}},
	])
	return e


# ════════════════════════════════════════════════════════════
# 通用「使用指定类型行动牌回复动力」模块
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 效果定义：build_use_action_type_restore_power_effect(params) 参数化构建（改 params 复用）。
#   - 触发：LISTEN USE_ACTION_AT（使用行动牌时时点，先于迎击牌等自身效果执行）。
#   - 条件：USED_CARD_OWNER_IS_SELF（持有者本人出牌）+ USED_CARD_TYPE_IS（按实体牌 action_type
#     判定攻击/迎击/辅助；转化牌按实体牌类型判定）→ 强制自动发动、无选择。
#   - 动作：RESTORE_POWER（method=restore，回复动力不超上限）。
#   - 每回合1次：once_per_turn_key（各分支独立 key，各自每回合1次）。
# 用法：任何「使用X型行动牌时回复Y动力（每回合1次）」效果直接复制构建调用+改 params。
static func build_use_action_type_restore_power_effect(params: Dictionary) -> _ActionEffect:
	var e := _ActionEffect.new()
	e.effect_id = params.get("effect_id", &"")
	e.display_name = params.get("display_name", "使用行动牌回复动力")
	e.description = params.get("description", "")
	e.mode = _TC.MODE_LISTEN
	e.priority = int(params.get("priority", 10))
	e.listen_timing = _TC.USE_ACTION_AT
	e.listen_action_type = &"use_action_card"
	e.once_per_turn_key = params.get("once_per_turn_key", &"")
	e.once_per_turn_max = 1
	e.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_CARD_TYPE_IS", "card_type": params.get("card_type", &"")},
	])
	e.set_target_rules([{"rule": &"NO_TARGET"}])
	e.set_costs([])
	e.set_actions([{
		"type": &"RESTORE_POWER",
		"params": {
			"mech_id": "$binding_context.mech_id",
			"amount": int(params.get("power_amount", 0)),
			"method": &"restore",
		},
	}])
	return e


# ════════════════════════════════════════════════════════════
# 通用「弃X张行动牌抽Y张(高级)装备并背面置备用区」模块
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 效果定义：build_discard_draw_advanced_equip_set_reserve_effect(params) 参数化构建（改 params 复用）。
#   - 选弃：CHOOSE_MANY_CARDS(OWNER_ACTION_HAND, min/max=discard_count, 可取消) → 确认即
#     mark once_per_turn（取消不消耗；DIRECT 效果无分支时由 CHOOSE_MANY_CARDS 确认路径标记）。
#   - 弃牌：EXECUTE_DISCARD($runtime.<store_key>)。
#   - 抽牌：EXECUTE_GAIN_CARD(from_zone, count, _tag_on_draw 打标签, _draw_result_sink 回写
#     父 record["<sink_key>"]——parent_action_id 省略时由 gain_card_action 回退到子动作直接
#     父动作，即抽牌子动作的父=效果动作）。
#   - 背面置备用区：新 act_type CHOOSE_RESERVE_SLOT_AND_SET_EQUIP（TimingEngine
#     _continue_seq_effect_actions 分发 + resume_pending_effect phase=choose_reserve_slot_and_set），
#     复用 hidden_reserve_slot 弹窗（全部机甲 RESERVE 槽，仅显示"（空）/（有牌）"不翻牌，
#     强制选择不可取消），确认后 EXECUTE_SET_EQUIP 效果驱动设置（RESERVE 槽自动 face_down，
#     绕过主动设置/卖出拦截）。
# 用法：任何「弃X张行动牌→抽Y张装备→背面置备用区（可带禁标签）」效果直接复制构建调用+改 params。
static func build_discard_draw_advanced_equip_set_reserve_effect(params: Dictionary) -> _ActionEffect:
	var e := _ActionEffect.new()
	e.effect_id = params.get("effect_id", &"")
	e.display_name = params.get("display_name", "弃牌抽装备置备用区")
	e.description = params.get("description", "")
	e.mode = _TC.MODE_DIRECT
	e.priority = int(params.get("priority", 10))
	e.once_per_turn_key = params.get("once_per_turn_key", e.effect_id)
	e.once_per_turn_max = int(params.get("once_per_turn_max", 1))
	var f_discard: int = int(params.get("discard_count", 2))
	var f_draw: int = int(params.get("draw_count", 1))
	var f_store_key: String = String(params.get("store_result_key", "%s_discard_ids" % String(e.effect_id)))
	var f_sink_key: StringName = StringName(params.get("sink_key", "%s_drawn" % String(e.effect_id)))
	var f_reason: StringName = StringName(params.get("reason_prefix", String(e.effect_id)))
	e.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": f_discard}},
	])
	e.set_target_rules([{"rule": &"NO_TARGET"}])
	e.set_costs([])
	e.set_actions([
		# ① 选弃 discard_count 张行动牌（可取消；取消不消耗次数，确认即 mark once_per_turn）
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": f_discard,
			"max_count": f_discard,
			"store_result_key": StringName(f_store_key),
			"discard_selected": false,
			"label": "选择要弃置的%d张行动牌" % f_discard,
			"confirm_verb": "弃置",
			"cancel_label": "取消",
		}},
		# ② 弃置选中行动牌
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.%s" % f_store_key,
			"reason": StringName("%s_discard" % String(f_reason)),
		}},
		# ③ 抽 draw_count 张（高级）装备牌并打标签（抽到的牌 id 回写父 record[f_sink_key]）
		{"type": &"EXECUTE_GAIN_CARD", "params": {
			"from_zone": params.get("from_zone", &"advanced_equipment_deck"),
			"card_kind": &"equipment",
			"count": f_draw,
			"player_id": "$binding_context.player_id",
			"reason": StringName("%s_draw" % String(f_reason)),
			"_tag_on_draw": {"tag_name": params.get("tag_name", &"")},
			"_draw_result_sink": {"key": f_sink_key},
		}},
		# ④ 弹备用区选择（全部机甲 RESERVE 槽，仅显示占位不翻牌），确认后效果驱动背面设置
		{"type": &"CHOOSE_RESERVE_SLOT_AND_SET_EQUIP", "params": {
			"sink_key": f_sink_key,
			"reason": StringName("%s_set" % String(f_reason)),
		}},
	])
	return e


# ════════════════════════════════════════════════════════════
# "近战弃牌威力"模块（泰特 pilot_073：弃1行动牌使本回合下次近战攻击威力+3，可叠加；
# 效果2把整个效果1授予其他机甲直到下个我方回合开始，EX 按钮）
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 待发威力按 (来源牌实例, 机甲) 分离存储 _melee_buff[source_cid][mech_id]：
#     泰特自己与他机各自独立、互不串扰；同一来源多目标互不影响。
#   - 效果定义：build_melee_discard_might_effect(params) 参数化构建（effect_id/once_per_turn_max/
#     delta/文案），改 params 复制复用。
#   - 生命周期：ATTACK_BEFORE 近战攻击应用（APPLY_MELEE_MIGHT）→ ATTACK_SETTLE 近战结算消耗
#     （CLEAR_MELEE_MIGHT，取消攻击保留）→ 持有者回合结束后 TURN_AFTER_END 清空"本回合"待发。
#   - 授予：grant_melee_might_to_mech 向目标机甲注册 DIRECT（虚拟时点）+ 隐藏 LISTEN，binding
#     打 granted=true（equipment_panel EX 按钮通用检测）；expire_melee_might_grants 到期注销
#     （来源下个回合开始后 TURN_AFTER_START，EX 消失）。

## 待发近战威力计数：{ source_card_instance: { mech_id: stacks } }
static var _melee_buff: Dictionary = {}
## 近战授予登记：{ source_card_instance: { target_mech_id: true } }（到期注销遍历用）
static var _melee_grant_mechs: Dictionary = {}


## 累积近战弃牌威力（+delta 可叠加）。
static func add_melee_buff(source_cid: StringName, mech_id: StringName, delta: int) -> void:
	if source_cid == &"" or mech_id == &"" or delta == 0:
		return
	if not _melee_buff.has(source_cid):
		_melee_buff[source_cid] = {}
	var holder: Dictionary = _melee_buff[source_cid]
	holder[mech_id] = int(holder.get(mech_id, 0)) + delta
	SLog.log_raw("[MELEE_BUFF] 累积+%d 威力（source=%s mech=%s）当前=%d" % [delta, String(source_cid), String(mech_id), int(holder[mech_id])])


## 读某来源×机甲当前待发近战威力。
static func get_melee_buff(source_cid: StringName, mech_id: StringName) -> int:
	if source_cid == &"" or mech_id == &"" or not _melee_buff.has(source_cid):
		return 0
	return int(_melee_buff[source_cid].get(mech_id, 0))


## 清空某来源×机甲的待发近战威力（近战结算消耗 / 回合后清空 / 到期清空）。
static func clear_melee_buff(source_cid: StringName, mech_id: StringName) -> void:
	if source_cid == &"" or mech_id == &"" or not _melee_buff.has(source_cid):
		return
	var holder: Dictionary = _melee_buff[source_cid]
	holder.erase(mech_id)
	if holder.is_empty():
		_melee_buff.erase(source_cid)


## 清空某来源全部近战威力状态（换机师 unset_pilot 时调用，注销授予 + 清待发）。
static func clear_melee_might_for_source(source_cid: StringName) -> void:
	if source_cid == &"":
		return
	_melee_buff.erase(source_cid)
	_melee_grant_mechs.erase(source_cid)


## 授予目标机甲近战弃牌威力效果：注册 DIRECT 按钮（虚拟时点 effect_id，EX 按钮可点）+
## 隐藏 LISTEN（ATTACK_BEFORE 应用 / ATTACK_SETTLE 消耗 / TURN_AFTER_END 清空）。
## binding_context.mech_id=目标机甲、card_instance_id=来源牌实例、granted=true。
## 记录到 _melee_grant_mechs 供到期/换机师注销。
static func grant_melee_might_to_mech(context, source_cid: StringName, target_mech_id: StringName) -> void:
	if context == null or context.timing_engine == null or context.game_state == null:
		return
	if source_cid == &"" or target_mech_id == &"":
		return
	var target_mech = context.game_state.mechs.get(target_mech_id)
	if target_mech == null:
		return
	var all_effects: Dictionary = build_pilot_effects()
	var e1_direct = all_effects.get(&"pilot_073_effect_01")
	var e1_apply = all_effects.get(&"pilot_073_effect_01_apply")
	var e1_consume = all_effects.get(&"pilot_073_effect_01_consume")
	var e1_turnend = all_effects.get(&"pilot_073_effect_01_turnend")
	if e1_direct == null or e1_apply == null or e1_consume == null or e1_turnend == null:
		return
	var bind: Dictionary = {
		"card_instance_id": source_cid,
		"mech_id": target_mech_id,
		"player_id": target_mech.owner_player_id,
		"slot_id": &"pilot",
		"granted": true,
	}
	context.timing_engine.register_permanent_listener(&"pilot_073_effect_01", e1_direct, bind)
	context.timing_engine.register_permanent_listener(_TC.ATTACK_BEFORE, e1_apply, bind)
	context.timing_engine.register_permanent_listener(_TC.ATTACK_SETTLE, e1_consume, bind)
	context.timing_engine.register_permanent_listener(_TC.TURN_AFTER_END, e1_turnend, bind)
	if not _melee_grant_mechs.has(source_cid):
		_melee_grant_mechs[source_cid] = {}
	_melee_grant_mechs[source_cid][target_mech_id] = true
	SLog.log_raw("[MELEE_BUFF] 授予近战弃牌威力 source=%s target=%s" % [String(source_cid), String(target_mech_id)])


## 到期注销某来源全部近战授予（来源下个回合开始后 TURN_AFTER_START 调用）。
## 逐目标定向注销（保留来源自身监听器）+ 清待发威力（EX 按钮消失）。
static func expire_melee_might_grants(context, source_cid: StringName) -> void:
	if source_cid == &"" or not _melee_grant_mechs.has(source_cid):
		return
	if context == null or context.timing_engine == null:
		return
	var targets: Dictionary = _melee_grant_mechs[source_cid]
	for mid: StringName in targets:
		clear_melee_buff(source_cid, mid)
		context.timing_engine.unregister_permanent_listeners_for_card_and_mech(source_cid, mid)
		SLog.log_raw("[MELEE_BUFF] 到期注销近战授予 source=%s target=%s" % [String(source_cid), String(mid)])
	_melee_grant_mechs.erase(source_cid)


# ════════════════════════════════════════════════════════════
# "禁"标签模块（弃X行动牌抽Y装备背面置备用区等：装备牌期间不能主动设置/卖出）
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 打标签：EXECUTE_GAIN_CARD 的 _tag_on_draw 参数（gain_card_action 通用支持，owner 空=抽牌玩家）。
#   - 拦截：equip_forbid_tagged(card) 供 CardSetService.set_equipment/sell_equipment 主动设置/卖出
#     拦截 + app_root/equipment_panel/sell_equipment_panel UI 置灰与"(禁)"后缀。
#   - 清除：clear_all_equip_forbid（TurnService ROUND_START：下轮开始统一恢复可主动设置/卖出，
#     清全场所有玩家名下标签，替代旧的按玩家 TURN_AFTER_START 清除）。
# 注意：只拦截【主动】设置与卖出（CardSetService/UI 按钮），效果驱动设置（EXECUTE_SET_EQUIP、
# 约书亚/霍恩等）不受影响——标签挂在牌上，效果路径不经 CardSetService。
const EQUIP_FORBID_TAG := &"equip_forbid_tag"


## 装备牌是否带"禁"标签（任意 owner；禁标签只由打标签玩家名下产生，任意判定即可）。
## 供 CardSetService 主动设置/卖出拦截 + UI 显示"(禁)"后缀置灰。
static func equip_forbid_tagged(card) -> bool:
	if card == null or not card.has_method(&"has_tag"):
		return false
	return card.has_tag(EQUIP_FORBID_TAG)


## 清指定玩家全部"禁"标签（该玩家下个回合开始后 TURN_AFTER_START 调用，恢复可主动设置/卖出）。
static func clear_all_equip_forbid_for_player(game_state, player_id: StringName) -> void:
	if game_state == null or player_id == &"":
		return
	for card in game_state.cards.values():
		if card == null or not card.has_method(&"remove_tag"):
			continue
		if card.has_tag(EQUIP_FORBID_TAG, player_id):
			card.remove_tag(EQUIP_FORBID_TAG, player_id)


## 清全场全部"禁"标签（新轮次开始 ROUND_START 调用：任何上一轮放置的禁标签到期恢复）。
## 权威规则「直到下个我方回合开始后」在轮次语义下=下轮开始统一到期（ROUND_START 全局一次，
## 位次1玩家回合开始前触发），故清除所有玩家名下标签，而非只清当前开始回合的玩家。
static func clear_all_equip_forbid(game_state) -> void:
	if game_state == null:
		return
	for card in game_state.cards.values():
		if card == null or not card.has_method(&"remove_tag"):
			continue
		card.remove_tag(EQUIP_FORBID_TAG)


# ════════════════════════════════════════════════════════════
# 通用「下次攻击范围加成」注册表（影刹 pilot_069 等）
# ════════════════════════════════════════════════════════════
# 攻击前置检查（app_root._get_weapon_range）须把"待用下次攻击范围加成"计入武器射程，否则范围+1
# 只在实际攻击时（ATTACK_BEFORE APPLY_NEXT_ATTACK_BONUS）生效，攻击牌预检仍按基础射程判
# "无可用目标"（影刹 4 射程武器打 5 格敌人，攻击牌却显示不可用）。
# 通用做法：ACCUMULATE_NEXT_ATTACK_BONUS 执行时把 range_key 注册进本表；_get_weapon_range 遍历
# 机甲名下所有牌、累加已注册 range_key 计数器的当前值（条件未满足=0，自动正确）。任何带
# range_key 的该 act_type 效果自动生效，不绑定具体机师/装备。
static var _next_attack_range_keys: Dictionary = {}


## 注册一个「下次攻击范围加成」计数器键（ACCUMULATE_NEXT_ATTACK_BONUS 执行时调用，去重）。
static func register_next_attack_range_key(key: String) -> void:
	if key != "":
		_next_attack_range_keys[key] = true


## 取机甲名下待用的下次攻击范围加成总和（攻击前置检查用）：遍历属于该机甲的牌实例，
## 累加所有已注册 range_key 计数器的当前值。
static func get_pending_next_attack_range(game_state, mech) -> int:
	if game_state == null or mech == null or _next_attack_range_keys.is_empty():
		return 0
	var total: int = 0
	for card in game_state.cards.values():
		if card == null or String(card.mech_id) != String(mech.mech_id):
			continue
		if not "counters" in card or card.counters.is_empty():
			continue
		for key: String in _next_attack_range_keys:
			total += int(card.counters.get(key, 0))
	return total


# ════════════════════════════════════════════════════════════
# 通用攻击窗口机制（铠威 pilot_039「被响应→结算后抽1再攻」等效果复用）
# ════════════════════════════════════════════════════════════
# 状态存 GameState（PvP 锁步各端确定性一致，无需网络同步）：
#   gs.attack_window              非空即激活：{"owner_player_id", "owner_mech_id"}
#   gs.attack_window_queue        待处理触发（攻击已完成、等待提示）：[{player_id, mech_id}]
#   gs.attack_window_pending_prompt 当前待玩家确认：{"player_id", "mech_id"}
# 流程：
#   ATTACK_SETTLE（PILOT_039_SCHEDULE_AFTER_ATTACK）→ run_after_action_completed(攻击action_id)
#   → 攻击完成 → pilot_039_after_attack_completed：入队 + process_next
#   → process_next：窗口未激活则弹确认 → 确认后抽1（gain_card）+ 打开窗口
#   → 窗口发动攻击：attack_action 关闭窗口 → 该攻击若被响应再次触发（递归）。
# ════════════════════════════════════════════════════════════

## 攻击窗口状态（空字典=未激活）。
static func attack_window_state(gs) -> Dictionary:
	if gs == null:
		return {}
	var w = gs.attack_window
	if not (w is Dictionary):
		return {}
	return w


## 攻击窗口是否激活。
static func attack_window_active(gs) -> bool:
	return not attack_window_state(gs).is_empty()


## 打开攻击窗口（铠威确认抽牌后）。owner_mech_id 指定窗口归属机甲。
static func attack_window_open(gs, owner_player_id: StringName, owner_mech_id: StringName) -> void:
	if gs == null or owner_mech_id == &"":
		return
	gs.attack_window = {
		"owner_player_id": owner_player_id,
		"owner_mech_id": owner_mech_id,
	}


## 攻击窗口是否激活且归属指定机甲（窗口攻击数豁免/UI 门控/关窗共用）。
static func attack_window_active_for_mech(gs, mech_id: StringName) -> bool:
	if mech_id == &"":
		return false
	var w = attack_window_state(gs)
	if w.is_empty():
		return false
	return String(w.get("owner_mech_id", &"")) == String(mech_id)


## 攻击窗口是否激活且归属指定玩家。
static func attack_window_active_for_player(gs, player_id: StringName) -> bool:
	if player_id == &"":
		return false
	var w = attack_window_state(gs)
	if w.is_empty():
		return false
	return String(w.get("owner_player_id", &"")) == String(player_id)


## 关闭攻击窗口并处理队列中的下一个触发（窗口关闭是串行处理新触发的时机）。
## owner_mech_id 非空时校验窗口仍归属该机甲（防御陈旧窗口覆盖新窗口）。
static func attack_window_close(context, owner_mech_id: StringName = &"") -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	var w = attack_window_state(gs)
	if w.is_empty():
		return
	if owner_mech_id != &"" and String(w.get("owner_mech_id", &"")) != String(owner_mech_id):
		return
	gs.attack_window = {}
	# 攻击完成/取消后处理排队中的后续触发（双连/递归多触发串行）
	attack_window_process_next(context)


## 登记一个待处理触发（攻击已结算、等待攻击动作完成后提示）。铠威 ATTACK_SETTLE 后调用。
static func attack_window_enqueue(gs, player_id: StringName, mech_id: StringName) -> void:
	if gs == null or mech_id == &"":
		return
	gs.attack_window_queue.append({"player_id": player_id, "mech_id": mech_id})


## 铠威触发回调：攻击动作完成后（action_completed，call_deferred）双端确定性执行——
## 登记触发入队 + 尝试处理（窗口未激活则弹确认，激活则留队列等窗口关闭）。
## 由 run_after_action_completed(action_id, Callable(...)) 挂到攻击动作上。
static func pilot_039_after_attack_completed(context, player_id: StringName, mech_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	attack_window_enqueue(context.game_state, player_id, mech_id)
	attack_window_process_next(context)


## 处理队列下一个触发：窗口未激活才弹确认（窗口激活时新触发保留队列，等窗口关闭后续跑）。
## AI 玩家暂不处理（先 PvP/PvP3 人类）：AI 触发的直接丢弃，避免卡死。
## 弹确认：设置 pending_prompt 后经 action_ui_bridge.request_ui_popup 通知 UI（PvP 双端
## 都执行本函数，handler 按 owner 过滤只弹窗口归属玩家；PvE 只弹人类方）。此举同时解决
## 攻击动作完成时点的弹窗时序——钩子在 action_completed 后 deferred 执行，UI 刷新已跑完，
## 直接 emit 保证确认框立即弹出。
static func attack_window_process_next(context) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	if attack_window_active(gs):
		return
	if gs.attack_window_queue.is_empty():
		return
	# 已有待确认触发：不覆盖（双连/递归多触发串行，等当前确认后再处理下一个）
	var existing: Dictionary = gs.attack_window_pending_prompt
	if not existing.is_empty():
		return
	var entry: Dictionary = gs.attack_window_queue.pop_front()
	var pid: StringName = entry.get("player_id", &"")
	var mid: StringName = entry.get("mech_id", &"")
	if pid == &"" or mid == &"":
		attack_window_process_next(context)
		return
	var player = gs.players.get(pid)
	if player == null or not player.is_human:
		# AI 玩家触发：先不处理（用户指定忽略 AI 逻辑），直接丢弃防卡死
		attack_window_process_next(context)
		return
	gs.attack_window_pending_prompt = {"player_id": pid, "mech_id": mid}
	if context.action_ui_bridge != null:
		context.action_ui_bridge.request_ui_popup.emit(&"attack_window_confirm", {"player_id": pid, "mech_id": mid})


## 铠威/攻击窗口触发确认（app_root 弹窗后经 attack_window_confirm op 双端执行）：
## 确认=抽1张行动牌+打开窗口；取消=无事发生。之后处理队列下一触发（若有）。
## 抽牌走 gain_card 动作（发 GAIN_CARD 时点，统一抽牌口径）。
static func attack_window_confirm(context, player_id: StringName, mech_id: StringName, accept: bool) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	var pending: Dictionary = gs.attack_window_pending_prompt
	if not (pending is Dictionary) or pending.is_empty():
		return
	# 陈旧确认守卫：确认的 mech/player 与待确认触发一致才处理
	if String(pending.get("player_id", &"")) != String(player_id) or String(pending.get("mech_id", &"")) != String(mech_id):
		return
	gs.attack_window_pending_prompt = {}
	if accept and context.action_service != null:
		# gain_card 只有 from_zone 命中 action_deck/equipment_deck 才会真正抽牌（见 gain_card_action
		# _step_transfer_card）；不传 from_zone 只 tag 不抽。走抽牌统一口径（GAIN_CARD 时点）。
		var gain: Dictionary = context.action_service.execute(&"gain_card", {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
			"player_id": player_id, "reason": &"pilot_039_after_attack",
		})
		attack_window_open(gs, player_id, mech_id)
	attack_window_process_next(context)


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


# ════════════════════════════════════════════════════════════
# pilot_020 肯德：弃置数 X 存取（按 turn_number 每回合自动重置）
# ════════════════════════════════════════════════════════════
# X = 本回合肯德行动牌从手牌区(action_hand)进弃牌堆的数量。存 pilot_card.counters
# ["pilot_020_x_<turn>"]，新回合新 key=0（与 pilot_010 每回合重置一致）。
# 护甲/动力加成每回合只触发一次，用 counters["pilot_020_armor_applied_<turn>"] 记已加。
# 供 TimingEngine 的 PILOT_020_* handler 与 ConditionChecker 的 PILOT_020_X_AT_LEAST 条件读用。

static func get_pilot_020_x(pilot_card, turn_number: int) -> int:
	if pilot_card == null or not "counters" in pilot_card:
		return 0
	return int(pilot_card.counters.get("pilot_020_x_%d" % turn_number, 0))


static func increment_pilot_020_x(pilot_card, turn_number: int, delta: int = 1) -> void:
	if pilot_card == null or not "counters" in pilot_card:
		return
	var key := "pilot_020_x_%d" % turn_number
	pilot_card.counters[key] = int(pilot_card.counters.get(key, 0)) + delta


static func is_pilot_020_armor_applied(pilot_card, turn_number: int) -> bool:
	if pilot_card == null or not "counters" in pilot_card:
		return false
	return bool(pilot_card.counters.get("pilot_020_armor_applied_%d" % turn_number, 0))


static func mark_pilot_020_armor_applied(pilot_card, turn_number: int) -> void:
	if pilot_card == null or not "counters" in pilot_card:
		return
	pilot_card.counters["pilot_020_armor_applied_%d" % turn_number] = true


## 从 binding_context 定位肯德 pilot 卡实例（ConditionChecker / TimingEngine handler 共用）。
## 机师效果注册时 binding_context 注入 card_instance_id；校验 def 确为肯德以防误用。
## 返回 CardInstance 或 null。
static func get_pilot_020_pilot_card(gs, bind_ctx: Dictionary):
	if gs == null or bind_ctx.is_empty() or gs.cards == null:
		return null
	var cid: StringName = bind_ctx.get("card_instance_id", &"")
	if cid == &"":
		return null
	var card = gs.cards.get(cid)
	if card == null or card.def == null or String(card.def.card_id) != "pilot_020_肯德":
		return null
	return card


# ════════════════════════════════════════════════════════════
# 通用维修增强机制（REPAIR_BOOST）
# ════════════════════════════════════════════════════════════
# 任意机师牌 def 带 repair_boost 字段（如坎得 pilot_023 {"extra_removal":2,"range":4}）即生效：
#   - 维修目标选择范围扩大为 boost.range（TargetChecker TARGET_IS_ADJACENT_OR_SELF /
#     维修目标候选高亮 / 点击校验 / REPAIR_HAS_VALID_TARGET 条件统一读 get_repair_range）
#   - 维修效果额外移除 boost.extra_removal 损伤（TimingEngine CHOOSE_ONE 对 repair_direct
#     改写选项：移除2→合并移除(2+extra)；回复4→之后额外移除 extra，无损伤不生效）
# 坎得 effect_01 主动按钮的 REPAIR_HAS_VALID_TARGET 也读 get_repair_range（维修牌使用条件同改）。
# 琳 pilot_024 等后续机师可复用同机制。

## 查询机甲当前机师牌的维修增强配置。返回 {} 或 {extra_removal:int, range:int}。
## 读取 pilot 槽机师牌 def 的 repair_boost 字段，机师牌换下/换人即时失效（无 equip 钩子，天然正确）。
static func get_repair_boost(gs, mech_id: StringName) -> Dictionary:
	if gs == null or mech_id == &"" or gs.mechs == null:
		return {}
	var mech = gs.mechs.get(mech_id)
	if mech == null:
		return {}
	var slot = mech.slots.get(&"pilot") if mech.slots != null else null
	if slot == null:
		return {}
	var card = slot.equipped_card
	if card == null or card.def == null:
		return {}
	var boost = {}
	if "repair_boost" in card.def:
		boost = card.def.repair_boost
	if not (boost is Dictionary):
		return {}
	return boost


## 机甲维修可用范围：默认1；机师牌带 repair_boost 时用 boost.range。
static func get_repair_range(gs, mech_id: StringName) -> int:
	var boost = get_repair_boost(gs, mech_id)
	return int(boost.get("range", 1))


# ════════════════════════════════════════════════════════════
# 远程武器范围加成通用机制（仿 REPAIR_BOOST）
# ════════════════════════════════════════════════════════════
## 任意机师牌 def 带 passive_weapon_range_bonus 字段（如克劳德 pilot_029 =1）即生效：
##   - 本机甲使用远程武器攻击时，攻击范围 +N（app_root._get_weapon_range 预检 / attack_action
##     选武器记录 weapon_range / 命中与范围校验统一读 get_passive_weapon_range_bonus）。
##   - 与狙击装·头部（equipment_effect_055/022）加成合并计算，不注册监听器（实时重算）。
## 克劳德 pilot_029 effect_01 按钮（effect_ids 里的被动占位）仅渲染置灰+悬停，派生值走本 helper。
## 机师牌换下/换人即时失效（无 equip 钩子，天然正确）。后续机师可复用同机制。

## 查询机甲当前机师牌提供的远程武器范围加成。返回 int（默认0）。
## 读取 pilot 槽机师牌 def 的 passive_weapon_range_bonus 字段，机师牌未设置/禁用即时失效。
static func get_pilot_passive_weapon_range_bonus(mech) -> int:
	if mech == null or mech.get("slots") == null:
		return 0
	var slot = mech.slots.get(&"pilot")
	if slot == null:
		return 0
	var card = slot.equipped_card
	if card == null or card.def == null or card.get("disabled") == true:
		return 0
	if "passive_weapon_range_bonus" in card.def:
		return int(card.def.passive_weapon_range_bonus)
	return 0


# ════════════════════════════════════════════════════════════
# pilot_022 塔莉娅：禁/策 标签系统
# ════════════════════════════════════════════════════════════
# PILOT_021_JIN_TAG "禁"：效果1抽的3张行动牌打上（owner=塔莉娅玩家），本回合塔莉娅无法使用；
#   牌离开塔莉娅手牌（转移）时清除；回合结束清塔莉娅全部禁标签（剩余牌恢复可用）。
# PILOT_021_CE_TAG "策"：行动牌从塔莉娅手牌转移到其他玩家手牌时打上（效果1交牌/识破偷牌/
#   玛丽尔偷牌都计入，owner=塔莉娅玩家）；带策标签的行动牌从临时区进弃牌堆（通用"使用"判定）
#   时塔莉娅抽2，标签随牌入弃牌堆消失。一张牌可带多个 owner 的标签（多塔莉娅场景），用 owner_pid 区分
#   （仿 pilot_006 狩猎标签）。

const PILOT_021_JIN_TAG := &"pilot_022_jin_tag"
const PILOT_021_CE_TAG := &"pilot_022_ce_tag"

## 温斯顿 pilot_082「联」标签：交牌时打在行动牌上（owner=温斯顿玩家），
## 持有者使用联牌时对温斯顿施加联合状态。牌离开持有者手牌/临时区即清除。
const LIAN_TAG := &"pilot_082_lian_tag"


## 打"禁"标签（效果1抽的3张行动牌）。
static func pilot_022_tag_jin(card, owner_pid: StringName) -> void:
	if card == null or owner_pid == &"" or not card.has_method(&"add_tag"):
		return
	card.add_tag(PILOT_021_JIN_TAG, owner_pid, {"jin": true})


## 该 owner 是否有"禁"标签（use_action_card validate 用：塔莉娅本回合无法使用）。
static func pilot_022_has_jin(card, owner_pid: StringName) -> bool:
	if card == null or owner_pid == &"" or not card.has_method(&"has_tag"):
		return false
	return card.has_tag(PILOT_021_JIN_TAG, owner_pid)


## 牌是否有任意 owner 的"禁"标签（UI 显示"牌名(禁)"后缀）。
static func pilot_022_card_has_any_jin(card) -> bool:
	if card == null or not card.has_method(&"has_tag"):
		return false
	return card.has_tag(PILOT_021_JIN_TAG)


## 清指定 owner 的"禁"标签（转移时/回合结束时）。
static func pilot_022_clear_jin(card, owner_pid: StringName) -> void:
	if card == null or owner_pid == &"" or not card.has_method(&"remove_tag"):
		return
	card.remove_tag(PILOT_021_JIN_TAG, owner_pid)


## 清指定玩家全部"禁"标签（回合结束：效果1剩余牌恢复可用）。
static func pilot_022_clear_all_jin_for_player(game_state, player_id: StringName) -> void:
	if game_state == null or player_id == &"":
		return
	var cards_dict: Dictionary = game_state.cards if "cards" in game_state else {}
	for card in cards_dict.values():
		if card == null or not card.has_method(&"remove_tag"):
			continue
		if card.has_tag(PILOT_021_JIN_TAG, player_id):
			card.remove_tag(PILOT_021_JIN_TAG, player_id)


## 清指定玩家（塔莉娅拥有者）名下的全部"策"标签（离场时：他人持有的策牌不再触发其抽2）。
static func pilot_022_clear_all_ce_for_player(game_state, player_id: StringName) -> void:
	if game_state == null or player_id == &"":
		return
	var cards_dict: Dictionary = game_state.cards if "cards" in game_state else {}
	for card in cards_dict.values():
		if card == null or not card.has_method(&"remove_tag"):
			continue
		if card.has_tag(PILOT_021_CE_TAG, player_id):
			card.remove_tag(PILOT_021_CE_TAG, player_id)


## 牌从塔莉娅手牌转移到其他玩家手牌时调用：清"禁"标签 + 打"策"标签。
## 禁标签牌离开塔莉娅手牌后消失；策标签记录来源（owner=塔莉娅玩家）。
static func pilot_022_on_card_left_taliyah_hand(card, taliyah_pid: StringName) -> void:
	if card == null or taliyah_pid == &"" or not card.has_method(&"add_tag"):
		return
	card.remove_tag(PILOT_021_JIN_TAG, taliyah_pid)
	card.add_tag(PILOT_021_CE_TAG, taliyah_pid, {"ce": true})


## 牌是否有任意 owner 的"策"标签（UI 显示"牌名(策)"后缀）。
static func pilot_022_card_has_any_ce(card) -> bool:
	if card == null or not card.has_method(&"has_tag"):
		return false
	return card.has_tag(PILOT_021_CE_TAG)


## 清全部 owner 的"策"标签（牌进入弃牌堆标签即消失，无论使用/直接弃置）。
static func pilot_022_clear_all_ce(card) -> void:
	if card == null or not card.has_method(&"remove_tag"):
		return
	card.remove_tag(PILOT_021_CE_TAG)


## 带"策"标签的行动牌从临时区进弃牌堆（通用"使用"判定）：塔莉娅抽2 + 清策标签（入弃牌堆消失）。
## 多塔莉娅：按 owner 各自抽2。返回触发次数。由 discard_card_action._step_transfer_to_pile 调用。
## 统一走 gain_card 动作（发 GAIN_CARD_BEFORE/AFTER/SETTLE 时点 + 抽取标），库马斯 pilot_035 等
## GAIN_CARD_AFTER 监听器可响应"塔莉娅策略回收抽2"（用户要求全抽取路径统一覆盖）。
static func pilot_022_trigger_ce_draw(context, card) -> int:
	if context == null or context.game_state == null or card == null:
		return 0
	if not card.has_tag(PILOT_021_CE_TAG):
		return 0
	var owners: Array = card.get_tag_owners(PILOT_021_CE_TAG) if card.has_method(&"get_tag_owners") else []
	var count: int = 0
	for owner_pid: StringName in owners:
		if owner_pid == &"":
			continue
		if context != null and context.action_service != null:
			context.action_service.execute(&"gain_card", {
				"from_zone": &"action_deck", "card_kind": &"action",
				"count": 2, "player_id": owner_pid, "reason": &"pilot_022_ce_draw",
			})
		count += 1
	# 清全部策标签（牌入弃牌堆，标签消失）
	card.remove_tag(PILOT_021_CE_TAG)
	return count


## from_player 是否装备塔莉娅机师牌（转移挂钩条件判断：只有塔莉娅手牌转出才打策标签）。
## 返回 player_id（装备塔莉娅则原样返回，否则 &""）。
static func pilot_022_taliyah_owner_for_player(game_state, player_id: StringName) -> StringName:
	if game_state == null or player_id == &"":
		return &""
	var mech = game_state.get_mech_for_player(player_id) if game_state.has_method(&"get_mech_for_player") else null
	if mech == null:
		return &""
	var slot = mech.slots.get(&"pilot") if "slots" in mech and mech.slots != null else null
	if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
		return &""
	if String(slot.equipped_card.def.card_id) == "pilot_022_塔莉娅":
		return player_id
	return &""


# ════════════════════════════════════════════════════════════
# 温斯顿 pilot_082「联」标签
# ════════════════════════════════════════════════════════════
# 打标签：温斯顿效果1交牌时（TRANSFER_ACTION_CARDS _tag_on_transfer 钩子，GameActions 调用）。
# 清标签：牌离开持有者手牌/临时区（再转移/被偷/使用进弃牌堆）即清除（转移、偷牌、弃牌堆钩子）；
#   温斯顿换下清其名下全部联标签（GameSetupService unset_pilot 钩子）。
# 判定：USED_CARD_HAS_TAG_FROM_ME 条件（ConditionChecker）读 card.has_tag(LIAN_TAG, 温斯顿玩家)。


## 打"联"标签（效果1交牌）。
static func pilot_082_tag_lian(card, owner_pid: StringName) -> void:
	if card == null or owner_pid == &"" or not card.has_method(&"add_tag"):
		return
	card.add_tag(LIAN_TAG, owner_pid, {"lian": true})


## 牌是否有任意 owner 的"联"标签（弃牌堆/转移清标签判定）。
static func pilot_082_card_has_any_lian(card) -> bool:
	if card == null or not card.has_method(&"has_tag"):
		return false
	return card.has_tag(LIAN_TAG)


## 清全部 owner 的"联"标签（牌离开持有者手牌/临时区进弃牌堆，标签即消失）。
static func pilot_082_clear_all_lian(card) -> void:
	if card == null or not card.has_method(&"remove_tag"):
		return
	card.remove_tag(LIAN_TAG)


## 清指定玩家（温斯顿拥有者）名下的全部"联"标签（温斯顿换下时：他人持有的联牌不再触发其联合）。
static func pilot_082_clear_all_lian_for_player(game_state, player_id: StringName) -> void:
	if game_state == null or player_id == &"":
		return
	var cards_dict: Dictionary = game_state.cards if "cards" in game_state else {}
	for card in cards_dict.values():
		if card == null or not card.has_method(&"remove_tag"):
			continue
		if card.has_tag(LIAN_TAG, player_id):
			card.remove_tag(LIAN_TAG, player_id)


# ════════════════════════════════════════════════════════════
# pilot_024 琳：当作维修 / 维修后双方各抽2 / 请求维修（RE）机制
# ════════════════════════════════════════════════════════════
# 维修窗口状态存 gs.pilot_024_repair_window（PvP 锁步各端确定性一致，无需网络同步）：
#   {"lin_mech_id", "requester_mech_id", "action_id"} —— 存在即窗口激活。
#   action_id 为被阻塞的 RE 请求 effect_fire 动作（waiting_timing 挂起）；维修完成/取消时
#   continue_action(action_id) 恢复请求方回合。
# RE 每回合使用次数存琳 pilot 牌实例 counters["pilot_024_re_<requester>_<turn_number>"]：
#   gs.turn_number 每轮递增一次（先手回合 +1），请求方每轮只行动1次 -> 天然每轮重置。

## 场上装备 pilot_024 琳 的机甲 id（唯一）。无琳返回 &""。
static func pilot_024_find_lin_mech(gs) -> StringName:
	if gs == null or gs.mechs == null:
		return &""
	for mid: StringName in gs.mechs:
		var m = gs.mechs[mid]
		if m == null or m.slots == null:
			continue
		var slot = m.slots.get(&"pilot")
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		if String(slot.equipped_card.def.card_id) == "pilot_024_琳":
			return mid
	return &""


## 指定机甲机师是否为琳（pilot_024）。
static func pilot_024_is_lin(gs, mech_id: StringName) -> bool:
	return mech_id != &"" and pilot_024_find_lin_mech(gs) == mech_id


## 琳 pilot 牌实例（RE 计数存放处）。无琳返回 null。
static func pilot_024_lin_pilot_card(gs):
	var lin_mid = pilot_024_find_lin_mech(gs)
	if lin_mid == &"" or gs == null or gs.mechs == null:
		return null
	var m = gs.mechs.get(lin_mid)
	if m == null or m.slots == null:
		return null
	var slot = m.slots.get(&"pilot")
	if slot == null:
		return null
	return slot.equipped_card


## 当前维修窗口（存在即激活）。返回 {} 或 {lin_mech_id, requester_mech_id, action_id}。
static func pilot_024_repair_window(gs) -> Dictionary:
	if gs == null:
		return {}
	var w = gs.get("pilot_024_repair_window")
	if not (w is Dictionary):
		return {}
	return w


## 维修窗口是否激活。
static func pilot_024_window_active(gs) -> bool:
	return not pilot_024_repair_window(gs).is_empty()


## 窗口激活且来源机甲是琳时，返回被请求维修的机甲（请求方）；否则 &""。
## TargetChecker 距离豁免 / _execute_effect 目标锁定 / 取消按钮判断共用。
static func pilot_024_window_requester_for(gs, lin_mech_id: StringName) -> StringName:
	if lin_mech_id == &"":
		return &""
	var w = pilot_024_repair_window(gs)
	if w.is_empty():
		return &""
	if String(w.get("lin_mech_id", &"")) != String(lin_mech_id):
		return &""
	return w.get("requester_mech_id", &"")


## 琳视角：维修窗口是否激活（琳自己处于被请求维修的窗口中）。
static func pilot_024_window_active_for_mech(gs, mech_id: StringName) -> bool:
	if mech_id == &"" or not pilot_024_is_lin(gs, mech_id):
		return false
	return pilot_024_window_active(gs)


## 打开维修窗口（琳确认 RE 请求后）。锁定请求方为唯一维修目标，记录被阻塞的 RE 动作。
static func pilot_024_open_repair_window(gs, lin_mech_id: StringName, requester_mech_id: StringName, re_action_id: StringName) -> void:
	if gs == null:
		return
	gs.pilot_024_repair_window = {
		"lin_mech_id": lin_mech_id,
		"requester_mech_id": requester_mech_id,
		"action_id": re_action_id,
	}


## 关闭维修窗口并恢复被阻塞的 RE 动作（call_deferred 等当前动作结算完再恢复）。
## requester_mech_id 非空时校验请求方仍为该机甲（防御陈旧窗口覆盖新窗口）。
static func pilot_024_close_repair_window(context, requester_mech_id: StringName = &"") -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	var w = pilot_024_repair_window(gs)
	if w.is_empty():
		return
	if requester_mech_id != &"" and String(w.get("requester_mech_id", &"")) != String(requester_mech_id):
		return
	var re_action_id: StringName = w.get("action_id", &"")
	gs.pilot_024_repair_window = {}
	if re_action_id != &"" and context.action_engine != null:
		context.action_engine.call_deferred("continue_action", re_action_id, {})


## 机甲是否可被维修（非满状态：HP 未满 或 有损伤）。RE 请求方满状态不可点。
static func pilot_024_mech_repairable(gs, mech_id: StringName) -> bool:
	if gs == null or not gs.mechs.has(mech_id):
		return false
	var m = gs.mechs[mech_id]
	if m == null or m.destroyed:
		return false
	if m.current_hp < m.max_hp:
		return true
	if m.slots != null:
		for sid: StringName in m.slots:
			var slot = m.slots[sid]
			if slot == null:
				continue
			if int(slot.get("region_damage_tokens")) > 0:
				return true
			if slot.equipped_card != null and int(slot.equipped_card.get("damage_tokens")) > 0:
				return true
	return false


## 请求方本回合（本轮）是否已对琳使用过 RE。点击即消耗，琳拒绝也不刷新。
static func pilot_024_re_used_this_round(gs, requester_mech_id: StringName) -> bool:
	var card = pilot_024_lin_pilot_card(gs)
	if card == null or gs == null:
		return false
	return bool(card.counters.get("pilot_024_re_%s_%d" % [String(requester_mech_id), int(gs.turn_number)], false))


## 标记请求方本回合已使用 RE（点击即消耗）。
static func pilot_024_re_mark_used(gs, requester_mech_id: StringName) -> void:
	var card = pilot_024_lin_pilot_card(gs)
	if card == null or gs == null:
		return
	if not "counters" in card:
		card.counters = {}
	card.counters["pilot_024_re_%s_%d" % [String(requester_mech_id), int(gs.turn_number)]] = true


## 效果2判定：琳对非自己的机甲执行维修时，返回抽牌玩家顺序 [琳玩家, 目标玩家]
## （我方先抽、目标后抽）。返回空数组则不触发（来源非琳 / 目标为自己 / 目标已销毁）。
static func pilot_024_draw_players_after_repair(gs, repair_source_mech: StringName, target_mech_id: StringName) -> Array:
	if gs == null or target_mech_id == &"" or target_mech_id == repair_source_mech:
		return []
	if not pilot_024_is_lin(gs, repair_source_mech):
		return []
	var lin_m = gs.mechs.get(repair_source_mech)
	var tgt_m = gs.mechs.get(target_mech_id)
	if lin_m == null or tgt_m == null or tgt_m.destroyed:
		return []
	var lin_pid: StringName = lin_m.owner_player_id
	var tgt_pid: StringName = tgt_m.owner_player_id
	if lin_pid == &"" or tgt_pid == &"":
		return []
	return [lin_pid, tgt_pid]


## 请求方是否在琳的 range 格内（RE 按钮动态渲染 / 距离判断）。
static func pilot_024_requester_in_range(gs, requester_mech_id: StringName, lin_mech_id: StringName, range: int) -> bool:
	if gs == null or gs.mechs == null:
		return false
	var r_m = gs.mechs.get(requester_mech_id)
	var l_m = gs.mechs.get(lin_mech_id)
	if r_m == null or l_m == null or r_m.destroyed:
		return false
	return int(_get_hex_grid().distance(r_m.position, l_m.position)) <= range


# ════════════════════════════════════════════════════════════
# pilot_081 汀兰：绿格光环（按需派生，不存状态）+ RE 请求回复
# ════════════════════════════════════════════════════════════
# 绑定到「效果」而非机师：任何 pilot 槽装备 card_id=="pilot_081_汀兰" 的存活机甲即持有者。
# 光环 = 各存活持有者所在格 + 6 邻居（红格除外），从持有者当前位置实时派生，
# 持有者移动/死亡/卸下后自动跟随/消失，无需监听器/恢复/死亡清理。
# 移动折扣：持有者玩家的机甲移动时全地图绿格耗 1（MapService.resolve_move_cost_params 通用查询，
# 敌方机甲在光环/绿格上仍耗 2（绿格是全局的，折扣是玩家作用域的）。
# RE 计数：存请求方所属玩家的 once_per_turn_used["pilot_081_re_<mech>"]，
# TURN_START 清零 -> 天然每「请求方回合」1 次；存于请求方而非持有者 ->
# 多持有者时拒绝 H1 后 H2 本回合亦不可用（与「拒绝仍消耗」一致）。

## 场上装备 pilot_081 汀兰 的存活机甲 id 数组（可多个）。
static func pilot_081_find_holders(gs) -> Array:
	var holders: Array = []
	if gs == null or gs.mechs == null:
		return holders
	for mid: StringName in gs.mechs:
		var m = gs.mechs[mid]
		if m == null or m.destroyed or m.slots == null:
			continue
		var slot = m.slots.get(&"pilot")
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		if String(slot.equipped_card.def.card_id) == "pilot_081_汀兰":
			holders.append(mid)
	return holders


## 指定 pilot 牌实例对应的汀兰持有者机甲 id（按 instance_id 精确定位，RE 确认窗回路由此找持有者）。
static func pilot_081_find_holder_for_pilot_instance(gs, instance_id: StringName) -> StringName:
	if gs == null or gs.mechs == null or instance_id == &"":
		return &""
	for mid: StringName in gs.mechs:
		var m = gs.mechs[mid]
		if m == null or m.destroyed or m.slots == null:
			continue
		var slot = m.slots.get(&"pilot")
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		if String(slot.equipped_card.def.card_id) == "pilot_081_汀兰" \
				and StringName(slot.equipped_card.instance_id) == StringName(instance_id):
			return mid
	return &""


## 覆盖指定机甲的光环持有者数组（持有者在其 1 格内，含自身；RE 按钮逐持有者渲染）。
## 空数组 = 该机甲不在光环内（无 RE 资格）。
static func pilot_081_find_covering_holders(gs, mech_id: StringName) -> Array:
	var result: Array = []
	if gs == null or gs.mechs == null or not gs.mechs.has(mech_id):
		return result
	var target = gs.mechs.get(mech_id)
	if target == null or target.destroyed:
		return result
	var tpos = target.position
	var hg = _get_hex_grid()
	for h in pilot_081_find_holders(gs):
		var hm = gs.mechs.get(h)
		if hm == null:
			continue
		if int(hg.distance(tpos, hm.position)) <= 1:
			result.append(h)
	return result


## 请求方本回合是否已用过 RE（点击即消耗，持有者拒绝也不刷新）。
## 存请求方所属玩家的 once_per_turn_used（TURN_START 清零 -> 每「请求方回合」1 次）。
static func pilot_081_re_used_this_turn(gs, requester_mech_id: StringName) -> bool:
	if gs == null or requester_mech_id == &"":
		return false
	var m = gs.mechs.get(requester_mech_id) if gs.mechs != null else null
	if m == null:
		return false
	var player = gs.players.get(m.owner_player_id) if gs.players != null else null
	if player == null:
		return false
	var used: Dictionary = player.once_per_turn_used if player.once_per_turn_used is Dictionary else {}
	return used.has("pilot_081_re_%s" % String(requester_mech_id))


## 标记请求方本回合已用 RE（拒绝路径也会调，与琳一致）。
static func pilot_081_re_mark_used(gs, requester_mech_id: StringName) -> void:
	if gs == null or requester_mech_id == &"":
		return
	var m = gs.mechs.get(requester_mech_id) if gs.mechs != null else null
	if m == null:
		return
	var player = gs.players.get(m.owner_player_id) if gs.players != null else null
	if player == null:
		return
	if not (player.once_per_turn_used is Dictionary):
		player.once_per_turn_used = {}
	player.once_per_turn_used["pilot_081_re_%s" % String(requester_mech_id)] = true


# ════════════════════════════════════════════════════════════
# pilot_083 瓦恩：武器修改通用 helpers（效果1主动 + RE 请求共用）
# ════════════════════════════════════════════════════════════
## 获取 GeneratedEquipmentEffects（延迟 load，避免 GeneratedEquipmentEffects->本文件
## const preload 循环依赖；与 _get_hex_grid 同模式）。
static var _gen_equip_effects_cache = null
static func _get_gen_equip_effects():
	if _gen_equip_effects_cache == null:
		_gen_equip_effects_cache = load("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
	return _gen_equip_effects_cache


## 场上存活且持有瓦恩（pilot 槽装备 pilot_083_瓦恩）的机甲 id 数组。
static func pilot_083_find_holders(gs) -> Array:
	var result: Array = []
	if gs == null or gs.mechs == null:
		return result
	for mid: StringName in gs.mechs:
		var m = gs.mechs.get(mid)
		if m == null or m.destroyed or m.slots == null:
			continue
		var slot = m.slots.get(&"pilot")
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		if String(slot.equipped_card.def.card_id) == "pilot_083_瓦恩":
			result.append(mid)
	return result


## 覆盖指定机甲的瓦恩持有者数组（持有者 3 格内；排除请求方自身--瓦恩持有者自己
## 不能自我请求，自身不渲染 RE 按钮）。空数组 = 该机甲不在范围内（无 RE 资格）。
## 3 格按地图直线距离（奇数q亦准确）。
static func pilot_083_find_covering_holders(gs, mech_id: StringName) -> Array:
	var result: Array = []
	if gs == null or gs.mechs == null or not gs.mechs.has(mech_id):
		return result
	var target = gs.mechs.get(mech_id)
	if target == null or target.destroyed:
		return result
	var tpos = target.position
	var hg = _get_hex_grid()
	for h in pilot_083_find_holders(gs):
		if h == mech_id:
			continue  # 请求方自身即瓦恩持有者：不能自己请求自己
		var hm = gs.mechs.get(h)
		if hm == null:
			continue
		if int(hg.distance(hm.position, tpos)) <= 3:
			result.append(h)
	return result


## 按瓦恩 pilot 牌实例找持有者机甲 id（RE 弹窗定位持有者玩家用）。
static func pilot_083_find_holder_for_pilot_instance(gs, instance_id: StringName) -> StringName:
	if gs == null or gs.mechs == null or instance_id == &"":
		return &""
	for mid: StringName in gs.mechs:
		var m = gs.mechs.get(mid)
		if m == null or m.destroyed or m.slots == null:
			continue
		var slot = m.slots.get(&"pilot")
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		if String(slot.equipped_card.def.card_id) == "pilot_083_瓦恩" \
				and StringName(slot.equipped_card.instance_id) == StringName(instance_id):
			return mid
	return &""


## 请求方本回合是否已用瓦恩 RE（点击即消耗，持有者拒绝也不刷新）。存请求方所属玩家
## once_per_turn_used["pilot_083_re_<mech>"]，TURN_START 清零 -> 每「请求方回合」1 次。
static func pilot_083_re_used_this_turn(gs, requester_mech_id: StringName) -> bool:
	if gs == null or requester_mech_id == &"":
		return false
	var m = gs.mechs.get(requester_mech_id) if gs.mechs != null else null
	if m == null:
		return false
	var player = gs.players.get(m.owner_player_id) if gs.players != null else null
	if player == null:
		return false
	var used: Dictionary = player.once_per_turn_used if player.once_per_turn_used is Dictionary else {}
	return used.has("pilot_083_re_%s" % String(requester_mech_id))


## 标记请求方本回合已用瓦恩 RE。
static func pilot_083_re_mark_used(gs, requester_mech_id: StringName) -> void:
	if gs == null or requester_mech_id == &"":
		return
	var m = gs.mechs.get(requester_mech_id) if gs.mechs != null else null
	if m == null:
		return
	var player = gs.players.get(m.owner_player_id) if gs.players != null else null
	if player == null:
		return
	if not (player.once_per_turn_used is Dictionary):
		player.once_per_turn_used = {}
	player.once_per_turn_used["pilot_083_re_%s" % String(requester_mech_id)] = true


## 构建武器选择选项列表。
## requester_mech_id == "" -> 场上所有武器（所有存活机甲的武器槽装备 + 虚拟武器，排除基础武器）；
## 否则 -> 仅该机甲（请求方）的武器。返回 Array[Dictionary] {label, weapon_key, mech_id, slot_id, is_virtual}。
## weapon_key 形如 "card:<instance_id>"（实体/虚拟武器统一按卡牌实例，TimingEngine 据此定位武器卡）。
static func pilot_083_list_weapon_options(gs, requester_mech_id: StringName) -> Array:
	var options: Array = []
	if gs == null or gs.mechs == null:
		return options
	var mechs_to_iter: Array = []
	if requester_mech_id == &"":
		for mid: StringName in gs.mechs:
			var m = gs.mechs.get(mid)
			if m != null and not m.destroyed:
				mechs_to_iter.append(m)
	else:
		var m = gs.mechs.get(requester_mech_id)
		if m != null and not m.destroyed:
			mechs_to_iter.append(m)
	var _GEE = _get_gen_equip_effects()
	for mech in mechs_to_iter:
		var mech_name: String = String(mech.frame_def.display_name) if mech.frame_def != null else String(mech.mech_id)
		if mech.slots == null:
			continue
		for sid in mech.slots:
			var slot = mech.slots[sid]
			if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
				continue
			var card = slot.equipped_card
			var vw: Dictionary = _GEE.get_virtual_weapon_from_equipment(card)
			var eff_stats: Dictionary = _GEE.get_effective_weapon_stats(card)
			var wname: String = String(eff_stats.get("weapon_name", card.def.display_name))
			var wm: int = int(eff_stats.get("might", 0))
			var wr: int = int(eff_stats.get("range_value", 1))
			var wkind: String = String(eff_stats.get("weapon_kind", ""))
			var region: String = String(slot.slot_id) if slot.slot_id != null else String(sid)
			if not vw.is_empty():
				# 虚拟武器（神莺躯干 effect_087 等）：区域=提供该武器的部件槽
				options.append({
					"label": "%s(虚拟武器) [威力:%d 射程:%d]（%s·%s）" % [wname, wm, wr, region, mech_name],
					"weapon_key": "card:%s" % String(card.instance_id),
					"mech_id": mech.mech_id,
					"slot_id": sid,
					"is_virtual": true,
				})
			elif slot.slot_kind == &"WEAPON":
				# 实体武器（武器槽）
				options.append({
					"label": "%s(%s) [威力:%d 射程:%d]（%s·%s）" % [wname, wkind, wm, wr, region, mech_name],
					"weapon_key": "card:%s" % String(card.instance_id),
					"mech_id": mech.mech_id,
					"slot_id": sid,
					"is_virtual": false,
				})
		# 基础武器（frame_base_weapon_N，武器槽无装备卡时生效；无卡牌实例，施加存机甲）
		for bi in range(mech.base_weapons.size()):
			var bw: Dictionary = mech.base_weapons[bi]
			if bw.is_empty():
				continue
			var bw_slot_id: StringName = StringName("weapon_%d" % [bi + 1])
			var bw_slot = mech.slots.get(bw_slot_id) if mech.slots != null else null
			if bw_slot != null and bw_slot.equipped_card != null:
				# 该槽位已装实体武器 → 基础武器不生效
				continue
			var bws: Dictionary = get_base_weapon_effective_stats(mech, bi)
			var bw_name: String = String(bws.get("weapon_name", ""))
			var bw_m: int = int(bws.get("might", 0))
			var bw_r: int = int(bws.get("range_value", 1))
			options.append({
				"label": "%s(基础武器) [威力:%d 射程:%d]（%s·%s）" % [bw_name, bw_m, bw_r, String(bw_slot_id), mech_name],
				"weapon_key": "base:%s:%d" % [String(mech.mech_id), bi],
				"mech_id": mech.mech_id,
				"slot_id": bw_slot_id,
				"is_virtual": true,
			})
	return options


## 取某武器卡已施加的瓦恩应用（聚合）。返回 {suffixes: Array[String], type_override: StringName,
## might_bonus: int, range_bonus: int}。suffixes 按施加先后累积去重；type_override 取最新带类型
## 覆盖的施加（按 apps 数组顺序迭代，最新生效）；might/range 全部叠加。
static func get_pilot_083_weapon_apps(card) -> Dictionary:
	var result := {"suffixes": [], "type_override": &"", "might_bonus": 0, "range_bonus": 0}
	if card == null or card.get("counters") == null:
		return result
	var apps: Array = card.counters.get("pilot_083_apps", [])
	if not (apps is Array) or apps.is_empty():
		return result
	for app in apps:
		if not (app is Dictionary):
			continue
		var suf: String = String(app.get("name_suffix", ""))
		if suf != "" and not result["suffixes"].has(suf):
			result["suffixes"].append(suf)
		var t_ov: StringName = StringName(app.get("type_override", ""))
		if t_ov != &"":
			result["type_override"] = t_ov
		result["might_bonus"] = int(result["might_bonus"]) + int(app.get("might", 0))
		result["range_bonus"] = int(result["range_bonus"]) + int(app.get("range", 0))
	return result


## 施加瓦恩打包状态到武器卡（效果1应用 / RE 接受后应用共用）。
## app 数据 {name_suffix, type_override, might, range}（可空字段）；owner_pid=瓦恩所属玩家；
## applied_turn=施加时回合号。追加到 counters["pilot_083_apps"]。
static func pilot_083_apply_to_weapon(card, owner_pid: StringName, applied_turn: int, app: Dictionary) -> void:
	if card == null or card.get("counters") == null:
		return
	var apps: Array = card.counters.get("pilot_083_apps", [])
	if not (apps is Array):
		apps = []
	apps.append({
		"owner_pid": owner_pid,
		"applied_turn": int(applied_turn),
		"name_suffix": String(app.get("name_suffix", "")),
		"type_override": StringName(app.get("type_override", "")),
		"might": int(app.get("might", 0)),
		"range": int(app.get("range", 0)),
	})
	card.counters["pilot_083_apps"] = apps
	SLog.log_raw("[PILOT083] 瓦恩施加武器修改 owner=%s turn=%d app=%s -> %s" % [
		String(owner_pid), int(applied_turn), str(app), String(card.instance_id)])


## 聚合基础武器已施加的瓦恩应用（基础武器无卡牌实例，施加存 mech.pilot_083_base_apps）。
## 返回 {suffixes, type_override, might_bonus, range_bonus}，与卡牌版 get_pilot_083_weapon_apps 同构。
static func get_pilot_083_base_apps(mech, slot_index: int) -> Dictionary:
	var result := {"suffixes": [], "type_override": &"", "might_bonus": 0, "range_bonus": 0}
	if mech == null or not ("pilot_083_base_apps" in mech):
		return result
	var apps: Array = mech.pilot_083_base_apps.get(str(slot_index), [])
	if not (apps is Array) or apps.is_empty():
		return result
	for app in apps:
		if not (app is Dictionary):
			continue
		var suf: String = String(app.get("name_suffix", ""))
		if suf != "" and not result["suffixes"].has(suf):
			result["suffixes"].append(suf)
		var t_ov: StringName = StringName(app.get("type_override", ""))
		if t_ov != &"":
			result["type_override"] = t_ov
		result["might_bonus"] = int(result["might_bonus"]) + int(app.get("might", 0))
		result["range_bonus"] = int(result["range_bonus"]) + int(app.get("range", 0))
	return result


## 基础武器施加瓦恩修改（存机甲 pilot_083_base_apps；app 数据与卡牌版同构，避免污染共享框架定义）。
static func pilot_083_apply_to_base_weapon(mech, slot_index: int, owner_pid: StringName, applied_turn: int, app: Dictionary) -> void:
	if mech == null:
		return
	if not ("pilot_083_base_apps" in mech) or not (mech.pilot_083_base_apps is Dictionary):
		mech.pilot_083_base_apps = {}
	var apps: Array = mech.pilot_083_base_apps.get(str(slot_index), [])
	if not (apps is Array):
		apps = []
	apps.append({
		"owner_pid": owner_pid,
		"applied_turn": int(applied_turn),
		"name_suffix": String(app.get("name_suffix", "")),
		"type_override": StringName(app.get("type_override", "")),
		"might": int(app.get("might", 0)),
		"range": int(app.get("range", 0)),
	})
	mech.pilot_083_base_apps[str(slot_index)] = apps
	SLog.log_raw("[PILOT083] 瓦恩施加基础武器修改 owner=%s turn=%d slot=%d app=%s -> %s" % [
		String(owner_pid), int(applied_turn), slot_index, str(app), String(mech.mech_id)])


## 基础武器带瓦恩修改的派生统计（通用入口，仿 get_effective_weapon_stats 的 p083 段）。
## 返回 {might, range_value, weapon_kind, weapon_name}（suffixes 已拼入 weapon_name，type 已覆盖）。
static func get_base_weapon_effective_stats(mech, slot_index: int) -> Dictionary:
	var base_weapon: Dictionary = mech.get_base_weapon(slot_index) if mech != null and mech.has_method(&"get_base_weapon") else {}
	var wname: StringName = StringName(base_weapon.get("name", &""))
	var wkind: StringName = base_weapon.get("weapon_kind", &"")
	var might: int = int(base_weapon.get("might", 0))
	var range: int = int(base_weapon.get("range_value", 1))
	var apps: Dictionary = get_pilot_083_base_apps(mech, slot_index)
	var m_bonus: int = int(apps.get("might_bonus", 0))
	var r_bonus: int = int(apps.get("range_bonus", 0))
	if m_bonus != 0 or r_bonus != 0:
		might += m_bonus
		range += r_bonus
	var sufs: Array = apps.get("suffixes", [])
	if not sufs.is_empty():
		wname = StringName("%s·%s" % [String(wname), String("·".join(sufs))])
	var t_ov: StringName = apps.get("type_override", &"")
	if t_ov != &"":
		wkind = t_ov
	# 事件牌派生武器加成（e015 强化：全部武器威力+4；e016 强化：全部武器范围+2）。
	# 基础武器无卡牌实例，按机甲 mech_id 实时查询 GeneratedEventEffects._derived_registry
	# （与 GeneratedEquipmentEffects.get_effective_weapon_stats 的装备武器路径同款）。
	if mech != null and "mech_id" in mech and String(mech.mech_id) != "":
		var ev_mid: StringName = StringName(String(mech.mech_id))
		might += _GeneratedEventEffects.get_weapon_might_bonus(ev_mid)
		range += _GeneratedEventEffects.get_weapon_range_bonus(ev_mid)
	return {
		"might": max(0, might),
		"range_value": max(0, range),
		"weapon_kind": wkind,
		"weapon_name": wname,
	}


## 瓦恩持有者玩家「下个我方回合结束」过期清理：移除 owner_pid==holder_player 且
## applied_turn < turn_number（当前回合号）的应用（跨过下个我方回合结束的终点）。
## 由 TurnService TURN_AFTER_END 对「当前回合所属玩家」调用（该玩家持有瓦恩时）。
static func pilot_083_expire_apps_for_turn(gs, holder_player_id: StringName, turn_number: int) -> void:
	if gs == null or gs.cards == null or holder_player_id == &"":
		return
	for cid: StringName in gs.cards:
		var card = gs.cards.get(cid)
		if card == null or card.get("counters") == null:
			continue
		var apps: Array = card.counters.get("pilot_083_apps", [])
		if not (apps is Array) or apps.is_empty():
			continue
		var kept: Array = []
		var removed: int = 0
		for app in apps:
			if app is Dictionary and String(app.get("owner_pid", "")) == String(holder_player_id) \
					and int(app.get("applied_turn", 0)) < turn_number:
				removed += 1
				continue
			kept.append(app)
		if removed > 0:
			card.counters["pilot_083_apps"] = kept
			SLog.log_raw("[PILOT083] 瓦恩过期清理 owner=%s turn=%d 移除%d条 -> %s" % [
				String(holder_player_id), int(turn_number), removed, String(card.instance_id)])
	# 基础武器版（存各机甲 pilot_083_base_apps）
	if gs.mechs == null:
		return
	for mid: StringName in gs.mechs:
		var mech = gs.mechs.get(mid)
		if mech == null or not ("pilot_083_base_apps" in mech) or not (mech.pilot_083_base_apps is Dictionary):
			continue
		for sidx: String in mech.pilot_083_base_apps:
			var apps: Array = mech.pilot_083_base_apps[sidx]
			if not (apps is Array):
				continue
			var kept: Array = []
			var removed: int = 0
			for app in apps:
				if app is Dictionary and String(app.get("owner_pid", "")) == String(holder_player_id) \
						and int(app.get("applied_turn", 0)) < turn_number:
					removed += 1
					continue
				kept.append(app)
			if removed > 0:
				mech.pilot_083_base_apps[sidx] = kept
				SLog.log_raw("[PILOT083] 瓦恩过期清理(基础武器) owner=%s turn=%d 移除%d条 -> %s·%s" % [
					String(holder_player_id), int(turn_number), removed, String(mech.mech_id), sidx])


## ROUND_START 孤儿清理：移除 owner 玩家已无存活瓦恩持有者的应用（瓦恩被换下/机甲被毁等）。
static func pilot_083_expire_orphan_apps(gs) -> void:
	if gs == null or gs.cards == null:
		return
	var holder_pids: Dictionary = {}
	for hmid in pilot_083_find_holders(gs):
		var hm = gs.mechs.get(hmid) if gs.mechs != null else null
		if hm != null:
			holder_pids[String(hm.owner_player_id)] = true
	for cid: StringName in gs.cards:
		var card = gs.cards.get(cid)
		if card == null or card.get("counters") == null:
			continue
		var apps: Array = card.counters.get("pilot_083_apps", [])
		if not (apps is Array) or apps.is_empty():
			continue
		var kept: Array = []
		var removed: int = 0
		for app in apps:
			if app is Dictionary and not holder_pids.has(String(app.get("owner_pid", ""))):
				removed += 1
				continue
			kept.append(app)
		if removed > 0:
			card.counters["pilot_083_apps"] = kept
			SLog.log_raw("[PILOT083] 瓦恩孤儿清理 移除%d条 -> %s" % [removed, String(card.instance_id)])
	# 基础武器版
	if gs.mechs == null:
		return
	for mid: StringName in gs.mechs:
		var mech = gs.mechs.get(mid)
		if mech == null or not ("pilot_083_base_apps" in mech) or not (mech.pilot_083_base_apps is Dictionary):
			continue
		for sidx: String in mech.pilot_083_base_apps:
			var apps: Array = mech.pilot_083_base_apps[sidx]
			if not (apps is Array):
				continue
			var kept: Array = []
			var removed: int = 0
			for app in apps:
				if app is Dictionary and not holder_pids.has(String(app.get("owner_pid", ""))):
					removed += 1
					continue
				kept.append(app)
			if removed > 0:
				mech.pilot_083_base_apps[sidx] = kept
				SLog.log_raw("[PILOT083] 瓦恩孤儿清理(基础武器) 移除%d条 -> %s·%s" % [removed, String(mech.mech_id), sidx])


## 场上是否有至少1把武器（效果1按钮前置：无武器不可点）。
## 判定与 pilot_083_list_weapon_options 一致：实体武器槽装备 + 虚拟武器 + 基础武器。
static func pilot_083_has_field_weapon(gs) -> bool:
	if gs == null or gs.mechs == null:
		return false
	var _GEE = _get_gen_equip_effects()
	for mid: StringName in gs.mechs:
		var m = gs.mechs.get(mid)
		if m == null or m.destroyed or m.slots == null:
			continue
		for sid in m.slots:
			var slot = m.slots[sid]
			if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
				continue
			var card = slot.equipped_card
			if not _GEE.get_virtual_weapon_from_equipment(card).is_empty():
				return true
			if slot.slot_kind == &"WEAPON":
				return true
		# 基础武器（武器槽无装备卡时生效）
		if m.base_weapons != null:
			for bi in range(m.base_weapons.size()):
				var bw: Dictionary = m.base_weapons[bi]
				if bw.is_empty():
					continue
				var bw_slot_id: StringName = StringName("weapon_%d" % [bi + 1])
				var bw_slot = m.slots.get(bw_slot_id)
				if bw_slot == null or bw_slot.equipped_card == null:
					return true
	return false


# ════════════════════════════════════════════════════════════
# pilot_026 伊万：按 effect_id 判定目标机甲是否带有该效果（效果2/效果3 通用）
# ════════════════════════════════════════════════════════════
## 判定绑定到「效果」而非具体机师：查该机甲 pilot 槽装备卡的 effect_ids
## （经 get_effects_for_pilot 从 context 的 JSON 数据 map 懒加载），包含指定 effect_id 即 true。
## 注意：不能从 card.def 上读 effect_ids（PilotCardDef 不存），必须走数据 map。
## context 传 GameContext（GameActions / 各 Action 均有），保证数据 map 已加载。
static func mech_has_pilot_effect(context, mech_id: StringName, effect_id: StringName) -> bool:
	if context == null:
		return false
	var gs = context.game_state if not context is Dictionary else context.get("game_state")
	if gs == null or gs.mechs == null or not gs.mechs.has(mech_id):
		return false
	var mech = gs.mechs.get(mech_id)
	if mech == null or mech.slots == null:
		return false
	var pilot_slot = mech.slots.get(&"pilot")
	if pilot_slot == null:
		return false
	var p_card = pilot_slot.equipped_card
	if p_card == null or p_card.def == null:
		return false
	var eff_ids: Array = get_effects_for_pilot(p_card.def.card_id, context)
	return eff_ids.has(effect_id)


# ════════════════════════════════════════════════════════════
# pilot_027 维罗妮卡：X 变量（4+X范围）/ 机师牌实例查询
# ════════════════════════════════════════════════════════════
## 场上装备 pilot_027 维罗妮卡 的机甲 id（唯一）。无维罗妮卡返回 &""。
static func pilot_027_find_v_mech(gs) -> StringName:
	if gs == null or gs.mechs == null:
		return &""
	for mid: StringName in gs.mechs:
		var m = gs.mechs[mid]
		if m == null or m.slots == null:
			continue
		var slot = m.slots.get(&"pilot")
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		if String(slot.equipped_card.def.card_id) == "pilot_027_维罗妮卡":
			return mid
	return &""


## 维罗妮卡机师牌实例（X 存放处）。无返回 null。
static func pilot_027_pilot_card(gs):
	var p27_mid = pilot_027_find_v_mech(gs)
	if p27_mid == &"" or gs == null or gs.mechs == null:
		return null
	var m = gs.mechs.get(p27_mid)
	if m == null or m.slots == null:
		return null
	var slot = m.slots.get(&"pilot")
	if slot == null:
		return null
	return slot.equipped_card


## pilot_027 维罗妮卡 X 变量（绑机师牌实例 counters["var_pilot_027_x"]，初始0）。
## 效果2「每回合1次，我方给予其他机甲金币时 X+1」递增；影响效果1分半/效果3给金的范围 4+X。
## 换机师不转移（旧实例 listener 注销，新实例从0开始）。
static func get_pilot_027_x(pilot_card) -> int:
	if pilot_card == null or not "counters" in pilot_card:
		return 0
	return int(pilot_card.counters.get("var_pilot_027_x", 0))


static func set_pilot_027_x(pilot_card, val: int) -> void:
	if pilot_card == null:
		return
	if not "counters" in pilot_card:
		pilot_card.counters = {}
	pilot_card.counters["var_pilot_027_x"] = maxi(0, int(val))


# ════════════════════════════════════════════════════════════
# pilot_028 乌尔：宣言类型 + X 变量（4+X范围）/ 机师牌实例查询
# ════════════════════════════════════════════════════════════
## 场上装备 pilot_028 乌尔 的机甲 id（唯一）。无乌尔返回 &""。
static func pilot_028_find_w_mech(gs) -> StringName:
	if gs == null or gs.mechs == null:
		return &""
	for mid: StringName in gs.mechs:
		var m = gs.mechs[mid]
		if m == null or m.slots == null:
			continue
		var slot = m.slots.get(&"pilot")
		if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
			continue
		if String(slot.equipped_card.def.card_id) == "pilot_028_乌尔":
			return mid
	return &""


## 乌尔机师牌实例（X/宣言存放处）。无返回 null。
static func pilot_028_pilot_card(gs):
	var p28_mid = pilot_028_find_w_mech(gs)
	if p28_mid == &"" or gs == null or gs.mechs == null:
		return null
	var m = gs.mechs.get(p28_mid)
	if m == null or m.slots == null:
		return null
	var slot = m.slots.get(&"pilot")
	if slot == null:
		return null
	return slot.equipped_card


## pilot_028 乌尔 X 变量（绑机师牌实例 counters["var_pilot_028_x"]，初始0）。
## 效果3「每回合1次，我方使用宣言类型行动牌时 X+1」递增；影响效果2需交牌范围 4+X。
## 换机师不转移（旧实例 listener 注销，新实例从0开始）。
static func get_pilot_028_x(pilot_card) -> int:
	if pilot_card == null or not "counters" in pilot_card:
		return 0
	return int(pilot_card.counters.get("var_pilot_028_x", 0))


static func set_pilot_028_x(pilot_card, val: int) -> void:
	if pilot_card == null:
		return
	if not "counters" in pilot_card:
		pilot_card.counters = {}
	pilot_card.counters["var_pilot_028_x"] = maxi(0, int(val))


## pilot_028 乌尔本轮宣言类型（绑机师牌实例 counters["var_pilot_028_declared"]，每轮宣言时重设）。
## 空串 = 本轮无宣言（效果2/3失效）。可选值："攻击"/"迎击"/"辅助"。
static func get_pilot_028_declared(pilot_card) -> String:
	if pilot_card == null or not "counters" in pilot_card:
		return ""
	return String(pilot_card.counters.get("var_pilot_028_declared", ""))


static func set_pilot_028_declared(pilot_card, declared_type: String) -> void:
	if pilot_card == null:
		return
	if not "counters" in pilot_card:
		pilot_card.counters = {}
	pilot_card.counters["var_pilot_028_declared"] = declared_type


## pilot_028 效果3（X+1）每回合1次：本轮 turn_number 是否已用过。
## 用机师牌实例计数器（键含回合号自动每回合重置）。不能走 once_per_turn_key（会误耗）。
static func pilot_028_xinc_used_this_turn(pilot_card, turn_number: int) -> bool:
	if pilot_card == null or not "counters" in pilot_card:
		return false
	return int(pilot_card.counters.get("pilot_028_xinc_turn_%d" % turn_number, 0)) > 0


static func pilot_028_mark_xinc_used(pilot_card, turn_number: int) -> void:
	if pilot_card == null:
		return
	if not "counters" in pilot_card:
		pilot_card.counters = {}
	pilot_card.counters["pilot_028_xinc_turn_%d" % turn_number] = 1


# ════════════════════════════════════════════════════════════
# 通用「被响应→抽2装备→逐张设置/弃置获金」链式模块（responded_equip_chain_*）
# ════════════════════════════════════════════════════════════
# 纯通用组件（不绑定机师）——任何 LISTEN ATTACK_SETTLE + 条件 SELF_MECH_IS_ATTACKER +
# ATTACK_WAS_RESPONDED + 动作 RESPONDED_EQUIP_SCHEDULE_AFTER_ATTACK 的效果都走这条链
# （铠厉 pilot_056_effect_01 当前唯一使用者；复用=复制该效果定义改 key 即可）。
# 权威文本：若发动的攻击被响应，则可以抽2张装备牌，若不立即设置，则需要直接弃置并获得牌面
# 记述数量的金币。每次被响应都触发（无每回合次数限制）。
#
# 状态机（GameState 字段）：
#   responded_equip_queue        待处理触发队列（攻击结算后入队，多条攻击/多响应串行）
#   responded_equip_pending_confirm  当前待玩家确认的触发（{player_id, mech_id}）
#   responded_equip_chain        逐张处理链（{owner_player_id, owner_mech_id, card_ids, index}）
#
# 流程：攻击动作完成 -> after_attack_completed 入队 -> process_next 弹确认
#   -> confirm(accept) 抽2装备 -> start_chain -> 逐张弹「立即设置/弃置获金(cost)」面板
#   -> card_resume(设置=set_equipment / 弃置=discard_card+gain_gold) -> advance -> 全部完清链
#   -> process_next 处理队列下一触发。AI 触发丢弃（先 PvP/PvP3 人类），链中 AI 卡设首合法槽。
# 弹窗经 action_ui_bridge.request_ui_popup 双端 emit，app_root 按 local_player_id 过滤（PvP 锁步）。

## 抽到的装备牌可设置的合法槽位（静态版 TimingEngine._valid_set_slots_for_drawn_card，链模块共用）：
## PART -> 对应槽位(card.def.slot) + 备用区；WEAPON -> 武器槽 + 备用区。含已占用槽（允许替换）。
static func responded_equip_valid_slots(mech, card) -> Array:
	var result: Array = []
	if mech == null or card == null or card.def == null:
		return result
	var kind_val = card.def.get("equipment_kind")
	var kind: StringName = kind_val if kind_val != null else &"PART"
	if kind == &"WEAPON":
		for ws_id in [&"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2"]:
			if mech.slots.has(ws_id):
				result.append(ws_id)
	else:
		var spec_slot_raw = card.def.get("slot")
		var spec_slot: StringName = StringName(spec_slot_raw) if spec_slot_raw != null else &""
		if spec_slot != &"" and mech.slots.has(spec_slot):
			result.append(spec_slot)
		for rs_id in [&"reserve_1", &"reserve_2"]:
			if mech.slots.has(rs_id):
				result.append(rs_id)
	return result


## 装备牌面 cost（弃置获金数额）。无 cost 字段返回 0。
static func responded_equip_card_cost(card) -> int:
	if card == null or card.def == null:
		return 0
	var c = card.def.get("cost")
	return int(c) if c != null else 0


## 弃置获金：弃掉抽到的装备牌（走 discard_card 动作发 DISCARD 时点）+ 我方获得牌面 cost 金币。
static func responded_equip_discard_and_gold(context, player_id: StringName, card_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	var cost := 0
	var card = context.game_state.get_card(card_id)
	if card != null:
		cost = responded_equip_card_cost(card)
	if context.action_service != null:
		context.action_service.execute(&"discard_card", {
			"card_ids": [card_id], "count": 1,
			"player_id": player_id, "executor": player_id, "reason": &"pilot_056_unset_discard",
		})
	if cost > 0 and context.game_actions != null:
		context.game_actions.gain_gold({"player_id": player_id, "amount": cost, "reason": &"pilot_056_unset_gold"})


## 开始逐张处理链：记录归属与抽到的装备牌（按抽到顺序），从第一张开始处理。
static func responded_equip_start_chain(context, player_id: StringName, mech_id: StringName, card_ids: Array) -> void:
	if context == null or context.game_state == null:
		return
	context.game_state.responded_equip_chain = {
		"owner_player_id": player_id,
		"owner_mech_id": mech_id,
		"card_ids": card_ids.duplicate(),
		"index": 0,
	}
	responded_equip_process_current_card(context)


## 处理当前卡：全部处理完 -> 清链 + 处理队列下一触发；人类弹「设置/弃置获金」面板；AI 设首合法槽。
static func responded_equip_process_current_card(context) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	var chain: Dictionary = gs.responded_equip_chain
	if chain.is_empty():
		return
	var card_ids: Array = chain.get("card_ids", [])
	var index: int = int(chain.get("index", 0))
	if index >= card_ids.size():
		gs.responded_equip_chain = {}
		responded_equip_process_next(context)
		return
	var pid: StringName = chain.get("owner_player_id", &"")
	var mid: StringName = chain.get("owner_mech_id", &"")
	var card_id: StringName = card_ids[index]
	if pid == &"" or mid == &"" or card_id == &"":
		responded_equip_advance_chain(context)
		return
	var player = gs.players.get(pid)
	if player == null or not player.is_human:
		# AI 玩家：先不处理（用户指定忽略 AI），设首合法槽后跳过防卡死
		var ai_mech = gs.mechs.get(mid)
		var ai_card = gs.get_card(card_id)
		if ai_mech != null and ai_card != null and ai_card.def != null and context.action_service != null:
			var ai_slots := responded_equip_valid_slots(ai_mech, ai_card)
			if not ai_slots.is_empty():
				context.action_service.execute(&"set_equipment", {
					"card_id": card_id, "mech_id": mid, "slot_id": ai_slots[0],
					"source": {"player_id": pid, "mech_id": mid, "card_instance_id": card_id},
				})
		responded_equip_advance_chain(context)
		return
	var mech = gs.mechs.get(mid)
	var card = gs.get_card(card_id)
	if card == null or card.def == null:
		# 抽到的牌已不在（被 effect_02 等移走）：跳过该张
		responded_equip_advance_chain(context)
		return
	var slots: Array = responded_equip_valid_slots(mech, card)
	var cost := responded_equip_card_cost(card)
	if context.action_ui_bridge != null:
		context.action_ui_bridge.request_ui_popup.emit(&"responded_equip_card_set", {
			"player_id": pid, "mech_id": mid, "card_id": card_id,
			"valid_slots": slots, "sell_price": cost,
		})


## 玩家对某张抽到装备做出选择（面板回调，双端锁步执行）：
## result.slot_id 非空 = 设置到该槽（set_equipment 动作）；否则 = 弃置获金。然后推进链。
static func responded_equip_card_resume(context, player_id: StringName, mech_id: StringName, card_id: StringName, result: Dictionary) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	var chain: Dictionary = gs.responded_equip_chain
	if chain.is_empty():
		return
	# 陈旧回调守卫：当前链的归属/当前卡与回调一致才处理（多触发串行防错位）
	if String(chain.get("owner_player_id", &"")) != String(player_id) or String(chain.get("owner_mech_id", &"")) != String(mech_id):
		return
	var card_ids: Array = chain.get("card_ids", [])
	var index: int = int(chain.get("index", 0))
	if index >= card_ids.size():
		return
	if String(card_ids[index]) != String(card_id):
		return
	var slot_id: StringName = result.get("slot_id", &"")
	if slot_id != &"" and context.action_service != null:
		context.action_service.execute(&"set_equipment", {
			"card_id": card_id, "mech_id": mech_id, "slot_id": slot_id,
			"source": {"player_id": player_id, "mech_id": mech_id, "card_instance_id": card_id},
		})
	else:
		responded_equip_discard_and_gold(context, player_id, card_id)
	responded_equip_advance_chain(context)


## 推进链到下一张卡（全部处理完时 process_current_card 负责清链收尾）。
static func responded_equip_advance_chain(context) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	if gs.responded_equip_chain.is_empty():
		return
	gs.responded_equip_chain["index"] = int(gs.responded_equip_chain.get("index", 0)) + 1
	responded_equip_process_current_card(context)


## 初始确认（链/确认进行中不弹新确认；队列空不动作）：AI 触发丢弃，人类弹「是否发动」。
static func responded_equip_process_next(context) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	# 链/确认进行中：等当前处理完再弹下一个（串行防重叠）
	if not gs.responded_equip_chain.is_empty():
		return
	if not gs.responded_equip_pending_confirm.is_empty():
		return
	if gs.responded_equip_queue.is_empty():
		return
	var entry: Dictionary = gs.responded_equip_queue.pop_front()
	var pid: StringName = entry.get("player_id", &"")
	var mid: StringName = entry.get("mech_id", &"")
	if pid == &"" or mid == &"":
		responded_equip_process_next(context)
		return
	var player = gs.players.get(pid)
	if player == null or not player.is_human:
		# AI 玩家触发：先不处理（用户指定忽略 AI），直接丢弃防卡死
		responded_equip_process_next(context)
		return
	gs.responded_equip_pending_confirm = {"player_id": pid, "mech_id": mid}
	if context.action_ui_bridge != null:
		context.action_ui_bridge.request_ui_popup.emit(&"responded_equip_confirm", {"player_id": pid, "mech_id": mid})


## 被响应攻击结算后触发回调（攻击动作完成后由 ActionService 派发）：入队 + 尝试处理。
static func responded_equip_after_attack_completed(context, player_id: StringName, mech_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	context.game_state.responded_equip_queue.append({"player_id": player_id, "mech_id": mech_id})
	responded_equip_process_next(context)


## 初始确认（app_root 弹窗后经 responded_equip_confirm op 双端执行）：
## accept = 抽2张装备牌并进入逐张「设置/弃置获金」链；cancel = 无事发生。
## 抽牌走 gain_card 动作（发 GAIN_CARD 时点，统一抽牌口径）。同步完成读 record.drawn_card_ids；
## 暂停（GAIN_CARD 时点监听/即时使用挂起）则钩子等动作完成后再读手牌新增部分。
static func responded_equip_confirm(context, player_id: StringName, mech_id: StringName, accept: bool) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	var pending: Dictionary = gs.responded_equip_pending_confirm
	if not (pending is Dictionary) or pending.is_empty():
		return
	# 陈旧确认守卫：确认的 mech/player 与待确认触发一致才处理
	if String(pending.get("player_id", &"")) != String(player_id) or String(pending.get("mech_id", &"")) != String(mech_id):
		return
	gs.responded_equip_pending_confirm = {}
	if not accept:
		responded_equip_process_next(context)
		return
	# 先快照手牌，抽完后取新增部分作为抽到的装备牌（含被 effect_02 移走的跳过）
	var p = gs.players.get(player_id)
	var before: Array = []
	if p != null and p.equipment_hand != null:
		before = p.equipment_hand.duplicate()
	var result: Dictionary = {}
	if context.action_service != null:
		result = context.action_service.execute(&"gain_card", {
			"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 2,
			"player_id": player_id, "reason": &"pilot_056_after_attack",
		})
	var drawn: Array = result.get("record", {}).get("drawn_card_ids", [])
	if result.get("state", &"") == &"completed" or result.is_empty():
		if drawn.is_empty() and p != null and p.equipment_hand != null:
			drawn = p.equipment_hand.slice(before.size())
		responded_equip_start_chain(context, player_id, mech_id, drawn)
		responded_equip_process_next(context)
		return
	# 暂停：等 gain_card 动作完成后（action_completed，call_deferred）再取手牌新增部分
	var gain_action_id: StringName = result.get("action_id", &"")
	if gain_action_id == &"":
		responded_equip_start_chain(context, player_id, mech_id, drawn)
		responded_equip_process_next(context)
		return
	var cb := Callable(func() -> void:
		var p2 = context.game_state.players.get(player_id)
		var drawn2: Array = []
		if p2 != null and p2.equipment_hand != null:
			drawn2 = p2.equipment_hand.slice(before.size())
		responded_equip_start_chain(context, player_id, mech_id, drawn2)
		responded_equip_process_next(context))
	context.action_service.run_after_action_completed(gain_action_id, cb)


## ────────────────────────────────────────────────────────────
## 铠德 pilot_062 通用「被响应→三选一」非阻塞模块（pilot_062_*，不绑机师）
## 复刻铠厉 responded_equip_chain_* 结构：攻击结算后入队 → 弹三选一 → 执行所选分支原子动作。
## 分支：0=抽2张行动牌（gain_card 动作，发 GAIN_CARD 时点/统一抽牌口径）/
##       1=回复3动力（restore_power）/ 2=获得4金币（gain_gold）/ 其它=放弃。
## 只处理人类玩家（PvP/PvP3），AI 触发直接丢弃防卡死。
static func pilot_062_after_attack_completed(context, player_id: StringName, mech_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	context.game_state.pilot_062_queue.append({"player_id": player_id, "mech_id": mech_id})
	pilot_062_process_next(context)


## 推进三选一队列：进行中有 pending 不弹新；队列空/条目无效/AI 触发直接跳过。
static func pilot_062_process_next(context) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	# 已有待选弹窗：等当前处理完再弹下一个（串行防重叠）
	if not gs.pilot_062_pending_choice.is_empty():
		return
	if gs.pilot_062_queue.is_empty():
		return
	var entry: Dictionary = gs.pilot_062_queue.pop_front()
	var pid: StringName = entry.get("player_id", &"")
	var mid: StringName = entry.get("mech_id", &"")
	if pid == &"" or mid == &"":
		pilot_062_process_next(context)
		return
	var player = gs.players.get(pid)
	if player == null or not player.is_human:
		# AI 玩家触发：先不处理（用户指定忽略 AI），直接丢弃防卡死
		pilot_062_process_next(context)
		return
	gs.pilot_062_pending_choice = {"player_id": pid, "mech_id": mid}
	if context.action_ui_bridge != null:
		context.action_ui_bridge.request_ui_popup.emit(&"pilot_062_choice", {"player_id": pid, "mech_id": mid})


## 三选一确认（app_root 弹窗后经 pilot_062_choice op 双端执行）：choice=0/1/2 执行对应奖励，其它=放弃。
static func pilot_062_choose(context, player_id: StringName, mech_id: StringName, choice: int) -> void:
	if context == null or context.game_state == null:
		return
	var gs = context.game_state
	var pending: Dictionary = gs.pilot_062_pending_choice
	if not (pending is Dictionary) or pending.is_empty():
		return
	# 陈旧确认守卫：确认的 mech/player 与待选触发一致才处理
	if String(pending.get("player_id", &"")) != String(player_id) or String(pending.get("mech_id", &"")) != String(mech_id):
		return
	gs.pilot_062_pending_choice = {}
	if choice == 0:
		# 抽2张行动牌：走 gain_card 动作（发 GAIN_CARD 时点，统一抽牌口径）。
		# 暂停（GAIN_CARD 时点监听挂起）则动作自行完成，无链式处理，忽略返回值。
		if context.action_service != null:
			context.action_service.execute(&"gain_card", {
				"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
				"player_id": player_id, "reason": &"pilot_062_draw",
			})
	elif choice == 1:
		# 回复3动力（走 restore_power，受 CANNOT_RESTORE_POWER/最大动力限制）
		if context.game_actions != null:
			context.game_actions.restore_power({"mech_id": mech_id, "amount": 3, "reason": &"pilot_062_power"})
	elif choice == 2:
		# 获得4金币
		if context.game_actions != null:
			context.game_actions.gain_gold({"player_id": player_id, "amount": 4, "reason": &"pilot_062_gold"})
	# 其它 choice（放弃）：无事发生
	pilot_062_process_next(context)


# ════════════════════════════════════════════════════════════
# 通用「范围内机甲受伤→确认→回复生命+抽行动牌」模块
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 效果定义：build_injury_heal_draw_effect(params) 参数化构建（改 params 复用）。
#   - 触发：LISTEN HP_CHANGE_SETTLE，条件=掉血(decrease)>0 + 目标机甲在持有者 base_range 格内
#     【含自身】HP_CHANGE_TARGET_WITHIN_RANGE_INCLUDING_SELF；每回合 once_per_turn_max 次
#     （确认发动才消耗，取消不消耗；每玩家回合自动重置）。
#   - 执行：INJURY_HEAL_DRAW（TimingEngine 状态机 handler）弹确认窗给持有者玩家，
#     确认 -> 串行 [EXECUTE_HP_CHANGE 受伤机甲回复 heal_amount(来源=持有者机甲),
#     EXECUTE_GAIN_CARD 受伤机甲所属玩家抽 draw_count 张行动牌]。
# 用法：任何「范围内（含自身）机甲受到伤害后，每回合N次使其回复X生命并抽Y行动牌」效果
#   直接复制构建调用 + 改 params 复用。
static func build_injury_heal_draw_effect(params: Dictionary) -> _ActionEffect:
	var e := _ActionEffect.new()
	e.effect_id = params.get("effect_id", &"")
	e.display_name = params.get("display_name", "受伤回复")
	e.description = params.get("description", "")
	e.mode = _TC.MODE_LISTEN
	e.priority = int(params.get("priority", 10))
	e.listen_timing = _TC.HP_CHANGE_SETTLE
	e.listen_action_type = &"hp_change"
	e.once_per_turn_key = params.get("once_per_turn_key", e.effect_id)
	e.once_per_turn_max = int(params.get("once_per_turn_max", 2))
	e.set_conditions([
		{"op": &"HP_CHANGE_LIVE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"HP_CHANGE_AMOUNT_ABOVE", "params": {"threshold": 0}},
		{"op": &"HP_CHANGE_TARGET_WITHIN_RANGE_INCLUDING_SELF", "params": {"base_range": int(params.get("base_range", 3))}},
	])
	e.set_target_rules([{"rule": &"NO_TARGET"}])
	e.set_costs([])
	e.set_actions([{
		"type": &"INJURY_HEAL_DRAW",
		"params": {
			"heal_amount": int(params.get("heal_amount", 2)),
			"draw_count": int(params.get("draw_count", 1)),
			"once_per_turn_key": params.get("once_per_turn_key", e.effect_id),
			"confirm_text": params.get("confirm_text", ""),
		},
	}])
	return e


## 通用「范围内攻击结算→抽牌+每回合1次弃X再开攻击窗口」效果构建器（维奥拉 pilot_074 等）。
## 参数化复用：改 params 即可（effect_id/display_name/description/base_range/draw_count/
## discard_count/once_per_turn_key/once_per_turn_max/priority）。
## LISTEN ATTACK_SETTLE（条件 ATTACK_ATTACKER_WITHIN_RANGE_INCLUDING_SELF 已校验攻击方在
## base_range 内含自身）→ 状态机 ATTACK_SETTLE_DRAW_REATTACK（TimingEngine）：
##   触发先抽 draw_count 张行动牌（强制）→ 每回合1次弹多选窗弃 discard_count 张（可取消不计次数）
##   → 给攻击方开凯威攻击窗口（attack_window_open，伏特式转化攻击也可用，可中途取消）。
static func build_attack_settle_draw_discard_reattack_effect(params: Dictionary) -> _ActionEffect:
	var e := _ActionEffect.new()
	e.effect_id = params.get("effect_id", &"")
	e.display_name = params.get("display_name", "攻击结算抽牌再攻")
	e.description = params.get("description", "")
	e.mode = _TC.MODE_LISTEN
	e.priority = int(params.get("priority", 10))
	e.listen_timing = _TC.ATTACK_SETTLE
	e.listen_action_type = &"attack"
	# 每回合1次只作用于「弃X再攻击」部分（内部状态机门控：_asdr_offer_discard 检查 +
	# resume 确认才 mark），触发时的抽牌是强制的、无次数限制——故不在效果级限次数，
	# 否则本回合第二次结算时整个效果（含强制抽牌）都会被 once_per_turn_used_up 跳过。
	e.once_per_turn_key = &""
	e.once_per_turn_max = 0
	e.set_conditions([
		{"op": &"ATTACK_ATTACKER_WITHIN_RANGE_INCLUDING_SELF", "params": {"base_range": int(params.get("base_range", 3))}},
	])
	e.set_target_rules([{"rule": &"NO_TARGET"}])
	e.set_costs([])
	e.set_actions([{
		"type": &"ATTACK_SETTLE_DRAW_REATTACK",
		"params": {
			"draw_count": int(params.get("draw_count", 1)),
			"discard_count": int(params.get("discard_count", 2)),
			"once_per_turn_key": params.get("once_per_turn_key", e.effect_id),
		},
	}])
	return e


# ════════════════════════════════════════════════════════════
# "原价购买"模块（每回合N次以原价购买商店装备）
# ════════════════════════════════════════════════════════════
# 通用可复用、与效果绑定不绑机师：
#   - 效果定义：build_face_value_buy_effect(params) 参数化构建（改 params 复用）。
#   - 次数存储：卡牌实例计数器 FACE_VALUE_BUY_COUNTER_KEY（SET_CARD_COUNTER 在持有者
#     回合开始 TURN_START 重置为 per_turn）。任意带此效果的卡（当前=机师牌）即生效。
#   - 查询/消耗：get_face_value_buy_uses / consume_face_value_buy_use（ShopService 委托调用）。
#   - 商店弹窗：app_root 按 get_face_value_buy_uses 的 uses 追加独立"用X原价购买"选项
#     （与折扣 DISCOUNT 状态互不影响）；购买走 ShopService 时 consume 消耗1次。
const FACE_VALUE_BUY_COUNTER_KEY := &"face_value_buy_uses"


## 获取指定玩家"原价购买"剩余次数 + 来源卡名（商店弹窗选项标签用）。
## 扫描该玩家机甲所有已装备卡（含机师槽）中带 FACE_VALUE_BUY_COUNTER_KEY 计数器的牌。
static func get_face_value_buy_uses(game_state, player_id: StringName) -> Dictionary:
	if game_state == null or player_id == &"":
		return {"uses": 0, "source_name": ""}
	var mech = game_state.get_mech_for_player(player_id)
	if mech == null:
		return {"uses": 0, "source_name": ""}
	var total: int = 0
	var source_name: String = ""
	for slot in mech.slots.values():
		var c = slot.equipped_card
		if c == null or not ("counters" in c):
			continue
		var n: int = int(c.counters.get(FACE_VALUE_BUY_COUNTER_KEY, 0))
		if n <= 0:
			continue
		total += n
		if source_name == "" and c.def != null:
			source_name = String(c.def.display_name)
	return {"uses": total, "source_name": source_name}


## 消耗1次"原价购买"次数（ShopService 购买原价时调用）。返回是否消耗成功。
static func consume_face_value_buy_use(game_state, player_id: StringName) -> bool:
	if game_state == null or player_id == &"":
		return false
	var mech = game_state.get_mech_for_player(player_id)
	if mech == null:
		return false
	for slot in mech.slots.values():
		var c = slot.equipped_card
		if c == null or not ("counters" in c):
			continue
		var n: int = int(c.counters.get(FACE_VALUE_BUY_COUNTER_KEY, 0))
		if n > 0:
			c.counters[FACE_VALUE_BUY_COUNTER_KEY] = n - 1
			return true
	return false


## 通用"每回合N次以原价购买商店装备"效果构建器（LISTEN TURN_START，持有者回合开始重置次数）。
## params：effect_id / display_name / description / per_turn(每回合次数，默认2) / priority(默认10)。
## 复用：复制构建调用 + 改 params 即可；任何"每回合N次原价购买"效果通用（不绑机师）。
static func build_face_value_buy_effect(params: Dictionary) -> _ActionEffect:
	var e := _ActionEffect.new()
	e.effect_id = params.get("effect_id", &"")
	e.display_name = params.get("display_name", "原价购买")
	e.description = params.get("description", "")
	e.mode = _TC.MODE_LISTEN  # 被动展示按钮（置灰+悬停说明），持有者回合开始重置次数
	e.priority = int(params.get("priority", 10))
	e.listen_timing = _TC.TURN_START
	e.listen_action_type = &"turn"
	# 注册即初始化次数（仅当键不存在）：中途换上机师牌无需等下回合 TURN_START 立即可用
	e.init_counters = {FACE_VALUE_BUY_COUNTER_KEY: int(params.get("per_turn", 2))}
	e.set_conditions([{"op": &"IS_OWNER_TURN"}])
	e.set_target_rules([{"rule": &"NO_TARGET"}])
	e.set_costs([])
	e.set_actions([{
		"type": &"SET_CARD_COUNTER",
		"params": {"key": FACE_VALUE_BUY_COUNTER_KEY, "value": int(params.get("per_turn", 2))},
	}])
	return e


# ════════════════════════════════════════════════════════════
# pilot_086 塔妮拉「交」标签系统
# ════════════════════════════════════════════════════════════
# PILOT_087_JIAO_TAG "交"：塔妮拉效果1交牌时（GameActions.transfer_action_cards 挂钩）打在
#   行动牌上（owner=塔妮拉玩家），跨玩家转出/被偷（steal_action_card 挂钩）也计入。
#   持有方使用带"交"标签的牌（discard_card_action._step_transfer_to_pile 检测 from_zone==temp_zone，
#   即通用"使用"判定，含迪恩转化代价牌等）→ 使用方先抽1 + 塔妮拉后抽1（各走 EXECUTE_GAIN_CARD
#   子动作串行），"交"标签随牌入弃牌堆消失。
#   仿塔莉娅"策"标签模式（多 owner 用 owner_pid 区分）。手牌直接弃置（from_zone==action_hand，
#   如回合超限/预判/肯特压制等）不触发抽牌，仅清"交"标签。
#   塔妮拉离场（GameSetupService _on_pilot_unset）清其名下全部"交"标签（他人持有的交牌
#   不再触发其抽1）。

const PILOT_087_JIAO_TAG := &"pilot_086_jiao_tag"


## 打"交"标签（效果1交牌 / 识破偷牌 / 玛丽尔偷牌等 transfer/steal 挂钩调用）。
static func pilot_086_tag_jiao(card, owner_pid: StringName) -> void:
	if card == null or owner_pid == &"" or not card.has_method(&"add_tag"):
		return
	card.add_tag(PILOT_087_JIAO_TAG, owner_pid, {"jiao": true})


## 牌是否有任意 owner 的"交"标签（UI 显示"牌名(交)"后缀）。
static func pilot_086_card_has_any_jiao(card) -> bool:
	if card == null or not card.has_method(&"has_tag"):
		return false
	return card.has_tag(PILOT_087_JIAO_TAG)


## 清全部 owner 的"交"标签（牌入弃牌堆标签即消失，无论使用/直接弃置）。
static func pilot_086_clear_all_jiao(card) -> void:
	if card == null or not card.has_method(&"remove_tag"):
		return
	card.remove_tag(PILOT_087_JIAO_TAG)


## 清指定玩家（塔妮拉拥有者）名下的全部"交"标签（塔妮拉离场时：他人持有的交牌不再触发其抽1）。
static func pilot_086_clear_all_jiao_for_player(game_state, player_id: StringName) -> void:
	if game_state == null or player_id == &"":
		return
	var cards_dict: Dictionary = game_state.cards if "cards" in game_state else {}
	for card in cards_dict.values():
		if card == null or not card.has_method(&"remove_tag"):
			continue
		if card.has_tag(PILOT_087_JIAO_TAG, player_id):
			card.remove_tag(PILOT_087_JIAO_TAG, player_id)


## from_player 是否装备塔妮拉机师牌（转移/偷牌挂钩条件判断：只有塔妮拉手牌转出才打交标签）。
## 返回 player_id（装备塔妮拉则原样返回，否则 &""）。仿 pilot_022_taliyah_owner_for_player 模板。
static func pilot_086_tanila_owner_for_player(game_state, player_id: StringName) -> StringName:
	if game_state == null or player_id == &"":
		return &""
	var mech = game_state.get_mech_for_player(player_id) if game_state.has_method(&"get_mech_for_player") else null
	if mech == null:
		return &""
	var slot = mech.slots.get(&"pilot") if "slots" in mech and mech.slots != null else null
	if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
		return &""
	if String(slot.equipped_card.def.card_id) == "pilot_086_塔妮拉":
		return player_id
	return &""


## 持有者使用带"交"标签的牌 → 触发双方各抽1（使用方先抽1，塔妮拉后抽1）。
## 牌从 temp_zone 进 discard 堆时由 discard_card_action._step_transfer_to_pile 调用。
## 多塔妮拉场景：按 owner 各自作为"塔妮拉"抽1（每 owner 独立发一次塔妮拉抽）。
## 返回触发抽牌的 owner 数（用于日志）。使用方为卡牌当前 owner_player_id（使用时刻）。
static func pilot_086_trigger_jiao_draw(context, card) -> int:
	if context == null or context.game_state == null or card == null:
		return 0
	if not card.has_tag(PILOT_087_JIAO_TAG):
		return 0
	# 收集所有 owner（多塔妮拉场景各自抽1）
	var owners: Array = card.get_tag_owners(PILOT_087_JIAO_TAG) if card.has_method(&"get_tag_owners") else []
	if owners.is_empty():
		return 0
	# 使用方（卡的当前持有者，先抽1）
	var user_pid: StringName = card.owner_player_id
	var count: int = 0
	# 1) 使用方先抽1（仅在 user_pid 有效且 game_state 有该玩家时）
	if user_pid != &"" and context.game_state.players.has(user_pid):
		if context.action_service != null:
			context.action_service.execute(&"gain_card", {
				"from_zone": &"action_deck", "card_kind": &"action",
				"count": 1, "player_id": user_pid, "reason": &"pilot_086_jiao_draw_user",
			})
	# 2) 每个 owner 各抽1（塔妮拉后抽1；与使用方同 owner 时不重复抽）
	for owner_pid: StringName in owners:
		if owner_pid == &"" or not context.game_state.players.has(owner_pid):
			continue
		if owner_pid == user_pid:
			# 使用方本身就是塔妮拉拥有者：上面已抽过1，不再重复（仅记一次触发）
			count += 1
			continue
		if context.action_service != null:
			context.action_service.execute(&"gain_card", {
				"from_zone": &"action_deck", "card_kind": &"action",
				"count": 1, "player_id": owner_pid, "reason": &"pilot_086_jiao_draw_tanila",
			})
		count += 1
	# 清全部交标签（牌入弃牌堆，标签消失）
	card.remove_tag(PILOT_087_JIAO_TAG)
	return count

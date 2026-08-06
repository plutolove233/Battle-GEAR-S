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


## pilot_005 肯特：帝国机甲动力+4（实时重算，MechState.get_total_power 调用）
static func get_pilot_005_empire_power_bonus(mech) -> int:
	return get_faction_pilot_aura_bonus(mech, "帝国", &"pilot_005_肯特", 4)


## pilot_002 莱比尔：联邦机甲护甲+4（实时重算，MechState.get_armor 调用）
static func get_pilot_002_federation_armor_bonus(mech) -> int:
	return get_faction_pilot_aura_bonus(mech, "联邦", &"pilot_002_莱比尔", 4)


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


# ════════════════════════════════════════════════════════════
# pilot_006 里昂 悬赏目标标记（effect_01 轮次悬赏 + effect_02 悬赏追击 共享）
# ════════════════════════════════════════════════════════════
## source pilot 设置后每轮 ROUND_START 选1台其他机甲为本轮悬赏目标。
## 存 {source_pilot_instance: {target, round_id}}，换机师清除。
static var _pilot_006_marks: Dictionary = {}


static func set_pilot_006_mark(source_pilot_instance: StringName, target_mech_id: StringName, round_id: int) -> void:
	_pilot_006_marks[source_pilot_instance] = {"target": target_mech_id, "round": round_id}


static func get_pilot_006_mark(source_pilot_instance: StringName) -> StringName:
	var entry: Dictionary = _pilot_006_marks.get(source_pilot_instance, {})
	return entry.get("target", &"")


static func clear_pilot_006_mark(source_pilot_instance: StringName) -> void:
	_pilot_006_marks.erase(source_pilot_instance)


## pilot_006 effect_02：抽1张行动牌，若为攻击牌则挂 passive_attack_bonus 标记（不计回合攻击数，持续到离手）。
## 裁定（歧义1）：抽到攻击牌不立即使用，只挂增益。
static func pilot_006_tag_if_attack(card) -> void:
	if card == null or card.def == null:
		return
	if String(card.def.action_type) == "攻击":
		if not "counters" in card:
			card.counters = {}
		card.counters["passive_attack_bonus"] = true


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
	p010e1.listen_action_type = &"turn_cycle"
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
	# 当前活动回合内，刻托使用的第1张实体攻击牌替换为强袭，第2张替换为闪击，第3张替换为预判。
	# 裁定：视为（出牌后替换，保留 USE_ACTION_*，攻击仍计回合攻击数）；虚拟当作不计数/不替换；
	# 每活动回合各自重置；牌进临时区即计数（取消也计）。第4张由 effect_03 在 validate 拦截。
	# REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE 设 as_card_def_id 让 _step_execute_effects 用具名牌 effect 链。
	var p010e2 := _ActionEffect.new()
	p010e2.effect_id = &"pilot_010_effect_02"
	p010e2.display_name = "三段演算"
	p010e2.description = "刻托使用的第1张实体攻击牌视为强袭，第2张视为闪击，第3张视为预判。"
	p010e2.mode = _TC.MODE_LISTEN
	p010e2.priority = 20
	p010e2.listen_timing = _TC.USE_ACTION_AT
	p010e2.listen_action_type = &"use_action_card"
	p010e2.set_conditions([
		{"op": &"USED_CARD_EXECUTOR_IS_SELF"},
		{"op": &"USED_CARD_TYPE_IS", "params": {"card_type": &"攻击"}},
		{"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"OWNER_ATTACK_CARD_USE_INDEX_THIS_TURN_BELOW", "params": {"max_index": 4}},
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

	# ── pilot_004_effect_01 装甲转能 ──
	# 每回合开始（任意玩家回合）可选转化 N 护甲为 N 动力（增加动力上限并补满），每完整3点抽2张。
	# 裁定（歧义1）：转化动力增加上限并补满，护甲减少上限；跨回合持久到下个我方 TURN_BEFORE_START 清。
	# 裁定（歧义5）：任意玩家回合开始均触发。
	# 护甲 -N: ARMOR_MODIFIER(duration=UNTIL_NEXT_OWNER_TURN, runtime_tag=pilot_004_armor_conversion)。
	# 动力 +N: POWER_CAP_MODIFIER(mode=cap_bonus, runtime_tag=pilot_004_power_conversion)，get_total_power 算入。
	var p004e1 := _ActionEffect.new()
	p004e1.effect_id = &"pilot_004_effect_01"
	p004e1.display_name = "装甲转能"
	p004e1.description = "每回合开始时，可将护甲转化为动力（增加动力上限并补满），每完整3点立即抽2张。"
	p004e1.mode = _TC.MODE_LISTEN
	p004e1.priority = 10
	p004e1.listen_timing = _TC.TURN_START
	p004e1.listen_action_type = &"turn_cycle"
	p004e1.set_conditions([
		{"op": &"SELF_MECH_ALIVE"},
		{"op": &"SELF_EFFECTIVE_ARMOR_ABOVE", "params": {"threshold": 0}},
	])
	p004e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p004e1.set_costs([])
	p004e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "将护甲转化为动力",
				"actions": [{
					"type": &"CHOOSE_INTEGER",
					"params": {
						"label": "选择要转化的护甲数",
						"min_value": 1,
						"max_value_expr": "$binding_context.mech_effective_armor",
						"bind_as": "n",
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
							{"type": &"DRAW_ACTION", "params": {
								"count_expr": "floor($choice.n / 3) * 2",
								"target_mech_id": "$binding_context.mech_id",
								"reason": &"pilot_004_armor_conversion",
							}},
						],
					}
				}]
			}]
		}
	}])
	effects[p004e1.effect_id] = p004e1

	# ── pilot_004_effect_02 护甲恢复 ──
	# 仅当即将开始的是机师拥有者回合时，清除本机师实例建立的全部转换层（护甲/动力 modifier）。
	# priority 30 先于回合动力回复。裁定：转化层持久到下个我方 TURN_BEFORE_START。
	var p004e2 := _ActionEffect.new()
	p004e2.effect_id = &"pilot_004_effect_02"
	p004e2.display_name = "护甲恢复"
	p004e2.description = "下个我方回合即将开始时，清除护甲转动力层，护甲与动力上限恢复。"
	p004e2.mode = _TC.MODE_LISTEN
	p004e2.priority = 30
	p004e2.listen_timing = _TC.TURN_BEFORE_START
	p004e2.listen_action_type = &"turn_cycle"
	p004e2.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"SOURCE_RUNTIME_MODIFIER_EXISTS", "params": {"tag": &"pilot_004_armor_conversion"}},
	])
	p004e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p004e2.set_costs([])
	p004e2.set_actions([{
		"type": &"CLEAR_SOURCE_STAT_MODIFIERS",
		"params": {
			"mech_id": "$binding_context.mech_id",
			"source_card_id": "$binding_context.card_instance_id",
			"runtime_tags": [&"pilot_004_armor_conversion", &"pilot_004_power_conversion"],
		}
	}])
	effects[p004e2.effect_id] = p004e2

	# ── pilot_004_effect_03a 攻击方动力代护甲 ──
	# 我方攻击时，可支付3动力，使本次攻击伤害计算用目标当前动力代替护甲。
	# 裁定（歧义3）：攻击/被攻击都是玛沙效果；每个目标用其自身当前动力代替自身护甲。
	# 裁定（歧义4）：被攻击分支用支付后动力（_step_calculate_damage 在 ATTACK_PRE 支付后读 target.power）。
	var p004e3a := _ActionEffect.new()
	p004e3a.effect_id = &"pilot_004_effect_03a"
	p004e3a.display_name = "动力穿透(攻)"
	p004e3a.description = "我方攻击时，可消耗3动力，使本次攻击伤害计算用目标当前动力代替护甲。"
	p004e3a.mode = _TC.MODE_LISTEN
	p004e3a.priority = 20
	p004e3a.listen_timing = _TC.ATTACK_PRE
	p004e3a.listen_action_type = &"attack"
	p004e3a.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "params": {"threshold": 3}},
	])
	p004e3a.set_target_rules([{"rule": &"NO_TARGET"}])
	p004e3a.set_costs([{"cost_type": &"SPEND_POWER", "amount": 3, "optional": true}])
	p004e3a.set_actions([{
		"type": &"SET_ATTACK_DEFENSE_STAT_SOURCE",
		"params": {
			"target_id": "$payload.target_id",
			"stat_source": &"current_power",
		}
	}])
	effects[p004e3a.effect_id] = p004e3a

	# ── pilot_004_effect_03b 被攻击方动力代护甲 ──
	var p004e3b := _ActionEffect.new()
	p004e3b.effect_id = &"pilot_004_effect_03b"
	p004e3b.display_name = "动力穿透(守)"
	p004e3b.description = "被攻击时，可消耗3动力，使本次攻击伤害计算用自身支付后当前动力代替护甲。"
	p004e3b.mode = _TC.MODE_LISTEN
	p004e3b.priority = 20
	p004e3b.listen_timing = _TC.ATTACK_PRE
	p004e3b.listen_action_type = &"attack"
	p004e3b.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "params": {"threshold": 3}},
	])
	p004e3b.set_target_rules([{"rule": &"NO_TARGET"}])
	p004e3b.set_costs([{"cost_type": &"SPEND_POWER", "amount": 3, "optional": true}])
	p004e3b.set_actions([{
		"type": &"SET_ATTACK_DEFENSE_STAT_SOURCE",
		"params": {
			"target_id": "$payload.target_id",
			"stat_source": &"current_power",
		}
	}])
	effects[p004e3b.effect_id] = p004e3b

	# ═══════════════════════════════════════════
	# pilot_005 肯特（帝国 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_005_effect_03 帝国光环开关（toggle）──
	# 我方回合1次，选择场上1台机甲，切换其是否获得本肯特实例提供的动力+4与授予能力。
	# 裁定（歧义3）：toggle 只影响本来源；非联邦机甲可记录开关但当下无收益。
	var p005e3 := _ActionEffect.new()
	p005e3.effect_id = &"pilot_005_effect_03"
	p005e3.display_name = "帝国光环开关"
	p005e3.description = "我方回合1次，选择1台机甲，切换其是否获得本肯特实例的帝国光环。"
	p005e3.mode = _TC.MODE_DIRECT
	p005e3.priority = 10
	p005e3.once_per_turn_key = &"pilot_005_effect_03"
	p005e3.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ANY_MECH_ON_FIELD"},
	])
	p005e3.set_target_rules([{"rule": &"TARGET_IS_MECH"}])
	p005e3.set_costs([])
	p005e3.set_actions([{
		"type": &"TOGGLE_AURA_TARGET",
		"params": {
			"toggle": &"toggle",
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
	p005_granted.description = "攻击或被攻击时，可消耗4动力，弃置对侧2张行动牌（不足2弃全部）。"
	p005_granted.mode = _TC.MODE_LISTEN
	p005_granted.priority = 20
	p005_granted.listen_timing = _TC.ATTACK_PRE
	p005_granted.listen_action_type = &"attack"
	p005_granted.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER_OR_TARGET"},
		{"op": &"PILOT_AURA_ACTIVE_FOR_MECH"},
		{"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "params": {"threshold": 4}},
		{"op": &"OPPOSING_ATTACK_PARTICIPANT_ACTION_HAND_ABOVE", "params": {"threshold": 1}},
	])
	p005_granted.set_target_rules([{"rule": &"NO_TARGET"}])
	p005_granted.set_costs([{"cost_type": &"SPEND_POWER", "amount": 4, "optional": true}])
	p005_granted.set_actions([{
		"type": &"PILOT_005_DISCARD_OPPOSING",
		"params": {}
	}])
	effects[p005_granted.effect_id] = p005_granted

	# ═══════════════════════════════════════════
	# pilot_002 莱比尔（联邦 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_002_effect_03 联邦光环开关（toggle）──
	# 我方回合1次，选择场上1台机甲，切换其是否获得本莱比尔实例的联邦护甲+4与交牌转化能力。
	var p002e3 := _ActionEffect.new()
	p002e3.effect_id = &"pilot_002_effect_03"
	p002e3.display_name = "联邦光环开关"
	p002e3.description = "我方回合1次，选择1台机甲，切换其是否获得本莱比尔实例的联邦光环。"
	p002e3.mode = _TC.MODE_DIRECT
	p002e3.priority = 10
	p002e3.once_per_turn_key = &"pilot_002_effect_03"
	p002e3.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ANY_MECH_ON_FIELD"},
	])
	p002e3.set_target_rules([{"rule": &"TARGET_IS_MECH"}])
	p002e3.set_costs([])
	p002e3.set_actions([{
		"type": &"TOGGLE_AURA_TARGET",
		"params": {"toggle": &"toggle"}
	}])
	effects[p002e3.effect_id] = p002e3

	# ── pilot_002_granted_transfer_attack 莱比尔协同·进攻（授予联邦机师的 DIRECT 主动能力）──
	# 由 pilot_002_effect_01（aura provider）向联邦阵营机师授予，注册为 granted DIRECT listener（虚拟时点）。
	# binding_context.mech_id=被授予联邦机甲；card_instance_id=pilot_002 实例（grant_source，注销用）。
	# 裁定：交牌不进临时区直接给目标手牌；接收者获一次性"当作进攻使用"权限；交牌者抽2。
	var p002g_atk := _ActionEffect.new()
	p002g_atk.effect_id = &"pilot_002_granted_transfer_attack"
	p002g_atk.display_name = "莱比尔协同·进攻"
	p002g_atk.description = "交任意张行动牌给5格内其他机甲，接收者当作进攻使用，交牌者抽2。"
	p002g_atk.mode = _TC.MODE_DIRECT
	p002g_atk.priority = 10
	p002g_atk.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 5}},
	])
	p002g_atk.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 5, "metric": &"hex_distance"}},
	])
	p002g_atk.set_costs([])
	p002g_atk.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": -1, "store_result_key": &"pilot_002_transfer_batch", "label": "选择要交给目标并作为一个转化批次的行动牌", "confirm_verb": "交给", "cancel_label": "取消"}},
		{"type": &"TRANSFER_ACTION_CARDS", "params": {"card_ids": "$runtime.pilot_002_transfer_batch", "target_mech_id": "$payload.target_id", "from_player_id": "$binding_context.player_id", "batch_tag": &"pilot_002_named_conversion_batch"}},
		{"type": &"GRANT_TRANSFER_BATCH_AS_NAMED_TYPE", "params": {"target_mech_id": "$payload.target_id", "batch_card_ids": "$runtime.pilot_002_transfer_batch", "named_type": &"进攻"}},
		{"type": &"DRAW_ACTION", "params": {"count": 2, "player_id": "$binding_context.player_id", "reason": &"pilot_002_after_transfer"}},
	])
	effects[p002g_atk.effect_id] = p002g_atk

	# ── pilot_002_granted_transfer_defense 莱比尔协同·防御（授予联邦机师的 AVAILABILITY 响应能力）──
	# ATTACK_AT 响应窗口：被攻击目标是5格内其他机甲时，被授予机师可交牌给被攻击目标，目标当作防御响应。
	var p002g_def := _ActionEffect.new()
	p002g_def.effect_id = &"pilot_002_granted_transfer_defense"
	p002g_def.display_name = "莱比尔协同·防御"
	p002g_def.description = "被攻击时，交牌给5格内被攻击目标，其当作防御响应。"
	p002g_def.mode = _TC.MODE_AVAILABILITY
	p002g_def.priority = 5
	p002g_def.listen_timing = _TC.ATTACK_AT
	p002g_def.listen_action_type = &"attack"
	p002g_def.set_conditions([
		{"op": &"SELF_MECH_NOT_ATTACK_TARGET"},
		{"op": &"ATTACK_TARGET_IN_HEX_RANGE", "params": {"range": 5}},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
	])
	p002g_def.set_target_rules([{"rule": &"NO_TARGET"}])
	p002g_def.set_costs([])
	p002g_def.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": -1, "store_result_key": &"pilot_002_transfer_batch", "label": "选择要交给被攻击目标并作为一个转化批次的行动牌", "confirm_verb": "交给", "cancel_label": "取消"}},
		{"type": &"TRANSFER_ACTION_CARDS", "params": {"card_ids": "$runtime.pilot_002_transfer_batch", "target_mech_id": "$payload.target_id", "from_player_id": "$binding_context.player_id", "batch_tag": &"pilot_002_named_conversion_batch"}},
		{"type": &"GRANT_TRANSFER_BATCH_AS_NAMED_TYPE", "params": {"target_mech_id": "$payload.target_id", "batch_card_ids": "$runtime.pilot_002_transfer_batch", "named_type": &"防御"}},
		{"type": &"PILOT_002_USE_BATCH_AS_NAMED", "params": {"as_card_def_id": &"action_009_防御", "attack_is_active": false}},
		{"type": &"DRAW_ACTION", "params": {"count": 2, "player_id": "$binding_context.player_id", "reason": &"pilot_002_after_transfer"}},
	])
	effects[p002g_def.effect_id] = p002g_def

	# ── pilot_002_batch_use_attack 批次当作进攻使用（DIRECT，目标点击批次按钮触发）──
	# binding_context.batch_id 由 GRANT_TRANSFER_BATCH_AS_NAMED_TYPE 注册时注入。
	# 整批牌进弃牌堆（保留首张作虚拟牌），use_action_card virtual_transform as action_001_进攻。
	var p002_bu_atk := _ActionEffect.new()
	p002_bu_atk.effect_id = &"pilot_002_batch_use_attack"
	p002_bu_atk.display_name = "莱比尔批次·进攻"
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
		{"type": &"CHOOSE_MANY_CARDS", "params": {"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": -1, "store_result_key": &"pilot_003_face_up_cards", "label": "选择正面朝上随机放入行动牌堆的牌", "confirm_verb": "放入牌堆", "cancel_label": "取消"}},
		{"type": &"INSERT_ACTION_CARDS_FACE_UP_RANDOM", "params": {"card_ids": "$runtime.pilot_003_face_up_cards", "deck_id": &"action_deck", "face_up": true}},
		{"type": &"CHOOSE_ONE_INSERTED_CARD_TO_DECK_TOP", "params": {"card_ids": "$runtime.pilot_003_face_up_cards", "optional": true, "deck_id": &"action_deck", "label": "选择1张正面牌放置到牌堆顶（可取消）"}},
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
		{"op": &"PAYLOAD_CARD_HAS_RUNTIME_TAG", "params": {"tag": &"pilot_003_face_up_leave_use"}},
		{"op": &"PAYLOAD_FROM_ZONE_IS", "params": {"zone": &"action_deck"}},
	])
	p003e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p003e2.set_costs([])
	p003e2.set_actions([
		{"type": &"CANCEL_PARENT_CARD_TRANSFER", "params": {"card_instance_id": "$payload.card_instance_id"}},
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
	p003e3.once_per_turn_key = &"pilot_003_effect_03"
	p003e3.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
	])
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
	# 维修被使用后（USE_ACTION_SETTLE），可回收弃牌堆的维修入手牌 + X+1（max5）。
	# 裁定：当作维修不触发；X 绑 card_instance_id 换机师不转移；01a/01b 共享 once_per_turn。
	var p008e1a := _ActionEffect.new()
	p008e1a.effect_id = &"pilot_008_effect_01a"
	p008e1a.display_name = "回收维修(使用)"
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
	p008e1a.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "获得维修，X+1", "actions": [
			{"type": &"PILOT_008_RECOVER_REPAIR", "params": {}}
		]}]}
	}])
	effects[p008e1a.effect_id] = p008e1a

	# ── pilot_008_effect_01b 回收维修(弃置) ──
	var p008e1b := _ActionEffect.new()
	p008e1b.effect_id = &"pilot_008_effect_01b"
	p008e1b.display_name = "回收维修(弃置)"
	p008e1b.mode = _TC.MODE_LISTEN
	p008e1b.priority = 20
	p008e1b.listen_timing = _TC.DISCARD_SETTLE
	p008e1b.listen_action_type = &"discard"
	p008e1b.once_per_turn_key = &"pilot_008_effect_01"
	p008e1b.once_per_turn_max = 1
	p008e1b.set_conditions([
		{"op": &"DISCARD_CONTAINS_CARD_DEF_ID", "params": {"card_def_id": &"action_013_维修"}},
	])
	p008e1b.set_target_rules([{"rule": &"NO_TARGET"}])
	p008e1b.set_costs([])
	p008e1b.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "获得维修，X+1", "actions": [
			{"type": &"PILOT_008_RECOVER_REPAIR", "params": {}}
		]}]}
	}])
	effects[p008e1b.effect_id] = p008e1b

	# ── pilot_008_effect_02 逆转治疗(回复->等量伤害) ──
	# 5+X 格内机甲即将回复生命时，可改为受到等量伤害（按实际可回复量，无源伤害）。
	var p008e2 := _ActionEffect.new()
	p008e2.effect_id = &"pilot_008_effect_02"
	p008e2.display_name = "逆转治疗"
	p008e2.mode = _TC.MODE_LISTEN
	p008e2.priority = 30
	p008e2.listen_timing = _TC.HP_CHANGE_BEFORE
	p008e2.listen_action_type = &"hp_change"
	p008e2.once_per_turn_key = &"pilot_008_effect_02"
	p008e2.once_per_turn_max = 1
	p008e2.set_conditions([
		{"op": &"HP_CHANGE_METHOD_IS", "params": {"method": &"restore"}},
		{"op": &"PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE", "params": {"base_range": 5}},
		{"op": &"HP_CHANGE_AMOUNT_ABOVE", "params": {"threshold": 0}},
	])
	p008e2.set_target_rules([{"rule": &"NO_TARGET"}])
	p008e2.set_costs([])
	p008e2.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "将回复改为受到等量伤害", "actions": [
			{"type": &"REDIRECT_HEAL_TO_DAMAGE", "params": {}}
		]}]}
	}])
	effects[p008e2.effect_id] = p008e2

	# ── pilot_008_effect_03 逆转维修(移除损伤->设置等量损伤) ──
	var p008e3 := _ActionEffect.new()
	p008e3.effect_id = &"pilot_008_effect_03"
	p008e3.display_name = "逆转维修"
	p008e3.mode = _TC.MODE_LISTEN
	p008e3.priority = 30
	p008e3.listen_timing = _TC.DAMAGE_CHANGE_BEFORE
	p008e3.listen_action_type = &"damage_change"
	p008e3.once_per_turn_key = &"pilot_008_effect_03"
	p008e3.once_per_turn_max = 1
	p008e3.set_conditions([
		{"op": &"DAMAGE_CHANGE_METHOD_IS", "params": {"method": &"decrease"}},
		{"op": &"PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE", "params": {"base_range": 5}},
		{"op": &"DAMAGE_CHANGE_AMOUNT_ABOVE", "params": {"threshold": 0}},
	])
	p008e3.set_target_rules([{"rule": &"NO_TARGET"}])
	p008e3.set_costs([])
	p008e3.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "将移除损伤改为设置等量损伤", "actions": [
			{"type": &"REDIRECT_REMOVE_TO_PLACE_TOKENS", "params": {}}
		]}]}
	}])
	effects[p008e3.effect_id] = p008e3

	# ═══════════════════════════════════════════
	# pilot_006 里昂（帝国 SSR，cost 15, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════

	# ── pilot_006_effect_01 轮次悬赏 ──
	# 每轮开始选1台其他机甲为本轮悬赏目标（替换上一轮标记）。
	var p006e1 := _ActionEffect.new()
	p006e1.effect_id = &"pilot_006_effect_01"
	p006e1.display_name = "轮次悬赏"
	p006e1.mode = _TC.MODE_LISTEN
	p006e1.priority = 10
	p006e1.listen_timing = _TC.ROUND_START
	p006e1.listen_action_type = &"round_cycle"
	p006e1.set_conditions([{"op": &"HAS_OTHER_MECH_ON_FIELD"}])
	p006e1.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	p006e1.set_costs([])
	p006e1.set_actions([{
		"type": &"SET_ROUND_MARKED_TARGET",
		"params": {}
	}])
	effects[p006e1.effect_id] = p006e1

	# ── pilot_006_effect_02 悬赏追击 ──
	# 悬赏目标被攻击时，攻击方抽1张，若为攻击牌挂 passive_attack_bonus 标记（不立即用）。
	# 裁定（歧义1）：抽到攻击牌不立即使用，只挂增益（不计回合攻击数，持续到离手）。
	var p006e2 := _ActionEffect.new()
	p006e2.effect_id = &"pilot_006_effect_02"
	p006e2.display_name = "悬赏追击"
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

	# ── pilot_006_effect_03 战后逼迫 ──
	# 我方攻击结算后，选5格内其他机甲（外层可选目标，可取消），
	# 被选机甲二选一（chooser=被选机甲玩家，不可取消）：立即使用1张攻击牌 / 受4伤害。
	# 裁定：二选一不可取消；选牌取消回落4伤害；当作转化不算攻击牌（MECH_HAS_USABLE_ATTACK_CARD 只看真实攻击牌）；
	# 被选机甲用攻击牌走正常 use_action_card（刻托"视为"照常触发），passive 不计攻击数。
	var p006e3 := _ActionEffect.new()
	p006e3.effect_id = &"pilot_006_effect_03"
	p006e3.display_name = "战后逼迫"
	p006e3.description = "我方攻击结算后，选5格内其他机甲，其立即使用1张攻击牌或受到4伤害（取消选牌回落4伤害）。"
	p006e3.mode = _TC.MODE_LISTEN
	p006e3.priority = 10
	p006e3.once_per_turn_key = &"pilot_006_effect_03"
	p006e3.listen_timing = _TC.ATTACK_SETTLE
	p006e3.listen_action_type = &"attack"
	p006e3.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 5}},
	])
	p006e3.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
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
	# 指定我方为目标的实体攻击牌结算后，可夺取该牌到我方手牌（可立即使用）。
	# 裁定：当作转化/飞弹不触发；攻击未命中仍可夺；夺后 use_action settle 跳过弃置（claimed 标记）。
	var p007e1 := _ActionEffect.new()
	p007e1.effect_id = &"pilot_007_effect_01"
	p007e1.display_name = "反夺攻击牌"
	p007e1.mode = _TC.MODE_LISTEN
	p007e1.priority = 20
	p007e1.listen_timing = _TC.ATTACK_SETTLE
	p007e1.listen_action_type = &"attack"
	p007e1.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"ATTACK_SOURCE_ACTION_CARD_TYPE_IS", "params": {"card_type": &"攻击"}},
		{"op": &"ATTACK_SOURCE_CARD_CAN_BE_CLAIMED"},
	])
	p007e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p007e1.set_costs([])
	p007e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "获得此攻击牌", "actions": [
			{"type": &"CLAIM_RESOLVED_ATTACK_SOURCE_CARD", "params": {}}
		]}]}
	}])
	effects[p007e1.effect_id] = p007e1

	# ── pilot_007_effect_02 类型破绽 ──
	# 我方用实体攻击牌攻击时，对每个攻击目标分别 peek 手牌、算缺类型数X、弃目标X+1张、我方抽X+1。
	# 裁定：多目标全部结算（每目标独立）；不足X+1弃全部剩余仍抽X+1（X决定抽牌数，与实际弃置量无关）。
	# PILOT_007_TYPE_FLAW atomic 内部循环目标 peek+算X+弃+抽。peek/choose弃牌 UI 后续补。
	var p007e2 := _ActionEffect.new()
	p007e2.effect_id = &"pilot_007_effect_02"
	p007e2.display_name = "类型破绽"
	p007e2.description = "我方用攻击牌攻击时，查看每个目标手牌，按缺失类型数X弃目标X+1张、我方抽X+1。"
	p007e2.mode = _TC.MODE_LISTEN
	p007e2.priority = 20
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
	p007e2.set_actions([{
		"type": &"PILOT_007_TYPE_FLAW",
		"params": {}
	}])
	effects[p007e2.effect_id] = p007e2

	# ═══════════════════════════════════════════
	# pilot_009 美杜莎（混乱 SSR，cost 15, attack_limit 1, action_card_limit 4）
	# ═══════════════════════════════════════════

	# ── pilot_009_effect_01 蛇发支配 ──
	# 我方回合1次，5格内选目标 reveal 手牌，选类型弃1支付，控制目标该类型牌（非排他，到回合结束）。
	# 裁定：非排他控制（双方可用先用者得）；必须全弃该类型（限定所有类型）；持续光环到回合结束；换下立即解。
	var p009e1 := _ActionEffect.new()
	p009e1.effect_id = &"pilot_009_effect_01"
	p009e1.display_name = "蛇发支配"
	p009e1.mode = _TC.MODE_DIRECT
	p009e1.priority = 10
	p009e1.once_per_turn_key = &"pilot_009_effect_01"
	p009e1.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"minimum": 1}},
		{"op": &"HAS_OTHER_MECH_IN_HEX_RANGE", "params": {"range": 5}},
	])
	p009e1.set_target_rules([
		{"rule": &"CHOOSE_OTHER_MECH"},
		{"rule": &"TARGET_IN_RANGE", "params": {"range": 5, "metric": &"hex_distance"}},
	])
	p009e1.set_costs([])
	p009e1.set_actions([
		{"type": &"EXECUTE_SHOW_CARD", "params": {"mode": &"reveal_hand", "source_mech_id": "$payload.target_id", "viewer_mech_ids": ["$binding_context.mech_id"], "card_zone": &"ACTION_HAND", "persistent": false, "reason": &"pilot_009_reveal"}},
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
			{"label": "指定攻击", "condition": {"op": &"HAS_ACTION_CARD_TYPE_IN_HAND", "params": {"card_type": &"攻击"}}, "actions": [
				{"type": &"EXECUTE_DISCARD", "params": {"from_target_mech_id": "$binding_context.mech_id", "card_type": &"攻击", "count": 1, "choose": true, "chooser_mech_id": "$binding_context.mech_id", "face_up": true, "reason": &"pilot_009_type_payment", "require_exact_count": true}},
				{"type": &"GRANT_TEMP_CARD_CONTROL", "params": {"card_type": &"攻击"}},
				{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "立即弃置目标全部攻击牌", "actions": [{"type": &"PILOT_009_DISCARD_ALL_CONTROLLED_TYPE", "params": {"card_type": &"攻击"}}]}]}}
			]},
			{"label": "指定迎击", "condition": {"op": &"HAS_ACTION_CARD_TYPE_IN_HAND", "params": {"card_type": &"迎击"}}, "actions": [
				{"type": &"EXECUTE_DISCARD", "params": {"from_target_mech_id": "$binding_context.mech_id", "card_type": &"迎击", "count": 1, "choose": true, "chooser_mech_id": "$binding_context.mech_id", "face_up": true, "reason": &"pilot_009_type_payment", "require_exact_count": true}},
				{"type": &"GRANT_TEMP_CARD_CONTROL", "params": {"card_type": &"迎击"}},
				{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "立即弃置目标全部迎击牌", "actions": [{"type": &"PILOT_009_DISCARD_ALL_CONTROLLED_TYPE", "params": {"card_type": &"迎击"}}]}]}}
			]},
			{"label": "指定辅助", "condition": {"op": &"HAS_ACTION_CARD_TYPE_IN_HAND", "params": {"card_type": &"辅助"}}, "actions": [
				{"type": &"EXECUTE_DISCARD", "params": {"from_target_mech_id": "$binding_context.mech_id", "card_type": &"辅助", "count": 1, "choose": true, "chooser_mech_id": "$binding_context.mech_id", "face_up": true, "reason": &"pilot_009_type_payment", "require_exact_count": true}},
				{"type": &"GRANT_TEMP_CARD_CONTROL", "params": {"card_type": &"辅助"}},
				{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "立即弃置目标全部辅助牌", "actions": [{"type": &"PILOT_009_DISCARD_ALL_CONTROLLED_TYPE", "params": {"card_type": &"辅助"}}]}]}}
			]},
		]}},
	])
	effects[p009e1.effect_id] = p009e1

	# ═══════════════════════════════════════════
	# pilot_001 阿克罗姆（联邦 SSR，cost 15, attack_limit 1, action_card_limit 5）
	# ═══════════════════════════════════════════

	# ── pilot_001_effect_01 双重生效 ──
	# 我方使用行动牌完成第1次效果结算后，可将该牌当前有效效果链再执行1次。
	# 裁定：迎击牌一般不可重复（时点已过，REPEAT 内部自然限制）；第2次重新选目标；
	# 失败不返还次数；repeat_depth 防递归；第2次攻击 passive（不计回合攻击数，REPEAT 不走 settle）。
	var p001e1 := _ActionEffect.new()
	p001e1.effect_id = &"pilot_001_effect_01"
	p001e1.display_name = "双重生效"
	p001e1.mode = _TC.MODE_LISTEN
	p001e1.priority = 10
	p001e1.listen_timing = _TC.USE_ACTION_AFTER
	p001e1.listen_action_type = &"use_action_card"
	p001e1.once_per_turn_key = &"pilot_001_effect_01"
	p001e1.once_per_turn_max = 1
	p001e1.set_conditions([
		{"op": &"USED_CARD_EXECUTOR_IS_SELF"},
		{"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"},
		{"op": &"PAYLOAD_EFFECT_CHAIN_COMPLETED"},
		{"op": &"PAYLOAD_REPEAT_DEPTH_BELOW", "params": {"max_depth": 1}},
	])
	p001e1.set_target_rules([{"rule": &"NO_TARGET"}])
	p001e1.set_costs([])
	p001e1.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {"optional": true, "options": [{"label": "使该行动牌的效果再生效1次", "actions": [
			{"type": &"REPEAT_USED_ACTION_EFFECT_CHAIN", "params": {}}
		]}]}
	}])
	effects[p001e1.effect_id] = p001e1

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

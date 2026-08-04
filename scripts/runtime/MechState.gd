## MechState.gd — 机甲运行时状态
##
## 机甲是玩家的战斗主体，由框架定义、6个部件槽位、2个武器槽位、
## 备用区域、事件区域和机师区域组成。
class_name MechState
extends RefCounted

const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _MechFrameDef = preload("res://scripts/card_defs/MechFrameDef.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")

## 机甲唯一 ID
var mech_id: StringName = &""

## 所属玩家 ID
var owner_player_id: StringName = &""

## 框架定义
var frame_def = null

## 基础武器数据（从框架继承，不作为卡牌存在）
## 结构: Array[Dictionary]，索引0对应weapon_1，索引1对应weapon_2
## 结构: {name: String, might: int, range_value: int, weapon_kind: StringName}
var base_weapons: Array[Dictionary] = []

## 当前生命值
var current_hp: int = 25

## 最大生命值
var max_hp: int = 25

## 当前动力
var power: int = 0

## 最大动力（回合开始回复到此值）
var max_power: int = 0

## 六边形网格坐标 {"q": int, "r": int}
var position: Dictionary = {"q": 0, "r": 0}

## 槽位状态字典：slot_id → MechSlotState
var slots: Dictionary = {}

## 状态效果列表（锁定/不能攻击/不能移动等）
var statuses: Array[Dictionary] = []

## 本回合已攻击次数
var attack_count_this_turn: int = 0

## 本回合累计消耗动力（effect_044/045 帝国赤枭腿用）
var power_spent_this_turn: int = 0

## 当前临时动力（本回合临时增加的动力，如推进/手持推进器 +N）。
## 是 power 的子集：power = 本身动力 + temp_power。消耗动力时优先扣减 temp_power，
## 回合结束未消耗的 temp_power 不保留（本身动力保留）。本身动力 = power - temp_power。
var temp_power: int = 0

## 本回合临时动力累计授予量（供详情面板显示「非本身的动力合计」）
var temp_power_granted_this_turn: int = 0

## 本回合消耗的本身动力（不含临时动力消耗，供详情面板显示）
var own_power_spent_this_turn: int = 0

## 本回合累计移动格数（effect_012/013 帝国腿主动效果阈值用）
var cells_moved_this_turn: int = 0

## 每回合最大攻击次数（由机师牌决定）
var max_attacks_per_turn: int = 1

## 是否已被摧毁
var destroyed: bool = false

## 临时护甲加成（防御牌等：本次攻击结算后恢复）
## 由 ADD_MECH_TEMP_ARMOR 增加，登记到攻击动作 record["temp_armor_grants"]，
## 攻击动作 _step_cleanup 结算后恢复。get_armor() 计入，故装备面板可见。
var temp_armor_bonus: int = 0


## ── 查询方法 ──


## 获取总护甲 = 所有部件槽位 effective_armor 之和 + 派生值加成
## 派生值：联邦普装·头部（其他区域每张联邦装备+1护甲）实时重算
func get_armor() -> int:
	var total: int = 0
	for slot_id: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		if slots.has(slot_id):
			total += slots[slot_id].get_effective_armor(self)
	# 联邦头部动态护甲（门控 by effect_002/effect_066）：联邦普装=其他区域，联邦圣牛=含自身
	total += _GenEquipEffects.compute_head_faction_armor_bonus(self)
	# 临时护甲加成（防御牌等，本次攻击结算后恢复）
	total += temp_armor_bonus
	# 「当前回合护甲+X」类效果（effect_015/029/047/062/075/009 等）经
	# GameActions.modify_armor 写入 ARMOR_MODIFIER 状态（duration=THIS_TURN）。
	# 排除 THIS_ATTACK：该 duration 路由由 attack record temporary_armor_bonus
	# 处理（attack_action._step_calculate_damage 单独读取），避免双计。
	# 回合结束 _clean_this_turn_durations 移除 THIS_TURN 的 ARMOR_MODIFIER 后自动不再计入。
	var am_bonus := 0
	for st: Dictionary in statuses:
		if st.get("type", &"") == &"ARMOR_MODIFIER" \
				and String(st.get("duration", &"")) != "THIS_ATTACK":
			am_bonus += int(st.get("delta", 0))
	total += am_bonus
	return total


## 获取总动力 = 所有部件槽位 effective_power 之和 + 派生值加成
## 派生值：帝国普装·头部（其他区域每张帝国装备+1动力上限）+ 重甲右臂/机动右腿(损伤≥1)+1 + 机动左腿(损伤≥2)+1
func get_total_power() -> int:
	var total: int = 0
	for slot_id: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		if slots.has(slot_id):
			total += slots[slot_id].get_effective_power()
	# 帝国头部动态动力上限（门控 by effect_008/effect_070）：帝国普装=其他区域，帝国雄鹰=含自身
	total += _GenEquipEffects.compute_head_faction_power_bonus(self)
	# 各 slot 损伤阈值动力加成（重甲右臂/机动右腿 effect_016 阈值1，机动左腿 effect_021 阈值2）
	for slot_id: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		total += _GenEquipEffects.slot_damage_threshold_power_bonus(self, slot_id)
	return total


## 损伤/装备变化后重算动力上限并同步当前动力。
## effect_016/021/048 等派生动力随损伤实时变，但 max_power 是存储字段，仅在装备
## 设置/损坏时重算 -> 损伤变化时上限不更新（详情 get_power_breakdown 实时算故可见，
## 但实际 max_power 未变）。在损伤增减点调用此方法同步：上限变多少，当前动力补/减多少。
func recalc_power_limits() -> void:
	var new_max: int = get_total_power()
	var delta: int = new_max - max_power
	if delta == 0:
		return
	max_power = new_max
	# 本身动力随上限变化同步增减，保留临时动力 temp_power（不被压回 max_power）
	var own: int = get_own_power()
	var new_own: int = clampi(own + delta, 0, max_power)
	power = new_own + temp_power


## 上限变化后同步本身动力（保留 temp_power）。在 max_power 已更新后调用，传入旧上限。
## 修复 maxi(0, power + delta) 在本身动力被扣至负时误压回 temp_power 的问题。
func sync_own_power_after_max_change(old_max_power: int) -> void:
	var delta: int = max_power - old_max_power
	var own2: int = get_own_power()
	own2 = clampi(own2 + delta, 0, max_power)
	power = own2 + temp_power


## 调整本身动力（+/-amount，clamp 到 [0, max_power]，保留 temp_power）。dev 模式动力 +/- 用。
func adjust_own_power(amount: int) -> void:
	var own: int = get_own_power()
	own = clampi(own + amount, 0, max_power)
	power = own + temp_power


## dev 模式 +/- 动力：正向当作额外(临时)动力增加（可超上限，不被 max_power 截断），
## 负向先扣临时再扣本身。不计入 own_power_spent_this_turn（dev 调试，不污染消耗统计）。
func dev_modify_power(amount: int) -> void:
	if amount > 0:
		add_temp_power(amount)
	elif amount < 0:
		var reduce: int = -amount
		var from_temp: int = mini(temp_power, reduce)
		temp_power -= from_temp
		power -= from_temp
		var remaining: int = reduce - from_temp
		if remaining > 0:
			var own: int = maxi(0, power - temp_power)
			power -= mini(own, remaining)


## ── 临时动力系统 ──
## 三种动力操作区分：增加上限(装备/派生→max_power)、当前增加(临时→temp_power，消耗优先、回合末清剩余)、
## 回复(填本身动力至上限，保留temp_power)。temp_power 是 power 的子集：power = 本身动力 + temp_power。


## 当前本身动力（上限囊括的动力，= power - temp_power，不含临时增加）。
## 返回原始值（可能为负，如被减动力 debuff 致 power < temp_power）；调用方按需 clamp。
func get_own_power() -> int:
	return power - temp_power


## 增加临时动力（本回合动力+N：推进/手持推进器等，允许超 max_power）
func add_temp_power(delta: int) -> void:
	power += delta
	temp_power += delta
	temp_power_granted_this_turn += delta


## 消耗动力：优先扣减 temp_power，再扣本身动力。返回从临时动力扣减的量。
## 调用前需保证 power >= amount。
func consume_power(amount: int) -> int:
	var from_temp: int = mini(temp_power, amount)
	temp_power -= from_temp
	power -= amount
	power_spent_this_turn += amount
	own_power_spent_this_turn += (amount - from_temp)
	return from_temp


## 回复本身动力（不超过上限，保留 temp_power）。返回实际回复量。
func restore_own_power(amount: int) -> int:
	var own: int = get_own_power()
	var new_own: int = clampi(own + amount, 0, max_power)
	var restored: int = new_own - own
	power += restored
	return restored


## 回复本身动力至上限（保留 temp_power，不压回临时动力）。返回回复量。
func restore_own_power_to_full() -> int:
	var own: int = get_own_power()
	var restored: int = maxi(0, max_power - own)
	power += restored
	return restored


## 回合结束：清除剩余临时动力（未消耗的临时动力不保留，本身动力保留）
func clear_temp_power() -> void:
	power = maxi(0, power - temp_power)
	temp_power = 0


## 重置回合临时动力计数（回合开始调用）
func reset_turn_power_counters() -> void:
	power_spent_this_turn = 0
	own_power_spent_this_turn = 0
	temp_power_granted_this_turn = 0


## 护甲来源明细（供机甲详情框展示）。各项 amount 之和 == get_armor()。
## temporary=true 表示本回合临时（防御牌/THIS_TURN 状态），回合结束/攻击结算后消失。
func get_armor_breakdown(context = null) -> Array:
	var result: Array = []
	var part_slots: Array[StringName] = [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]
	for slot_id: StringName in part_slots:
		if not slots.has(slot_id):
			continue
		var slot: MechSlotState = slots[slot_id]
		var slot_name := String(slot_id)
		var active := slot.equipped_card != null and not bool(slot.equipped_card.counters.get("_pending_equipment_activation", false))
		# 装备护甲 / 框架基础护甲
		if active and slot.equipped_card.def is EquipmentCardDef and slot.equipped_card.def.equipment_kind == &"PART":
			result.append({"label": "装备·%s(%s)" % [slot_name, slot.equipped_card.def.display_name], "amount": int(slot.equipped_card.def.armor), "temporary": false})
		elif not active:
			result.append({"label": "基础框架·%s" % slot_name, "amount": int(slot.base_armor), "temporary": false})
		# 槽位护甲修正
		if int(slot.armor_modifier) != 0:
			result.append({"label": "护甲修正·%s" % slot_name, "amount": int(slot.armor_modifier), "temporary": false})
		# 损伤扣减（effect_014/089 免疫时为0）
		var dmg := _GenEquipEffects.card_damage_immune_armor_amount(slot.equipped_card, self, slot.region_damage_tokens)
		if dmg != 0:
			result.append({"label": "损伤·%s" % slot_name, "amount": -dmg, "temporary": false})
		# 联邦光环（per-slot，effect_080）
		if active:
			var aura := _GenEquipEffects.get_global_faction_equipment_aura_bonus(slot.equipped_card, "联邦")
			if aura != 0:
				result.append({"label": "联邦光环·%s" % slot_name, "amount": aura, "temporary": false})
	# 联邦头部派生护甲（effect_002/066）
	var head_bonus := _GenEquipEffects.compute_head_faction_armor_bonus(self)
	if head_bonus != 0:
		result.append({"label": "派生·联邦头部", "amount": head_bonus, "temporary": false})
	# 临时护甲（防御牌等，本次攻击结算后恢复）
	if temp_armor_bonus != 0:
		result.append({"label": "临时·防御牌", "amount": temp_armor_bonus, "temporary": true})
	# ARMOR_MODIFIER 状态（THIS_TURN 本回合临时；排除 THIS_ATTACK 由 attack record 处理）
	for st: Dictionary in statuses:
		if st.get("type", &"") == &"ARMOR_MODIFIER" and String(st.get("duration", &"")) != "THIS_ATTACK":
			var delta := int(st.get("delta", 0))
			if delta == 0:
				continue
			var label := "状态·护甲修正"
			var src := _resolve_source_name(context, st.get("source_card_id", &""))
			if src != "":
				label += "（%s）" % src
			result.append({"label": label, "amount": delta, "temporary": true})
	return result


## 动力上限来源明细（供机甲详情框展示）。各项 amount 之和 == get_total_power() == max_power。
## 注意：当前可花动力 = power（含 temp_power 临时动力）；临时动力（推进/手持推进器 +N）单独由
## temp_power 追踪，消耗时优先扣减、回合末清剩余，不在此上限明细中（详情面板单独显示）。
func get_power_breakdown(_context = null) -> Array:
	var result: Array = []
	var part_slots: Array[StringName] = [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]
	for slot_id: StringName in part_slots:
		if not slots.has(slot_id):
			continue
		var slot: MechSlotState = slots[slot_id]
		var slot_name := String(slot_id)
		var active := slot.equipped_card != null and not bool(slot.equipped_card.counters.get("_pending_equipment_activation", false))
		if active and slot.equipped_card.def is EquipmentCardDef and slot.equipped_card.def.equipment_kind == &"PART":
			result.append({"label": "装备·%s(%s)" % [slot_name, slot.equipped_card.def.display_name], "amount": int(slot.equipped_card.def.power), "temporary": false})
		elif not active:
			result.append({"label": "基础框架·%s" % slot_name, "amount": int(slot.base_power), "temporary": false})
		if int(slot.power_modifier) != 0:
			result.append({"label": "动力修正·%s" % slot_name, "amount": int(slot.power_modifier), "temporary": false})
		if active:
			var aura := _GenEquipEffects.get_global_faction_equipment_aura_bonus(slot.equipped_card, "帝国")
			if aura != 0:
				result.append({"label": "帝国光环·%s" % slot_name, "amount": aura, "temporary": false})
	# 帝国头部派生动力（effect_008/070）
	var head_p := _GenEquipEffects.compute_head_faction_power_bonus(self)
	if head_p != 0:
		result.append({"label": "派生·帝国头部", "amount": head_p, "temporary": false})
	# 各 slot 损伤阈值动力加成（effect_016/021）
	for slot_id: StringName in part_slots:
		if not slots.has(slot_id):
			continue
		var thr := _GenEquipEffects.slot_damage_threshold_power_bonus(self, slot_id)
		if thr != 0:
			result.append({"label": "派生·损伤阈值·%s" % String(slot_id), "amount": thr, "temporary": false})
	return result


## 解析状态来源牌实例ID为显示名（无 context 时返回空）
func _resolve_source_name(context, card_id) -> String:
	if context == null or context.get("game_state") == null:
		return ""
	var cid_str := String(card_id)
	if cid_str == "":
		return ""
	var card = context.game_state.get_card(StringName(cid_str))
	if card != null and card.def != null:
		return card.def.display_name
	return ""


## 获取武器槽位中的装备 instance_id 列表
## 如果槽位为空但有基础武器，返回基础武器虚拟 ID（带槽位索引）
func get_weapon_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for i: int in range(2):
		var slot_id: StringName = StringName("weapon_%d" % [i + 1])
		if slots.has(slot_id):
			var slot: MechSlotState = slots[slot_id]
			if slot.equipped_card:
				# 有装备牌，使用装备牌的 instance_id
				result.append(slot.equipped_card.instance_id)
			elif i < base_weapons.size() and not base_weapons[i].is_empty():
				# 槽位为空但有基础武器，使用虚拟 ID（包含槽位索引）
				result.append(StringName("frame_base_weapon_%d" % [i + 1]))
	return result


## 获取基础武器数据（用于攻击计算）
## slot_index: 0=weapon_1, 1=weapon_2
func get_base_weapon(slot_index: int = 0) -> Dictionary:
	if slot_index >= 0 and slot_index < base_weapons.size():
		return base_weapons[slot_index]
	return {}


## 获取所有基础武器数据
func get_all_base_weapons() -> Array[Dictionary]:
	return base_weapons


## 设置基础武器数据（单把武器）
func set_base_weapon(weapon_data: Dictionary) -> void:
	base_weapons = [weapon_data]


## 设置基础武器数据（多把武器）
func set_base_weapons(weapons: Array[Dictionary]) -> void:
	base_weapons = weapons


## 获取所有区域损伤标记总数
func get_damage_token_count() -> int:
	var total: int = 0
	for slot in slots.values():
		total += slot.region_damage_tokens
	return total


## 获取指定槽位的装备牌
func get_equipped_card_in_slot(slot_id: StringName):
	if slots.has(slot_id):
		return slots[slot_id].equipped_card
	return null


## 是否有指定状态
func has_status(status_type: StringName) -> bool:
	for s: Dictionary in statuses:
		if s.get("type", &"") == status_type:
			return true
	return false


## 添加状态
func add_status(status: Dictionary) -> void:
	statuses.append(status)


## 移除指定类型的状态
func remove_status(status_type: StringName) -> void:
	statuses = statuses.filter(func(s: Dictionary) -> bool:
		return s.get("type", &"") != status_type
	)


## 本回合是否还能攻击
func can_attack() -> bool:
	if destroyed:
		return false
	if has_status(&"cannot_attack"):
		return false
	return attack_count_this_turn < max_attacks_per_turn


## 本回合是否还能移动
func can_move() -> bool:
	if destroyed:
		return false
	if has_status(&"cannot_move"):
		return false
	return power > 0


## ── 新状态系统方法 ──


## 获取指定类型的状态（返回第一个匹配的状态字典）
func get_status(status_type: StringName) -> Dictionary:
	for s: Dictionary in statuses:
		if s.get("type", &"") == status_type:
			return s
	return {}


## 获取指定类型的所有状态实例
func get_all_statuses(status_type: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for s: Dictionary in statuses:
		if s.get("type", &"") == status_type:
			result.append(s)
	return result


## 获取指定状态的层数（可叠加状态如聚能/折扣）
func get_status_stacks(status_type: StringName) -> int:
	for s: Dictionary in statuses:
		if s.get("type", &"") == status_type:
			return int(s.get("stacks", 1))
	return 0


## 添加或叠加状态（可叠加状态：聚能/折扣）
func add_or_stack_status(status_type: StringName, stacks: int = 1, data: Dictionary = {}) -> void:
	# 可叠加状态类型
	var stackable_types: Array[StringName] = [&"ENERGY_CHARGE", &"DISCOUNT"]
	if status_type in stackable_types:
		for s: Dictionary in statuses:
			if s.get("type", &"") == status_type:
				s["stacks"] = int(s.get("stacks", 1)) + stacks
				# 合并附加数据
				for key: String in data:
					if not s.has(key):
						s[key] = data[key]
				return
	# 不可叠加或不存在 → 新增
	var new_status: Dictionary = {"type": status_type, "stacks": stacks}
	new_status.merge(data, true)
	statuses.append(new_status)


## 减少状态层数（层数到0时移除）
func decrement_status_stacks(status_type: StringName, amount: int = 1, remove_if_zero: bool = true) -> void:
	for i: int in range(statuses.size()):
		var s: Dictionary = statuses[i]
		if s.get("type", &"") == status_type:
			var current: int = int(s.get("stacks", 1))
			current -= amount
			if current <= 0 and remove_if_zero:
				statuses.remove_at(i)
			else:
				s["stacks"] = max(0, current)
			return


## 移除指定类型和来源的状态（用于联合/锁定等独立状态）
func remove_status_with_source(status_type: StringName, source_player_id: StringName) -> void:
	statuses = statuses.filter(func(s: Dictionary) -> bool:
		if s.get("type", &"") != status_type:
			return true
		return String(s.get("source_player_id", &"")) != String(source_player_id)
	)


## 减少指定状态的持续时间（持续到0时移除）
## 返回因 duration 归 0 被移除的状态对象列表（含 status_id，供监听器注销用）
func tick_status_duration(status_type: StringName) -> Array:
	var to_remove: Array[int] = []
	var removed: Array = []
	for i: int in range(statuses.size()):
		var s: Dictionary = statuses[i]
		if s.get("type", &"") == status_type:
			var duration: int = int(s.get("duration", 0))
			if duration > 0:
				duration -= 1
				if duration <= 0:
					to_remove.append(i)
					removed.append(s)
				else:
					s["duration"] = duration
	# 从后往前移除，避免索引偏移
	for i: int in to_remove:
		statuses.remove_at(i)
	return removed


## 检查是否有来自指定玩家的锁定状态
func is_locked_by(attacker_player_id: StringName) -> bool:
	for s: Dictionary in statuses:
		if s.get("type", &"") == &"LOCKED" and String(s.get("source_player_id", &"")) == String(attacker_player_id):
			return true
	return false


## 检查是否有联合状态（来自指定unite机甲）
func has_unite_with(unite_mech_id: StringName) -> bool:
	for s: Dictionary in statuses:
		if s.get("type", &"") == &"UNITE" and String(s.get("unite_mech_id", &"")) == String(unite_mech_id):
			return true
	return false


## 获取折扣状态的总层数（用于商店价格计算）
func get_discount_stacks() -> int:
	return get_status_stacks(&"DISCOUNT")


## 获取聚能状态的总层数（用于威力加成计算）
func get_energy_charge_stacks() -> int:
	return get_status_stacks(&"ENERGY_CHARGE")

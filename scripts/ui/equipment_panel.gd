## EquipmentPanel.gd — 机甲装备面板
##
## 显示机甲的所有槽位（6部件+2武器+2备用+1事件+1机师），
## 每个槽位显示装备名、护甲/动力数值、损伤/耐久。
extends VBoxContainer
class_name EquipmentPanel

const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

## 备用区设置按钮被点击（参数：备用区槽位ID，如"reserve_1"）
signal reserve_set_clicked(slot_id: StringName)

## 装备主动效果"发动"按钮被点击（参数：来源牌实例ID, 效果ID）
signal equipment_active_clicked(card_instance_id: StringName, effect_id: StringName)

## 当前机甲引用
var _mech = null  # type: MechState

## 是否是敌方机甲（用于决定是否显示背面信息）
var _is_enemy: bool = false

## GameContext 引用（用于扫描装备 DIRECT 主动效果，仅玩家面板注入）
var _context = null

## 槽位显示顺序
const SLOT_ORDER: Array[StringName] = [
	&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿",
	&"weapon_1", &"weapon_2",
	&"reserve_1", &"reserve_2",
	&"event", &"pilot",
]

## 槽位中文名映射
const SLOT_NAMES: Dictionary = {
	&"头部": "头部", &"躯干": "躯干", &"右臂": "右臂", &"左臂": "左臂",
	&"右腿": "右腿", &"左腿": "左腿",
	&"weapon_1": "武器1", &"weapon_2": "武器2",
	&"reserve_1": "备用1", &"reserve_2": "备用2",
	&"event": "事件", &"pilot": "机师",
}


## 配置面板
## mech: 机甲状态
## is_enemy: 是否是敌方机甲（用于决定是否显示背面信息）
## game_context: 可选，注入后显示该机甲装备的 DIRECT 主动效果"发动"按钮
func configure(mech, is_enemy: bool = false, game_context = null) -> void:
	_mech = mech
	_is_enemy = is_enemy
	_context = game_context
	_refresh()


## 刷新装备显示
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	if not _mech:
		return

	# 标题
	var title = Label.new()
	title.text = "── 装备面板 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	# 生命/动力摘要
	var summary = Label.new()
	summary.text = "HP: %d/%d  动力: %d  护甲: %d" % [
		_mech.current_hp, _mech.max_hp,
		_mech.power, _mech.get_armor()
	]
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(summary)

	# 基础武器信息不再单列一行：武器槽（weapon_1/weapon_2）为空时
	# 已在 _add_slot_row 中显示基础武器名与威/射，无需重复。
	# 本机甲装备主动效果索引：card_instance_id -> Array[Dictionary{effect, bind_ctx}]
	# 仅在 _refresh 内构建一次，供各槽位行查询自己该挂哪些「触发」按钮，
	# 避免每个槽位行都重复扫描、把同一按钮挂到所有槽位上。
	var _active_by_card: Dictionary = {}
	if not _is_enemy and _context != null and _context.get("timing_engine") != null:
		var _TC = preload("res://scripts/action_core/TimingConst.gd")
		for timing: StringName in _context.timing_engine.permanent_listeners:
			var entries: Array = _context.timing_engine.permanent_listeners[timing]
			for entry in entries:
				if entry == null or not (entry is Dictionary):
					continue
				var eff = entry.get("effect")
				if eff == null or eff.mode != _TC.MODE_DIRECT:
					continue
				# 跳过 actions 为空的 DIRECT 占位效果（001卖出权限、002/008/014/016/021派生值实时重算、023无效果）
				# 这些没有可执行的主动动作，不该挂「触发」按钮（点了也没反应）。
				if eff.actions == null or eff.actions.is_empty():
					continue
				var bind_ctx: Dictionary = entry.get("binding_context", {})
				if String(bind_ctx.get("mech_id", &"")) != String(_mech.mech_id):
					continue
				var cid: StringName = bind_ctx.get("card_instance_id", &"")
				if cid == &"":
					continue
				if not _active_by_card.has(cid):
					_active_by_card[cid] = []
				_active_by_card[cid].append({"effect": eff, "bind_ctx": bind_ctx})

	# 各槽位
	for slot_id: StringName in SLOT_ORDER:
		if not _mech.slots.has(slot_id):
			continue
		var slot: MechSlotState = _mech.slots[slot_id]
		_add_slot_row(slot_id, slot, _active_by_card)


## 添加单行槽位显示
## active_by_card: card_instance_id -> Array[Dictionary{effect, bind_ctx}]，
## 本槽位 equipped_card 命中的主动效果会在此行内挂「触发」按钮。
func _add_slot_row(slot_id: StringName, slot, active_by_card: Dictionary = {}) -> void:
	var hbox = HBoxContainer.new()

	# 槽位名
	var name_label = Label.new()
	name_label.text = SLOT_NAMES.get(slot_id, String(slot_id))
	name_label.custom_minimum_size = Vector2(50, 24)
	hbox.add_child(name_label)

	# 装备名
	var equip_label = Label.new()
	if slot.equipped_card and slot.equipped_card.def:
		equip_label.text = slot.equipped_card.def.display_name
		# 附加数值信息
		if slot.equipped_card.def is _EquipmentCardDef:
			var eq_def = slot.equipped_card.def
			if eq_def.equipment_kind == &"PART":
				equip_label.text += " [甲%d 动%d]" % [eq_def.armor, eq_def.power]
			elif eq_def.equipment_kind == &"WEAPON":
				equip_label.text += " [威%d 射%d]" % [eq_def.might, eq_def.range_value]
	elif slot_id == &"weapon_1" or slot_id == &"weapon_2":
		# 武器槽位为空时显示基础武器信息
		var slot_index: int = 0 if slot_id == &"weapon_1" else 1
		var base_weapon = _mech.get_base_weapon(slot_index)
		if not base_weapon.is_empty():
			equip_label.text = "%s [威:%d 射:%d](空)" % [
				base_weapon.get("name", "基础武器"),
				base_weapon.get("might", 0),
				base_weapon.get("range_value", 1),
			]
			equip_label.add_theme_color_override("font_color", Color.CYAN)
		else:
			equip_label.text = "（空）"
	elif slot_id == &"reserve_1" or slot_id == &"reserve_2":
		# 备用区：对我方显示背面信息，对敌人显示"备用 未知"
		if slot.equipped_card and slot.equipped_card.def is _EquipmentCardDef:
			if _is_enemy:
				# 敌方：显示"备用 未知"
				equip_label.text = "备用 未知"
				equip_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			else:
				# 我方：显示"备用 XXX"
				equip_label.text = "备用 %s" % slot.equipped_card.def.display_name
				equip_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
		else:
			equip_label.text = "（空）"
	else:
		equip_label.text = "（空）"
	equip_label.custom_minimum_size = Vector2(100, 20)
	hbox.add_child(equip_label)

	# 损伤/耐久
	var damage_label = Label.new()
	if slot.equipped_card and slot.equipped_card.def is _EquipmentCardDef:
		var durability: int = slot.equipped_card.def.durability
		var card_dmg: int = slot.equipped_card.damage_tokens
		# 备用区特殊规则：装备耐久视为1
		if slot.slot_kind == &"RESERVE":
			durability = 1
		damage_label.text = "损伤:%d/%d" % [card_dmg, durability]
		if card_dmg >= durability:
			damage_label.add_theme_color_override("font_color", Color.RED)
		elif card_dmg > 0:
			damage_label.add_theme_color_override("font_color", Color.YELLOW)
	elif slot.region_damage_tokens > 0:
		damage_label.text = "区域损伤:%d" % slot.region_damage_tokens
		damage_label.add_theme_color_override("font_color", Color.YELLOW)
	else:
		damage_label.text = ""
	damage_label.custom_minimum_size = Vector2(70, 20)
	hbox.add_child(damage_label)

	# 有效护甲和动力（部件槽位）
	if slot.slot_kind == &"PART":
		var armor_label = Label.new()
		armor_label.text = "甲:%d" % slot.get_effective_armor()
		armor_label.custom_minimum_size = Vector2(35, 20)
		hbox.add_child(armor_label)

		var power_label = Label.new()
		power_label.text = "动:%d" % slot.get_effective_power()
		power_label.custom_minimum_size = Vector2(35, 20)
		hbox.add_child(power_label)

	# 武器槽位显示基础武器的耐久（固定1）
	if (slot_id == &"weapon_1" or slot_id == &"weapon_2") and not slot.equipped_card:
		var base_weapon = _mech.get_base_weapon(0 if slot_id == &"weapon_1" else 1)
		if not base_weapon.is_empty():
			damage_label.text = "（基础武器）"
			damage_label.add_theme_color_override("font_color", Color.CYAN)

	# 备用区设置按钮（仅在我方且有装备时显示）
	if (slot_id == &"reserve_1" or slot_id == &"reserve_2") and not _is_enemy:
		if slot.equipped_card != null:
			var set_btn = Button.new()
			set_btn.text = "设置"
			set_btn.custom_minimum_size = Vector2(40, 20)
			var captured_slot_id = slot_id
			set_btn.pressed.connect(func(): reserve_set_clicked.emit(captured_slot_id))
			hbox.add_child(set_btn)

	# 装备主动效果「触发」按钮：仅挂在该效果来源装备所在的槽位行内，
	# 按 equipped_card.instance_id 查 active_by_card 命中（仅玩家面板、有 context 时）。
	if not _is_enemy and slot.equipped_card != null and not active_by_card.is_empty():
		var inst_id: StringName = slot.equipped_card.instance_id
		if active_by_card.has(inst_id):
			for item: Dictionary in active_by_card[inst_id]:
				var eff = item.get("effect")
				var bind_ctx: Dictionary = item.get("bind_ctx", {})
				var btn = Button.new()
				btn.text = "触发"
				btn.tooltip_text = eff.description
				# 与备用区「设置」按钮同尺寸，避免撑满屏幕；效果详情靠悬停浮框显示
				btn.custom_minimum_size = Vector2(40, 20)
				btn.add_theme_color_override("font_color", Color(0.6, 0.9, 0.7))
				var cid: StringName = bind_ctx.get("card_instance_id", &"")
				var eid: StringName = eff.effect_id
				btn.pressed.connect(func(): equipment_active_clicked.emit(cid, eid))
				hbox.add_child(btn)

	add_child(hbox)

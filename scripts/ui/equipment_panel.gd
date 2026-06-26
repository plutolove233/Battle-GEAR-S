## EquipmentPanel.gd — 机甲装备面板
##
## 显示机甲的所有槽位（6部件+2武器+2备用+1事件+1机师），
## 每个槽位显示装备名、护甲/动力数值、损伤/耐久。
extends VBoxContainer
class_name EquipmentPanel

const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

## 当前机甲引用
var _mech = null  # type: MechState

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
func configure(mech) -> void:
	_mech = mech
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

	# 各槽位
	for slot_id: StringName in SLOT_ORDER:
		if not _mech.slots.has(slot_id):
			continue
		var slot: MechSlotState = _mech.slots[slot_id]
		_add_slot_row(slot_id, slot)


## 添加单行槽位显示
func _add_slot_row(slot_id: StringName, slot) -> void:
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
	else:
		equip_label.text = "（空）"
	equip_label.custom_minimum_size = Vector2(100, 20)
	hbox.add_child(equip_label)

	# 损伤/耐久
	var damage_label = Label.new()
	if slot.equipped_card and slot.equipped_card.def is _EquipmentCardDef:
		var durability: int = slot.equipped_card.def.durability
		var card_dmg: int = slot.equipped_card.damage_tokens
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

	# 有效护甲（部件槽位）
	if slot.slot_kind == &"PART":
		var armor_label = Label.new()
		armor_label.text = "护甲:%d" % slot.get_effective_armor()
		armor_label.custom_minimum_size = Vector2(40, 20)
		hbox.add_child(armor_label)

	add_child(hbox)

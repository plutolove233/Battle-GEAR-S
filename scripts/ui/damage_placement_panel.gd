## DamagePlacementPanel.gd — 损伤标记放置面板
##
## 攻击命中后，让玩家选择将损伤标记放置在目标机甲的哪个槽位。
## 每次点击一个槽位放置1个损伤标记，直到所有标记放完。
extends VBoxContainer
class_name DamagePlacementPanel

## 放置完成（所有损伤标记已放置）
signal placement_completed()

## 槽位显示顺序
const SLOT_ORDER: Array[StringName] = [
	&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿",
	&"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2",
	&"event_1", &"pilot_1",
]

## 槽位中文显示名
const SLOT_NAMES: Dictionary = {
	&"头部": "头部", &"躯干": "躯干", &"右臂": "右臂", &"左臂": "左臂",
	&"右腿": "右腿", &"左腿": "左腿", &"weapon_1": "武器1", &"weapon_2": "武器2",
	&"reserve_1": "备用1", &"reserve_2": "备用2", &"event_1": "事件", &"pilot_1": "机师",
}

## 当前 GameContext 引用
var _context = null  # type: GameContext
## 目标机甲 ID
var _target_mech_id: StringName = &""
## 剩余需放置的损伤标记数
var _remaining_tokens: int = 0
## 损伤放置来源攻击 ID（用于日志）
var _source_attack_id: StringName = &""


## 配置面板
func configure(game_context, target_mech_id: StringName, token_count: int, source_attack_id: StringName = &"") -> void:
	_context = game_context
	_target_mech_id = target_mech_id
	_remaining_tokens = token_count
	_source_attack_id = source_attack_id
	_refresh()


## 刷新面板显示
## P2-4: 每枚放置后刷新可选槽位（装备损坏后可选槽位可能变化）
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	if not _context:
		return

	var gs = _context.game_state
	var mech: MechState = gs.mechs.get(_target_mech_id)
	if not mech:
		return

	# P2-4: 使用 DamageTokenService 查询可选槽位
	var valid_slots: Array[StringName] = []
	if _context.damage_token_service:
		valid_slots = _context.damage_token_service.get_valid_damage_slots(_target_mech_id)

	# 标题：显示剩余损伤数
	var title = Label.new()
	title.text = "── 放置损伤标记（剩余: %d）──" % _remaining_tokens
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	# 目标机甲名称
	var mech_name = Label.new()
	mech_name.text = "目标: %s" % (mech.frame_def.display_name if mech.frame_def else String(_target_mech_id))
	mech_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(mech_name)

	# 每个槽位一行
	for slot_id: StringName in SLOT_ORDER:
		if not mech.slots.has(slot_id):
			continue
		var slot: MechSlotState = mech.slots[slot_id]
		var is_valid: bool = slot_id in valid_slots
		_add_slot_button(slot_id, slot, is_valid)


## 添加一个槽位按钮
## is_valid: 该槽位是否为当前合法放置目标
func _add_slot_button(slot_id: StringName, slot: MechSlotState, is_valid: bool) -> void:
	var hbox = HBoxContainer.new()

	# 槽位名称
	var name_label = Label.new()
	name_label.text = SLOT_NAMES.get(slot_id, String(slot_id))
	name_label.custom_minimum_size = Vector2(50, 0)
	hbox.add_child(name_label)

	# 装备信息
	var info_label = Label.new()
	if slot.equipped_card:
		var card_name: String = slot.equipped_card.def.display_name if slot.equipped_card.def else "?"
		var dmg: int = slot.equipped_card.damage_tokens
		var dur: int = slot.get_equipment_durability()
		info_label.text = "%s 损伤:%d/%d" % [card_name, dmg, dur]
	else:
		info_label.text = "（空）损伤:%d" % slot.region_damage_tokens
	info_label.custom_minimum_size = Vector2(160, 0)
	hbox.add_child(info_label)

	# 放置按钮
	var place_btn = Button.new()
	place_btn.text = "+1"
	place_btn.custom_minimum_size = Vector2(50, 28)
	# P2-4: 使用 is_valid 判断是否可放置（装备损坏后可选槽位会变化）
	if _remaining_tokens <= 0 or not is_valid:
		place_btn.disabled = true
	var captured_slot_id = slot_id
	place_btn.pressed.connect(func(): _on_place_token(captured_slot_id))
	hbox.add_child(place_btn)

	add_child(hbox)


## 点击放置一个损伤标记
## P2-4: 每放1枚后检查装备损坏，损坏则刷新可选槽位
func _on_place_token(slot_id: StringName) -> void:
	if _remaining_tokens <= 0:
		return
	if not _context:
		return

	var gs = _context.game_state
	var mech: MechState = gs.mechs.get(_target_mech_id)
	if not mech or not mech.slots.has(slot_id):
		return

	# 放置1个损伤标记
	_context.damage_token_service.place_one_damage_token(_target_mech_id, slot_id)
	_remaining_tokens -= 1

	# P2-4: 检查装备是否因损伤损坏（损坏后可选槽位会变化）
	_context.damage_token_service.check_and_handle_equipment_break(_target_mech_id, slot_id)

	# 刷新显示（装备损坏后可选槽位可能变化）
	_refresh()

	# 全部放置完毕
	if _remaining_tokens <= 0:
		placement_completed.emit()

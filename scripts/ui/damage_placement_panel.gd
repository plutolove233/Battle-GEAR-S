## DamagePlacementPanel.gd — 损伤标记放置面板
##
## 攻击命中后，让玩家选择将损伤标记放置在目标机甲的哪个槽位。
## 每次点击一个槽位放置1个损伤标记，直到所有标记放完。
extends PanelContainer
class_name DamagePlacementPanel

## 面板背景样式（深色不透明，确保在战场上清晰可读）
const _BG_STYLE := {
	"bg_color": Color(0.08, 0.09, 0.12, 0.96),
	"border_width": 2,
	"border_color": Color(0.85, 0.75, 0.3, 0.9),
	"corner_radius": 6,
	"content_margin": 12,
}

## 放置完成（所有损伤标记已放置）
signal placement_completed()
## PvP client 模式：每点一个槽位 emit（不本地真改 state，由 host 应用；client 仅乐观更新 mirror 刷新显示）
signal token_placed(slot_id: StringName)
## PvP client 模式 removal：每点一个槽位 emit（移除1损伤，走 damage_remove op）
signal token_removed(slot_id: StringName)

## PvP client 模式开关
var network_mode: bool = false

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
var _removal_mode: bool = false
## removal 模式下排除的槽位（effect_079 移除"其他区域"损伤，排除来源槽）
var _exclude_slot_id: StringName = &""
## 来源标签（"牌名：效果描述"，可空）
var _source_text: String = ""


## 配置面板
func configure(game_context, target_mech_id: StringName, token_count: int, source_attack_id: StringName = &"") -> void:
	_context = game_context
	_target_mech_id = target_mech_id
	_remaining_tokens = token_count
	_source_attack_id = source_attack_id
	_removal_mode = false
	_exclude_slot_id = &""
	_source_text = ""
	_ensure_styled()
	_refresh()


func configure_removal(game_context, target_mech_id: StringName, token_count: int, exclude_slot_id: StringName = &"", source_label: String = "") -> void:
	_context = game_context
	_target_mech_id = target_mech_id
	_remaining_tokens = token_count
	_source_attack_id = &""
	_removal_mode = true
	_exclude_slot_id = exclude_slot_id
	_source_text = source_label
	_ensure_styled()
	_refresh()


## 确保面板背景样式已应用（深色不透明 + 金色描边，战场上清晰可读）
func _ensure_styled() -> void:
	custom_minimum_size = Vector2(380, 0)
	var style = StyleBoxFlat.new()
	style.bg_color = _BG_STYLE.bg_color
	style.set_border_width_all(_BG_STYLE.border_width)
	style.border_color = _BG_STYLE.border_color
	style.set_corner_radius_all(_BG_STYLE.corner_radius)
	style.set_content_margin_all(_BG_STYLE.content_margin)
	add_theme_stylebox_override("panel", style)


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

	# PanelContainer 是单子节点容器，必须用一个 VBoxContainer 包裹所有内容，
	# 否则标题/机甲名/各槽位行会挤在一起无法布局。
	var vbox = VBoxContainer.new()
	vbox.name = "DamagePlacementContent"
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	# P2-4: 使用 DamageTokenService 查询可选槽位
	var valid_slots: Array[StringName] = []
	if _removal_mode:
		for slot_id: StringName in mech.slots:
			if slot_id == _exclude_slot_id:
				continue  # 排除来源槽（effect_079 移除"其他区域"损伤）
			var damage_slot: MechSlotState = mech.slots[slot_id]
			if damage_slot.region_damage_tokens > 0 or (damage_slot.equipped_card != null and damage_slot.equipped_card.damage_tokens > 0):
				valid_slots.append(slot_id)
	elif _context.damage_token_service:
		valid_slots = _context.damage_token_service.get_valid_damage_slots(_target_mech_id)

	# removal 边界：待移除数>0 但已无损伤可移（目标损伤不足 value）-> 提前完成，避免卡死
	if _removal_mode and _remaining_tokens > 0 and valid_slots.is_empty():
		placement_completed.emit()
		return

	# 标题：显示剩余损伤数
	var title = Label.new()
	title.text = ("── 移除损伤标记（剩余: %d）──" if _removal_mode else "── 放置损伤标记（剩余: %d）──") % _remaining_tokens
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# 来源标签（装备离场/维修等效果来源，可空）
	if _source_text != "":
		var src_label = Label.new()
		src_label.text = _source_text
		src_label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
		src_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		src_label.add_theme_font_size_override("font_size", 14)
		vbox.add_child(src_label)

	# 目标机甲名称
	var mech_name = Label.new()
	mech_name.text = "目标: %s" % (mech.frame_def.display_name if mech.frame_def else String(_target_mech_id))
	mech_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(mech_name)

	# 每个槽位一行
	for slot_id: StringName in SLOT_ORDER:
		if not mech.slots.has(slot_id):
			continue
		var slot: MechSlotState = mech.slots[slot_id]
		var is_valid: bool = slot_id in valid_slots
		_add_slot_button(vbox, slot_id, slot, is_valid)


## 添加一个槽位按钮
## is_valid: 该槽位是否为当前合法放置目标
func _add_slot_button(parent: Control, slot_id: StringName, slot: MechSlotState, is_valid: bool) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

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
	info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info_label)

	# 放置按钮
	var place_btn = Button.new()
	place_btn.text = "-1" if _removal_mode else "+1"
	place_btn.custom_minimum_size = Vector2(50, 28)
	# P2-4: 使用 is_valid 判断是否可放置（装备损坏后可选槽位会变化）
	if _remaining_tokens <= 0 or not is_valid:
		place_btn.disabled = true
	var captured_slot_id = slot_id
	place_btn.pressed.connect(func(): _on_token_clicked(captured_slot_id))
	hbox.add_child(place_btn)

	parent.add_child(hbox)


## 点击放置一个损伤标记
## P2-4: 每放1枚后检查装备损坏，损坏则刷新可选槽位
func _on_token_clicked(slot_id: StringName) -> void:
	if _remaining_tokens <= 0:
		return
	if not _context:
		return

	if network_mode:
		# 锁步:emit 给 app_root 转 _net_exec 双端应用。removal 模式走 damage_remove op。
		if _removal_mode:
			token_removed.emit(slot_id)
		else:
			token_placed.emit(slot_id)
		_remaining_tokens -= 1
		_refresh()
		if _remaining_tokens <= 0:
			placement_completed.emit()
		return

	var gs = _context.game_state
	var mech: MechState = gs.mechs.get(_target_mech_id)
	if not mech or not mech.slots.has(slot_id):
		return

	# 放置1个损伤标记
	if _removal_mode:
		_context.game_actions.remove_damage_tokens({"mech_id": _target_mech_id, "slot_id": slot_id, "amount": 1})
	else:
		_context.damage_token_service.place_one_damage_token(_target_mech_id, slot_id)
	_remaining_tokens -= 1

	# P2-4: 检查装备是否因损伤损坏（损坏后可选槽位会变化）
	if not _removal_mode:
		_context.damage_token_service.check_and_handle_equipment_break(_target_mech_id, slot_id)

	# 刷新显示（装备损坏后可选槽位可能变化）
	_refresh()

	# 全部放置完毕
	if _remaining_tokens <= 0:
		placement_completed.emit()

## WeaponPickerPanel.gd — 武器选择面板
##
## 当机甲有多把武器时，弹出此面板让玩家选择使用哪把武器攻击。
## 先点击选择武器高亮，再点击确认按钮提交。
extends PanelContainer
class_name WeaponPickerPanel

const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")

## 确认选择了一把武器
signal weapon_selected(weapon_id: StringName)
## 取消武器选择
signal selection_cancelled()

## 当前 GameContext 引用
var _context = null  # type: GameContext
## 自定义标题
var _title_text: String = "── 选择武器 ──"
## 当前机甲引用（用于获取基础武器数据）
var _mech = null  # type: MechState
## 当前选中的武器ID
var _selected_weapon_id: StringName = &""
## 当前可选武器ID列表
var _current_weapon_ids: Array[StringName] = []

## 内部布局
var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _title_label: Label
var _confirm_btn: Button


## 配置面板：显示可选武器列表
func configure(game_context, weapon_ids: Array[StringName], title: String = "── 选择武器 ──", mech = null) -> void:
	_context = game_context
	_title_text = title
	_mech = mech
	_selected_weapon_id = &""
	_current_weapon_ids = weapon_ids
	_ensure_layout()
	_refresh()


## 确保布局已初始化
func _ensure_layout() -> void:
	if _vbox:
		return

	# 创建主 VBox 容器
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	# 标题
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.3, 0.8, 0.9))
	_vbox.add_child(_title_label)

	# 滚动容器
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(280, 200)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_vbox.add_child(_scroll)

	# 滚动内容容器
	var scroll_content = VBoxContainer.new()
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("separation", 4)
	_scroll.add_child(scroll_content)
	_scroll.set_meta("content", scroll_content)

	# 确认按钮
	_confirm_btn = Button.new()
	_confirm_btn.custom_minimum_size = Vector2(220, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(func(): _on_confirm())
	_vbox.add_child(_confirm_btn)

	# 取消按钮
	var cancel_btn = Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(220, 40)
	cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cancel_btn.pressed.connect(func(): selection_cancelled.emit())
	_vbox.add_child(cancel_btn)


## 刷新武器列表
func _refresh() -> void:
	if not _vbox:
		return

	# 更新标题
	_title_label.text = _title_text

	# 更新确认按钮状态
	_confirm_btn.text = "确认选择" if _selected_weapon_id != &"" else "请选择武器"
	_confirm_btn.disabled = _selected_weapon_id == &""
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.8, 0.9) if _selected_weapon_id != &"" else Color(0.5, 0.5, 0.5))

	# 获取滚动内容容器
	var scroll_content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if not scroll_content:
		return

	# 清空现有内容
	for child in scroll_content.get_children():
		child.queue_free()

	if not _context:
		return

	var gs = _context.game_state
	for wid: StringName in _current_weapon_ids:
		var wid_str = String(wid)
		var btn: Button = null
		var is_base_weapon: bool = false
		var base_slot_index: int = 0

		# 检查是否是基础武器虚拟 ID（如 frame_base_weapon_1 或 frame_base_weapon_2）
		var _base_weapon_prefix := "frame_base_weapon_"
		if wid_str.begins_with(_base_weapon_prefix) and _mech != null:
			# 前缀 "frame_base_weapon_" 长度为 18，substr(18) 取末尾数字（"1"/"2"）
			base_slot_index = int(wid_str.substr(_base_weapon_prefix.length())) - 1
			is_base_weapon = true

		if is_base_weapon:
			var base_weapon = _mech.get_base_weapon(base_slot_index)
			if base_weapon.is_empty():
				continue
			btn = Button.new()
			var slot_name = "武器%d" % [base_slot_index + 1]
			btn.text = "%s: %s [威:%d 射:%d]" % [
				slot_name,
				base_weapon.get("name", "基础武器"),
				base_weapon.get("might", 0),
				base_weapon.get("range_value", 1),
			]
			btn.custom_minimum_size = Vector2(260, 36)
			btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			if wid == _selected_weapon_id:
				btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
				btn.modulate = Color(1.2, 1.2, 0.8)
			else:
				btn.add_theme_color_override("font_color", Color.CYAN)
		else:
			# 普通装备武器 / 虚拟武器（帝国的神莺·躯干 effect_087）
			var card = gs.cards.get(wid)
			if not card or not card.def:
				continue
			btn = Button.new()
			var vw = _GenEquipEffects.get_virtual_weapon_from_equipment(card)
			if not vw.is_empty():
				# 虚拟武器：躯干当远程武器用，不占武器槽
				btn.text = "%s(虚拟武器) [威力:%d 射程:%d]" % [
					String(vw.get("display_name", card.def.display_name)),
					int(vw.get("might", 20)),
					int(vw.get("range_value", 6)),
				]
			else:
				btn.text = "%s [威力:%d 射程:%d]" % [
					card.def.display_name,
					card.def.might,
					card.def.range_value,
				]
			btn.custom_minimum_size = Vector2(260, 36)
			btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			if wid == _selected_weapon_id:
				btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
				btn.modulate = Color(1.2, 1.2, 0.8)

		var captured_id = wid
		btn.pressed.connect(func(): _on_weapon_clicked(captured_id))
		scroll_content.add_child(btn)


## 点击武器选项：选择/取消选择
func _on_weapon_clicked(weapon_id: StringName) -> void:
	if _selected_weapon_id == weapon_id:
		_selected_weapon_id = &""  # 再次点击取消选择
	else:
		_selected_weapon_id = weapon_id
	_refresh()


## 确认选择
func _on_confirm() -> void:
	if _selected_weapon_id != &"":
		weapon_selected.emit(_selected_weapon_id)

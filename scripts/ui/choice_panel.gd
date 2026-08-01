## ChoicePanel.gd — 效果选择面板
##
## 当辅助牌有多个可选效果时弹出，让玩家选择一个效果。
## 先点击选项高亮选择，再点击确认按钮提交。
extends PanelContainer
class_name ChoicePanel

## 玩家确认了某个效果选择
signal choice_made(effect_id: StringName)
## 取消选择
signal choice_cancelled()

## 内部布局
var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _confirm_btn: Button
## 来源标签（"牌名：效果描述"，可空）
var _source_label: Label
## 当前选中的效果ID
var _selected_effect_id: StringName = &""
## 当前可选选项列表
var _current_options: Array[Dictionary] = []


## 配置面板：显示可选效果列表
func configure(options: Array[Dictionary], source_label: String = "") -> void:
	_selected_effect_id = &""
	_current_options = options
	_ensure_layout()
	if _source_label:
		_source_label.text = source_label
		_source_label.visible = source_label != ""
	_refresh()


## 确保布局已初始化
func _ensure_layout() -> void:
	if _vbox:
		return

	# 创建主 VBox 容器
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	# 来源标签（效果牌名+描述，可空）
	_source_label = Label.new()
	_source_label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_source_label.add_theme_font_size_override("font_size", 14)
	_source_label.visible = false
	_vbox.add_child(_source_label)

	# 标题
	var title = Label.new()
	title.text = "── 效果选择 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	_vbox.add_child(title)

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
	_confirm_btn.custom_minimum_size = Vector2(240, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(func(): _on_confirm())
	_vbox.add_child(_confirm_btn)

	# 取消按钮
	var cancel_btn = Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(240, 40)
	cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cancel_btn.pressed.connect(func(): choice_cancelled.emit())
	_vbox.add_child(cancel_btn)


## 刷新显示
func _refresh() -> void:
	if not _vbox:
		return

	# 更新确认按钮状态
	_confirm_btn.text = "确认选择" if _selected_effect_id != &"" else "请选择"
	_confirm_btn.disabled = _selected_effect_id == &""
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4) if _selected_effect_id != &"" else Color(0.5, 0.5, 0.5))

	# 获取滚动内容容器
	var scroll_content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if not scroll_content:
		return

	# 清空现有内容
	for child in scroll_content.get_children():
		child.queue_free()

	if _current_options.is_empty():
		var no_opt = Label.new()
		no_opt.text = "（无可选效果）"
		no_opt.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		no_opt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		scroll_content.add_child(no_opt)
		return

	# 每个选项一个按钮（点击只是选择/高亮，不直接确认）
	for option in _current_options:
		var label: String = String(option.get("label", ""))
		var effect_id: StringName = StringName(option.get("effect_id", &""))
		var btn = Button.new()
		btn.text = label
		btn.custom_minimum_size = Vector2(260, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		# 已选中高亮
		if effect_id == _selected_effect_id:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)
		var eid = effect_id
		btn.pressed.connect(func(): _on_option_selected(eid))
		scroll_content.add_child(btn)


## 点击选项：选择/取消选择
func _on_option_selected(effect_id: StringName) -> void:
	if _selected_effect_id == effect_id:
		_selected_effect_id = &""  # 再次点击取消选择
	else:
		_selected_effect_id = effect_id
	_refresh()


## 确认选择
func _on_confirm() -> void:
	if _selected_effect_id != &"":
		choice_made.emit(_selected_effect_id)

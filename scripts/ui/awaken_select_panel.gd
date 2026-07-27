## AwakenSelectPanel.gd - 觉醒种类选择面板
##
## 觉醒效果（action_024_觉醒）：当弃牌堆中不存在预判/识破时弹出，
## 列出行动弃牌堆里所有行动牌种类及对应数量，由玩家单选1种。
## 确认后获得弃牌堆中该种类1张 + 行动牌堆顶1张。
##
## 通用设计：不绑定具体玩家，由 app_root 按 player_id 路由到对应人类玩家窗口。
## 选择为强制（规格要求"选择其中1种"），故无取消按钮。
extends PanelContainer
class_name AwakenSelectPanel

## 选择完成时发射（selected_def_id 为选中的 card_def_id）
signal selection_completed(selected_def_id: StringName)
## 取消（保留以备扩展；当前 UI 不提供取消按钮）
signal selection_cancelled()

var _context = null  # type: GameContext
var _options: Array[Dictionary] = []  # [{def_id, label, count}]
var _selected: StringName = &""  # 当前选中的 card_def_id（单选）
var _label: String = "觉醒：选择1种行动牌"
var _hint: String = ""  # 已获得提示（如"已获得 预判 ×1"）

var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _confirm_btn: Button
var _hint_label: Label


func configure(game_context, options: Array, label: String = "觉醒：选择1种行动牌", hint: String = "") -> void:
	_context = game_context
	_options.clear()
	for opt in options:
		if opt is Dictionary:
			_options.append(opt)
	_label = label
	_hint = hint
	_selected = &""
	_ensure_layout()
	_refresh()


func _ready() -> void:
	call_deferred("_ensure_layout")


func _ensure_layout() -> void:
	if _vbox:
		return
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	var title := Label.new()
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = "── %s ──" % _label
	title.name = "TitleLabel"
	_vbox.add_child(title)

	# 已获得提示（如"已获得 预判 ×1"），仅"缺少之一"场景非空
	_hint_label = Label.new()
	_hint_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.name = "HintLabel"
	_vbox.add_child(_hint_label)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(300, 220)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_vbox.add_child(_scroll)

	var scroll_content = VBoxContainer.new()
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("separation", 4)
	_scroll.add_child(scroll_content)
	_scroll.set_meta("content", scroll_content)

	_confirm_btn = Button.new()
	_confirm_btn.custom_minimum_size = Vector2(260, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(func(): _on_confirm())
	_vbox.add_child(_confirm_btn)


func _refresh() -> void:
	if not _vbox:
		return
	var title = _vbox.get_node_or_null("TitleLabel")
	if title != null:
		title.text = "── %s ──" % _label
	if _hint_label != null:
		_hint_label.text = _hint
		_hint_label.visible = (_hint != "")
	_confirm_btn.text = "确认选择" if _selected != &"" else "请选择1种"
	_confirm_btn.disabled = (_selected == &"")
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4) if _selected != &"" else Color(0.5, 0.5, 0.5))

	var scroll_content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if not scroll_content:
		return
	for child in scroll_content.get_children():
		child.queue_free()
	if _options.is_empty():
		var empty = Label.new()
		empty.text = "（弃牌堆无行动牌可选）"
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		scroll_content.add_child(empty)
		return
	for opt in _options:
		var did: StringName = opt.get("def_id", &"")
		var lbl: String = String(opt.get("label", String(did)))
		var btn = Button.new()
		btn.text = lbl
		btn.tooltip_text = String(opt.get("tooltip", ""))
		btn.custom_minimum_size = Vector2(280, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		if did == _selected:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)
		var captured = did
		btn.pressed.connect(func(): _on_option_selected(captured))
		scroll_content.add_child(btn)


## 单选：选中1种，再点同1种取消选中
func _on_option_selected(def_id: StringName) -> void:
	if _selected == def_id:
		_selected = &""
	else:
		_selected = def_id
	_refresh()


func _on_confirm() -> void:
	if _selected != &"":
		selection_completed.emit(_selected)

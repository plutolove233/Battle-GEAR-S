## Pilot003SkipPanel.gd — pilot_003 瑟尔基尔「跳过公开牌」复选框面板
##
## 点机师效果按钮弹此面板：列出所有玩家（含自己），CheckBox 勾选「抽牌跳过正面牌」
## 的玩家，提交后生效（裁定权威"重要补充"：可随时更改，提交后才更新）。
## 被勾选玩家抽牌遇正面牌自动跳过；自己勾选且将抽到正面牌时抽牌数+1（按"次"计）。
extends PanelContainer
class_name Pilot003SkipPanel

## 提交勾选的玩家集合
signal skip_players_submitted(player_ids: Array)
## 取消（不修改）
signal skip_players_cancelled()

## 内部布局
var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _checkboxes: Dictionary = {}  # String(player_id) -> CheckBox
var _source_label: Label


## 配置面板：列出所有玩家，回显当前勾选
func configure(player_ids: Array, checked_ids: Array, source_label: String = "") -> void:
	_ensure_layout()
	if _source_label:
		_source_label.text = source_label
		_source_label.visible = source_label != ""
	_refresh(player_ids, checked_ids)


func _ensure_layout() -> void:
	if _vbox:
		return
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	_source_label = Label.new()
	_source_label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_source_label.add_theme_font_size_override("font_size", 14)
	_source_label.visible = false
	_vbox.add_child(_source_label)

	var title = Label.new()
	title.text = "── 跳过公开牌：勾选玩家 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	_vbox.add_child(title)

	var hint = Label.new()
	hint.text = "被勾选玩家抽牌时自动跳过牌堆正面朝上的牌；\n自己勾选且将抽到正面牌时，此次抽牌数+1。"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	_vbox.add_child(hint)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(280, 150)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_vbox.add_child(_scroll)

	var scroll_content = VBoxContainer.new()
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("separation", 4)
	_scroll.add_child(scroll_content)
	_scroll.set_meta("content", scroll_content)

	# 提交/取消按钮
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 16)
	_vbox.add_child(hbox)

	var submit_btn = Button.new()
	submit_btn.text = "提交"
	submit_btn.custom_minimum_size = Vector2(120, 36)
	submit_btn.pressed.connect(_on_submit)
	hbox.add_child(submit_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(120, 36)
	cancel_btn.pressed.connect(func(): skip_players_cancelled.emit())
	hbox.add_child(cancel_btn)


## 刷新显示：重建复选框列表
func _refresh(player_ids: Array, checked_ids: Array) -> void:
	if not _vbox or not _scroll:
		return
	var scroll_content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if not scroll_content:
		return
	for child in scroll_content.get_children():
		child.queue_free()
	_checkboxes.clear()

	var checked_set: Dictionary = {}
	for c in checked_ids:
		checked_set[String(c)] = true

	for pid in player_ids:
		var pid_str: String = String(pid)
		var cb = CheckBox.new()
		cb.text = "玩家 %s" % pid_str
		cb.button_pressed = checked_set.has(pid_str)
		cb.custom_minimum_size = Vector2(260, 30)
		cb.add_theme_font_size_override("font_size", 14)
		scroll_content.add_child(cb)
		_checkboxes[pid_str] = cb


func _on_submit() -> void:
	var selected: Array = []
	for pid_str in _checkboxes:
		if _checkboxes[pid_str].button_pressed:
			selected.append(pid_str)
	skip_players_submitted.emit(selected)

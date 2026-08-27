## WeaponModifyOptionsPanel.gd — 瓦恩 pilot_083 武器修改：三横排选项面板
##
## 选中武器后弹出：3 个横向行，每行 2 个互斥选项（行间独立、可再点取消选中，全部可留空）：
##   行1 名称附加：热能 / 光束
##   行2 类型转变：近战 / 远程
##   行3 数值加成：威力+3 / 范围+1
## 底部「确认施加」+「取消」。确认后 emit options_confirmed（打包状态），取消 emit options_cancelled。
extends PanelContainer
class_name WeaponModifyOptionsPanel

## 确认：打包状态 {name_suffix: String, type_override: StringName, might: int, range: int}
signal options_confirmed(payload: Dictionary)
## 取消
signal options_cancelled()

## 内部布局
var _vbox: VBoxContainer
var _source_label: Label
var _confirm_btn: Button
var _cancel_btn: Button
## 行按钮引用：{row_key: {value: Button}}
var _row_buttons: Dictionary = {}
## 每行当前选中值（"" = 未选）
var _row_selection: Dictionary = {}
## 行定义：{key, title, options: [{value, text}]}
const _ROWS: Array = [
	{"key": &"name", "title": "名称附加", "options": [{"value": "热能", "text": "热能"}, {"value": "光束", "text": "光束"}]},
	{"key": &"type", "title": "类型转变", "options": [{"value": &"近战", "text": "近战"}, {"value": &"远程", "text": "远程"}]},
	{"key": &"value", "title": "数值加成", "options": [{"value": &"might", "text": "威力+3"}, {"value": &"range", "text": "范围+1"}]},
]


## 配置面板：显示三横排选项。
func configure(weapon_name: String, source_label: String = "") -> void:
	_ensure_layout()
	# 重置选中状态（面板复用）
	_row_selection = {}
	for rk in _row_buttons:
		for bv in _row_buttons[rk]:
			var _b: Button = _row_buttons[rk][bv]
			_b.set_pressed_no_signal(false)
	if _source_label:
		_source_label.text = source_label if source_label != "" else "对「%s」施加武器修改" % weapon_name
		_source_label.visible = true
	_refresh()


## 确保布局已初始化
func _ensure_layout() -> void:
	if _vbox:
		return

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 10)
	add_child(_vbox)

	# 来源标签（武器名+说明）
	_source_label = Label.new()
	_source_label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_source_label.add_theme_font_size_override("font_size", 14)
	_source_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_source_label.custom_minimum_size = Vector2(420, 0)
	_vbox.add_child(_source_label)

	# 说明
	var hint = Label.new()
	hint.text = "每行可独立选择1项（再点取消）；三行可全部留空。确认后施加，持续到下个我方回合结束。"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.6, 0.68, 0.75))
	hint.add_theme_font_size_override("font_size", 12)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(420, 0)
	_vbox.add_child(hint)

	# 三行选项
	for row in _ROWS:
		var row_key: StringName = row["key"]
		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 12)
		hbox.alignment = BoxContainer.ALIGNMENT_CENTER
		_vbox.add_child(hbox)
		var title_lbl = Label.new()
		title_lbl.text = "%s：" % String(row["title"])
		title_lbl.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
		title_lbl.add_theme_font_size_override("font_size", 14)
		title_lbl.custom_minimum_size = Vector2(90, 0)
		hbox.add_child(title_lbl)
		var row_btns: Dictionary = {}
		for opt in row["options"]:
			var opt_val: Variant = opt["value"]
			var btn = Button.new()
			btn.text = String(opt["text"])
			btn.custom_minimum_size = Vector2(120, 40)
			btn.toggle_mode = true
			btn.add_theme_font_size_override("font_size", 14)
			btn.add_theme_color_override("font_color_pressed", Color(1.0, 0.85, 0.2))
			var rk = row_key
			var ov = opt_val
			btn.toggled.connect(func(on: bool): _on_row_toggled(rk, ov, on))
			hbox.add_child(btn)
			row_btns[ov] = btn
		_row_buttons[row_key] = row_btns

	# 确认 / 取消按钮
	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 16)
	btn_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_vbox.add_child(btn_hbox)
	_confirm_btn = Button.new()
	_confirm_btn.text = "确认施加"
	_confirm_btn.custom_minimum_size = Vector2(150, 40)
	_confirm_btn.add_theme_font_size_override("font_size", 14)
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	_confirm_btn.pressed.connect(func(): _on_confirm())
	btn_hbox.add_child(_confirm_btn)
	_cancel_btn = Button.new()
	_cancel_btn.text = "取消"
	_cancel_btn.custom_minimum_size = Vector2(120, 40)
	_cancel_btn.add_theme_font_size_override("font_size", 14)
	_cancel_btn.pressed.connect(func(): options_cancelled.emit())
	btn_hbox.add_child(_cancel_btn)


## 刷新确认按钮可用状态（全可选留空，始终可确认）
func _refresh() -> void:
	if _confirm_btn:
		_confirm_btn.disabled = false


## 行内选项切换：互斥（同行使其他取消勾选）+ 可再点取消
func _on_row_toggled(row_key: StringName, value: Variant, on: bool) -> void:
	var row_btns: Dictionary = _row_buttons.get(row_key, {})
	if on:
		_row_selection[row_key] = value
		# 互斥：同行使其他按钮取消勾选
		for ov in row_btns:
			if ov != value:
				var other_btn: Button = row_btns[ov]
				if other_btn.button_pressed:
					other_btn.set_pressed_no_signal(false)
	else:
		if _row_selection.get(row_key) == value:
			_row_selection.erase(row_key)


## 确认：打包状态
func _on_confirm() -> void:
	var payload: Dictionary = {}
	payload["name_suffix"] = String(_row_selection.get(&"name", ""))
	payload["type_override"] = _row_selection.get(&"type", &"")
	payload["might"] = 3 if _row_selection.get(&"value") == &"might" else 0
	payload["range"] = 1 if _row_selection.get(&"value") == &"range" else 0
	options_confirmed.emit(payload)

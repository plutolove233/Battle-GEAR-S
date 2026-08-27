## StepperPanel.gd - 步进数值输入面板
##
## pilot_004 玛沙 装甲转能用：LineEdit + ±3 按钮 + 键盘输入。
## 默认 0，最大=有效护甲；确认后发 choice_made("__int_N__")（与 ChoicePanel 接口一致，app_root 复用 choose_integer 回填）。
extends PanelContainer
class_name StepperPanel

## 玩家确认了某数值（effect_id 格式 __int_N__，与 ChoicePanel 一致）
signal choice_made(effect_id: StringName)
## 取消选择
signal choice_cancelled()

var _vbox: VBoxContainer
var _title: Label
var _value_label: Label
var _line_edit: LineEdit
var _minus_btn: Button
var _plus_btn: Button
var _confirm_btn: Button
var _cancel_btn: Button
var _current_value: int = 0
var _min_value: int = 0
var _max_value: int = 0
var _step_value: int = 3
var _range_hint: Label


## 配置面板：显示提示，设置范围。默认值 = min_value（通常 0）。
## step_val：±按钮步长（默认3=玛沙装甲转能；维罗妮卡给金用5）。
func configure(label: String, min_val: int, max_val: int, optional: bool, step_val: int = 3) -> void:
	_min_value = min_val
	_max_value = max_val
	_step_value = maxi(1, step_val)
	_current_value = min_val
	_ensure_layout()
	_title.text = label
	_refresh_value()
	_cancel_btn.visible = optional
	_confirm_btn.disabled = false
	# 范围标签随 configure 更新（_ensure_layout 首次创建时设过，二次 configure 因
	# if _vbox: return 不再进 _ensure_layout，range_hint 仍是旧值--此处显式刷新）
	if _range_hint:
		_range_hint.text = "范围：%d ~ %d" % [_min_value, _max_value]


## 确保布局已初始化
func _ensure_layout() -> void:
	if _vbox:
		return
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	# 标题（效果描述）
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	_title.add_theme_font_size_override("font_size", 14)
	_vbox.add_child(_title)

	# 当前值显示（大字）
	_value_label = Label.new()
	_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_value_label.add_theme_font_size_override("font_size", 28)
	_value_label.add_theme_color_override("font_color", Color(0.6, 0.95, 0.7))
	_vbox.add_child(_value_label)

	# 输入行：[-step] [LineEdit] [+step]
	var input_row = HBoxContainer.new()
	input_row.alignment = BoxContainer.ALIGNMENT_CENTER
	input_row.add_theme_constant_override("separation", 8)

	_minus_btn = Button.new()
	_minus_btn.text = "-%d" % _step_value
	_minus_btn.custom_minimum_size = Vector2(50, 40)
	_minus_btn.pressed.connect(_on_minus)
	input_row.add_child(_minus_btn)

	_line_edit = LineEdit.new()
	_line_edit.custom_minimum_size = Vector2(80, 40)
	_line_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_line_edit.placeholder_text = "0"
	_line_edit.text = "0"
	_line_edit.text_changed.connect(_on_text_changed)
	_line_edit.text_submitted.connect(_on_text_submitted)
	input_row.add_child(_line_edit)

	_plus_btn = Button.new()
	_plus_btn.text = "+%d" % _step_value
	_plus_btn.custom_minimum_size = Vector2(50, 40)
	_plus_btn.pressed.connect(_on_plus)
	input_row.add_child(_plus_btn)

	_vbox.add_child(input_row)

	# 范围提示
	_range_hint = Label.new()
	_range_hint.text = "范围：%d ~ %d" % [_min_value, _max_value]
	_range_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_range_hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_range_hint.add_theme_font_size_override("font_size", 11)
	_vbox.add_child(_range_hint)

	# 确认按钮
	_confirm_btn = Button.new()
	_confirm_btn.text = "确认"
	_confirm_btn.custom_minimum_size = Vector2(240, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(_on_confirm)
	_vbox.add_child(_confirm_btn)

	# 取消按钮（optional 时显示）
	_cancel_btn = Button.new()
	_cancel_btn.text = "取消"
	_cancel_btn.custom_minimum_size = Vector2(240, 40)
	_cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel_btn.visible = false
	_cancel_btn.pressed.connect(_on_cancel)
	_vbox.add_child(_cancel_btn)


## 刷新数值显示
func _refresh_value() -> void:
	_current_value = clamp(_current_value, _min_value, _max_value)
	_value_label.text = str(_current_value)
	# LineEdit 同步（不触发 text_changed 回环：用 set_text 不发信号）
	if _line_edit and _line_edit.text != str(_current_value):
		_line_edit.set_text(str(_current_value))


func _on_plus() -> void:
	_current_value = mini(_current_value + _step_value, _max_value)
	_refresh_value()


func _on_minus() -> void:
	_current_value = maxi(_current_value - _step_value, _min_value)
	_refresh_value()


## 键盘输入：解析数字，过滤非法字符并回写 LineEdit
func _on_text_changed(new_text: String) -> void:
	# 只保留数字
	var filtered := ""
	for ch in new_text:
		if ch >= "0" and ch <= "9":
			filtered += ch
	# 含非法字符：回写过滤后的纯数字文本（set_text 不触发 text_changed 回环），
	# 恢复光标位置（被滤掉的非法字符占位，光标回退一位，钳制到过滤后文本长度内）
	if filtered != new_text:
		var caret := _line_edit.caret_column
		_line_edit.set_text(filtered)
		_line_edit.set_caret_column(clampi(caret - 1, 0, filtered.length()))
	var n: int = filtered.to_int() if filtered != "" else 0
	_current_value = clamp(n, _min_value, _max_value)
	# 更新大字显示
	_value_label.text = str(_current_value)


## 回车提交
func _on_text_submitted(_text: String) -> void:
	_on_confirm()


func _on_confirm() -> void:
	_current_value = clamp(_current_value, _min_value, _max_value)
	choice_made.emit(StringName("__int_%d__" % _current_value))


func _on_cancel() -> void:
	choice_cancelled.emit()

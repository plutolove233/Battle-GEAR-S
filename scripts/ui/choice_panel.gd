## ChoicePanel.gd — 效果选择面板
##
## 当辅助牌有多个可选效果时弹出，让玩家选择一个效果。
extends VBoxContainer
class_name ChoicePanel

## 玩家选择了某个效果
signal choice_made(effect_id: StringName)
## 取消选择
signal choice_cancelled()


## 配置面板：显示可选效果列表
func configure(options: Array[Dictionary]) -> void:
	for child in get_children():
		child.queue_free()

	# 标题
	var title = Label.new()
	title.text = "── 效果选择 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	add_child(title)

	if options.is_empty():
		var no_opt = Label.new()
		no_opt.text = "（无可选效果）"
		no_opt.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(no_opt)
		return

	# 每个选项一个按钮
	for option in options:
		var label: String = String(option.get("label", ""))
		var effect_id: StringName = StringName(option.get("effect_id", &""))
		var btn = Button.new()
		btn.text = label
		btn.custom_minimum_size = Vector2(240, 36)
		var eid = effect_id
		btn.pressed.connect(func(): choice_made.emit(eid))
		add_child(btn)

	# 取消按钮
	var cancel_btn = Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(240, 36)
	cancel_btn.pressed.connect(func(): choice_cancelled.emit())
	add_child(cancel_btn)

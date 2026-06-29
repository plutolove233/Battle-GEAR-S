## WeaponPickerPanel.gd — 武器选择面板
##
## 当机甲有多把武器时，弹出此面板让玩家选择使用哪把武器攻击。
extends VBoxContainer
class_name WeaponPickerPanel

## 选择了一把武器
signal weapon_selected(weapon_id: StringName)
## 取消武器选择
signal selection_cancelled()

## 当前 GameContext 引用
var _context = null  # type: GameContext


## 配置面板：显示可选武器列表
func configure(game_context, weapon_ids: Array[StringName]) -> void:
	_context = game_context
	_refresh(weapon_ids)


## 刷新武器列表
func _refresh(weapon_ids: Array[StringName]) -> void:
	for child in get_children():
		child.queue_free()

	# 标题
	var title = Label.new()
	title.text = "── 选择武器 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	if not _context:
		return

	var gs = _context.game_state
	for wid: StringName in weapon_ids:
		var card = gs.cards.get(wid)
		if not card or not card.def:
			continue
		var btn = Button.new()
		btn.text = "%s [威力:%d 射程:%d]" % [
			card.def.display_name,
			card.def.might,
			card.def.range_value,
		]
		btn.custom_minimum_size = Vector2(220, 36)
		var captured_id = wid
		btn.pressed.connect(func(): weapon_selected.emit(captured_id))
		add_child(btn)

	# 取消按钮
	var cancel_btn = Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(220, 36)
	cancel_btn.pressed.connect(func(): selection_cancelled.emit())
	add_child(cancel_btn)

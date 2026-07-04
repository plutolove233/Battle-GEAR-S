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
## 自定义标题
var _title_text: String = "── 选择武器 ──"
## 当前机甲引用（用于获取基础武器数据）
var _mech = null  # type: MechState


## 配置面板：显示可选武器列表
func configure(game_context, weapon_ids: Array[StringName], title: String = "── 选择武器 ──", mech = null) -> void:
	_context = game_context
	_title_text = title
	_mech = mech
	_refresh(weapon_ids)


## 刷新武器列表
func _refresh(weapon_ids: Array[StringName]) -> void:
	for child in get_children():
		child.queue_free()

	# 标题
	var title = Label.new()
	title.text = _title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	if not _context:
		return

	var gs = _context.game_state
	for wid: StringName in weapon_ids:
		var wid_str = String(wid)
		# 检查是否是基础武器虚拟 ID（如 frame_base_weapon_1 或 frame_base_weapon_2）
		if wid_str.begins_with("frame_base_weapon") and _mech != null:
			var slot_index: int = 0
			if wid_str.begins_with("frame_base_weapon_"):
				slot_index = int(wid_str.substr(19)) - 1  # "frame_base_weapon_" 长度为19

			var base_weapon = _mech.get_base_weapon(slot_index)
			if not base_weapon.is_empty():
				var btn = Button.new()
				var slot_name = "武器%d" % [slot_index + 1]
				btn.text = "%s: %s [威:%d 射:%d]" % [
					slot_name,
					base_weapon.get("name", "基础武器"),
					base_weapon.get("might", 0),
					base_weapon.get("range_value", 1),
				]
				btn.custom_minimum_size = Vector2(220, 36)
				btn.add_theme_color_override("font_color", Color.CYAN)  # 基础武器用青色标记
				var captured_id = wid
				btn.pressed.connect(func(): weapon_selected.emit(captured_id))
				add_child(btn)
				continue

		# 普通装备武器
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

## SellEquipmentPanel.gd — 卖出装备面板
##
## 专门用于卖出装备的选择界面
extends VBoxContainer
class_name SellEquipmentPanel

## 玩家选择了要卖出的装备
signal equipment_selected(card_id: StringName)
## 取消选择
signal cancelled()

## 当前 GameContext 引用
var _context = null  # type: GameContext


## 配置面板
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新显示
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	if not _context:
		return

	# 标题
	var title = Label.new()
	title.text = "── 卖出装备 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
	add_child(title)

	var gs = _context.game_state
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	if not player or not mech:
		return

	var has_options = false

	# 1. 玩家手中的装备牌
	for card_id: StringName in player.equipment_hand:
		var card = gs.get_card(card_id)
		if card and card.def:
			has_options = true
			var btn = Button.new()
			btn.text = "%s (手中)" % card.def.display_name
			btn.custom_minimum_size = Vector2(240, 36)
			btn.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
			var cid = card.instance_id  # 使用 instance_id
			btn.pressed.connect(func():
				print("DEBUG SellPanel: 点击手中装备, cid=", cid)
				equipment_selected.emit(cid)
			)
			add_child(btn)

	# 2. 备用区的装备牌
	for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
		if mech.slots.has(rs_id) and mech.slots[rs_id].equipped_card != null:
			var card = mech.slots[rs_id].equipped_card
			if card and card.def:
				has_options = true
				var reserve_name = "备用1" if rs_id == &"reserve_1" else "备用2"
				var btn = Button.new()
				btn.text = "%s: %s" % [reserve_name, card.def.display_name]
				btn.custom_minimum_size = Vector2(240, 36)
				btn.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
				var cid = card.instance_id
				btn.pressed.connect(func():
					print("DEBUG SellPanel: 点击备用区装备, cid=", cid)
					equipment_selected.emit(cid)
				)
				add_child(btn)

	if not has_options:
		var no_opt = Label.new()
		no_opt.text = "（没有可卖出的装备）"
		no_opt.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(no_opt)

	# 取消按钮
	var cancel_btn = Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(240, 36)
	cancel_btn.pressed.connect(func(): cancelled.emit())
	add_child(cancel_btn)

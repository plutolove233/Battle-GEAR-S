## EnemyInfoPopup.gd — 敌方信息弹窗
##
## 点击"敌方信息"按钮后弹出的模态窗口，
## 显示敌方机甲的装备槽位、手牌数量、动力、金币、HP、护甲。
extends PopupPanel
class_name EnemyInfoPopup

const _EquipmentPanel = preload("res://scripts/ui/equipment_panel.gd")

var _context = null  # type: GameContext
var _equipment_panel: EquipmentPanel
var _stats_container: VBoxContainer


func _ready() -> void:
	# 弹窗内 VBox
	var vbox := VBoxContainer.new()
	add_child(vbox)

	# 标题
	var title := Label.new()
	title.text = "── 敌方信息 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	vbox.add_child(title)

	# 装备面板（复用 EquipmentPanel，传入敌方机甲）
	_equipment_panel = _EquipmentPanel.new()
	_equipment_panel.custom_minimum_size = Vector2(240, 0)
	vbox.add_child(_equipment_panel)

	# 分隔线
	var sep := HSeparator.new()
	vbox.add_child(sep)

	# 统计信息容器
	_stats_container = VBoxContainer.new()
	vbox.add_child(_stats_container)

	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(140, 32)
	close_btn.pressed.connect(func(): visible = false)
	vbox.add_child(close_btn)


## 配置弹窗：从 GameContext 读取敌方数据
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新显示内容
func _refresh() -> void:
	if _context == null:
		return

	var gs = _context.game_state
	var enemy_player = gs.players.get(&"enemy")
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	# 更新装备面板
	if enemy_mech:
		_equipment_panel.configure(enemy_mech)

	# 清除并重建统计信息
	for child in _stats_container.get_children():
		child.queue_free()

	if enemy_player and enemy_mech:
		_add_stat("金币: %d" % enemy_player.gold)
		_add_stat("行动牌: %d 张" % enemy_player.action_hand.size())
		_add_stat("装备牌: %d 张" % enemy_player.equipment_hand.size())
		_add_stat("动力: %d / %d" % [enemy_mech.power, enemy_mech.max_power])
		_add_stat("生命: %d / %d" % [enemy_mech.current_hp, enemy_mech.max_hp])
		_add_stat("护甲: %d" % enemy_mech.get_armor())

		# 显示损伤标记
		var damaged_slots: Array[String] = []
		for slot_id: StringName in enemy_mech.slots:
			var slot = enemy_mech.slots[slot_id]
			if slot.region_damage_tokens > 0:
				var slot_name := _slot_display_name(String(slot_id))
				damaged_slots.append("%s:%d" % [slot_name, slot.region_damage_tokens])
		if not damaged_slots.is_empty():
			_add_stat("损伤部位: %s" % " ".join(damaged_slots))


## 添加一行统计文本
func _add_stat(text: String) -> void:
	var label := Label.new()
	label.text = text
	_stats_container.add_child(label)


## 槽位ID → 中文名
func _slot_display_name(slot_id: String) -> String:
	const NAMES := {
		"头部": "头部", "躯干": "躯干", "右臂": "右臂", "左臂": "左臂",
		"右腿": "右腿", "左腿": "左腿",
		"weapon_1": "武器1", "weapon_2": "武器2",
		"reserve_1": "备用1", "reserve_2": "备用2",
		"event": "事件", "pilot": "机师",
	}
	return NAMES.get(slot_id, slot_id)

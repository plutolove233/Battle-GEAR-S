## EnemyInfoPopup.gd — 敌方信息弹窗
##
## 点击"敌方信息"按钮后弹出的模态窗口，
## 显示敌方机甲的装备槽位、手牌数量、动力、金币、HP、护甲。
extends PopupPanel
class_name EnemyInfoPopup

const _EquipmentPanel = preload("res://scripts/ui/equipment_panel.gd")

var _context = null  # type: GameContext
var _local_player_id: StringName = &"player"
var _content_container: VBoxContainer


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

	# 内容容器（按对手动态填充多个块，3人PvP时含 enemy+third）
	_content_container = VBoxContainer.new()
	vbox.add_child(_content_container)

	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(140, 32)
	close_btn.pressed.connect(func(): visible = false)
	vbox.add_child(close_btn)


## 配置弹窗：从 GameContext 读取敌方数据
## local_player_id 用于排除己方（3人PvP时显示其余2个对手）
func configure(game_context, local_player_id: StringName = &"player") -> void:
	_context = game_context
	_local_player_id = local_player_id
	_refresh()


## 刷新显示内容（遍历所有非本地玩家，每个生成一个对手块）
func _refresh() -> void:
	if _context == null:
		return

	# 清除旧内容
	for child in _content_container.get_children():
		child.queue_free()

	var gs = _context.game_state
	for pid: StringName in gs.players:
		if pid == _local_player_id:
			continue
		var enemy_player = gs.players[pid]
		var enemy_mech = gs.get_mech_for_player(pid)
		if enemy_mech == null:
			continue
		_add_opponent_block(gs, pid, enemy_player, enemy_mech)


## 添加单个对手的信息块
func _add_opponent_block(gs, pid: StringName, enemy_player, enemy_mech) -> void:
	# 对手小标题
	var sub_title := Label.new()
	sub_title.text = "【%s】" % String(pid)
	sub_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_title.add_theme_color_override("font_color", Color(0.85, 0.55, 0.2))
	_content_container.add_child(sub_title)

	# 装备面板（敌方机甲，隐藏正面信息）
	var eq_panel := _EquipmentPanel.new()
	eq_panel.custom_minimum_size = Vector2(240, 0)
	_content_container.add_child(eq_panel)
	eq_panel.configure(enemy_mech, true)

	# 统计信息
	var stats := VBoxContainer.new()
	_content_container.add_child(stats)

	_add_stat_to(stats, "金币: %d" % enemy_player.gold)
	_add_stat_to(stats, "行动牌: %d 张" % enemy_player.action_hand.size())
	_add_stat_to(stats, "装备牌: %d 张" % enemy_player.equipment_hand.size())
	_add_stat_to(stats, "动力: %d / %d" % [enemy_mech.power, enemy_mech.max_power])
	_add_stat_to(stats, "生命: %d / %d" % [enemy_mech.current_hp, enemy_mech.max_hp])
	_add_stat_to(stats, "护甲: %d" % enemy_mech.get_armor())

	# 显示损伤标记
	var damaged_slots: Array[String] = []
	for slot_id: StringName in enemy_mech.slots:
		var slot = enemy_mech.slots[slot_id]
		if slot.region_damage_tokens > 0:
			var slot_name := _slot_display_name(String(slot_id))
			damaged_slots.append("%s:%d" % [slot_name, slot.region_damage_tokens])
	if not damaged_slots.is_empty():
		_add_stat_to(stats, "损伤部位: %s" % " ".join(damaged_slots))

	# 显示联合状态（Target UI 信息：被哪些 unite 机甲联合）
	var unite_names: Array[String] = []
	for s: Dictionary in enemy_mech.statuses:
		if s.get("type", &"") == &"UNITE":
			var u_mid: StringName = s.get("unite", &"")
			var u_mech = gs.mechs.get(u_mid) if u_mid != &"" else null
			var u_name: String = u_mech.frame_def.display_name if (u_mech != null and u_mech.frame_def != null) else String(u_mid)
			unite_names.append(u_name)
	if not unite_names.is_empty():
		_add_stat_to(stats, "联合状态: 被 %s 联合" % " ".join(unite_names))

	# 块间分隔
	_content_container.add_child(HSeparator.new())


## 添加一行统计文本到指定容器
func _add_stat_to(container: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	container.add_child(label)


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

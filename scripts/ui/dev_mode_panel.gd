## DevModePanel.gd — 开发者模式面板
##
## 提供卡牌和属性修改的调试UI。
class_name DevModePanel
extends Control

## 引用
var context: GameContext = null
var dev_mode_service = null  # type: DevModeService

## UI元素
var player_dropdown: OptionButton
var action_card_dropdown: OptionButton
var equipment_card_dropdown: OptionButton
var slot_dropdown: OptionButton

var action_cards_label: Label
var equipment_label: Label
var mech_info_label: Label

## 当前选中的玩家
var current_player_id: StringName = &""

## 颜色
const COLOR_ACTION = Color(0.2, 0.6, 1.0)
const COLOR_EQUIP = Color(1.0, 0.6, 0.2)
const COLOR_DANGER = Color(1.0, 0.3, 0.3)
const COLOR_SUCCESS = Color(0.3, 0.9, 0.4)

func _ready() -> void:
	visible = false  # 默认隐藏，按快捷键显示
	_setup_ui()


func _setup_ui() -> void:
	# 主容器
	var main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 8)
	add_child(main_vbox)

	# 标题
	var title = Label.new()
	title.text = "🔧 开发者模式"
	title.add_theme_font_size_override("font_size", 20)
	main_vbox.add_child(title)

	# 玩家选择
	var player_hbox = HBoxContainer.new()
	main_vbox.add_child(player_hbox)
	var player_label = Label.new()
	player_label.text = "玩家: "
	player_hbox.add_child(player_label)
	player_dropdown = OptionButton.new()
	player_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	player_dropdown.item_selected.connect(_on_player_selected)
	player_hbox.add_child(player_dropdown)

	# 分割线
	main_vbox.add_child(_create_separator())

	# === 行动牌部分 ===
	var action_section = _create_section("行动牌管理", COLOR_ACTION)
	main_vbox.add_child(action_section)

	# 添加行动牌
	var add_action_hbox = HBoxContainer.new()
	action_section.add_child(add_action_hbox)
	var add_action_label = Label.new()
	add_action_label.text = "添加: "
	add_action_hbox.add_child(add_action_label)
	action_card_dropdown = OptionButton.new()
	action_card_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_action_hbox.add_child(action_card_dropdown)
	var add_action_btn = Button.new()
	add_action_btn.text = "添加"
	add_action_btn.pressed.connect(_on_add_action_card)
	add_action_hbox.add_child(add_action_btn)

	# 弃置行动牌
	var discard_action_hbox = HBoxContainer.new()
	action_section.add_child(discard_action_hbox)
	var discard_action_btn = Button.new()
	discard_action_btn.text = "弃置所有行动牌"
	discard_action_btn.pressed.connect(_on_discard_all_action_cards)
	discard_action_hbox.add_child(discard_action_btn)

	# 行动牌列表显示
	action_cards_label = Label.new()
	action_cards_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	action_cards_label.custom_minimum_size.y = 60
	action_section.add_child(action_cards_label)

	# 分割线
	main_vbox.add_child(_create_separator())

	# === 装备牌部分 ===
	var equip_section = _create_section("装备牌管理", COLOR_EQUIP)
	main_vbox.add_child(equip_section)

	# 添加装备牌
	var add_equip_hbox = HBoxContainer.new()
	equip_section.add_child(add_equip_hbox)
	var add_equip_label = Label.new()
	add_equip_label.text = "添加: "
	add_equip_hbox.add_child(add_equip_label)
	equipment_card_dropdown = OptionButton.new()
	equipment_card_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_equip_hbox.add_child(equipment_card_dropdown)
	var add_equip_btn = Button.new()
	add_equip_btn.text = "添加到手牌"
	add_equip_btn.pressed.connect(_on_add_equipment_card)
	add_equip_hbox.add_child(add_equip_btn)

	# 设置到槽位
	var set_slot_hbox = HBoxContainer.new()
	equip_section.add_child(set_slot_hbox)
	var set_slot_label = Label.new()
	set_slot_label.text = "设置到槽位: "
	set_slot_hbox.add_child(set_slot_label)
	slot_dropdown = OptionButton.new()
	slot_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_slot_hbox.add_child(slot_dropdown)
	var set_slot_btn = Button.new()
	set_slot_btn.text = "设置"
	set_slot_btn.pressed.connect(_on_set_equipment_to_slot)
	set_slot_hbox.add_child(set_slot_btn)

	# 弃置装备牌
	var discard_equip_btn = Button.new()
	discard_equip_btn.text = "弃置所有装备牌"
	discard_equip_btn.pressed.connect(_on_discard_all_equipment_cards)
	equip_section.add_child(discard_equip_btn)

	# 装备牌列表显示
	equipment_label = Label.new()
	equipment_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	equipment_label.custom_minimum_size.y = 80
	equip_section.add_child(equipment_label)

	# 分割线
	main_vbox.add_child(_create_separator())

	# === 区域损伤部分 ===
	var damage_section = _create_section("区域损伤管理", COLOR_DANGER)
	main_vbox.add_child(damage_section)

	var damage_hbox = HBoxContainer.new()
	damage_section.add_child(damage_hbox)
	var damage_slot_label = Label.new()
	damage_slot_label.text = "槽位: "
	damage_hbox.add_child(damage_slot_label)
	var damage_slot_dropdown = OptionButton.new()
	damage_slot_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	damage_slot_dropdown.name = "DamageSlotDropdown"
	damage_hbox.add_child(damage_slot_dropdown)
	var add_damage_btn = Button.new()
	add_damage_btn.text = "+1 损伤"
	add_damage_btn.pressed.connect(_on_add_region_damage)
	damage_hbox.add_child(add_damage_btn)
	var remove_damage_btn = Button.new()
	remove_damage_btn.text = "-1 损伤"
	remove_damage_btn.pressed.connect(_on_remove_region_damage)
	damage_hbox.add_child(remove_damage_btn)

	# 分割线
	main_vbox.add_child(_create_separator())

	# === 属性修改器部分 ===
	var modify_section = _create_section("属性修改器", COLOR_SUCCESS)
	main_vbox.add_child(modify_section)

	# HP修改
	var hp_hbox = HBoxContainer.new()
	modify_section.add_child(hp_hbox)
	var hp_label = Label.new()
	hp_label.text = "生命值: "
	hp_hbox.add_child(hp_label)
	var hp_minus_btn = Button.new()
	hp_minus_btn.text = "-10"
	hp_minus_btn.pressed.connect(func(): _on_modify_hp(-10))
	hp_hbox.add_child(hp_minus_btn)
	var hp_plus_btn = Button.new()
	hp_plus_btn.text = "+10"
	hp_plus_btn.pressed.connect(func(): _on_modify_hp(10))
	hp_hbox.add_child(hp_plus_btn)
	var hp_set_btn = Button.new()
	hp_set_btn.text = "设为满血"
	hp_set_btn.pressed.connect(_on_set_full_hp)
	hp_hbox.add_child(hp_set_btn)

	# 动力修改
	var power_hbox = HBoxContainer.new()
	modify_section.add_child(power_hbox)
	var power_label = Label.new()
	power_label.text = "动力: "
	power_hbox.add_child(power_label)
	var power_minus_btn = Button.new()
	power_minus_btn.text = "-5"
	power_minus_btn.pressed.connect(func(): _on_modify_power(-5))
	power_hbox.add_child(power_minus_btn)
	var power_plus_btn = Button.new()
	power_plus_btn.text = "+5"
	power_plus_btn.pressed.connect(func(): _on_modify_power(5))
	power_hbox.add_child(power_plus_btn)
	var power_set_btn = Button.new()
	power_set_btn.text = "设为满动力"
	power_set_btn.pressed.connect(_on_set_full_power)
	power_hbox.add_child(power_set_btn)

	# 金币修改
	var gold_hbox = HBoxContainer.new()
	modify_section.add_child(gold_hbox)
	var gold_label = Label.new()
	gold_label.text = "金币: "
	gold_hbox.add_child(gold_label)
	var gold_minus_btn = Button.new()
	gold_minus_btn.text = "-10"
	gold_minus_btn.pressed.connect(func(): _on_modify_gold(-10))
	gold_hbox.add_child(gold_minus_btn)
	var gold_plus_btn = Button.new()
	gold_plus_btn.text = "+10"
	gold_plus_btn.pressed.connect(func(): _on_modify_gold(10))
	gold_hbox.add_child(gold_plus_btn)
	var gold_set_btn = Button.new()
	gold_set_btn.text = "设为50"
	gold_set_btn.pressed.connect(_on_set_gold_50)
	gold_hbox.add_child(gold_set_btn)

	# 机甲信息显示
	mech_info_label = Label.new()
	mech_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	mech_info_label.custom_minimum_size.y = 60
	modify_section.add_child(mech_info_label)

	# 分割线
	main_vbox.add_child(_create_separator())

	# 关闭按钮
	var close_btn = Button.new()
	close_btn.text = "关闭开发者模式 (F1)"
	close_btn.pressed.connect(_on_close)
	main_vbox.add_child(close_btn)


func _create_section(title: String, color: Color) -> VBoxContainer:
	var section = VBoxContainer.new()
	section.add_theme_constant_override("separation", 4)

	var label = Label.new()
	label.text = title
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 16)
	section.add_child(label)

	return section


func _create_separator() -> HSeparator:
	var sep = HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	return sep


func setup(context: GameContext) -> void:
	self.context = context
	self.dev_mode_service = context.dev_mode_service
	_refresh_player_list()


func _refresh_player_list() -> void:
	if dev_mode_service == null:
		return

	player_dropdown.clear()
	var player_ids = dev_mode_service.get_all_player_ids()
	for i in range(player_ids.size()):
		var pid = player_ids[i]
		player_dropdown.add_item(String(pid), i)
		player_dropdown.set_item_metadata(i, pid)

	if player_ids.size() > 0:
		player_dropdown.select(0)
		_on_player_selected(0)


func _on_player_selected(index: int) -> void:
	var metadata = player_dropdown.get_item_metadata(index)
	if metadata != null:
		current_player_id = metadata
		_refresh_action_card_list()
		_refresh_equipment_card_list()
		_refresh_slot_list()
		_update_info_display()


func _refresh_action_card_list() -> void:
	if dev_mode_service == null:
		return

	action_card_dropdown.clear()
	var card_ids = dev_mode_service.get_action_card_ids()
	for i in range(card_ids.size()):
		var cid = card_ids[i]
		var name = dev_mode_service.get_card_display_name(cid)
		action_card_dropdown.add_item(String(name), i)
		action_card_dropdown.set_item_metadata(i, cid)


func _refresh_equipment_card_list() -> void:
	if dev_mode_service == null:
		return

	equipment_card_dropdown.clear()
	var part_ids = dev_mode_service.get_equipment_part_ids()
	var weapon_ids = dev_mode_service.get_equipment_weapon_ids()

	# 先添加部件
	for i in range(part_ids.size()):
		var cid = part_ids[i]
		var name = dev_mode_service.get_card_display_name(cid)
		equipment_card_dropdown.add_item("[部件] " + String(name), i)
		equipment_card_dropdown.set_item_metadata(i, cid)

	# 再添加武器
	for i in range(weapon_ids.size()):
		var cid = weapon_ids[i]
		var name = dev_mode_service.get_card_display_name(cid)
		equipment_card_dropdown.add_item("[武器] " + String(name), part_ids.size() + i)
		equipment_card_dropdown.set_item_metadata(part_ids.size() + i, cid)


func _refresh_slot_list() -> void:
	if dev_mode_service == null:
		return

	slot_dropdown.clear()
	var damage_slot_dropdown = find_child("DamageSlotDropdown", true, false) as OptionButton

	var slot_ids = dev_mode_service.get_mech_slot_ids(current_player_id)
	for i in range(slot_ids.size()):
		var sid = slot_ids[i]
		slot_dropdown.add_item(String(sid), i)
		slot_dropdown.set_item_metadata(i, sid)

		if damage_slot_dropdown != null:
			damage_slot_dropdown.add_item(String(sid), i)
			damage_slot_dropdown.set_item_metadata(i, sid)

	if slot_ids.size() > 0:
		slot_dropdown.select(0)
		if damage_slot_dropdown != null:
			damage_slot_dropdown.select(0)


func _update_info_display() -> void:
	if dev_mode_service == null:
		return

	# 更新行动牌列表
	var action_cards = dev_mode_service.get_player_action_cards(current_player_id)
	var action_text = "行动牌 (" + str(action_cards.size()) + "张): "
	for i in range(action_cards.size()):
		var cid = action_cards[i]
		var name = dev_mode_service.get_card_display_name(cid)
		action_text += String(name)
		if i < action_cards.size() - 1:
			action_text += ", "
	action_cards_label.text = action_text

	# 更新装备牌列表
	var equip_cards = dev_mode_service.get_player_equipment_cards(current_player_id)
	var equip_text = "装备牌 (" + str(equip_cards.size()) + "张):\n"
	for i in range(equip_cards.size()):
		var card = equip_cards[i]
		equip_text += "[" + String(card.zone) + "] " + String(card.display_name)
		if card.has("slot_id") and card.slot_id != "":
			equip_text += " (槽位: " + String(card.slot_id) + ")"
		equip_text += "\n"
	equipment_label.text = equip_text

	# 更新机甲信息
	var mech_info = dev_mode_service.get_mech_info(current_player_id)
	if not mech_info.is_empty():
		mech_info_label.text = "机甲: %s | HP: %d/%d | 动力: %d/%d | 护甲: %d | 金币: %d | 攻击: %d/%d | %s" % [
			String(mech_info.get("mech_id", "")),
			mech_info.get("current_hp", 0),
			mech_info.get("max_hp", 0),
			mech_info.get("power", 0),
			mech_info.get("max_power", 0),
			mech_info.get("armor", 0),
			mech_info.get("gold", 0),
			mech_info.get("attack_count", 0),
			mech_info.get("max_attacks", 0),
			"已摧毁" if mech_info.get("destroyed", false) else "存活"
		]


func _on_add_action_card() -> void:
	if dev_mode_service == null:
		return
	var index = action_card_dropdown.get_selected_id()
	var card_id = action_card_dropdown.get_item_metadata(index)
	if card_id != null:
		dev_mode_service.add_action_card_to_player(current_player_id, card_id)
		_update_info_display()


func _on_discard_all_action_cards() -> void:
	if dev_mode_service == null:
		return
	dev_mode_service.discard_all_action_cards_from_player(current_player_id)
	_update_info_display()


func _on_add_equipment_card() -> void:
	if dev_mode_service == null:
		return
	var index = equipment_card_dropdown.get_selected_id()
	var card_id = equipment_card_dropdown.get_item_metadata(index)
	if card_id != null:
		dev_mode_service.add_equipment_card_to_player(current_player_id, card_id)
		_update_info_display()


func _on_set_equipment_to_slot() -> void:
	if dev_mode_service == null:
		return

	# 获取玩家手牌中的第一张装备牌
	var equip_cards = dev_mode_service.get_player_equipment_cards(current_player_id)
	var hand_card = null
	for card in equip_cards:
		if card.zone == "hand":
			hand_card = card
			break

	if hand_card == null:
		return

	var slot_index = slot_dropdown.get_selected_id()
	var slot_id = slot_dropdown.get_item_metadata(slot_index)
	if slot_id != null:
		dev_mode_service.set_equipment_card_to_slot(current_player_id, hand_card.instance_id, slot_id)
		_update_info_display()


func _on_discard_all_equipment_cards() -> void:
	if dev_mode_service == null:
		return

	var equip_cards = dev_mode_service.get_player_equipment_cards(current_player_id)
	for card in equip_cards:
		dev_mode_service.discard_equipment_card_from_player(current_player_id, card.instance_id)

	_update_info_display()


func _on_add_region_damage() -> void:
	if dev_mode_service == null:
		return

	var damage_slot_dropdown = find_child("DamageSlotDropdown", true, false) as OptionButton
	if damage_slot_dropdown == null:
		return

	var slot_index = damage_slot_dropdown.get_selected_id()
	var slot_id = damage_slot_dropdown.get_item_metadata(slot_index)
	if slot_id != null:
		dev_mode_service.add_region_damage(current_player_id, slot_id, 1)
		_update_info_display()


func _on_remove_region_damage() -> void:
	if dev_mode_service == null:
		return

	var damage_slot_dropdown = find_child("DamageSlotDropdown", true, false) as OptionButton
	if damage_slot_dropdown == null:
		return

	var slot_index = damage_slot_dropdown.get_selected_id()
	var slot_id = damage_slot_dropdown.get_item_metadata(slot_index)
	if slot_id != null:
		dev_mode_service.remove_region_damage(current_player_id, slot_id, 1)
		_update_info_display()


func _on_modify_hp(amount: int) -> void:
	if dev_mode_service == null:
		return
	dev_mode_service.modify_mech_hp(current_player_id, amount)
	_update_info_display()


func _on_set_full_hp() -> void:
	if dev_mode_service == null:
		return
	var mech_info = dev_mode_service.get_mech_info(current_player_id)
	if not mech_info.is_empty():
		dev_mode_service.set_mech_hp(current_player_id, mech_info.get("max_hp", 0))
		_update_info_display()


func _on_modify_power(amount: int) -> void:
	if dev_mode_service == null:
		return
	dev_mode_service.modify_mech_power(current_player_id, amount)
	_update_info_display()


func _on_set_full_power() -> void:
	if dev_mode_service == null:
		return
	var mech_info = dev_mode_service.get_mech_info(current_player_id)
	if not mech_info.is_empty():
		dev_mode_service.set_mech_power(current_player_id, mech_info.get("max_power", 0))
		_update_info_display()


func _on_modify_gold(amount: int) -> void:
	if dev_mode_service == null:
		return
	dev_mode_service.modify_player_gold(current_player_id, amount)
	_update_info_display()


func _on_set_gold_50() -> void:
	if dev_mode_service == null:
		return
	# 先设为0再加50
	dev_mode_service.modify_player_gold(current_player_id, -999)
	dev_mode_service.modify_player_gold(current_player_id, 50)
	_update_info_display()


func _on_close() -> void:
	visible = false


func toggle() -> void:
	visible = !visible
	if visible:
		_refresh_player_list()

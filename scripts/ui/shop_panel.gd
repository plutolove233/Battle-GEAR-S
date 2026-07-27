## ShopPanel.gd — 商店面板
##
## 显示商店中的装备牌，支持购买、查看隐藏牌、刷新商店等操作。
extends PopupPanel
class_name ShopPanel

const _GameConfig = preload("res://scripts/config/GameConfig.gd")

## 购买普通装备信号
signal normal_equipment_buy_clicked(slot_index: int)
## 购买高级装备信号
signal advanced_equipment_buy_clicked()
## 购买隐藏高级装备信号
signal buy_hidden_advanced_clicked()
## 查看隐藏高级装备信号
signal reveal_hidden_clicked()
## 刷新商店信号
signal refresh_shop_clicked()
## 关闭信号
signal closed()

var _context = null  # type: GameContext
var _content: VBoxContainer
## 本窗口控制的玩家（PvP host=player, client=enemy）。显示该玩家的金币/折扣。
var local_player_id: StringName = &"player"

## 普通装备槽按钮（3个）
var _normal_slot_buttons: Array[Button] = []
## 高级装备槽按钮
var _advanced_slot_button: Button = null
## 隐藏槽按钮
var _hidden_slot_button: Button = null
## 刷新商店按钮
var _refresh_shop_button: Button = null
## 玩家金币显示
var _gold_label: Label = null


func _ready() -> void:
	# 弹窗内 VBox + ScrollContainer
	var vbox := VBoxContainer.new()
	add_child(vbox)

	# 标题
	var heading := Label.new()
	heading.text = "── 商店 ──"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Color(0.3, 0.8, 0.5))
	vbox.add_child(heading)

	# 玩家金币显示
	_gold_label = Label.new()
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_label.add_theme_font_size_override("font_size", 16)
	_gold_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	vbox.add_child(_gold_label)

	# 滚动容器
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 400)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)

	# 操作按钮区
	var button_box := HBoxContainer.new()
	button_box.alignment = BoxContainer.ALIGNMENT_CENTER
	button_box.add_theme_constant_override("separation", 10)
	vbox.add_child(button_box)

	# 刷新商店按钮（每回合1次）
	_refresh_shop_button = Button.new()
	_refresh_shop_button.text = "刷新(%dG)" % _GameConfig.SHOP_REFRESH_COST
	_refresh_shop_button.custom_minimum_size = Vector2(100, 36)
	_refresh_shop_button.pressed.connect(func(): refresh_shop_clicked.emit())
	button_box.add_child(_refresh_shop_button)

	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(100, 36)
	close_btn.pressed.connect(func():
		visible = false
		closed.emit()
	)
	vbox.add_child(close_btn)


## 配置面板：从 GameContext 读取商店数据
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新显示内容
func _refresh() -> void:
	if _context == null:
		return

	# 清除现有内容
	for child in _content.get_children():
		child.queue_free()
	_normal_slot_buttons.clear()

	var gs = _context.game_state
	var shop = gs.shop_state
	var player = gs.players.get(local_player_id)

	# 更新金币显示（附折扣层数）
	if player and _gold_label:
		var gold_text: String = "金币: %d" % player.gold
		if _context.shop_service != null:
			var discount_uses: int = _context.shop_service.get_discount_uses(local_player_id)
			if discount_uses > 0:
				gold_text += "   当前折扣 ×%d" % discount_uses
		_gold_label.text = gold_text

	# 更新刷新商店按钮状态（每回合1次：已用或金币不足则禁用）
	if _refresh_shop_button and player:
		var refresh_key = &"refresh_shop"
		var refresh_used: bool = player.once_per_turn_used.get(refresh_key, 0) > 0
		var refresh_price: int = _GameConfig.SHOP_REFRESH_COST
		_refresh_shop_button.disabled = refresh_used or (player.gold < refresh_price)
		_refresh_shop_button.tooltip_text = "本回合已使用" if refresh_used else "将商店所有牌放回弃牌堆并重新抽取（%d金币，每回合1次）" % refresh_price

	# ── 普通装备槽（3个）────
	_add_section("普通装备", Color(0.85, 0.75, 0.3))

	for i: int in range(3):
		var card_id: StringName = shop.normal_slots[i] if i < shop.normal_slots.size() else &""
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(300, 40)

		if card_id != &"":
			var card = gs.get_card(card_id)
			if card and card.def:
				var price: int = _get_buy_price(card)
				btn.text = "%s [%s] - %d金币" % [card.def.display_name, card.def.rarity, price]
				btn.tooltip_text = card.def.effect_text
				# 根据稀有度设置颜色
				_set_button_rarity_color(btn, card.def.rarity)
				var idx = i
				btn.pressed.connect(func(): normal_equipment_buy_clicked.emit(idx))
			else:
				btn.text = "（空）"
				btn.disabled = true
		else:
			btn.text = "（空）"
			btn.disabled = true

		_content.add_child(btn)
		_normal_slot_buttons.append(btn)

	# ── 高级装备槽 ──
	_add_section("高级装备", Color(0.9, 0.6, 0.1))
	_advanced_slot_button = Button.new()
	_advanced_slot_button.custom_minimum_size = Vector2(300, 40)

	if shop.advanced_slot != &"":
		var card = gs.get_card(shop.advanced_slot)
		if card and card.def:
			var price: int = _get_buy_price(card)
			_advanced_slot_button.text = "%s [%s] - %d金币" % [card.def.display_name, card.def.rarity, price]
			_advanced_slot_button.tooltip_text = card.def.effect_text
			_set_button_rarity_color(_advanced_slot_button, card.def.rarity)
			_advanced_slot_button.pressed.connect(func(): advanced_equipment_buy_clicked.emit())
		else:
			_advanced_slot_button.text = "（空）"
			_advanced_slot_button.disabled = true
	else:
		_advanced_slot_button.text = "（空）"
		_advanced_slot_button.disabled = true

	_content.add_child(_advanced_slot_button)

	# ── 隐藏高级装备槽 ──
	_add_section("隐藏高级装备", Color(0.7, 0.4, 0.8))
	_hidden_slot_button = Button.new()
	_hidden_slot_button.custom_minimum_size = Vector2(300, 40)

	if shop.hidden_advanced_slot != &"":
		if shop.hidden_revealed:
			# 已查看，显示内容
			var card = gs.get_card(shop.hidden_advanced_slot)
			if card and card.def:
				var price: int = _get_buy_price(card)
				_hidden_slot_button.text = "%s [%s] - %d金币" % [card.def.display_name, card.def.rarity, price]
				_hidden_slot_button.tooltip_text = card.def.effect_text
				_set_button_rarity_color(_hidden_slot_button, card.def.rarity)
				_hidden_slot_button.pressed.connect(func(): buy_hidden_advanced_clicked.emit())
			else:
				_hidden_slot_button.text = "（已查看）"
				_hidden_slot_button.disabled = true
		else:
			# 未查看，显示背面
			_hidden_slot_button.text = "★★★ 隐藏卡 ★★★"
			_hidden_slot_button.tooltip_text = "点击花费2金币查看"
			_hidden_slot_button.pressed.connect(func(): _on_hidden_slot_clicked())
	else:
		_hidden_slot_button.text = "（空）"
		_hidden_slot_button.disabled = true

	_content.add_child(_hidden_slot_button)


## 隐藏槽点击处理：弹出选项
func _on_hidden_slot_clicked() -> void:
	if _context == null:
		return
	var gs = _context.game_state
	var player = gs.players.get(local_player_id)
	if player == null:
		return

	# 简单处理：先询问是否查看，玩家可以选直接购买
	# 使用内置的确认对话框不够灵活，我们用 ChoicePanel 或简单的确认
	# 这里简化：点击隐藏卡直接触发查看操作
	# 如果玩家想直接买，可以再点击已查看的卡（修改逻辑让已查看的卡可以买）
	reveal_hidden_clicked.emit()


## 隐藏卡查看后购买的辅助方法
func _on_hidden_buy_after_reveal() -> void:
	# 已查看后，点击该卡触发购买高级装备
	advanced_equipment_buy_clicked.emit()


## 获取购买价格
func _get_buy_price(card) -> int:
	if card and card.def:
		# EquipmentCardDef 有 cost 属性
		var base_cost: int = 1
		# 直接访问 cost 属性
		base_cost = int(card.def.cost) if card.def.cost > 0 else 1
		# 如果 cost 为 0，尝试使用 armor+power 作为基准
		if base_cost <= 0:
			base_cost = int(card.def.armor) + int(card.def.power)
		if base_cost <= 0:
			base_cost = 1
		return int(ceil(base_cost * 1.5))
	return 3


## 根据稀有度设置按钮颜色
func _set_button_rarity_color(btn: Button, rarity: StringName) -> void:
	match rarity:
		&"N":
			btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
		&"R":
			btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
		&"SR":
			btn.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
		&"SSR":
			btn.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))


## 添加分区标题
func _add_section(text: String, color: Color) -> void:
	var sep := HSeparator.new()
	_content.add_child(sep)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", color)
	_content.add_child(label)

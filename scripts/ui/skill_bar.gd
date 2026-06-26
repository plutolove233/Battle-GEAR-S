## SkillBar.gd — 主动技能栏
##
## 显示当前玩家可用的主动效果按钮。
extends HBoxContainer
class_name SkillBar

## 主动效果被点击时发射
signal active_effect_clicked(effect_id: StringName)

## 当前 GameContext 引用
var _context = null  # type: GameContext


## 配置面板
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新技能按钮
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	if not _context:
		return

	# 标签
	var label = Label.new()
	label.text = "技能:"
	label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	add_child(label)

	# 查询当前玩家的主动效果
	var gs = _context.game_state
	var player_id: StringName = gs.active_player_id
	if player_id == &"" or not gs.players.has(player_id):
		return

	var mech = gs.get_mech_for_player(player_id)
	if not mech:
		return

	# 从 EffectRegistry 获取所有绑定到此机甲装备的 ACTIVE 效果
	if not _context.effect_registry:
		return

	var bindings = _context.effect_registry.get_all_active_bindings()
	for binding in bindings:
		# 只显示当前玩家机甲的主动效果
		if binding.get_owner_player_id() != player_id:
			continue
		if binding.effect.mode != EffectConst.MODE_ACTIVE:
			continue

		var btn = Button.new()
		btn.text = binding.effect.display_name
		btn.tooltip_text = binding.effect.description
		btn.custom_minimum_size = Vector2(80, 32)
		var eid: StringName = binding.effect.effect_id
		btn.pressed.connect(func(): active_effect_clicked.emit(eid))
		add_child(btn)

	# 如果没有主动效果
	if get_child_count() <= 1:
		var none_label = Label.new()
		none_label.text = "（无可用技能）"
		none_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(none_label)

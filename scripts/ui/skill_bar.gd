## SkillBar.gd — 主动技能栏（空壳）
##
## 主动效果入口现由各面板自行接管：
##   - 装备主动效果（DIRECT 模式）→ 装备面板对应槽位的「触发」按钮（equipment_active_clicked）
## 此处保留空壳，便于将来接入非装备类的主动效果按钮。
extends HBoxContainer
class_name SkillBar

## 当前 GameContext 引用（保留供将来按钮使用）
var _context = null  # type: GameContext


## 配置面板：当前无按钮来源，仅占位
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新：显示占位标签
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	var label = Label.new()
	label.text = "技能:"
	label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	add_child(label)

	var none_label = Label.new()
	none_label.text = "（无可用技能）"
	none_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	add_child(none_label)

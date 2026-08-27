## SkillBar.gd - 主动技能栏（空壳）
##
## 主动效果入口现由各面板自行接管：
##   - 装备主动效果（DIRECT 模式）-> 装备面板对应槽位的「触发」按钮（equipment_active_clicked）
## 此处保留空壳，便于将来接入非装备类的主动效果按钮。
##
## 差量刷新：两个占位标签只建一次，刷新仅更新（内容固定时零分配）。
extends HBoxContainer
class_name SkillBar

## 当前 GameContext 引用（保留供将来按钮使用）
var _context = null  # type: GameContext

## 占位标签（持久）
var _title_label: Label = null
## "无可用技能"占位标签（持久）
var _none_label: Label = null


## 配置面板：当前无按钮来源，仅占位
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新：显示占位标签
func _refresh() -> void:
	if _title_label == null:
		_title_label = Label.new()
		_title_label.text = "技能:"
		_title_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
		add_child(_title_label)
	if _none_label == null:
		_none_label = Label.new()
		_none_label.text = "（无可用技能）"
		_none_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(_none_label)

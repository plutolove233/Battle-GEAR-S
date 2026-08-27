## immediate_use_action.gd - 即时使用动作
##
## 「即时使用」机制（new_logic/各动作的生命周期与时点.txt / 即时使用机制定稿）：
##   攻击进行中（未到 check_hit）玩家抽到/设置新牌时，若该牌监听 ATTACK_PRE/AT 且基本条件满足，
##   弹出效果窗让玩家确认即时发动；确认则直接执行（不再走时点监听，而是暂停攻击、执行、继续）。
##
## 本动作是即时使用的编排容器：作为 gain_card / set_equipment 的子动作生成，父动作等待其完成。
## record._imm_items 存「待即时处理」条目数组，逐条执行：
##   - 装备补触发：条目带 effect(装备 LISTEN ATTACK_PRE 效果) + payload(攻击上下文+binding_context)。
##     调 TimingEngine._execute_effect 直接补 fire（装备自带 optional CHOOSE_ONE「是否发动」由该路径弹出）。
##   - 掩护即时使用：条目带 effect(合成 CHOOSE_ONE：使用/不使用) + payload。确认「使用」则分支
##     EXECUTE_USE_ACTION_CARD(带 attack_action_id) 打出掩护，掩护 DIRECT MODIFY_ATTACK_MIGHT -5 命中攻击。
##
## 串行与暂停恢复：_step_process 用 while 循环逐条处理，处理前先 _imm_index+1。
##   _execute_effect 挂起（CHOOSE_ONE 弹窗 waiting_timing / 子动作 waiting_effect_action）时返回，
##   父动作暂停；恢复时（resume_pending_effect -> continue_action）重入 _step_process，_imm_index 已推进，
##   续跑下一条。同步完成的效果直接进下一条。
extends Action
class_name ImmediateUseAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const SLog = preload("res://scripts/services/slog.gd")


func _init() -> void:
	action_type = &"immediate_use"


func setup_steps() -> void:
	steps = [
		{step_name = &"process", timing_point = &"", handler = _step_process},
	]


func get_display_name() -> String:
	return "即时使用"


## 逐条处理 _imm_items。每条处理前推进 _imm_index，故挂起恢复后续跑下一条（不会重跑已处理条目）。
func _step_process(action: Action) -> Dictionary:
	var items: Array = action.record.get("_imm_items", [])
	while true:
		var idx: int = int(action.record.get("_imm_index", 0))
		if idx >= items.size():
			return {}
		# 先推进索引：挂起恢复后直接续跑下一条，不重跑当前条目
		action.record["_imm_index"] = idx + 1
		var item: Dictionary = items[idx] if items[idx] is Dictionary else {}
		var effect = item.get("effect")
		var payload: Dictionary = item.get("payload", {})
		if effect == null:
			continue
		if context == null or context.timing_engine == null:
			continue
		SLog.log_raw("[IMM_USE] %s 处理即时使用条目 %d/%d effect=%s" % [String(action.action_id), idx + 1, items.size(), String(effect.effect_id)])
		# 直接补触发/执行效果：效果自带 CHOOSE_ONE/目标选择时挂起本动作（waiting_timing/_pending_effect），
		# 分支子动作挂起时置 waiting_effect_action。两条暂停路径都由 ActionEngine 检测并暂停父动作。
		context.timing_engine._execute_effect(effect, payload, action)
		# 挂起则返回，等恢复后重入本函数续跑循环
		if action.state == &"waiting_timing" or action.state == &"waiting_effect_action":
			return {}
		# 同步完成（条件不满足跳过 / 原子动作即时生效）-> 继续下一条
	return {}

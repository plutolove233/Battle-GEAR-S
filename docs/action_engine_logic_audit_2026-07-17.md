# Action Engine、行动牌与 AI 逻辑审查报告

> 审查日期：2026-07-17  
> 审查性质：只读逻辑审查；本报告未修改游戏逻辑。  
> 唯一权威依据：`new_logic/行动牌的效果与逻辑.txt`、`new_logic/各动作的生命周期与时点.txt` 全文。  
> 冲突处理：本报告不以代码注释、旧 Hook/Effect 逻辑、README 或既有测试作为规则依据；它们与上述两份文档冲突时，一律以文档为准。

## 1. 结论摘要

当前实现已经搭出了 Action、Step、Timing、父子动作、临时区、响应窗口和 AI 自动输入的基本骨架，但尚不能保证权威文档要求的“一个时点内按优先级逐个完整结算”“一个效果内的所有操作串行完成后才算效果完成”“一张行动牌的全部效果完成/无法继续执行后才离开临时区”。

最核心的问题不是某一张牌的参数写错，而是执行器缺少一个统一的、可暂停的串行效果队列：`TimingEngine._execute_actions()` 会在同一个 `for` 循环里连续启动多个子动作；第一个子动作即使进入 `waiting_input`，循环仍会启动后续子动作并把效果标记为完成。与此同时，`ActionUIBridge` 只有一个全局 `_waiting_action_id`，后发出的输入会覆盖前一个输入。由此会系统性地产生以下错误：

1. 同一效果的后续动作在前一个动作未完成时提前开始。
2. `requires_effect` 实际判断的是“效果已发起/已排出子动作”，不是“效果所有动作已完整结算”。
3. 同一时点的低优先级监听可能在高优先级监听的子动作尚未完成时开始。
4. AI 与人类的两个输入请求互相覆盖，最终把 AI 的选择交给人类 UI，或让原动作永久等待。
5. 行动牌可能在仍有跨动作监听效果未完成时进入弃牌堆。

因此，当前状态应判定为：**动作框架部分符合，核心串行语义不符合；23 张行动牌中只有少数简单单效果牌接近可用，多目标、跨时点、多个子动作、需要连续选择的牌存在明确缺陷；AI 只能完成一小部分输入，无法使用全部行动牌。**

## 2. 严重级别和整改目标

- **P0：规则主链错误或会造成错序、提前结算、输入串线、动作卡死。** 必须先改执行模型，之后才适合修单牌。
- **P1：某个基础动作或行动牌的权威效果明确不成立。** 会直接改变胜负或牌效。
- **P2：边界、UI、数据记录或测试覆盖不完整。** 不一定每局触发，但会造成错误交互或无法证明正确性。

整改最终目标：

1. 任意 Action 始终只有一个当前步骤；任意 Effect 始终只有一个当前操作；任意 Timing 始终只有一个当前监听器。
2. 子动作进入任意等待态时，父效果、父时点、父动作全部保持暂停，直到该子动作完成或按明确规则取消。
3. 所有选择先产生统一的 `DecisionRequest`，再由 HumanDecisionProvider 或 AIDecisionProvider 返回同一种数据结构；UI 不参与规则判断。
4. 行动牌从确认使用后进入临时区，直到该牌所有直接效果、依赖效果、绑定到攻击 A 的跨时点效果和其产生的全部子动作均完成/确定无法执行，才执行弃置牌动作，最后发出使用行动牌结算时点。
5. 每个规则时点都有可验证的 action id、完整 record 快照、稳定优先级顺序和注册序号。

## 3. P0 结构性问题

### P0-01：效果动作列表不是串行队列

明确位置：

- `scripts/action_core/TimingEngine.gd:1280-1380`：`_execute_actions()` 用 `for act in effect.actions` 连续执行全部动作。
- `scripts/action_core/ActionService.gd:84-120`：`execute_sub_action()` 会同步启动子动作；子动作可能返回 `waiting_input` / `waiting_timing`。
- `scripts/action_core/TimingEngine.gd:738-757`：启动完 `actions[]` 后即把效果记为 `completed` 和 `_mark_effect_executed()`。
- `scripts/action_core/ActionEngine.gd:318-327`：只有 Step handler 返回 `effect_action_created` 时，ActionEngine 才进入父动作等待；Timing listener 内创建子动作没有等价的逐项续跑状态机。

与文档冲突：

- 生命周期文档第6、9行要求动作/时点一旦暂停，整体及后续执行暂停；同一时点监听按优先级逐个完整执行。
- 行动牌文档多次写明“上述效果/动作全部结算后，结束监听”；用户又明确要求效果的所有操作和触发动作串行结算。

可复现后果：

- 识破效果1依次定义 `RESPOND_ATTACK -> EXECUTE_STEAL -> EXECUTE_SINGLE_MOVE`（`GeneratedActionEffects.gd:877-881`）。偷牌动作等待选择时，移动动作仍会启动；随后效果1被标记完成，效果2可立即无效攻击。
- 预判效果2定义 `ADD_STATUS -> EXECUTE_DISCARD`（`GeneratedActionEffects.gd:829-836`）。弃牌尚未选完时，同一时点后续监听仍可继续。
- 维修二选一分支创建 HP/损伤子动作后，分支循环没有通用“等待该子动作完成再结束效果”的游标。
- 任意装备/机师效果只要一个 effect 内含多个可暂停动作，也受同一问题影响。

整改要求：

1. 新增运行时 `EffectExecution`（或把 effect 也建模为 Action），至少包含 `effect_id`、`action_index`、`state`、`parent_timing_frame_id`、`pending_child_id`、`payload`。
2. `_execute_actions()` 每次只执行当前一项。若创建非原子子动作，则立即保存游标并返回等待；收到 child completed 后才 `action_index += 1`。
3. 只有 action index 越过末尾，才 emit `effect_executed`、写 `_mark_effect_executed`、允许下一个监听器开始。
4. 原子操作也必须明确返回成功/失败/跳过；失败不能静默当作完成。

验收：用一个包含两个需要输入子动作的测试效果验证，在第一个输入完成前，第二个动作不存在于 ActionRegistry，效果也没有 completed 记录。

### P0-02：时点监听器只按“启动顺序”排序，没有按“完整结算顺序”执行

明确位置：

- `TimingEngine.gd:177-200`、`210-250`：排序规则本身是优先级降序、同优先级 seq 升序，表面正确；但 `_execute_effect()` 创建可暂停子动作后，父 `action.state` 通常不会变为 `waiting_timing`，循环继续下一个 listener。
- `TimingEngine.gd:152-175`：AVAILABILITY 被从 regular listener 中分离，并且只要存在可用牌就先开响应窗口，regular listener 无论优先级多少都被延后。

问题：

1. “优先级正确”目前只保证调用 `_execute_effect` 的先后，不保证高优先级效果的全部动作先完成。
2. AVAILABILITY 与 LISTEN 没有统一调度。锁定优先级20对普通迎击优先级5的抑制，目前靠 `_check_availability()` 内联特判（`TimingEngine.gd:1161-1172`）绕过，而不是由权威规则所述的优先级监听自然产生。新增类似效果会再次错序。
3. `available_cards` 构造时没有保存 listener 的 `seq`（`TimingEngine.gd:268-287`），后续同优先级排序读取不存在的 `seq`，全部退回0，不能稳定表达“先来后到”。

整改要求：建立 `TimingFrame`，统一收集 LISTEN/AVAILABILITY，统一排序；每次只推进一个 listener。响应窗口本身应作为一个可暂停的 listener/effect，而不是绕过队列的特殊分支。锁定效果1应成为真实优先级20监听，不应只靠 availability 查询时硬编码。

### P0-03：全局单槽输入会被嵌套动作覆盖

明确位置：`ActionUIBridge.gd:19-24` 只有 `_waiting_action_id`、`_current_input_type`、`_current_input_params` 一套；每次 `_on_action_needs_input()` 在 `46-49` 直接覆盖。

当 P0-01 同时启动偷牌和移动，或监听器与伤害放置同时请求输入时，最后一次请求覆盖前一次。UI 确认后只会继续最后记录的 action id，先前动作仍在等待。`app_root.gd:798-822`、`831-836` 还通过“当前全局等待动作”寻找响应攻击 action，进一步放大串线风险。

整改要求：

- 正常规则链必须通过串行调度保证同一执行栈最多一个 active decision。
- Bridge 仍应以 `request_id -> DecisionRequest` 字典保存，而不是单槽；确认必须携带 request_id/action_id，拒绝过期响应。
- UI 层不得通过“当前等待动作”猜原攻击；响应面板应保存显式 attack action id。

### P0-04：Step 返回 `error` 不会中断动作，底层合法性检查可被绕过

明确位置：`ActionEngine.gd:293-316` 对 handler 返回结果只识别 `need_input`，其他结果（包括 `{"error": ...}`）全部 merge 后继续下一步。

受影响例子：

- `use_action_card_action.gd:53-95` 的无卡、找不到实例、攻击次数不足、只能响应窗口使用等错误不会终止动作。
- `basic_move_action.gd:40-61` 的目标非法、动力不足也只返回 error；动作仍可能继续消耗/移动。
- `attack_action.gd` 的输入和对象异常没有统一失败状态。

此外，`use_action_card_action.gd:48-97` 没有在底层检查当前 active player、MAIN 阶段、牌是否确实在该玩家行动手牌、owner 是否匹配。玩家回合限制主要在 `app_root.gd:545-565`，调用 ActionService 可绕过 UI 守卫。AI 与人类因此并未真正共享同一套合法性。

整改要求：规定 StepResult：`ok / need_input / failed / cancelled / skipped`。`failed` 必须停止当前动作并按事务策略回滚或保持未提交状态。所有主动使用条件移入 `use_action_card` 的 validate step；UI 只显示校验结果。

### P0-05：回合时点不是可暂停 Action，监听效果无法阻塞回合流程

明确位置：

- `TurnService.gd:185-205` 创建未注册的轻量 Action 后直接 `fire_timing()`，不检查 `waiting_timing`、子动作或输入。
- `TurnService.gd:49-118` 连续发 ROUND_START、TURN_BEFORE_START、TURN_START、资源恢复、抽牌、加金币、TURN_AFTER_START。
- `TurnService.gd:134-173` 连续发结束时点、计时、弃牌、清状态、TURN_AFTER_END。

结果：若回合时点监听器需要选择、产生可暂停子动作或打开窗口，TurnService 仍会执行后续阶段，违反文档第6、9、124-147行。

并且存在明确顺序差异：文档在“回复机甲动力”后发“回合开始时”，代码在 `TurnService.gd:65-73` 先 fire `TURN_START` 再回复动力。若文档原意确为第130行先回复、第131行发时点，当前顺序相反。

整改要求：把 start_turn/end_turn/round 做成正式 Action，所有资源变化、抽牌、弃牌都是子动作，并使用同一串行等待机制。

## 4. 基础动作逐项审查

| 动作 | 符合部分 | 明确问题 | 级别 |
|---|---|---|---|
| 攻击 | Step 与 `ATTACK_BEFORE/PRE/AT/AFTER/SETTLE` 的表面映射符合文档；handler 后 fire timing 符合“完成该步后发时点” | 仅支持单 `target_id`；`target_count=2` 只传给 UI，无法记录/结算多目标；监听效果不保证完整结算；取消/失败语义不统一 | P0/P1 |
| 使用行动牌 | 确认后从手牌移到 `temp_zone`；USE_ACTION 四时点位置表面正确 | 跨攻击时点效果未完成便弃牌；validate error 不终止；主动可用条件不在底层完整校验；settle 发起弃置但不把弃置动作作为必须等待的 child | P0 |
| 数值修正 | 三时点映射正确；might/range 可写攻击 record | 不支持文档所说的多对象对应关系；基础移动绕过它直接扣动力；`value_multiplier` 未被参数提取，导致聚能+4*X无效 | P1 |
| 基础移动 | 相邻、地形、占用、动力检查存在；四时点映射正确 | 第2步直接 `GameActions.spend_power`（`basic_move_action.gd:65-87`），没有执行文档要求的数值修正动作，因而缺失 STAT_MOD 时点与可插入效果 | P1 |
| 单次移动 | 路径拆成多个 basic_move 子动作，基本方向正确 | 插入整条路径时预先扣 `_remaining_power`（`single_move_action.gd:93-106`），不是每个 basic_move 完成后再更新；中途动作取消/路径失效时记录可能不正确 | P1 |
| 设置装备 | 选择区域、弃旧牌、放置/激活分段及时点基本对应 | 移除耐久数量损伤直接改 slot（`set_equipment_action.gd:80-96`），未执行损伤变动动作；AI 对 `select_equipment_slot` 没有自动决策分支 | P1 |
| 获取牌 | BEFORE/AFTER/SETTLE 和多牌给同一机甲基本可用 | 许多牌效/回合抽牌绕过 gain_card 动作直接调用原子 draw；来源与牌的对应记录不完整 | P1 |
| 弃置牌 | 确定牌、移区、入弃牌堆及时点大体存在 | 预判应由发动者从未知牌中选择，代码强制 `system_random`（`ActionService.gd:1150-1164`）；使用行动牌 settle 的弃置没有纳入父子等待 | P1 |
| 效果发动 | 三时点壳存在 | `_step_execute_effect()` 不返回/等待 effect 创建的子动作（`effect_fire_action.gd:38-49`），仍受 P0-01 | P0 |
| 生命变动 | BEFORE、变动、AFTER、SETTLE 的常规实现合理 | 权威文档第103行重复写“生命变动前”，而代码为 `HP_CHANGE_AFTER`；需文档确认后判定 | 待确认 |
| 损伤变动 | BEFORE/AFTER/SETTLE、增加时的放置输入存在 | 减少损伤直接自动移除（`damage_change_action.gd:78-82`），没有让执行者逐区选择；AI/human 判断把任意非 `player` executor 都当 AI | P1 |
| 展示牌 | persistent known_to 有初步实现 | 总是返回 `need_input` 且无“已展示”守卫（`show_card_action.gd:38-65`），确认后重跑仍再次 need_input；AI 无 show_cards 分支，会弹人类 UI | P0 |

### 攻击动作额外明确错误

1. **破甲+2损伤不生效。** `attack_action.gd:197-233` 在 ATTACK_AFTER 之前已经把 `markers` 算好写入 record；破甲监听在 ATTACK_AFTER 把 `extra_markers += 2`（`GeneratedActionEffects.gd:213-227`、`ActionService.gd:278-290`）；随后 `_step_apply_damage()` 只读取旧 `markers`（`attack_action.gd:249-250`），不再合并 `extra_markers`。应在 AFTER 时点结束后统一 clamp/finalize damage/markers，或让破甲直接改 record.markers。
2. **双连未实现。** `target_count=2` 只存在于 record/UI 参数；选择、命中、伤害和响应全部是单数 `target_id`。应定义 targets 数组以及逐目标/共享攻击的精确结算模型，不能仅改 UI 多选。
3. **额外范围与 UI/AI 可选范围不一致。** 已指定目标时验证使用 `weapon_range + extra_range`（`attack_action.gd:116-123`），但 need_input 只传基础 `weapon_range`（`130-134`）。UI 高亮和 AI 选择会漏掉加范围后的合法目标。
4. **主动使用前的“最大可能范围”检查只在玩家 UI，且只算基础武器范围。** `app_root.gd:567-590` 没有提取所有可能加范围效果；AI `_ai_try_attack_new()` 也只用第一把武器基础范围（`battle_state.gd:677-690`）。不符合生命周期文档第10行。

## 5. 行动牌逐张审查

| # | 牌 | 判定 | 明确问题与代码位置 |
|---:|---|---|---|
| 1 | 进攻 | 部分符合 | 能创建单目标攻击；受底层失败/取消、串行问题影响。 |
| 2 | 强袭 | 部分符合 | effect2 优先级-1、ATTACK_AT条件定义正确（`GeneratedActionEffects.gd:138-157`）；但移动子动作没有被 timing frame 串行等待，监听可能提前结束。 |
| 3 | 猛击 | 接近符合 | +4写 `extra_might`，时点正确；仍依赖统一 timing 串行修复。 |
| 4 | 破甲 | 不符合 | ATTACK_AFTER 写 extra_markers 后不重新进入 markers，实际+2不参与放置，见第4节。 |
| 5 | 双连 | 不符合 | 只写 `target_count=2`，攻击数据和流程仍是单目标。 |
| 6 | 闪击 | 部分符合 | 条件和 ATTACK_SETTLE 定义存在；弃牌费用通过 CostChecker 原子弃牌而非完整弃置牌动作；再攻击 child 在监听效果内没有通用等待；AI固定弃第一张且固定选择再攻。 |
| 7 | 回避 | 部分符合 | 先写响应再移动的定义顺序正确；但 effect 完成标记与移动 child 完成没有统一绑定。 |
| 8 | 疾行 | 部分符合 | 同回避；全动力移动存在。 |
| 9 | 防御 | 部分符合 | 响应、临时护甲+5、损伤-1存在（`GeneratedActionEffects.gd:359-372`）；护甲修正没有执行数值修正动作及其时点。 |
| 10 | 反击 | 不符合 | 使用行动牌 settle 在 effect2 的 ATTACK_SETTLE 触发前就弃牌；`_has_bind_to_attack_action_effect()`（`use_action_card_action.gd:330-340`）从未使用。攻击B也不会阻塞原 ATTACK_SETTLE 完整结束。 |
| 11 | 维修 | 部分符合 | 目标与二选一存在；移除损伤不让执行者选择区域；AI完成目标自动选择后，`choose_one_effect` 参数无 owner/mech，Bridge 会误判为人类并弹 UI。 |
| 12 | 聚能 | 不符合 | 状态创建存在；状态effect1使用 `value_multiplier`/stacks（`GeneratedActionEffects.gd:477-480`），但 `_extract_stat_mod_params()`（`ActionService.gd:1081-1093`）不提取这些字段，value默认为0，威力不增加。 |
| 13 | 推进 | 不符合 | 文档是动力+5，代码是+4（`GeneratedActionEffects.gd:522-534`）；手牌中的普通 LISTEN 不会注册，推进effect2无法在持有时监听迎击；也未实现“所有推进共用监听、可选任意数量”。 |
| 14 | 掩护 | 不符合 | 条件范围计算最后比较 holder 到攻击者，而不是 holder 到被攻击目标（`TimingEngine.gd:1175-1207`）；响应处理只取 selected_cards[0]，无法任意张掩护；共用监听未实现。 |
| 15 | 联合 | 不符合 | effect2 监听 USE_ACTION_BEFORE，但牌的 LISTEN 在 card_to_temp（即 BEFORE 已结束后）才注册，永远赶不上本牌 BEFORE；联合状态后续 `EXECUTE_USE_ACTION_CARD` 没有让 Target 选择具体攻击牌；AI owner 丢失。 |
| 16 | 回收 | 接近符合 | 使用 gain_card 从装备弃牌堆随机1张；需统一串行和空牌堆规则测试。 |
| 17 | 回忆 | 接近符合 | 使用 gain_card 随机2张；需验证不足2张时行为和串行。 |
| 18 | 折扣 | 部分符合 | 2层状态及商店价格UI存在；购买直接改金币/zone/hand（`ShopService.gd:71-95`），没有按文档执行数值修正动作、获取牌动作及各自时点；AI不会购物。 |
| 19 | 补给 | 不符合动作语义 | 数量2行动+1装备正确，但定义为原子 `DRAW_ACTION/DRAW_EQUIPMENT`（`GeneratedActionEffects.gd:742-745`），绕过获取牌动作和时点。 |
| 20 | 锁定 | 部分符合 | 施加、命中清除、回合递减存在；优先级20的“暂时取消低优先级响应条件”没有作为真实 effect1 定义，而是在 availability 检查中硬编码；不具可扩展性。 |
| 21 | 预判 | 不符合 | 锁定+弃牌定义存在，但弃对手未知手牌被强制随机而非发动者UI选择；弃牌动作未完成前同一时点后续监听可继续；不可无效定义存在。 |
| 22 | 识破 | 不符合 | 偷牌和移动被同轮启动，effect1提前完成，effect2可提前无效攻击；这是 P0-01/P0-03 的直接实例。 |
| 23 | 觉醒 | 不符合 | `GameActions.awaken_draw()` 是标注 Simplified 的原子实现；用英文 `predict/expose` 搜中文ID（`GameActions.gd:2430-2465`），很可能识别不到预判/识破；缺少两次按种类选择、临时区、正式获取牌动作、AI选择和手牌availability注册。 |

## 6. 响应窗口、攻击牌与迎击牌结算

### 6.1 响应窗口不支持文档要求的多牌选择

权威文档第38行允许选择任意张可响应牌，最多1张迎击牌，然后按优先级、同优先级先来后到依次使用牌/执行其他效果。

当前 `TimingEngine.handle_response_selection()`：

- 虽对 `selected_cards` 排序（`352-360`），但 `362-365` 只取 `selected_cards[0]`。
- 注释明确写“非迎击牌暂不处理”（`362-364`）。
- 无论选中项是否行动牌，都按 `use_action_card` 发起（`381-395`），没有“装备牌/机师牌直接执行效果”的分支。
- 没有验证 selected 中迎击牌数量最多1，也没有验证选项仍然可用、仍在合法区域。

这会直接破坏掩护任意张、推进任意张以及未来装备/机师响应。

### 6.2 迎击牌临时区生命周期错误

普通回避/疾行/防御在直接效果 child 完成后才进入 settle，方向基本合理；反击属于跨原攻击 ATTACK_SETTLE 的特殊牌，effect2 未触发时牌仍有未完成效果，按用户明确要求必须继续处于临时区。

但 `_step_settle()` 对所有非虚拟牌统一调用弃置（`use_action_card_action.gd:295-327`），没有使用已经写出的 `_has_bind_to_attack_action_effect()`。代码注释声称此类牌应由 attack cleanup 弃置，但 `attack_action.gd:331-334` cleanup 实际为空。说明设计意图和可执行代码相互矛盾。

正确模型不应再添加“某张牌特判”：use_action_card 应持有该牌的 pending effect scope；只要 scope 内还有跨时点 listener 未终结，settle 就不可运行。

### 6.3 使用牌的弃置动作没有纳入父子链

`use_action_card_action.gd:320-325` 通过 DeckService 发起 discard，但不返回 `effect_action_created`。如果弃置动作的 DISCARD 时点触发离场效果并暂停，使用行动牌仍可能发 `USE_ACTION_SETTLE` 和完成。应直接创建 `EXECUTE_DISCARD` child 并等待 `DISCARD_SETTLE`。

## 7. AI 与人类共用底层逻辑审查

### 7.1 当前 AI 不是“同规则、不同决策器”，而是分散特判

AI判断散落在：

- `ActionUIBridge.gd` 的每个 input_type match 分支；
- `TimingEngine.gd` 的 optional弃牌、损伤转移特判；
- `steal_action_card_action.gd:97-130`；
- `battle_state.gd:647-698` 的主回合脚本；
- 旧服务中的自动放置逻辑。

玩家身份通过 `player_id != "player"` 判断（如 `ActionUIBridge.gd:145-160`、`steal_action_card_action.gd:126-130`），没有 controller type。未来第二个人类、本地多人、观战/远程玩家都会被误当 AI。

### 7.2 已确认“AI效果弹给人类”的具体根因

`TimingEngine._execute_actions()` 触发 `choose_one_effect` 时只发送 action/effect/options（`TimingEngine.gd:1315-1321`），没有 `player_id`、`mech_id`、`source_mech_id`。`ActionUIBridge._is_ai_source()`（`153-160`）因此返回 false，走人类 `effect_choice` UI。维修、联合攻击、推进监听及装备/机师 CHOOSE_ONE 均可能受影响。

此外：

- `select_equipment_slot`、`show_cards`、`confirm_use_card`、未知 generic input 没有 AI 分支。
- `redirect_select` 的 AI逻辑写死在 TimingEngine，未经过统一决策接口。
- `_auto_mech_target()` 只选字典中的第一个非自身存活机甲（`312-330`），未根据 target rule 区分敌/友、收益或合法候选集。
- `_auto_select_weapon()` 固定第一把武器；`_auto_discard_cards()` 固定前N张；这些是占位策略，不足以支持所有牌。

### 7.3 AI 主回合无法使用全部行动牌

`battle_state.gd:284-307` 的 AI 回合只有：向玩家移动一次、尝试攻击一次、结束回合。`_ai_try_attack_new()`（`657-698`）只找第一张攻击牌和第一把武器，只有目标已在该基础射程内才使用。

当前 AI 不会主动：

- 使用维修、聚能、推进、联合、回收、回忆、折扣、补给、锁定、觉醒等辅助牌；
- 设置装备、选择替换区域；
- 购买/使用折扣/刷新商店；
- 评估不同攻击牌（双连、预判、闪击等）的收益和合法性；
- 在攻击前利用范围修正寻找原本可攻击的目标；
- 根据牌效规划弃牌、目标、武器和移动终点。

所以“AI可以实现所有牌的使用和选择对象确认”的答案是：**现在不可以。** 当前仅能自动完成一部分被动响应和少量通用输入。

### 7.4 建议的通用 AI 决策架构

统一定义：

```text
Action/Effect 规则层
  -> DecisionRequest(type, actor_player_id, legal_options, min, max, optional, context)
       -> HumanDecisionProvider: 显示UI，返回DecisionResult
       -> AIDecisionProvider: 对同一legal_options评分，返回DecisionResult
  -> ActionService.continue(request_id, DecisionResult)
```

必须遵守：

1. 合法候选由规则层生成；AI和UI都不能自己重新推导一套候选。
2. DecisionRequest 必须始终带 actor_player_id，不允许 Bridge 从不稳定字段猜。
3. AI只决定“选哪个”，不直接改状态；所有结果仍回到同一 Action step。
4. 支持的通用类型至少包括：confirm、choose_cards、choose_mechs、choose_weapon、choose_cells/path、choose_slots、choose_number、choose_option、select_response_set、acknowledge_show。
5. AI策略可先是启发式评分，但不得以“第一项”代替合法性和完整覆盖。

## 8. 测试审查与本次运行结果

### 8.1 本次运行

执行命令：

```text
F:\Godot_4.6\Godot_v4.6-stable_win64.exe --headless --path . -s res://tests/run_tests.gd
```

结果：启动命令的外层进程先返回，但实际 Godot 测试进程继续运行并卡住；会话日志 `battle_logs/session_log_20260717_213505.txt` 最后停在 `damage_change` 请求 `place_damage_tokens`。测试进程持续占用 CPU，之后已终止。因此本次不能给出“全部测试通过”的结论。

这也表明测试驱动对真实 UI 等待态缺少超时、自动决策或失败退出机制。

### 8.2 当前测试覆盖缺口

- `tests/test_ai_input_bridge.gd` 存在，但没有列入 `tests/run_tests.gd:30-55` 的 test_files。
- 大量测试验证“effect定义存在、字段正确、动作被创建”，没有验证“前一 child 完成前后一 child绝不启动”。
- 没有覆盖23张牌的完整端到端生命周期：hand -> confirm -> temp -> 全效果/全部输入 -> discard -> USE_ACTION_SETTLE。
- 没有覆盖响应窗口多选、最多1张迎击、装备/机师效果与行动牌混选、同优先级注册顺序。
- 没有双连两个目标的独立响应/命中/伤害测试。
- 没有反击牌在攻击B完成前仍处于temp_zone的断言。
- 没有 Turn Action 在时点 listener 等待输入时停住后续资源变化的测试。
- 没有针对 Step error 必须中断且不改状态的测试。

## 9. 详细整改计划

### 阶段 A：冻结规则接口并补失败测试（先红后绿）

目标：在改执行器前，把权威串行语义固定为可执行测试。

1. 为 Action/Effect/Timing 分别添加 trace recorder：记录 start、pause、resume、complete、cancel 和 record快照。
2. 添加 P0-01 测试：effect actions=[等待输入A, 动作B]，断言A完成前B未创建。
3. 添加 listener 优先级测试：priority20 child等待时，priority10 listener未启动；同优先级按seq。
4. 添加 stale request 测试：错误request_id不能继续任何动作。
5. 添加 error中断测试：非法主动用牌、非法移动、无合法目标均不得离手/扣资源/继续时点。
6. 给所有等待测试加帧数/时间上限，超时输出全部 active actions 与 decision requests 后退出失败。

完成标准：测试会稳定失败并明确指出当前错序，不再以卡死表示失败。

### 阶段 B：实现统一串行执行栈

目标：解决所有 P0 的共同根因。

1. 引入 `ExecutionFrame`：ActionFrame、TimingFrame、EffectFrame、DecisionFrame。
2. Action step handler只返回结构化结果；禁止内部一边循环一边启动多个 child。
3. TimingFrame收集、统一排序 listener；保存 cursor；一个 listener完整结束才 cursor+1。
4. EffectFrame保存 actions cursor；一个 child完整结束才执行下一 action。
5. parent-child 只允许一个 active child；如确需并行，必须由权威规则明确声明，本项目两份文档当前没有并行要求。
6. `requires_effect` 改查 EffectFrame completed，不查“已调用”。
7. 把 ActionUIBridge 单槽改成 request map，并让 UI回传 request_id。

完成标准：识破的偷牌、移动、无效攻击严格三段；预判的锁定、弃牌、不可无效按同一时点顺序；日志不存在两个同时等待的同链 child。

### 阶段 C：重做使用行动牌生命周期与响应窗口

目标：满足临时区和整牌串行结算。

1. validate完整检查 active player、phase、owner、zone、牌种、主动/响应可用条件、攻击次数、最大修正范围内目标。
2. 确认使用不是 Action 内重复确认；Human先确认，AI decision provider确认，确认后才创建 use action。
3. `card_effect_scope` 跟踪该牌所有 DIRECT/LISTEN/依赖效果，包括绑定攻击A后续时点的效果。
4. scope未关闭时禁止 settle；settle用正式 discard_card child并等待。
5. 响应窗口生成完整 legal options；允许任意张，验证最多1张迎击；排序后逐项使用/执行并等待。
6. 非行动牌响应执行 effect_fire，不走 use_action_card。
7. 取消响应只关闭窗口；取消移动只结束该移动循环；取消攻击选择按文档中断攻击。为不同取消语义建立明确枚举，禁止统一 `cancel_action` 猜测。

完成标准：反击牌在攻击B完整结算前始终temp_zone；响应窗口多牌逐个完成；任何时刻最多一个 decision。

### 阶段 D：修基础动作

推荐顺序：

1. Attack：多目标数据模型、finalize damage/markers、extra_range候选、取消与错误。
2. Stat/BasicMove：移动扣动力改成 stat_modify child。
3. DamageChange：增加/减少都按 executor 决策合法区域；AI provider自动选，人类UI选。
4. SetEquipment：移除损伤改 damage_change child；AI slot决策。
5. Gain/Discard/Show/EffectFire：统一等待，修show重复need_input。
6. Turn/Round：改正式 Action，所有子动作可暂停。

完成标准：生命周期文档每一行都有对应 step 测试和 timing trace 断言。

### 阶段 E：逐张修23张牌

建议分批：

- E1 简单牌：进攻、猛击、回收、回忆、补给。
- E2 攻击修正：强袭、破甲、双连、闪击、预判。
- E3 迎击：回避、疾行、防御、反击、识破。
- E4 状态与选择：维修、聚能、推进、掩护、联合、折扣、锁定、觉醒。

每张牌必须有一个真实流程测试，并至少断言：区域变化、时点序列、effect顺序、child顺序、取消路径、AI路径、人类路径、最终弃置时刻。

必须优先修的单牌明确项：

1. 推进+4改为权威+5；实现手牌共用监听和任意数量选择。
2. 破甲在 AFTER 后更新最终markers。
3. 聚能正确解析 stacks multiplier。
4. 掩护范围使用被攻击目标位置，支持多张。
5. 联合effect2在 USE_ACTION_BEFORE 可见，并支持Target选择攻击牌。
6. 觉醒移出 legacy原子简化实现，做成可暂停、两轮选择的效果序列。

### 阶段 F：通用 AI

1. PlayerState新增 controller_type（human/ai），禁止用id字符串判断。
2. 构建统一 legal option generators。
3. 为每类 DecisionRequest 建立AI scorer。
4. 主回合生成所有合法候选动作：移动、攻击、每张可主动行动牌、设置装备、商店、结束回合。
5. 用轻量模拟或启发式评分选择动作；执行仍走 ActionService。
6. 为23张牌分别跑 AI端到端测试，确认无 `request_ui_popup`，且结果合法完成。

完成标准：把玩家ID改成任意值仍能正确识别人类/AI；AI使用每张牌时不触发人类UI；Human和AI同一输入在进入Action后的trace除DecisionProvider外完全一致。

## 10. 建议的验收清单

- [ ] Step error 会中断，非法行动牌不离手。
- [ ] 任意执行链最多一个 active child、一个 active decision。
- [ ] Timing监听高优先级完整完成后才开始低优先级。
- [ ] 同优先级严格按注册seq；响应选项保留seq。
- [ ] 双连能选择最多2个目标并正确记录、响应、命中、结算。
- [ ] 破甲命中后最终损伤确实+2。
- [ ] 反击牌在攻击B完成后才弃置。
- [ ] 识破严格偷牌完成 -> 移动完成/取消 -> 无效攻击。
- [ ] 聚能每层+4，使用对应武器结算后清空。
- [ ] 推进每张+5，并可在迎击使用时选任意数量。
- [ ] 掩护按被攻击目标与持有者范围判断，可多张，且不记为迎击响应。
- [ ] 预判由发动者选择对手未知手牌，不是系统随机。
- [ ] 觉醒完整执行两轮选择/随机/牌顶、临时区、获取动作。
- [ ] Turn/Round时点效果可暂停整个周期。
- [ ] AI能对每一种DecisionRequest给出合法结果；测试期间没有人类UI信号。
- [ ] `tests/run_tests.gd` 纳入AI bridge和23张牌端到端套件，并有超时失败机制。

## 11. 权威文档待确认项

生命周期文档第99-105行“生命变动动作”中：第101行是“生命变动前”，第102行正式变动生命，第103行再次写“生命变动前”。代码发 `HP_CHANGE_AFTER`。从其他动作的命名对称性看，第103行很可能是笔误，但由于用户指定文档为唯一权威，本报告不擅自修正文档。需要规则作者确认第103行是否应为“生命变动后”。

在确认前：保留代码现状但把相关测试标为 pending，不要让其他编码AI依据猜测改常量。

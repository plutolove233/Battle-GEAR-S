# 人类玩家 UI 与攻击结算链路补充审查（2026-07-17）

> 本文是对 `docs/action_engine_logic_audit_2026-07-17.md` 的补充审查。审查范围为人类玩家从输入请求到 UI、确认/取消、动作恢复、界面刷新，以及攻击损伤标记全部放置后的最终结算。规则判断以 `new_logic/行动牌的效果与逻辑.txt` 与 `new_logic/各动作的生命周期与时点.txt` 为唯一权威；本文不修改代码。

## 一、结论摘要

当前 UI 能够显示若干基本面板，但仍不是一个可靠的“一个等待动作对应一个输入面板”的系统：旧版 `app_root.gd` 预选流程和 Action Engine 的 `ActionUIBridge` 同时存在；所有等待输入共用一组全局状态；不同面板的取消含义不一致；部分目标高亮没有按规则过滤；AI/人类分流依赖不稳定的字符串字段。结果是：

1. **攻击损伤标记面板本身会在最后一枚标记放置后才发出 `placement_completed`，这一点正确；但攻击是否真正等待到该信号，取决于 ActionUIBridge 的等待槽和回调是否仍指向同一个动作。** 一旦等待槽被覆盖或取消按钮清掉状态，攻击可能停在 `waiting_sub_action`、错误进入 `ATTACK_SETTLE`，或 UI 消失而动作仍未完成。
2. **攻击结算前置条件必须是“所有损伤标记已实际写入状态并完成损伤触发”，而不是“损伤面板已弹出”或“用户点过一次确认”。** 当前实现依赖面板点击逐枚写入，再由 `placed=true` 恢复 `damage_change`；缺少统一的服务层完成校验，不能防止数量不足、非法槽位、装备损坏后可选槽变化等异常路径。
3. `select_mech_target` 在 `ActionUIBridge` 中重复匹配；`response_panel.availability_effect_selected` 仍连接了旧回调，但新面板确认只发 `response_selected`；旧版卡牌确认、目标选择、聚能武器选择与新 Action 输入重复，存在重复弹窗和状态串线风险。
4. 攻击目标 UI 只按“武器可达格子内有机甲”高亮，没有过滤己方/敌方；迎击移动 UI 同时显示可移动范围与攻击威胁范围，但点击处理和取消处理依赖旧状态字段，容易出现按钮可见而没有有效动作的情况。
5. 部分 UI 没有 AI 分支：`select_equipment_slot`、`show_cards`、`confirm_use_card`、`redirect_select` 等会直接请求人类弹窗；其中有些输入可能由 AI 效果触发，必须在底层统一决策后再决定是否显示 UI。

## 二、攻击结算的正确时序与当前实现核对

### 2.1 规范要求

攻击应保持以下严格串行关系：

`ATTACK_BEFORE → ATTACK_PRE → ATTACK_AT（响应窗口完成）→ 命中判定 → ATTACK_AFTER → 产生 HP/损伤子动作 → 每个损伤点实际放置及其触发处理 → DAMAGE_CHANGE_SETTLE → ATTACK_SETTLE → 行动牌最终离开临时区`。

其中，损伤标记 UI 是一个**暂停点**，不是结算完成事件。只有以下条件全部满足，才允许攻击进入 `ATTACK_SETTLE`：

- `damage_change` 的 `remaining` 为 0；
- 每一枚标记都已经通过服务层写入目标槽位；
- 每次放置后的装备损坏、替换、触发动作已经完成；
- `DAMAGE_CHANGE_SETTLE` 已执行；
- 父级攻击动作确认子动作完成。

### 2.2 当前正确部分

- `scripts/ui/damage_placement_panel.gd:117-197` 的面板按一次点击放置一枚标记，并在 `_remaining_tokens <= 0` 后才发出 `placement_completed`。因此，单从面板信号定义看，不是弹窗出现即完成。
- `scripts/app/app_root.gd:382-384` 正确连接了 `placement_completed`；`2165-2174` 在等待输入类型为 `place_damage_tokens` 时才提交 `{"placed": true}`。
- `scripts/action_defs/damage_change_action.gd:78-99` 只有在 `placed/auto_placed` 为真时才越过人工放置等待；`attack_action.gd` 的 `apply_damage` 创建损伤子动作，父攻击应等待子动作完成后才走 settle。

### 2.3 必须修复的结算风险（P0）

#### P0-1：完成条件只由 UI 回调声明，没有服务层核验

位置：

- `scripts/app/app_root.gd:2165-2174`
- `scripts/action_defs/damage_change_action.gd:78-99`
- `scripts/ui/damage_placement_panel.gd:171-197`

问题：UI 只发送 `placed=true`，`damage_change_action` 没有重新计算“请求数量 - 已实际放置数量”。如果发生非法槽位、服务调用失败、重复点击、装备损坏导致槽位变化，UI 仍可能把动作标记为完成。`_remaining_tokens` 是面板内存变量，不是权威状态。

整改：在 `DamageChangeAction` 或专用 `DamagePlacementSession` 保存 `requested_tokens`、`placed_tokens`、`remaining_tokens`；恢复动作时必须由服务层查询/核对结果，数量不为零就继续等待，禁止仅凭 `placed=true` 跳过。

#### P0-2：取消攻击按钮可能取消 UI 而不取消真实等待动作

位置：`scripts/app/app_root.gd:2052-2080`。

问题：`_on_cancel_attack()` 对所有非空等待槽调用 `ActionUIBridge.on_ui_cancelled()`，但损伤放置不是普通的可撤销目标选择。若攻击已造成命中且损伤子动作正在等待放置，用户点击“取消攻击”会把损伤动作取消/清理，语义上等同于撤销已发生的攻击；若等待槽已经被其他请求覆盖，按钮可能只清理高亮，留下原攻击动作卡死。

整改：损伤放置阶段隐藏通用“取消攻击”按钮，改为不可取消的强制放置面板；或提供“放弃并按规则自动放置”的明确按钮，按钮只能提交合法的自动决策，不能取消已产生的攻击损伤。所有取消操作必须通过动作 ID 定向取消，并记录原因。

#### P0-3：全局单等待槽无法保证父子动作串行

位置：`scripts/action_core/ActionUIBridge.gd:19-24,46-142,494-534`。

问题：`_waiting_action_id/_current_input_type/_current_input_params` 只有一份。攻击、损伤子动作、装备损坏触发动作或响应窗口嵌套时，后到的请求会覆盖前一个请求；面板完成时只读取“当前”请求，可能把损伤完成提交给错误动作。该问题直接破坏“损伤全部完成后才 ATTACK_SETTLE”。

整改：改为 `Dictionary[action_id, InputRequest]`，并在 UI 层维护一个明确的 modal 队列；每个面板携带 `action_id` 和 `request_token`。确认/取消必须校验二者，过期回调丢弃并记录错误。父动作只能在子动作 `completed` 信号后恢复。

#### P0-4：AI 自动放置也缺少完成回读

位置：`scripts/action_core/ActionUIBridge.gd:427-442`。

问题：AI 直接调用 `place_damage_tokens` 后发送 `auto_placed=true`，没有核对实际写入数量，也没有保证装备损坏处理动作已完成。AI 路径和人类路径必须共享同一完成校验。

整改：抽取 `DamagePlacementResolver.resolve(session, policy)`；人类点击和 AI 策略都只产生“选择槽位”命令，resolver 串行执行、校验、等待损坏动作，最后统一发 `placement_complete`。

## 三、人类 UI 逐项审查

### 3.1 卡牌入口与重复确认

位置：`scripts/app/app_root.gd:545-603,2522-2539,2570-2816`。

- 手牌点击后先由 `app_root` 弹“确定使用/取消使用”，Action Engine 又可能在 `confirm_use_card` 再弹一次确认。应保留一个确认层，避免重复按钮。
- `_enter_choice_select`、`_handle_repair_play`、`_enter_support_weapon_select` 等旧流程仍在处理目标/效果选择；新流程应只由 `ActionUIBridge` 发请求。两个流程都写 `_choice_select_card_id`、`_support_*`、`_pending_target_*`，可造成一次点击同时恢复旧动作和新动作。
- `_play_action_card` 依据 `ok/needs` 判断结果，但 Action Engine 可能返回 `waiting_input/waiting_effect_action`。UI 可能显示“打出失败”，实际动作已经暂停等待输入。

整改：卡牌点击仅调用 `ActionService.execute`；返回 `waiting_*` 时显示对应面板，返回 `completed` 才显示成功，`cancelled/error` 才显示失败。删除旧版预选分支或改成纯展示适配器。

### 3.2 武器选择

位置：`scripts/ui/weapon_picker_panel.gd:35-132`、`app_root.gd:1390-1406,1518-1525,1990-2050`。

- 面板本身有“确认”和“取消”两按钮，正确支持先选后确认。
- 同一面板被攻击、聚能、迎击反击、装备替换四种流程复用，回调通过多个全局标志分派；若弹窗切换或旧标志未清空，武器选择会提交给错误流程。
- `weapon_charge_select` 弹窗分支未统一调用 `_show_cancel_button(true)`，底部取消按钮状态可能残留。

整改：面板配置必须带 `request_id/input_type/purpose`，回调直接回传请求 ID；取消按钮由面板内部处理，不再依赖全局 `_support_weapon_select_card_id` 等标志。

### 3.3 攻击目标与迎击移动目标

位置：`app_root.gd:1399-1440,1441-1458,1285-1338`。

- 攻击目标高亮包含所有机甲，没有按敌我过滤；玩家可点击己方单位，随后才在动作层失败。UI 应只显示合法目标，并对非法点击给出明确提示。
- 迎击移动同时显示绿色可移动格和红色攻击威胁格，但“取消攻击”按钮与旧 `_assault_movement_active` 状态耦合；新 `single_move` 等待输入应以 `action_id` 定向取消/结束。
- 修理/联动目标高亮读取 `from_mech_id`，而输入参数实际可能只有 `mech_id`，会出现面板打开但没有高亮。

整改：由 `TargetChecker` 生成合法目标列表，UI 只渲染该列表；点击时把 `target_id` 原样回传，不在 app_root 重复推导规则。

### 3.4 响应/迎击窗口

位置：`scripts/ui/response_panel.gd:10-18,37-69,270-299`、`app_root.gd:366-372,793-851`。

- 新面板确认只发 `response_selected`，但仍连接 `availability_effect_selected`，且 app_root 仍有旧回调；这是重复入口，应删除旧信号或彻底隔离 legacy 模式。
- 面板关闭发生在调用 TimingEngine 之前；若动作 ID 已过期或提交失败，玩家看不到可恢复的错误，也不能重新打开窗口。
- 需要显示当前攻击者、响应时限、可用卡牌和“跳过”结果；当前面板只有卡牌/确认/跳过，缺少提交中禁用，可能重复点击。

整改：提交后按钮立即禁用，等待 `response_resolved` 后关闭；失败保持面板并显示原因；只保留 `handle_response_selection(action_id, selected_cards)` 一个入口。

### 3.5 损伤放置面板

位置：`scripts/ui/damage_placement_panel.gd:46-197`、`app_root.gd:1499-1508,2165-2174,2507-2515`。

- 面板逐枚放置并在最后一枚后发完成信号，这是正确基础。
- 没有取消按钮，也没有“自动放置剩余”按钮；若合法槽位为空、装备损坏改变可选槽、服务调用失败，面板可能显示无可点击按钮而无法恢复。
- `_refresh()` 使用 `queue_free()` 后立即重建，信号回调/快速双击期间可能命中旧按钮；应增加提交锁和服务层幂等检查。
- 新 Action Engine 路径和旧 `_handle_attack_result/_show_damage_placement` 路径都能打开同一面板，必须确认同一攻击不会出现两个入口。

整改：面板显示“剩余 N/总计 M”，每次点击后由服务返回成功/失败；失败保留剩余数量并提示；完成前禁止关闭；完成回调携带 action_id 和实际计数。

### 3.6 选择效果/弃牌面板

位置：`scripts/ui/choice_panel.gd:20-123`、`discard_select_panel.gd:35-190`、`app_root.gd:2391-2476`。

- `ChoicePanel` 的确认/取消按钮是持久布局，选项内容只清理 scroll_content，当前没有明显重复创建；但同一面板承载卡牌确认、效果选择、转移点数、商店/出售确认，依靠全局字段区分，串线风险高。
- `DiscardSelectPanel` 只在选够数量后启用确认；强制弃牌取消会重新显示，optional/need_input 取消则走不同恢复语义，用户看不到当前动作是否仍在等待。
- 旧版弃牌路径直接调用 `game_actions.discard_action_card` 并刷新，不等待每个弃牌动作完成；这与“行动牌效果串行完成后才离开临时区”不一致。

整改：统一 `ChoiceRequest`/`DiscardRequest`，每个请求带动作 ID、来源效果、是否可取消、取消策略；弃牌动作逐个 await 完成后才结束父效果。

## 四、AI 与人类 UI 分流补充

`ActionUIBridge` 当前对部分输入自动决策，但 `select_equipment_slot`、`show_cards`、`confirm_use_card`、`redirect_select` 和未知输入直接发 UI。必须按“执行者/拥有者”统一判断，而不是按是否当前窗口或硬编码 `owner_player_id == "player"` 判断。AI 决策结果应调用与人类完全相同的 `continue_action(action_id, input_data)`；区别只能是输入来源，不得绕过服务校验、损伤触发和子动作等待。

建议建立 `AIDecisionService`：输入 `InputRequest`，输出合法候选；再由同一个 `InputResolver` 校验并提交。没有合法候选时返回规则定义的 pass/auto-default/error，不能弹人类窗口。

## 五、整改计划（按优先级）

### 阶段 1：先保证攻击不会提前结算

1. 实现带 `action_id/request_id` 的输入请求对象和请求表，移除 ActionUIBridge 单槽覆盖。
2. 将损伤放置封装为可查询的串行会话；人类和 AI 共用 resolver。
3. `DamageChangeAction` 恢复时核对实际放置数量、装备损坏子动作状态和 `DAMAGE_CHANGE_SETTLE` 完成标志。
4. 损伤放置期间禁用“取消攻击”；只允许完成或规则允许的自动放置。
5. 在 `AttackAction` 增加断言/日志：未完成 damage child 时禁止进入 `ATTACK_SETTLE`。

### 阶段 2：收敛 UI 入口

1. 删除或隔离 app_root 的旧卡牌预选/目标/聚能流程。
2. 每类输入只保留一个面板、一个确认入口、一个取消入口。
3. 面板回调统一携带请求 ID；提交中禁用按钮，失败不关闭面板。
4. 目标高亮改由 TargetChecker 的合法目标集合驱动，过滤敌我、距离、状态和效果条件。
5. 清理 response_panel 的旧 `availability_effect_selected` 通道及所有重复连接。

### 阶段 3：统一 AI

1. 增加 `AIDecisionService` 覆盖所有 `input_type`。
2. AI 不创建人类 UI；自动选择仍走同一个 resolver/continue_action。
3. 为每种牌建立“可用目标为空、多个目标、多个效果、需要弃牌、需要放置损伤、需要响应”的决策测试。

### 阶段 4：可观测性与回归测试

日志至少记录：`action_id`、`parent_action_id`、`request_id`、输入类型、请求/确认/取消时间、请求数量、实际放置数量、每个损伤槽、触发的装备损坏动作、`DAMAGE_CHANGE_SETTLE` 和 `ATTACK_SETTLE` 时间。

必须增加以下测试：

- 3 枚损伤标记逐枚放置：前 2 枚后攻击仍不能 settle，第三枚及所有损坏动作完成后才 settle。
- 非法槽位/服务失败/装备损坏后槽位变化：动作保持等待并显示错误，不得提前完成。
- AI 3 枚损伤自动放置与人类路径产生相同最终状态和时点顺序。
- 响应窗口、目标选择、弃牌、效果选择嵌套时，旧请求不会被新请求覆盖。
- 任一取消按钮只取消被授权的可取消输入，不会撤销已经产生的攻击损伤。
- 卡牌确认、效果选择、响应窗口均无重复按钮/重复信号，提交后不可重复点击。

## 六、验收标准

修复完成后应满足：

1. 任一时刻屏幕上最多只有当前 `request_id` 对应的一个输入面板；旧面板关闭不会影响新动作。
2. UI 显示、确认、取消、错误提示都能回到同一个动作 ID；动作状态可在日志中追踪。
3. 攻击在所有 HP/损伤子动作、全部损伤标记、装备损坏/替换触发完成前，绝不发出或执行 `ATTACK_SETTLE`。
4. 人类与 AI 的底层动作、费用、目标校验、时点和结算完全相同，仅选择来源不同。
5. 行动牌在其全部效果及触发动作完成前保持临时区；完成/取消按规则统一进入弃置或原区，不能由 UI 刷新提前改变区域。

## 七、补充问题：AI 对 AI 的选择效果不得干扰人类玩家

这是一个独立且必须优先处理的 UI 隔离问题。规则上，AI 玩家触发、且作用对象/选择执行者仍为 AI 玩家的效果，应由 AI 决策服务在后台完成；即使效果需要选择目标、选择卡牌、选择武器、选择损伤槽位、选择二选一效果或选择转移点数，也不能打开人类玩家的 UI。

### 7.1 当前风险位置

- `scripts/action_core/ActionUIBridge.gd:46-142`：收到输入请求后直接写入全局 `_waiting_action_id/_current_input_*`，再按若干字段判断是否 AI。只要 `input_params` 缺少 `attacker_id/mech_id/source_mech_id/executor/player_id` 中的正确来源字段，`_is_ai_source()` 会返回 false，随后错误发出 `request_ui_popup`。
- `scripts/action_core/ActionUIBridge.gd:145-185`：AI 判断依赖硬编码 `owner_player_id != "player"` 以及从多种字段猜测机甲来源；无法可靠区分“AI 触发、AI 选择”和“人类触发、目标是 AI”。后者不应自动化，前者必须自动化。
- `scripts/app/app_root.gd:1390-1585`：所有 `request_ui_popup` 都由同一个人类 AppRoot 接收，并使用全局 `choice_panel/weapon_picker_panel/damage_placement_panel/response_panel`。一旦误判，AI 的请求会遮挡人类界面，覆盖人类等待动作。
- `scripts/app/app_root.gd:366-400`：所有面板都是单实例、全局可见，没有 `executor_player_id`、`input_owner` 或 `action_id` 的显示隔离检查。
- `scripts/action_core/TimingEngine.gd`（响应/监听效果分支）：AI 触发的监听效果若通过 `action_needs_input` 请求选择，而参数没有携带明确执行者，最终会落入人类 UI 通道。

### 7.2 典型错误场景

1. AI 玩家打出辅助牌，效果要求在自身两个效果中选择一个：`choose_one_effect` 被误判为人类请求，弹出人类 `choice_panel`；人类点击后却恢复了 AI 的动作。
2. AI 对 AI 造成攻击并产生损伤标记：`place_damage_tokens` 的 executor 没有正确传递，损伤面板覆盖人类操作；人类选择的槽位被写入 AI 机甲。
3. AI 触发需要选择武器/目标的迎击或聚能效果：`weapon_picker_panel` 复用人类面板，底部“取消攻击”按钮进入错误动作分支。
4. AI 触发可选弃牌或转移效果：`discard_select_panel/choice_panel` 改写全局 pending 状态，人类原本正在响应的窗口被隐藏或恢复到错误 action_id。

### 7.3 必须采用的隔离模型

每一个输入请求必须携带并校验以下元数据：

```text
action_id
parent_action_id
request_id
executor_player_id
source_mech_id
decision_owner       # HUMAN 或 AI
target_player_id
input_type
```

分流规则必须是：

- `decision_owner == AI`：禁止发出 `request_ui_popup`；交给 `AIDecisionService`，通过与人类相同的 `InputResolver/continue_action` 提交。
- `decision_owner == HUMAN`：才允许发出 UI 请求；UI 必须绑定 `request_id`，不能读取全局“当前等待动作”。
- “效果作用于 AI”不等于“由 AI 选择”。判断依据是**谁拥有决策权/谁是执行者**，不是目标机甲的归属。
- AI 请求执行期间，不能改变或清空人类的 modal、overlay、pending target、choice 或 response 状态。
- 若 AI 需要多个连续选择，必须在 AI 自己的 action 队列中串行完成，不能借用人类 UI 队列。

### 7.4 具体整改项

1. 在 Action 创建时固定 `executor_player_id` 和 `decision_owner`，禁止在 UI 层通过 `owner_player_id` 猜测。
2. 将 `ActionUIBridge` 的单槽改成按 `request_id` 分区的请求表；AI 请求不进入人类 UI 表。
3. 增加 `AIDecisionService.resolve(request)`，覆盖目标、武器、效果、弃牌、损伤槽位、转移点数、响应和确认等所有 `input_type`。
4. AppRoot 的 `_on_action_ui_popup_requested` 第一行增加防御校验：非 HUMAN 请求直接记录错误并拒绝显示；正常 AI 请求根本不应到达此函数。
5. 所有面板显示前验证 `request_id` 与 `decision_owner == HUMAN`；关闭/刷新只能作用于匹配请求。
6. 日志记录 `executor_player_id/decision_owner/target_player_id/request_id`，能够证明 AI 请求从未触碰人类面板。

### 7.5 必须增加的回归测试

- AI→AI 的 `choose_one/choose_one_effect`：不创建任何 UI 节点，不改变人类等待请求，人类仍可正常操作自己的面板。
- AI→AI 的多枚损伤：AI 自动逐枚完成，未显示损伤面板，攻击仍在所有损伤和装备损坏动作完成后才 settle。
- AI→AI 的武器/目标/弃牌/转移选择：所有选择通过 AI resolver 完成，AppRoot 不收到 popup 信号。
- AI 动作与人类响应窗口同时存在：AI 子动作完成不会隐藏、覆盖或恢复人类 response/choice panel。
- 人类→AI 目标的效果：仍由人类选择（不能仅因目标是 AI 就自动执行）。

该隔离要求与本文第三、第四、第五节的请求 ID、统一 resolver、攻击串行结算方案是同一整改链路的一部分；未完成隔离前，不能认为“AI 与人类使用同一套底层逻辑”已经实现。

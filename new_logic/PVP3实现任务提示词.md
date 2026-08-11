# 任务：实现 PVP 3人模式

## 你的身份与约束（必须遵守）
- 这是 Godot 4.6 GDScript 项目「机斗战甲」(Battle-GEAR-S)，回合制机甲战棋桌游。
- **用中文回复**（用户看不懂英文，所有面向用户的回复用中文）。
- **不要用 subagent/智能体**（用户不信任 subagent 产出，自己用 Read/Grep/Edit 干活，不 spawn Agent）。
- 用 `python` 不用 `python3`。
- 每阶段完成后必须跑全套件测试确保无回归：
  `"F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd`
  用 `timeout 300` 包裹防止 Godot 卡死/OOM 耗尽显存（headless 模式仍可能泄漏，必须用 timeout 杀）。
- 每阶段存 memory 到 `C:\Users\m1396\.claude\projects\f--Battle-GEAR-S\memory\` 并更新 MEMORY.md 索引。
- 完整计划已写在 `.claude/plans/pvp3_plan.md`，先读它。
- 多问少错，过程中遇到歧义用 AskUserQuestion 问用户，不要自己拍板大方向。
- 详细 2 人 PvP 实现历史见 memory `pvp-test-mode-plan.md`（锁步/种子/对等输入交换全部已验证）。

## 背景：现有 2 人 PVP 架构（你要参考并扩展，不要破坏）
- **进程模型**：双进程 + 本地 TCP（127.0.0.1:port）。host=player 窗跑权威逻辑+NetHost(TCPServer)，spawn 1 个 client=enemy 窗。
- **锁步**：host 选随机种子 broadcast 给 client，双端用同种子 `start_tutorial` 建出相同牌堆/instance_id/action_id（ActionRegistry._id_counter + GameState._next_id_counter 纯计数无随机），对等跑完整动作引擎，**交换 input（op+data）而非状态**。协议消息 `{type:"input",op:String,data:Dict}`，net_transport 用 put_var/get_var（原生保留 StringName）。
- **核心方法**（全在 `scripts/app/app_root.gd`）：
  - `_net_exec(op,data)` L1032：本地执行 `_dispatch_input` + 广播（PvE 退化只本地）
  - `_broadcast_input(op,data)` L1022：host 用 net_host.send 广播；client 用 net_client.send 上行
  - `_apply_remote_input(op,data)` L1040：收对方 input 只本地执行
  - `_dispatch_input(op,data)` L1046：op->引擎方法分发（16 个 op: move/play_action_card/set_equipment/sell_equipment/shop_*/equipment_active/end_turn/ui_confirmed/ui_cancelled/respond_attack/resume_effect/damage_place/discard_cards/dev_edit/pilot_select）
  - `_net_end_turn(pid,discarded)` L1501：弃超限牌 + end_turn + 切对手回合（用 `gs.get_opponent_player_id(pid)` ← **2人逻辑，3人要改**）
  - `_is_my_turn()` L2350：ap==local_player_id（通用 ✓）
  - `_popup_owner(popup_type,params)` L1544：按 mech_id/player_id 反查 owner（**已通用，3人天然支持**）
  - `_start_pvp_host()` L412 / `_spawn_pvp_client()` L641 / `_start_pvp_client(args)` L668 / `_apply_pvp_seed_and_build()` L699
  - 机师选择：`_generate_pvp_pilot_pool()` L490 取6张不重复（host3+client3），`_check_pvp_both_selected` 双方选完开战
- **网络层**（`scripts/net/`）：net_host.gd 单 `_peer`/单 `_reader`/`send()` 单发；net_client.gd 连 host。
- **回合**：RoundService.gd `turn_order=[&"player",&"enemy"]`，`advance_to_next` 取模循环（已通用，set_turn_order 即可配3人）。GameState.get_opponent_player_id L122 返回第一个!=player_id（2人专用）。
- **建局**：GameSetupService.setup_tutorial_battle L22 硬编码 player/enemy 2玩家2机甲；configure_map_features L520 遍历 gs.players（**已通用 ✓**）。BattleState.start_tutorial L60 是入口。
- **胜利**：VictoryService.check_victory 硬编码 player/enemy（player destroyed=defeat, enemy destroyed=victory），回合上限比2人HP。
- **建局配置**：`data/campaign/tutorial_campaign.json`：frame_001_基础框架(联邦/25HP)、frame_002_原始框架(帝国/25HP)、player_start(2,2)、enemy_start(20,-6)、turn_limit=12、地图24×8。**只有2个机甲框架定义**，第3玩家复用 frame_001。

## 已确认决策（用户拍板，不要再问）
1. **范围**：完整可玩3人（网络+回合+建局+UI信息隐藏+胜利条件全做）
2. **拓扑**：星型 1host+2client，host 中继广播（任一窗口 input 发 host，host 广播给所有 client）
3. **模式**：新增独立 PVP3 模式（game_mode=&"PVP3"），主菜单加按钮「3人PvP」。原2人PvP/PvE 零改动，PVP3 逻辑全用 game_mode==PVP3 门控。
4. **第3玩家**：预设 id=&"third"，机甲复用 frame_001_基础框架，起始位置 (2,-6)，回合顺序 player->enemy->third 循环。

## 分阶段执行计划

### 阶段1：建局支持3人
- GameSetupService 新增 `setup_pvp3_battle(data_registry, pvp_map_features=true)`：仿 setup_tutorial_battle，创建3玩家(&"player"/&"enemy"/&"third"，全 is_human=true)、3机甲(&"player_mech"/&"enemy_mech"/&"third_mech"，player=frame_001, enemy=frame_002, third=frame_001)，起始 player(2,2)/enemy(20,-6)/third(2,-6)。**建局顺序固定 player_mech->enemy_mech->third_mech** 保证 instance_id 同步。牌堆/装备效果注册复用现有。
- BattleState 新增 `start_pvp3(registry)` 入口（仿 start_tutorial：context.initialize + set_rng_seed + setup_pvp3_battle + 初始装备/抽牌/商店/注册手牌 + _sync_compat_fields）。
- GameState 新增 `get_next_player_id(player_id) -> StringName`：按 [&"player",&"enemy",&"third"] 顺序取下一个**机甲未 destroyed** 玩家；全淘汰返回 &""。新增 `alive_player_count() -> int`。
- 保留 get_opponent_player_id（2人兼容，不动）。
- **测试**：新建 tests/test_pvp3_setup.gd，断言3玩家3机甲3起始位置 + get_next_player_id 轮转 + 跳过淘汰。注册到 run_tests.gd test_files 数组。

### 阶段2：网络层多 client
- net_host.gd：`_peer`单个 -> `_peers:Array[StreamPeerTCP]` + `_readers:Array` + `_peer_player_ids:Array[StringName]`。
  - `start(port, max_clients=2)`：max_clients 参数（2人调用传1，3人传2）。
  - `_process`：循环 accept 直到 max_clients 满；每个 peer 独立 poll+read。
  - `send(msg)`：广播给所有已连接 client。
  - `send_to(player_id, msg)`：按 player_id 定向发（seed/client_pilot_ids 需定向）。
  - 握手：client 连上发 `{"type":"hello","player_id":...}`，host 记录 _peer_player_ids。`client_connected` 信号带 player_id 参数。
  - `is_client_connected()` -> `client_count()` / `is_client_connected(player_id)`。
- net_client.gd：基本不变（连 host + 连上发 hello 带 local_player_id）。
- **注意向后兼容**：2人 PVP 仍调 start(port)（max_clients 默认2够用，或传1）。`send()` 广播对单 client 等价。改动 net_host 后必须跑 2 人 PVP 相关测试（test_pvp_lockstep_sync / test_pvp_client_intents）无回归。
- **测试**：新建 tests/test_pvp3_net_host.gd，2 client 连接 + 广播双收 + 定向 send_to。

### 阶段3：回合3人轮转
- RoundService.set_turn_order 已通用 ✓，PVP3 启动时 set_turn_order([&"player",&"enemy",&"third"])。
- app_root `_net_end_turn(pid,...)`：PVP3 时切 `gs.get_next_player_id(pid)`（非 get_opponent_player_id）。用 game_mode 判断分支，2人路径不动。
- `_pvp_start_other_turn()`：同上。
- **测试**：test_pvp3_turn_rotation：player 结束->enemy->third->player，淘汰一个跳过。

### 阶段4：app_root PVP3 启动+广播+机师选择
- 新增 `game_mode = &"PVP3"` 常量。
- `_start_pvp3_host()`：仿 _start_pvp_host，local_player_id=&"player"，set_turn_order 3人，调 battle.start_pvp3，spawn **2** client（enemy+third，各自 --pvp-local-player 参数），net_host.start(port, 2)。
- `_spawn_pvp_client` 已支持 `--pvp-local-player` ✓；加 `--pvp3` 标志区分入口（或复用，按 game_mode 判断）。
- `_start_pvp3_client(args)`：仿 _start_pvp_client，local_player_id=enemy/third。
- `_broadcast_input`：PVP3 host 用 net_host.send 广播所有 client；client 发 host（不变）。
- `_on_pvp_client_connected`：PVP3 时给每个新连 client 发种子（send_to(player_id, seed)），各自带本方候选机师 id。
- 机师选择：`_generate_pvp3_pilot_pool` 取 **9** 张不重复（host3+enemy3+third3），按 client player_id 发各自3张。`_check_pvp3_all_selected`：3方都选完统一开战。
- `_apply_pvp3_seed_and_build`：client 收种子调 start_pvp3 自建3人局。
- 窗口标题/偏移区分3窗（host/enemy/third）。
- **测试**：test_pvp3_host_spawn：host 配置2 client + 种子广播 + 机师9候选。

### 阶段5：胜利条件3人
- VictoryService.check_victory 新增 PVP3 分支（玩家数>2 或 game_mode 判断）：
  - 遍历所有玩家机甲，destroyed/HP<=0 标记淘汰。
  - 存活数 <= 1：结束（存活者胜；全灭平局攻击方不利）。
  - 回合上限：3人比 HP，最高胜，平局攻击方不利。
- 2人路径（player/enemy）保留不变。
- **测试**：test_pvp3_victory：2淘汰1胜 + 回合上限3人比HP。

### 阶段6：UI 信息隐藏（3人）
- hand_panel.gd 已 local_player_id ✓（己方手牌可见）。
- 对手手牌显示：3人时显示2个对手牌背数量（enemy + third）。看现有 hand_panel 怎么显示对手手牌，扩展为遍历非己方玩家。
- battle_board 遍历 mechs 通用 ✓（3机甲自动渲染，确认无硬编码2）。
- equipment_panel 显示己方 ✓。
- enemy_info_popup / mech_detail_panel 扩展支持查看2个对手（或通用遍历非己方玩家）。
- _popup_owner 通用 ✓（3人天然支持，确认即可）。
- **测试**：test_pvp3_ui：3机甲渲染 + 己方手牌可见 + 对手手牌隐藏。

### 阶段7：集成测试 + 实机
- 新建 tests/test_pvp3_lockstep_sync.gd（注册 run_tests.gd）：仿 test_pvp_lockstep_sync.gd，3端同种子建局一致 + move/set_equipment/shop/end_turn/attack 全流程 _net_exec + 手动喂 _apply_remote_input，断言 HP/活跃动作一致。
- headless `--pvp3-host` 连通测：3端同种子抽同牌，godot.log 无错误。
- 全套件无回归。

## 关键坑点（2人PVP已踩，3人复用）
1. **instance_id/action_id 同步**：3人建局顺序必须固定（player_mech->enemy_mech->third_mech），双端一致。next_id 是纯计数器，顺序一致即同步。
2. **网络握手用 player_id 不用连接顺序**：client 连接顺序不固定，必须靠 hello 消息带的 player_id 识别，不能用连接 index。
3. **GDScript lambda 按值捕获**：int/bool 局部变量在 lambda 内赋值不改外部；测试信号计数须用 Array 容器。
4. **弹窗一段式启动**：client 不能先建临时 context 再替换（会断 action_ui_bridge 信号致弹窗不弹）。必须与 host 一致：连 host 等种子 -> 收种子 start_pvp3 建真实 context -> _show_battle 连信号。
5. **_execute_step 阶段4 timing_done**：PVP3 的 end_turn 切人不要破坏现有 step loop。
6. **net_host 改多 client 必须保 2人兼容**：2人 PVP 测试（test_pvp_lockstep_sync 7用例 / test_pvp_client_intents 4用例）必须全 PASS。
7. **SLog preload**：-s 测试模式 autoload 裸标识符不可解析，日志必须用 `preload("res://scripts/services/slog.gd")`。
8. **关 Godot**：测试完用 timeout 杀，否则显存泄漏。

## 测试基线（当前 535 PASS）
当前全套件 TESTS PASSED（535 测试，含 pilot_011 测试20-21）。每阶段后必须维持全绿。已知偶发 flaky：test_assault_autoplay_ordering/test_expose_predict/test_equipment_effect_registers_on_set/test_mobile_head，重跑通过即可。

## 第一步建议
先读 `.claude/plans/pvp3_plan.md` + 现有 `scripts/net/net_host.gd` + `scripts/services/GameSetupService.gd` 的 setup_tutorial_battle + `scripts/app/app_root.gd` 的 _start_pvp_host/_spawn_pvp_client/_apply_pvp_seed_and_build，从阶段1开始。每阶段做完跑测试+存memory+报告进度。

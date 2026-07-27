## test_net_transport.gd - Phase B: TCP 传输层连通测试
##
## 验证 NetHost/NetClient 能在 localhost 建连，双向交换 Variant 消息，
## 且 StringName 经 var_to_bytes/bytes_to_var 保留（不降级为 String）。
extends RefCounted

const NetHost = preload("res://scripts/net/net_host.gd")
const NetClient = preload("res://scripts/net/net_client.gd")


func _frame(n: int = 1) -> void:
	var ml = Engine.get_main_loop()
	if ml and ml is SceneTree:
		for i in range(n):
			await (ml as SceneTree).process_frame


func _cleanup(host, client) -> void:
	if host != null:
		host.stop()
		host.queue_free()
	if client != null:
		client.disconnect_from_host()
		client.queue_free()


## host/client 建连 + 双向交换 + StringName 保留
func test_host_client_exchange_preserves_stringname() -> Variant:
	var ml = Engine.get_main_loop() as SceneTree
	var host = NetHost.new()
	var client = NetClient.new()
	ml.root.add_child(host)
	ml.root.add_child(client)

	var port := 45731
	var start_err = host.start(port)
	if start_err != OK:
		_cleanup(host, client)
		return "host.start failed: %d" % start_err
	client.connect_to(port)

	# 先接信号，再发数据，避免消息在 connect 前 _process 已 emit
	# 用 Array 容器捕获（GDScript lambda 按值捕获局部变量，直接赋值外层不会生效；
	# Array 是引用类型，append 其内容一定同步到外层）
	var received := []
	var host_received := []
	client.message_received.connect(func(msg): received.append(msg))
	host.message_received.connect(func(msg): host_received.append(msg))

	# 等连接建立（双向都 CONNECTED）
	var timeout := 0
	while (not host.is_client_connected() or not client.is_connected_to_host()) and timeout < 90:
		await _frame()
		timeout += 1
	if not host.is_client_connected() or not client.is_connected_to_host():
		_cleanup(host, client)
		return "connect timeout (host=%s client=%s)" % [host.is_client_connected(), client.is_connected_to_host()]

	# host 下行含 StringName 的快照式 dict
	var sent := {"type": "snapshot", "active": &"enemy", "slot": &"头部", "nested": {"k": &"v"}, "n": 42}
	host.send(sent)

	timeout = 0
	while received.is_empty() and timeout < 90:
		await _frame()
		timeout += 1
	if received.is_empty():
		_cleanup(host, client)
		return "client receive timeout"
	var rmsg = received[0]
	# StringName 保留校验
	if typeof(rmsg.get("active", null)) != TYPE_STRING_NAME:
		_cleanup(host, client)
		return "active not StringName: type=%d" % typeof(rmsg.get("active", null))
	if rmsg.get("active", &"") != &"enemy":
		_cleanup(host, client)
		return "active value mismatch: %s" % str(rmsg.get("active"))
	if typeof(rmsg.get("slot", null)) != TYPE_STRING_NAME:
		_cleanup(host, client)
		return "slot not StringName"
	if typeof(rmsg.get("nested", {}).get("k", null)) != TYPE_STRING_NAME:
		_cleanup(host, client)
		return "nested.k not StringName"
	if int(rmsg.get("n", 0)) != 42:
		_cleanup(host, client)
		return "n int mismatch: %d" % int(rmsg.get("n", 0))

	# client 上行 intent
	var intent := {"type": "intent", "action": "end_turn", "pid": &"enemy"}
	client.send(intent)
	timeout = 0
	while host_received.is_empty() and timeout < 90:
		await _frame()
		timeout += 1
	if host_received.is_empty():
		_cleanup(host, client)
		return "host receive timeout"
	var hmsg = host_received[0]
	if hmsg.get("action", "") != "end_turn":
		_cleanup(host, client)
		return "host received action mismatch: %s" % str(hmsg)
	if typeof(hmsg.get("pid", null)) != TYPE_STRING_NAME:
		_cleanup(host, client)
		return "intent pid not StringName"

	_cleanup(host, client)
	return true


## 大快照往返：用真实序列化产物测传输（模拟 Phase C 实际下行）
func test_large_snapshot_roundtrip() -> Variant:
	var ml = Engine.get_main_loop() as SceneTree
	# 复用 Phase A 的序列化器造一个真实大 dict
	const DataRegistry = preload("res://scripts/data/data_registry.gd")
	const BattleState = preload("res://scripts/battle/battle_state.gd")
	const StateSnapshot = preload("res://scripts/net/state_snapshot.gd")
	var registry := DataRegistry.new()
	registry.load_all()
	var battle := BattleState.new()
	battle.start_tutorial(registry)
	var snap := StateSnapshot.new().serialize(battle.context, &"enemy")

	var host = NetHost.new()
	var client = NetClient.new()
	ml.root.add_child(host)
	ml.root.add_child(client)
	host.start(45732)
	client.connect_to(45732)
	var received := []
	client.message_received.connect(func(msg): received.append(msg))

	var timeout := 0
	while (not host.is_client_connected() or not client.is_connected_to_host()) and timeout < 90:
		await _frame(); timeout += 1
	host.send(snap)
	timeout = 0
	while received.is_empty() and timeout < 90:
		await _frame(); timeout += 1
	if received.is_empty():
		_cleanup(host, client)
		return "large snapshot receive timeout"
	# 校验快照关键字段经传输后保留
	var rmsg = received[0]
	if int(rmsg.get("turn_number", -1)) != int(snap.get("turn_number", -2)):
		_cleanup(host, client)
		return "turn_number mismatch after transport"
	var r_players: Dictionary = rmsg.get("players", {})
	var s_players: Dictionary = snap.get("players", {})
	if r_players.size() != s_players.size():
		_cleanup(host, client)
		return "players size mismatch after transport: %d vs %d" % [r_players.size(), s_players.size()]
	# 对手(player)手牌隐藏标志应保留
	var p_snap: Dictionary = r_players.get(&"player", {})
	if not bool(p_snap.get("hand_hidden", false)):
		_cleanup(host, client)
		return "player hand_hidden flag lost after transport"
	_cleanup(host, client)
	return true

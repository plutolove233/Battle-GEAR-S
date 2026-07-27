## net_host.gd - PvP host 端 TCP 服务
##
## host（player 窗，权威进程）监听 127.0.0.1:port，接受一个 client 连接。
## 收到 client 的 intent 消息 -> 调 on_message 回调（host app_root 处理）。
## host 调 send() 下发 snapshot / popup / close_popup / battle_over。
##
## 单 client（1v1 测试模式仅需一个 client）。重连：client 断开后 host 重新接受新连接。
extends Node

const NetTransport = preload("res://scripts/net/net_transport.gd")

signal client_connected()
signal client_disconnected()
signal message_received(msg: Variant)

var _server := TCPServer.new()
var _peer: StreamPeerTCP = null
var _reader = null  # NetMessageReader
var _port: int = 0
var _listening: bool = false


func start(port: int) -> Error:
	_port = port
	_reader = NetTransport.NetMessageReader.new()
	var err: Error = _server.listen(port, "127.0.0.1")
	_listening = (err == OK)
	return err


func stop() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _server.is_listening():
		_server.stop()
	_listening = false


func is_client_connected() -> bool:
	return _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func send(msg: Variant) -> void:
	if not is_client_connected():
		return
	NetTransport.send(_peer, msg)


func _process(_delta: float) -> void:
	if not _listening:
		return
	# 接受新连接
	if _peer == null and _server.is_connection_available():
		_peer = _server.take_connection()
		if _peer != null:
			_reader = NetTransport.NetMessageReader.new()
			client_connected.emit()
	if _peer == null:
		return
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		var avail := _peer.get_available_bytes()
		if avail > 0:
			var got = _peer.get_data(avail)
			if got[0] == OK:
				_reader.append(got[1])
			while true:
				var msg = _reader.pop()
				if msg == null:
					break
				message_received.emit(msg)
	else:
		# 断开/错误
		_peer = null
		_reader = null
		client_disconnected.emit()

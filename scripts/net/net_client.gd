## net_client.gd - PvP client 端 TCP 连接
##
## client（enemy 窗，视图进程）连接到 host 的 127.0.0.1:port。
## 收到 host 的 snapshot / popup / close_popup / battle_over -> 调 on_message 回调。
## client 调 send() 上行 intent。
extends Node

const NetTransport = preload("res://scripts/net/net_transport.gd")

signal connected_to_host()
signal disconnected_from_host()
signal message_received(msg: Variant)

var _peer := StreamPeerTCP.new()
var _reader = null  # NetMessageReader
var _port: int = 0
var _was_connected: bool = false


func connect_to(port: int) -> Error:
	_port = port
	_reader = NetTransport.NetMessageReader.new()
	var err: Error = _peer.connect_to_host("127.0.0.1", port)
	return err


func disconnect_from_host() -> void:
	_peer.disconnect_from_host()
	_was_connected = false
	_reader = null


func is_connected_to_host() -> bool:
	return _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func send(msg: Variant) -> void:
	if not is_connected_to_host():
		return
	NetTransport.send(_peer, msg)


func _process(_delta: float) -> void:
	if _reader == null:
		return
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		if not _was_connected:
			_was_connected = true
			connected_to_host.emit()
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
	elif status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		if _was_connected:
			_was_connected = false
			disconnected_from_host.emit()
	# STATUS_CONNECTING -> 继续等

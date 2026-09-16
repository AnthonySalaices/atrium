extends Node3D

## Minimal boot: bring up OpenXR if present, and report what the runtime
## actually supports. Runs flat on the desktop too, which is the point.

func _ready() -> void:
	var iface := XRServer.find_interface("OpenXR")
	if iface and iface.is_initialized():
		get_viewport().use_xr = true
		print("[xr] OpenXR initialised: ", iface.get_name())
	else:
		print("[xr] no OpenXR runtime — running flat")
	print("[xr] godot ", Engine.get_version_info().string)

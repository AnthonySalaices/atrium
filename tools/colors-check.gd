extends SceneTree
## Headless check of CellGrid.set_colors: palette slots, defaults, cursor.
## Run: $GODOT --headless --path godot --script ../tools/colors-check.gd

func _init() -> void:
	var g := CellGrid.new()
	g.set_colors({
		"foreground": "#e0def4", "background": "#232136",
		"cursor_bg": "#59546d", "cursor_fg": "#e0def4", "cursor_border": "#59546d",
		"ansi": ["#393552", "#eb6f92", "#3e8fb0", "#f6c177", "#9ccfd8", "#c4a7e7", "#ea9a97", "#e0def4"],
		"brights": ["#6e6a86", "#eb6f92", "#3e8fb0", "#f6c177", "#9ccfd8", "#c4a7e7", "#ea9a97", "#e0def4"],
		"indexed": {"16": "#ffb86c"},
	}, "BlinkingBar", 500)
	var ok := true
	ok = ok and g.color_of(1, true).to_html(false) == "eb6f92"
	ok = ok and g.color_of(8, true).to_html(false) == "6e6a86"
	ok = ok and g.color_of(16, true).to_html(false) == "ffb86c"
	ok = ok and g.color_of(17, true).to_html(false) == "00005f"      # cube untouched
	ok = ok and g.color_of(-1, false).to_html(false) == "232136"
	ok = ok and g.cursor_style == "BlinkingBar" and g.blink_ms == 500
	g.grid = [[[-1, -1, 0, "ab"], [-1, -1, 0, "cd"]]]
	ok = ok and g._char_at(2, 0) == "c" and g._char_at(9, 0) == ""
	print("colors-check: ", "PASS" if ok else "FAIL")
	g.free()
	quit(0 if ok else 1)

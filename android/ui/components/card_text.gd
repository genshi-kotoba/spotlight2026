class_name CardText
extends RefCounted

## 卡面小字折行。卡牌缩小时字体必须按显示比例放大，否则文字会跟着卡一起缩到看不清；
## 折行按真实字宽手动插入换行，避免 Label 把整段文本算进最小宽度后顶出卡槽。

const BREAK_EXCEPTIONS := "，。！？；：、,.!?;:"


static func wrap_to_width(text: String, font: Font, font_size: int,
		max_width: float) -> String:
	if text.is_empty() or max_width <= 0.0:
		return text
	if font == null:
		font = ThemeDB.fallback_font
	var lines: Array[String] = []
	var line := ""
	for index in text.length():
		var character := text[index]
		if character == "\r":
			continue
		if character == "\n":
			lines.append(line)
			line = ""
			continue
		var candidate := line + character
		var width := font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT,
			-1.0, font_size).x
		if not line.is_empty() and width > max_width:
			# 标点不另起一行，但也不许超宽：把上一行末尾若干字一起带到下一行，
			# 否则这一行会宽出卡面，居中后被裁掉左右各半个字。
			if character in BREAK_EXCEPTIONS:
				# 末字与标点一起放到下一行，不能把标点插到末字前面。
				var carry := line.right(1) + character
				if line.length() > 1 and font.get_string_size(carry, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x <= max_width:
					lines.append(line.left(line.length() - 1))
					line = carry
				else:
					lines.append(line)
					line = character
			else:
				lines.append(line)
				line = character
		else:
			line = candidate
	if not line.is_empty():
		lines.append(line)
	return "\n".join(lines)

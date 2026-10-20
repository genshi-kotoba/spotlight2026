#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 wwise_soundbanks/Wwise_IDs.h 生成 Wwise/resources/wwise_ids.gd（AK 常量类）。

用法（在仓库根目录）：
    python tools/generate_wwise_ids.py

每次 Wwise 重新生成 SoundBank 后运行一次即可。
Wwise_IDs.h 由 Wwise 生成，本脚本只读不写它。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEADER = ROOT / "wwise_soundbanks" / "Wwise_IDs.h"
OUTPUT = ROOT / "Wwise" / "resources" / "wwise_ids.gd"

NS_RE = re.compile(r"^\s*namespace\s+(\w+)\s*\{?\s*$")  # 大括号可能在本行或下一行
NS_END_RE = re.compile(r"^\s*}\s*//\s*namespace\s+(\w+)")
CONST_RE = re.compile(r"^\s*static const AkUniqueID\s+(\w+)\s*=\s*(\d+)U;")


def parse() -> dict:
    """解析为嵌套 dict：{namespace: {... 或 {name: id}}}"""
    tree: dict = {}
    stack: list[dict] = [tree]
    names: list[str] = []
    for line in HEADER.read_text(encoding="utf-8").splitlines():
        m = NS_RE.match(line)
        if m:
            node: dict = {}
            stack[-1][m.group(1)] = node
            stack.append(node)
            names.append(m.group(1))
            continue
        m = NS_END_RE.match(line)
        if m:
            stack.pop()
            names.pop()
            continue
        m = CONST_RE.match(line)
        if m:
            stack[-1][m.group(1)] = int(m.group(2))
    return tree


def emit(node: dict, indent: int, lines: list[str]) -> None:
    pad = "\t" * indent
    for key in sorted(node, key=str.lower):
        value = node[key]
        if isinstance(value, dict):
            lines.append(f"{pad}class {key}:")
            emit(value, indent + 1, lines)
        else:
            lines.append(f"{pad}const {key} := {value}")


def collect_flat(tree: dict) -> dict[str, int]:
    """EVENTS 命名空间的平铺 {原名: id}，用于按名字反查。"""
    events = tree.get("AK", tree).get("EVENTS", {})
    return {k: v for k, v in sorted(events.items()) if isinstance(v, int)}


def main() -> int:
    if not HEADER.exists():
        print(f"[错误] 找不到 {HEADER}——请先在 Wwise 里生成 SoundBank", file=sys.stderr)
        return 1

    tree = parse()
    ak = tree.get("AK", {})
    if not ak:
        print("[错误] 解析失败：没有找到 AK 命名空间", file=sys.stderr)
        return 1

    lines: list[str] = [
        "class_name AK",
        "## 自动生成，请勿手改。来源：wwise_soundbanks/Wwise_IDs.h",
        "## 重新生成：python tools/generate_wwise_ids.py",
        "##",
        "## 用法：AK.EVENTS.SFX_001_UI_HOVER / AK.STATES.COMBAT.STATE.BATTLE /",
        "##        AK.SWITCHES.FOOT_MATERIAL.SWITCH.WOOD / AK.GAME_PARAMETERS.VOLUME_MUSIC",
        "",
    ]
    emit(ak, 0, lines)

    flat = collect_flat(tree)
    lines += [
        "",
        "",
        "## 事件名 → ID 平铺表（调试/测试场景反查用；key 为 Wwise 事件原名大写）",
        f"const EVENT_NAMES := {{",
    ]
    for name, uid in flat.items():
        lines.append(f'\t"{name}": {uid},')
    lines.append("}")
    lines.append("")

    if "--stdout" in sys.argv:
        # 沙箱/CI 环境：内容走 stdout，由调用方负责落盘（如 pwsh 的 Out-File）
        print("\n".join(lines))
        return 0

    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"[完成] {OUTPUT.relative_to(ROOT)} ← {len(flat)} 个事件，"
          f"共 {sum(1 for _ in OUTPUT.open(encoding='utf-8'))} 行")
    return 0


if __name__ == "__main__":
    sys.exit(main())

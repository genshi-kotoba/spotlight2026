"""Read-only XLSX -> game CSV; worksheet row order is the stable fragment ID."""
import argparse
import csv
import hashlib
import json
from pathlib import Path

import openpyxl


PROGRAMS = [
    ("card_gained", "four", "", 0), ("pointer_four", "column", "", 0),
    ("turn_end", "row", "", 0), ("card_discarded", "four", "", 0),
    ("blocked", "eight", "", 0), ("player_damaged", "four", "", 0),
    ("pointer_moved", "four", "", 0), ("dot_damage", "vertical", "", 0),
    ("enemy_died", "all", "", 0), ("attack_five", "eight", "", 0),
    ("", "none", "extra_pointer", 2), ("", "none", "enchant", 5),
    ("", "none", "turn_damage", 1), ("", "none", "rewind", 1),
    ("", "none", "debuff_duration", 1), ("", "none", "block", 1),
    ("", "none", "draw", 1), ("", "none", "next_damage", 2),
    ("turn_end", "none", "carry_slot", 1), ("", "none", "few_enemies", 1),
    ("", "none", "extra_choice", 1), ("card_gained", "none", "random_damage", 2),
    ("player_turn_started", "none", "discard_chance", 1),
    ("", "none", "loss_on_play", 2), ("", "none", "hand_limit", -2),
    ("player_turn_started", "none", "less_discard_more_hand", 1),
    ("", "none", "less_draw", 1), ("", "none", "trigger_loss", 1),
    ("", "none", "trigger_discard", 1), ("", "none", "trigger_heal_enemy", 5),
    ("", "none", "poison", 2), ("", "none", "next_slot", 1),
    ("", "none", "silver", 50),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    # WPS exports may contain incorrect worksheet dimensions; normal loading
    # reads the actual cells without trusting the streaming dimensions.
    workbook = openpyxl.load_workbook(args.source, data_only=True)
    rows = [r for r in workbook["典籍残片"].iter_rows(min_row=2, values_only=True) if r[1] is not None]
    if len(rows) != len(PROGRAMS):
        raise ValueError(f"Expected {len(PROGRAMS)} source fragments, got {len(rows)}; update explicit programs first")
    kinds = {"触发": "trigger", "效果": "effect", "在场": "presence", "负面": "negative"}
    rule_rows, text_rows = [], []
    for index, (row, program) in enumerate(zip(rows, PROGRAMS), 1):
        name, kind, text = (str(v).strip() if v is not None else "暂无" for v in row[:3])
        fragment_id = f"FRG-{index:03d}"
        rule_rows.append([fragment_id, name, text, kinds[kind], *program])
        text_rows.append([fragment_id, "res://assets/relics/fragment-placeholder.png", name, text, kind, "暂无"])
    for path, headers, content in [
        ("data/relics/fragments.csv", ["id", "name", "description", "kind", "event", "reach", "action", "amount"], rule_rows),
        ("data/text/fragments.csv", ["编号", "卡图资源路径", "卡名", "效果文本", "类型", "文本"], text_rows),
    ]:
        with (args.root / path).open("w", encoding="utf-8", newline="") as target:
            writer = csv.writer(target)
            writer.writerow(headers)
            writer.writerows(content)
    print(json.dumps({"sheet": "典籍残片", "count": len(rows), "sha256": hashlib.sha256(args.source.read_bytes()).hexdigest()}, ensure_ascii=False))


if __name__ == "__main__":
    main()

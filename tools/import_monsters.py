"""只读 Excel 的怪物页，机械导出游戏 CSV；不修改源工作簿。"""
import argparse
import csv
from pathlib import Path

import openpyxl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "data/text/monsters.csv")
    args = parser.parse_args()
    # 此工作簿的缓存 dimension 为 A1；普通加载可正确还原实际单元格范围。
    book = openpyxl.load_workbook(args.workbook, data_only=True)
    sheet = book["怪物"]
    rows = list(sheet.values)
    headers = list(rows[0])
    required = ["编号", "怪物", "资产路径", "机制", "文本", "战斗中文本资源路径", "出现层数", "级别"]
    if any(key not in headers for key in required):
        raise ValueError("怪物页缺少所需列")
    output = []
    seen = set()
    for cells in rows[1:]:
        record = dict(zip(headers, cells))
        if record["编号"] is None:
            continue
        number = str(record["编号"])
        if number in seen:
            raise ValueError(f"重复怪物编号: {number}")
        seen.add(number)
        def value(key):
            raw = record[key]
            return "暂无" if raw is None or str(raw).strip() == "" else str(raw)
        output.append([number, value("资产路径"), value("怪物"), value("机制"),
                       f'{value("级别")} · 第{value("出现层数")}层', value("文本"), value("战斗中文本资源路径")])
    book.close()
    with args.output.open("w", encoding="utf-8", newline="") as file:
        writer = csv.writer(file, lineterminator="\n")
        writer.writerow(["编号", "怪物图资源路径", "怪物名", "能力文本", "类型与出现地", "文本", "战斗中文本资源路径"])
        writer.writerows(output)
    print(f"Exported {len(output)} monsters -> {args.output}")


if __name__ == "__main__":
    main()

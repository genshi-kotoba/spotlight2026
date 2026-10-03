// =============================================================================
// 模块：探索系统 - 荒野事件目录 WildernessEventCatalog
// 用途：荒野图事件格的抽取来源（design §3.1）。SO 存 32 个 EventData 的引用，
//       投放时按 biomeTag 分池抽。资产位置：Assets/Resources/WildernessEventCatalog.asset
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

[CreateAssetMenu(fileName = "荒野事件目录", menuName = "CardDice/荒野事件目录")]
public class WildernessEventCatalog : ScriptableObject
{
    public const string ResourcePath = "WildernessEventCatalog";

    [Tooltip("全部荒野事件（32 个 = 通用池 8 + 六群系各 4）。按 biomeTag 自动分池")]
    public List<EventData> events = new List<EventData>();
}

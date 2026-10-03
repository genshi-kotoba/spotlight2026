// =============================================================================
// 打包用巡逻目录：由编辑器扫描 Assets/Data/SquadPatrols 自动写入。
// 运行时 Resources.Load("SquadPatrolCatalog") 读取。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public class SquadPatrolCatalog : ScriptableObject
{
    public List<SquadPatrolData> patrols = new List<SquadPatrolData>();
}

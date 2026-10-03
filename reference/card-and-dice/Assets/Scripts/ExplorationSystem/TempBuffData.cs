// =============================================================================
// 模块：探索系统 - 临时强化 TempBuffData
// 用途：事件获得的「下一场战斗生效、战后即耗」增益
//       设计依据：docs/2026-09-16_荒野事件-design.md §2（十枚总表）/ §3.5（数据规格）
// 资产位置：Assets/Data/TempBuffs/（批 3 由编辑器构建器生成）
//
// ★6 枚群系特色（脱兔/解毒剂/收骨/火油/钉鞋/厚甲）分别拆一个家族的族语言，
//   其词条口径以敌人线词条落稿为准 → 本批只做「定义 + 入槽 + 顶栏显示」，
//   战斗效果接线延后（转交清单第 1 项）。
// =============================================================================
using UnityEngine;

/// <summary>
/// 临时强化种类（design §2 两张表）。每种在 <see cref="TempBuffRuntime"/> 里挂一条既有战斗机制。
/// </summary>
public enum TempBuffKind
{
    // 群系特色 6（逐条拆解该族打法）
    脱兔,    // 密林·狼族：下场战斗不会被挂猎物标记
    解毒剂,  // 洞穴·蛛族：下场战斗免疫中毒
    收骨,    // 废墟·骸骨：被你击杀的骸骨不再复苏进死气池
    火油,    // 古林·树族：下场战斗荆棘不反伤
    钉鞋,    // 沼泽·爬族：下场战斗免疫击退与拽移
    厚甲,    // 荒村·巨怪：下场战斗破甲无效

    // 通用 4
    有数,    // 下场战斗起始手牌 +1
    壮胆,    // 下场战斗你的第一次攻击 +2 伤害
    暖身,    // 下场战斗第 1 回合 +1 能量
    护心镜   // 下场战斗受到的暴击伤害 -2
}

/// <summary>事件获得的临时强化（SO）。一局内可并存不同种，同种不叠加。</summary>
[CreateAssetMenu(fileName = "新临时强化", menuName = "CardDice/临时强化")]
public class TempBuffData : ScriptableObject
{
    [Tooltip("唯一标识（与 buffName 一致即可；日志与存档用）")]
    public string buffId;

    [Tooltip("显示名（顶栏用）")]
    public string buffName;

    [TextArea(2, 4)]
    [Tooltip("一句话说明（顶栏悬停用）")]
    public string description;

    [Tooltip("种类：决定挂哪条战斗机制")]
    public TempBuffKind kind;

    [Tooltip("数值：有数=1 / 壮胆=2 / 暖身=1 / 护心镜=2；免疫类填 0")]
    public int value;

    [Tooltip("顶栏图标（可空：空则用纯文字）")]
    public Sprite icon;
}

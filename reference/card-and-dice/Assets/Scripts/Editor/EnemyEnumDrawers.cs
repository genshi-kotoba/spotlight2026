// =============================================================================
// 模块：M6 敌人系统 - EnemyEnumDrawers 枚举选项「选中即解释」属性抽屉
// 用途：Unity 原生枚举下拉不支持「逐项悬停提示」，因此给移动预设 / 编队角色 / 编队模板
//       三个枚举各做一个自定义属性抽屉：在枚举下拉下方绘制一个提示框（HelpBox），
//       实时显示「当前选中项」的中文含义，帮助团队成员不查文档就能理解每个选项的作用。
// 设计依据：用户 2026-08-19 需求「鼠标放到选项上会具体解释一下是什么意思」
// 说明：
//   - 枚举值已中文化（见 MoveAI.cs / EnemySquadData.cs），本抽屉只补「含义解释」；
//   - 抽屉按枚举类型自动应用到所有引用它的字段（含 EnemyData / EnemySquadData / EnemyUnitConfig）；
//   - 可空覆盖字段（如 movePresetOverride?）由 Unity 默认抽屉处理，不影响本功能。
// =============================================================================
using UnityEditor;
using UnityEngine;

/// <summary>
/// 枚举「选中即解释」属性抽屉基类。
/// 子类只需用 [CustomPropertyDrawer(typeof(某枚举))] 注册 + 提供每个枚举值的中文解释。
/// </summary>
public abstract class EnemyEnumDescriptionDrawer : PropertyDrawer
{
    /// <summary>枚举每个下标对应的中文解释（数组下标 = 枚举值 int，需与枚举声明顺序一致）。</summary>
    protected abstract string[] Descriptions { get; }

    public override void OnGUI(Rect position, SerializedProperty property, GUIContent label)
    {
        EditorGUI.BeginProperty(position, label, property);

        float lineHeight = EditorGUIUtility.singleLineHeight;
        float spacing = EditorGUIUtility.standardVerticalSpacing;

        // 第一行：标准枚举下拉（展开后就是已中文化的选项名）
        Rect popupRect = new Rect(position.x, position.y, position.width, lineHeight);
        EditorGUI.PropertyField(popupRect, property, label);

        // 第二行：当前选中项的中文解释（HelpBox 自动换行）
        string desc = GetDescription(property.enumValueIndex);
        if (!string.IsNullOrEmpty(desc))
        {
            Rect helpRect = new Rect(position.x, position.y + lineHeight + spacing, position.width, lineHeight * 1.8f);
            EditorGUI.HelpBox(helpRect, desc, MessageType.Info);
        }

        EditorGUI.EndProperty();
    }

    public override float GetPropertyHeight(SerializedProperty property, GUIContent label)
    {
        float lineHeight = EditorGUIUtility.singleLineHeight;
        float spacing = EditorGUIUtility.standardVerticalSpacing;
        string desc = GetDescription(property.enumValueIndex);
        float extra = string.IsNullOrEmpty(desc) ? 0f : lineHeight * 1.8f + spacing;
        return lineHeight + extra;
    }

    private string GetDescription(int index)
    {
        string[] d = Descriptions;
        if (d == null || index < 0 || index >= d.Length) return "";
        return d[index];
    }
}

/// <summary>
/// 移动预设（MoveAIPresetType）抽屉：解释每种「行为逻辑类型」每回合怎么走。
/// 数组顺序必须与 MoveAI.cs 中枚举声明顺序一致：本能/包抄/拦截/风筝/远离/守卫/自爆/炮台/游击/召唤者。
/// </summary>
[CustomPropertyDrawer(typeof(MoveAIPresetType))]
public class MoveAIPresetTypeDrawer : EnemyEnumDescriptionDrawer
{
    protected override string[] Descriptions { get; } = new string[]
    {
        "本能：直线 A* 追击玩家，进入射程即停。适合近战怪（如史莱姆）。",
        "包抄：绕到玩家背对友军一侧的相邻格再攻击，形成夹击。适合近战怪（如哥布林）。",
        "拦截：移动到玩家逃跑路线前方的极限射程格堵路，压缩逃生空间。",
        "风筝：保持在极限射程边打边退，放玩家风筝。适合远程怪（如强盗弓箭手）。",
        "远离：与玩家保持安全距离，边拉距离边进行远程/辅助。适合辅助怪（如亡灵法师）。",
        "守卫：站桩守点，不主动追击，防守固定区域（预留扩展）。",
        "自爆：主动贴近玩家后自爆造成伤害（预留扩展）。",
        "炮台：固定在原地不动，持续远程输出（预留扩展）。",
        "游击：打一下换位再打，机动骚扰（预留扩展）。",
        "召唤者：周期性召唤小怪，本身不主动输出（预留扩展）。",
    };
}

/// <summary>
/// 编队角色（CombatRole）抽屉：解释每种角色在小队摆位时站在什么位置。
/// 数组顺序须与 EnemySquadData.cs 枚举声明顺序一致：先锋/近卫/狙击/术士/辅助。
/// </summary>
[CustomPropertyDrawer(typeof(CombatRole))]
public class CombatRoleDrawer : EnemyEnumDescriptionDrawer
{
    protected override string[] Descriptions { get; } = new string[]
    {
        "先锋：最先行动，高速突进抢占位置。",
        "近卫：近战单位，正面推进与玩家短兵相接。",
        "狙击：远程输出，保持距离攻击。",
        "术士：魔法输出，并给敌我上 buff/debuff 的施法单位。",
        "辅助：提供增益/治疗/召唤等支援。",
    };
}

/// <summary>
/// 编队模板（FormationType）抽屉：解释每种一键摆位阵型长什么样。
/// 数组顺序须与 EnemySquadData.cs 枚举声明顺序一致：聚拢/横排/楔形/方阵/散开。
/// </summary>
[CustomPropertyDrawer(typeof(FormationType))]
public class FormationTypeDrawer : EnemyEnumDescriptionDrawer
{
    protected override string[] Descriptions { get; } = new string[]
    {
        "聚拢：所有成员聚集在小队锚点附近，抱团推进。",
        "横排：成员沿一条横线一字排开，正面推进。",
        "楔形：呈箭头/楔形阵型，尖头突前。",
        "方阵：方块状阵型，四面均衡。",
        "散开：成员分散站位，避免聚堆被范围攻击波及。",
    };
}

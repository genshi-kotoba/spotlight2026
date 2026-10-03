using UnityEngine;
using System.Collections.Generic;

/// <summary>
/// 卡牌稀有度枚举
/// </summary>
public enum CardRarity
{
    普通,
    优秀,
    稀有,
    传说
}

/// <summary>
/// 花色选项枚举
/// </summary>
public enum SuitOption
{
    无,
    红色, // 力量
    绿色, // 敏捷
    蓝色, // 智力
    黄色  // 体质
}

/// <summary>
/// 卡牌效果类型枚举
/// </summary>
public enum CardEffectType
{
    伤害,    // 造成伤害
    防御,    // 防御效果
    效果     // 施加效果
}

/// <summary>
/// 目标类型枚举
/// </summary>
public enum CardTargetType
{
    自己,
    目标敌人,
    射程内所有敌人
}

/// <summary>
/// 战斗骰子选择枚举
/// </summary>
public enum DiceSelect
{
    无,
    战斗骰子1,
    战斗骰子2,
    战斗骰子3,
    战斗骰子4
}

/// <summary>
/// 数值配置类
/// </summary>
[System.Serializable]
public class ValueConfig
{
    [Tooltip("基础值")]
    public int baseValue = 0;
    
    [Tooltip("战斗骰子")]
    public DiceSelect diceSelect = DiceSelect.无;
}

/// <summary>
/// 探索效果类
/// </summary>
[System.Serializable]
public class ExploreEffect
{
    [Tooltip("效果类型选择")]
    public string effectTypeName = "";
    
    [Tooltip("效果层数")]
    public int stacks = 0;
}

/// <summary>
/// 卡牌效果类
/// </summary>
[System.Serializable]
public class CardEffect
{
    [Tooltip("效果类型")]
    public CardEffectType effectType = CardEffectType.伤害;
    
    [Tooltip("目标类型")]
    public CardTargetType targetType = CardTargetType.目标敌人;
    
    [Tooltip("伤害配置")]
    public ValueConfig damageConfig = new ValueConfig();
    
    [Tooltip("攻击次数配置")]
    public ValueConfig attackCountConfig = new ValueConfig();
    
    [Tooltip("防御配置")]
    public ValueConfig defenseConfig = new ValueConfig();
    
    [Tooltip("防御次数配置")]
    public ValueConfig defenseCountConfig = new ValueConfig();
    
    [Tooltip("效果类型选择")]
    public string effectTypeName = "";
    
    [Tooltip("效果层数配置")]
    public ValueConfig effectStacksConfig = new ValueConfig();
    
    [Tooltip("效果次数配置")]
    public ValueConfig effectCountConfig = new ValueConfig();
    
    [Tooltip("是否误伤友军（默认 false）。仅对 AOE（射程内所有敌人）生效：敌方施法时，除玩家外，射程内友军敌人也受此效果")]
    public bool friendlyFire = false;
}







/// <summary>
/// 计算值片段：描述中被 [表达式] 替换出的最终数字在文本中的位置信息。
/// 用途：CardView 悬停检测 —— 鼠标落在片段内时弹小窗显示算式构成（如 "5" ← "1+4"）。
/// ★用户需求 2026-08-17：玩家看到最终值，悬停才显示构成；
///   描述中骰子影响的数值显示蓝色；小窗内骰子值按最大=绿/最小=红/其余=蓝着色。
/// </summary>
public class ComputedValueSegment
{
    /// <summary>在最终文本中的起始字符索引（按纯文本计，不含颜色标签）</summary>
    public int startIndex;

    /// <summary>片段字符数（如 "5" 长 1，"18" 长 2）</summary>
    public int length;

    /// <summary>骰子点数代入后的纯文本算式（如 "1+4"）</summary>
    public string expression;

    /// <summary>骰子值带颜色标签的算式（如 "1+&lt;color=#2ECC71&gt;4&lt;/color&gt;"），用于 tooltip</summary>
    public string coloredExpression;

    /// <summary>计算结果（如 5）</summary>
    public int result;
}

/// <summary>
/// 卡牌数据模板
/// </summary>
[CreateAssetMenu(fileName = "NewCard", menuName = "卡牌与骰子/卡牌数据", order = 1)]
public class CardData : ScriptableObject
{
    /// <summary>
    /// 卡牌唯一ID
    /// </summary>
    [Header("基础信息")]
    [Tooltip("卡牌的唯一标识符")]
    public string cardID;
    
    /// <summary>
    /// 卡牌名称
    /// </summary>
    [Tooltip("卡牌的显示名称")]
    public string cardName = "新卡牌";
    
    /// <summary>
    /// 能量消耗
    /// </summary>
    [Tooltip("使用卡牌需要消耗的能量")]
    public int energyCost = 1;
    
    /// <summary>
    /// 冷却时间
    /// </summary>
    [Tooltip("卡牌在战术卡槽中使用后的冷却回合数")]
    public int cooldown = 0;
    
    /// <summary>
    /// 射程配置
    /// </summary>
    [Tooltip("卡牌的射程配置")]
    public ValueConfig rangeConfig = new ValueConfig();

    /// <summary>
    /// 绑定的战斗骰子槽位（最多 4 槽，空 = 未绑定）
    /// 设计依据：总策划案 5.3.1/5.3.2 —— 卡牌需绑定 0-4 个骰子，
    /// 装填只记录类型不消耗实体；Demo 简化为 Inspector 直接配置（等价"设为默认"装填结果）
    /// </summary>
    [Header("骰子绑定")]
    [Tooltip("骰子槽 1（可空 = 未绑定）")]
    public DiceData diceSlot1;
    [Tooltip("骰子槽 2（可空 = 未绑定）")]
    public DiceData diceSlot2;
    [Tooltip("骰子槽 3（可空 = 未绑定）")]
    public DiceData diceSlot3;
    [Tooltip("骰子槽 4（可空 = 未绑定）")]
    public DiceData diceSlot4;
    
    /// <summary>
    /// 卡牌描述
    /// </summary>
    [Tooltip("卡牌的描述文本")]
    [TextArea]
    public string description = "卡牌描述";
    
    /// <summary>
    /// 卡牌稀有度
    /// </summary>
    [Tooltip("卡牌的稀有度：普通、优秀、稀有、传说")]
    public CardRarity rarity = CardRarity.普通;
    
    /// <summary>
    /// 战斗效果列表
    /// </summary>
    [Header("战斗效果")]
    [Tooltip("卡牌的战斗效果列表")]
    public List<CardEffect> effects = new List<CardEffect>();
    
    /// <summary>
    /// 探索效果列表
    /// </summary>
    [Header("探索属性")]
    [Tooltip("卡牌的探索效果列表")]
    public List<ExploreEffect> exploreEffects = new List<ExploreEffect>();

    /// <summary>
    /// 卡牌是否需要手动指向目标（2026-08-18 出牌交互重构）。
    /// 判定规则：任一战斗效果的 targetType == 目标敌人 → true（直刺/纵劈/断筋）；
    /// 自己/射程内所有敌人的卡（防御/嗅盐/横斩）→ false，直接打出。
    /// 对应 P16 TargetMode 的 UI 交互层简化版（效果执行层的 TargetMode 留 M5b-3）。
    /// </summary>
    public bool RequiresManualTarget
    {
        get
        {
            if (effects == null) return false;
            foreach (var e in effects)
            {
                if (e != null && e.targetType == CardTargetType.目标敌人) return true;
            }
            return false;
        }
    }

    /// <summary>
    /// 卡牌射程（Demo 简化：只用基础值，骰子绑定的动态射程留 M5b-3）。
    /// 射程高亮与箭头目标有效性判定用。0 = 无射程概念（自身卡）。
    /// </summary>
    public int Range => rangeConfig != null ? rangeConfig.baseValue : 0;
    
    /// <summary>
    /// 卡牌花色选项
    /// </summary>
    [Header("花色信息")]
    [Tooltip("第一个花色位置的选项")]
    public SuitOption suit1 = SuitOption.无;
    
    [Tooltip("第二个花色位置的选项")]
    public SuitOption suit2 = SuitOption.无;
    
    [Tooltip("第三个花色位置的选项")]
    public SuitOption suit3 = SuitOption.无;
    
    [Tooltip("第四个花色位置的选项")]
    public SuitOption suit4 = SuitOption.无;
    
    /// <summary>
    /// 卡牌展示图片
    /// </summary>
    [Header("视觉效果")]
    [Tooltip("卡牌的显示图片")]
    public Sprite cardImage;
    
    /// <summary>
    /// 升级状态
    /// </summary>
    [Header("升级信息")]
    [Tooltip("卡牌是否已升级")]
    public bool isUpgraded = false;
    
    /// <summary>
    /// 升级效果
    /// </summary>
    [Tooltip("卡牌升级后的效果描述")]
    [TextArea]
    public string upgradeEffect = "无";
    
    /// <summary>
    /// 验证卡牌数据的有效性
    /// </summary>
    private void OnValidate()
    {
        // 确保能量消耗不为负数
        if (energyCost < 0)
        {
            energyCost = 0;
        }
        
        // 确保冷却时间不为负数
        if (cooldown < 0)
        {
            cooldown = 0;
        }
        
        // 确保射程配置值不为负数
        if (rangeConfig.baseValue < 0)
        {
            rangeConfig.baseValue = 0;
        }
        
        // 确保效果列表中的数值有效
        foreach (var effect in effects)
        {
            // 确保伤害配置值不为负数
            if (effect.damageConfig.baseValue < 0)
            {
                effect.damageConfig.baseValue = 0;
            }
            
            // 确保攻击次数配置值不为负数
            if (effect.attackCountConfig.baseValue < 0)
            {
                effect.attackCountConfig.baseValue = 0;
            }
            
            // 确保防御配置值不为负数
            if (effect.defenseConfig.baseValue < 0)
            {
                effect.defenseConfig.baseValue = 0;
            }
            
            // 确保防御次数配置值不为负数
            if (effect.defenseCountConfig.baseValue < 0)
            {
                effect.defenseCountConfig.baseValue = 0;
            }
            
            // 确保效果层数配置值不为负数
            if (effect.effectStacksConfig.baseValue < 0)
            {
                effect.effectStacksConfig.baseValue = 0;
            }
            
            // 确保效果次数配置值不为负数
            if (effect.effectCountConfig.baseValue < 0)
            {
                effect.effectCountConfig.baseValue = 0;
            }
        }
        
        // 确保探索效果列表中的数值有效
        foreach (var exploreEffect in exploreEffects)
        {
            // 确保效果层数不为负数
            if (exploreEffect.stacks < 0)
            {
                exploreEffect.stacks = 0;
            }
        }
    }
    
    /// <summary>
    /// 在资源创建时自动生成唯一ID
    /// </summary>
    private void OnEnable()
    {
        if (string.IsNullOrEmpty(cardID))
        {
            GenerateUniqueID();
        }
    }
    
    /// <summary>
    /// 生成唯一ID
    /// 格式：CARD_时间戳后6位
    /// </summary>
    public void GenerateUniqueID()
    {
        // 使用时间戳后6位作为唯一标识
        string timestamp = System.DateTime.Now.ToString("HHmmss");
        cardID = "CARD_" + timestamp;
    }
    
    /// <summary>
    /// 获取所有已绑定的战斗骰子（按槽位 1-4 顺序，跳过空槽）
    /// "战斗骰子N"编号 = 此列表的序号（1 起），空槽不占编号
    /// </summary>
    /// <returns>绑定的骰子列表（可能为空，不为 null）</returns>
    public List<DiceData> GetBoundDice()
    {
        var result = new List<DiceData>(4);
        if (diceSlot1 != null) result.Add(diceSlot1);
        if (diceSlot2 != null) result.Add(diceSlot2);
        if (diceSlot3 != null) result.Add(diceSlot3);
        if (diceSlot4 != null) result.Add(diceSlot4);
        return result;
    }

    /// <summary>
    /// 获取本卡在指定花色上的点数（该花色在 suit1-4 四个槽位中出现的次数）。
    /// 用途：①探索鉴定「弃牌辅助」按对应花色点数 1:1 降难度（探索系统 v2 §7.2）；
    ///       ②人物属性 CharacterStats 汇总持有卡牌的花色总和（探索系统 v2 §5.2/D9）。
    /// </summary>
    /// <param name="suit">目标花色（无 恒返回 0）</param>
    public int GetSuitCount(SuitOption suit)
    {
        if (suit == SuitOption.无) return 0;
        int count = 0;
        if (suit1 == suit) count++;
        if (suit2 == suit) count++;
        if (suit3 == suit) count++;
        if (suit4 == suit) count++;
        return count;
    }

    // ======== 骰子数值颜色（★用户 2026-08-17） ========
    // 描述中受骰子影响的最终值 = 蓝色；tooltip 中骰子值 = 最大绿 / 最小红 / 其余蓝

    /// <summary>蓝色（骰子影响值 / 普通骰子值）</summary>
    public const string DiceValueBlueHex = "#3B82F6";

    /// <summary>绿色（骰子掷出最大值）</summary>
    public const string DiceValueGreenHex = "#2ECC71";

    /// <summary>红色（骰子掷出最小值）</summary>
    public const string DiceValueRedHex = "#E74C3C";

    /// <summary>
    /// 获取骰子值对应的富文本颜色。
    /// 规则（★用户 2026-08-17）：值 == 该骰子最大点数 → 绿；== 最小点数 → 红；其余 → 蓝。
    /// </summary>
    /// <param name="value">掷出的点数</param>
    /// <param name="dice">该骰子的数据模板（null 时按蓝色）</param>
    public static string GetDiceValueColorHtml(int value, DiceData dice)
    {
        if (dice != null && dice.diceValues != null && dice.diceValues.Length > 0)
        {
            int min = dice.diceValues[0];
            int max = dice.diceValues[0];
            foreach (int v in dice.diceValues)
            {
                if (v < min) min = v;
                if (v > max) max = v;
            }
            if (value >= max) return DiceValueGreenHex;
            if (value <= min) return DiceValueRedHex;
        }
        return DiceValueBlueHex;
    }

    /// <summary>
    /// 生成动态描述（旧接口，兼容现有调用方）
    /// </summary>
    /// <param name="diceValues">战斗骰子的实际值</param>
    /// <returns>生成的动态描述</returns>
    public string GenerateDynamicDescription(int[] diceValues)
    {
        return GenerateDynamicDescription(diceValues, null);
    }

    /// <summary>
    /// 生成动态描述（新接口：附带计算值片段表）
    /// 将描述中 [表达式] 的占位替换为计算后的最终值（如 "造成[1+战斗骰子1]伤害" → "造成5伤害"），
    /// 并记录每个最终值在文本中的位置，供 CardView 悬停显示算式构成（"5" ← "1+4"）。
    /// 公式依据：F5.2 finalValue = cardValue + Σ(diceValue[i])
    /// </summary>
    /// <param name="diceValues">战斗骰子的实际值（-1 = 未投掷，该占位保持原文）</param>
    /// <param name="segments">输出：计算值片段表（可为 null = 不需要片段）</param>
    /// <returns>生成的动态描述</returns>
    public string GenerateDynamicDescription(int[] diceValues, List<ComputedValueSegment> segments)
    {
        // 收集原文中所有 [表达式] 占位
        System.Text.RegularExpressions.Regex bracketRegex =
            new System.Text.RegularExpressions.Regex(@"\[(.*?)\]");
        System.Text.RegularExpressions.MatchCollection matches = bracketRegex.Matches(description);

        // 绑定骰子列表（与 diceValues 下标对齐，用于骰子值着色判定）
        List<DiceData> boundDice = GetBoundDice();

        // 逐段重建字符串：未匹配部分原样保留，匹配部分替换为计算结果并记录位置
        var builder = new System.Text.StringBuilder(description.Length + 16);
        int copiedUpTo = 0; // 原文中已拷贝到的位置

        foreach (System.Text.RegularExpressions.Match match in matches)
        {
            // 1. 拷贝占位符之前的原文
            builder.Append(description, copiedUpTo, match.Index - copiedUpTo);
            copiedUpTo = match.Index + match.Length;

            // 2. 骰子点数代入：把"战斗骰子N"替换为实际点数（未投掷的跳过，保持占位）
            //    同时生成两份算式：纯文本（expression）+ 骰子值带颜色标签（coloredExpression）
            string expression = match.Groups[1].Value;
            string coloredExpression = expression;
            if (diceValues != null)
            {
                for (int i = 0; i < diceValues.Length; i++)
                {
                    if (diceValues[i] < 0) continue; // 未投掷的骰子不代入
                    string dicePlaceholder = $"战斗骰子{i + 1}";
                    if (expression.Contains(dicePlaceholder))
                    {
                        expression = expression.Replace(dicePlaceholder, diceValues[i].ToString());
                        // 骰子值着色（★用户 2026-08-17）：最大绿 / 最小红 / 其余蓝
                        string colorHex = GetDiceValueColorHtml(
                            diceValues[i], i < boundDice.Count ? boundDice[i] : null);
                        coloredExpression = coloredExpression.Replace(dicePlaceholder,
                            $"<color={colorHex}>{diceValues[i]}</color>");
                    }
                }
            }

            // 3. 计算算式；失败（如仍有未代入的占位）则保留原文占位
            int result;
            try
            {
                result = EvaluateExpression(expression);
            }
            catch
            {
                builder.Append(match.Value); // 保持 [原文] 不变
                continue;
            }

            // 4. 追加计算结果并记录片段位置（供悬停 tooltip 使用）
            string resultText = result.ToString();
            segments?.Add(new ComputedValueSegment
            {
                startIndex = builder.Length,
                length = resultText.Length,
                expression = expression,
                coloredExpression = coloredExpression,
                result = result
            });
            builder.Append(resultText);
        }

        // 5. 拷贝最后一段原文
        builder.Append(description, copiedUpTo, description.Length - copiedUpTo);

        return builder.ToString();
    }
    
    /// <summary>
    /// 计算简单的数学表达式
    /// 只支持加减乘除
    /// </summary>
    /// <param name="expression">表达式字符串</param>
    /// <returns>计算结果</returns>
    private int EvaluateExpression(string expression)
    {
        // 移除空格
        expression = expression.Replace(" ", "");
        
        // 简单的表达式计算，只支持加减乘除
        // 这里使用一个简单的实现，实际项目中可以使用更复杂的表达式解析器
        
        // 处理乘除
        System.Text.RegularExpressions.Regex multiplyDivideRegex = new System.Text.RegularExpressions.Regex(@"(\d+)([*/])(\d+)");
        while (multiplyDivideRegex.IsMatch(expression))
        {
            System.Text.RegularExpressions.Match match = multiplyDivideRegex.Match(expression);
            int left = int.Parse(match.Groups[1].Value);
            string op = match.Groups[2].Value;
            int right = int.Parse(match.Groups[3].Value);
            int result = 0;
            
            if (op == "*")
                result = left * right;
            else if (op == "/")
                result = left / right;
            
            expression = expression.Replace(match.Value, result.ToString());
        }
        
        // 处理加减
        System.Text.RegularExpressions.Regex addSubtractRegex = new System.Text.RegularExpressions.Regex(@"(\d+)([+-])(\d+)");
        while (addSubtractRegex.IsMatch(expression))
        {
            System.Text.RegularExpressions.Match match = addSubtractRegex.Match(expression);
            int left = int.Parse(match.Groups[1].Value);
            string op = match.Groups[2].Value;
            int right = int.Parse(match.Groups[3].Value);
            int result = 0;
            
            if (op == "+")
                result = left + right;
            else if (op == "-")
                result = left - right;
            
            expression = expression.Replace(match.Value, result.ToString());
        }
        
        return int.Parse(expression);
    }
}

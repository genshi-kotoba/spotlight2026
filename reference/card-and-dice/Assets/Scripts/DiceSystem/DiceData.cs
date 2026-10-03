using UnityEngine;
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// 骰子品质枚举
/// </summary>
public enum DiceQuality
{
    普通,
    优秀,
    稀有,
    传说
}

/// <summary>
/// 骰子效果绑定类
/// </summary>
[System.Serializable]
public class DiceValueEffectBinding
{
    [Tooltip("触发效果的点数")]
    public int value;
    
    [Tooltip("效果类型")]
    [EffectTypeDropdown]
    public string effectTypeName;
    
    [Tooltip("目标类型")]
    public TargetType targetType;
    
    [Tooltip("施加层数")]
    public int stacks = 1;
    
    [Tooltip("施加时机")]
    public EffectApplyTiming timing = EffectApplyTiming.立即;
    
    /// <summary>
    /// 获取效果实例
    /// </summary>
    /// <returns>效果实例</returns>
    public Effect GetEffectInstance()
    {
        return EffectUtils.CreateEffectInstance(effectTypeName);
    }
}



/// <summary>
/// 战斗骰子数据模板
/// </summary>
[CreateAssetMenu(fileName = "NewBattleDice", menuName = "卡牌与骰子/战斗骰子数据", order = 2)]
public class DiceData : ScriptableObject
{
    /// <summary>
    /// 骰子唯一ID
    /// </summary>
    [Header("基础信息")]
    [Tooltip("骰子的唯一标识符")]
    public string diceID;
    
    /// <summary>
    /// 骰子名称
    /// </summary>
    [Tooltip("骰子的显示名称")]
    public string diceName = "新战斗骰子";
    
    /// <summary>
    /// 骰子描述
    /// </summary>
    [Tooltip("骰子的描述文本")]
    [TextArea]
    public string description = "战斗骰子描述";
    
    /// <summary>
    /// 骰子品质
    /// </summary>
    [Header("属性")]
    [Tooltip("骰子的品质")]
    public DiceQuality quality;
    
    /// <summary>
    /// 骰子点数列表
    /// </summary>
    [Tooltip("骰子的所有可能点数，支持任意顺序和值")]
    public int[] diceValues = new int[] { 1, 2, 3, 4, 5, 6 };
    
    /// <summary>
    /// 点数效果绑定列表
    /// </summary>
    [Header("效果系统")]
    [Tooltip("骰子点数与效果的绑定")]
    public List<DiceValueEffectBinding> valueEffectBindings = new List<DiceValueEffectBinding>();
    
    /// <summary>
    /// 骰子图片
    /// </summary>
    [Header("视觉效果")]
    [Tooltip("骰子的显示图片")]
    public Sprite diceImage;
    
    /// <summary>
    /// 验证骰子数据的有效性
    /// </summary>
    private void OnValidate()
    {
        // 确保骰子点数列表不为空
        if (diceValues == null || diceValues.Length == 0)
        {
            diceValues = new int[] { 1 };
        }
        
        // 确保效果层数不为负数
        foreach (var binding in valueEffectBindings)
        {
            if (binding.stacks < 1)
            {
                binding.stacks = 1;
            }
        }
    }
    
    /// <summary>
    /// 在资源创建时自动生成唯一ID
    /// </summary>
    private void OnEnable()
    {
        if (string.IsNullOrEmpty(diceID))
        {
            GenerateUniqueID();
        }
    }
    
    /// <summary>
    /// 生成唯一ID
    /// 格式：DICE_时间戳后6位
    /// </summary>
    public void GenerateUniqueID()
    {
        // 使用时间戳后6位作为唯一标识
        string timestamp = System.DateTime.Now.ToString("HHmmss");
        diceID = "DICE_" + timestamp;
    }
    
    /// <summary>
    /// ★2026-09-16 骰面最小值（骰面「下限」修正的钳位基准，d4 → 1）。空数组按 1。
    /// </summary>
    public int MinFace
    {
        get
        {
            if (diceValues == null || diceValues.Length == 0) return 1;
            int min = diceValues[0];
            for (int i = 1; i < diceValues.Length; i++)
                if (diceValues[i] < min) min = diceValues[i];
            return min;
        }
    }

    /// <summary>
    /// ★2026-09-16 骰面最大值（骰面「上限」修正基准 + **暴击阈值**，d4 → 4）。
    /// 暴击判据始终用这个原面值顶，不随上限修正抬高（设计页 R1 铁律⑤）。空数组按 1。
    /// </summary>
    public int MaxFace
    {
        get
        {
            if (diceValues == null || diceValues.Length == 0) return 1;
            int max = diceValues[0];
            for (int i = 1; i < diceValues.Length; i++)
                if (diceValues[i] > max) max = diceValues[i];
            return max;
        }
    }

    /// <summary>
    /// 掷骰子
    /// </summary>
    /// <returns>掷出的点数</returns>
    public int Roll()
    {
        if (diceValues == null || diceValues.Length == 0)
        {
            return 1;
        }
        return diceValues[Random.Range(0, diceValues.Length)];
    }

    /// <summary>
    /// 获取指定点数的效果绑定列表
    /// </summary>
    /// <param name="value">骰子点数</param>
    /// <returns>效果绑定列表</returns>
    public List<DiceValueEffectBinding> GetEffectBindingsForValue(int value)
    {
        List<DiceValueEffectBinding> bindings = new List<DiceValueEffectBinding>();
        foreach (var binding in valueEffectBindings)
        {
            if (binding.value == value)
            {
                bindings.Add(binding);
            }
        }
        return bindings;
    }
}
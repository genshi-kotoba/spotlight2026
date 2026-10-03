using UnityEngine;

/// <summary>
/// 效果工具类
/// 提供效果相关的辅助方法
/// </summary>
public static class EffectUtils
{
    /// <summary>
    /// 根据效果类型名称创建效果实例
    /// </summary>
    /// <param name="effectTypeName">效果类型名称</param>
    /// <returns>效果实例</returns>
    public static Effect CreateEffectInstance(string effectTypeName)
    {
        if (string.IsNullOrEmpty(effectTypeName))
            return null;
        
        // 尝试获取效果类型
        System.Type effectType = System.Type.GetType(effectTypeName);
        if (effectType == null)
        {
            // 尝试在当前命名空间中查找
            effectType = System.Type.GetType($"{effectTypeName}");
        }
        
        if (effectType == null || !typeof(Effect).IsAssignableFrom(effectType))
            return null;
        
        // 创建效果实例
        return (Effect)System.Activator.CreateInstance(effectType);
    }
}

using UnityEngine;

#if UNITY_EDITOR
using UnityEditor;
using System;
using System.Linq;

/// <summary>
/// 效果类型下拉菜单属性抽屉
/// </summary>
[CustomPropertyDrawer(typeof(EffectTypeDropdown))]
public class EffectTypeDropdownDrawer : PropertyDrawer
{
    public override void OnGUI(Rect position, SerializedProperty property, GUIContent label)
    {
        // 获取所有继承自Effect的类型
        Type[] effectTypes = AppDomain.CurrentDomain.GetAssemblies()
            .SelectMany(assembly => assembly.GetTypes())
            .Where(type => typeof(Effect).IsAssignableFrom(type) && !type.IsAbstract)
            .ToArray();
        
        // 提取类型名称
        string[] effectTypeNames = effectTypes.Select(type => type.Name).ToArray();
        
        // 添加一个空选项
        string[] displayOptions = new string[effectTypeNames.Length + 1];
        displayOptions[0] = "None";
        Array.Copy(effectTypeNames, 0, displayOptions, 1, effectTypeNames.Length);
        
        // 找到当前值的索引
        int currentIndex = 0;
        string currentValue = property.stringValue;
        if (!string.IsNullOrEmpty(currentValue))
        {
            currentIndex = Array.IndexOf(effectTypeNames, currentValue) + 1;
        }
        
        // 绘制下拉菜单
        currentIndex = EditorGUI.Popup(position, label.text, currentIndex, displayOptions);
        
        // 更新属性值
        if (currentIndex == 0)
        {
            property.stringValue = "";
        }
        else
        {
            property.stringValue = effectTypeNames[currentIndex - 1];
        }
    }
}

#endif

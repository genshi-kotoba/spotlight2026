using UnityEngine;
using UnityEditor;

/// <summary>
/// 探索效果属性抽屉
/// 控制效果类型的下拉菜单选择
/// </summary>
[CustomPropertyDrawer(typeof(ExploreEffect))]
public class ExploreEffectDrawer : PropertyDrawer
{
    // 获取所有可用的效果类型
    private string[] GetAvailableEffectTypes()
    {
        System.Type effectBaseType = typeof(Effect);
        System.Type[] allTypes = System.Reflection.Assembly.GetAssembly(effectBaseType).GetTypes();
        
        System.Collections.Generic.List<string> effectTypes = new System.Collections.Generic.List<string>();
        effectTypes.Add(""); // 空选项
        
        foreach (System.Type type in allTypes)
        {
            if (type.IsSubclassOf(effectBaseType) && !type.IsAbstract)
            {
                effectTypes.Add(type.Name);
            }
        }
        
        return effectTypes.ToArray();
    }
    
    public override void OnGUI(Rect position, SerializedProperty property, GUIContent label)
    {
        EditorGUI.BeginProperty(position, label, property);
        
        // 计算属性高度
        float lineHeight = EditorGUIUtility.singleLineHeight;
        float spacing = EditorGUIUtility.standardVerticalSpacing;
        float currentY = position.y;
        
        // 效果类型选择
        SerializedProperty effectTypeNameProp = property.FindPropertyRelative("effectTypeName");
        Rect effectTypeSelectRect = new Rect(position.x, currentY, position.width, lineHeight);
        string[] effectTypes = GetAvailableEffectTypes();
        int selectedIndex = 0;
        if (!string.IsNullOrEmpty(effectTypeNameProp.stringValue))
        {
            selectedIndex = System.Array.IndexOf(effectTypes, effectTypeNameProp.stringValue);
            if (selectedIndex < 0) selectedIndex = 0;
        }
        selectedIndex = EditorGUI.Popup(effectTypeSelectRect, "效果类型", selectedIndex, effectTypes);
        if (selectedIndex >= 0 && selectedIndex < effectTypes.Length)
        {
            effectTypeNameProp.stringValue = effectTypes[selectedIndex];
        }
        currentY += lineHeight + spacing;
        
        // 效果层数
        SerializedProperty stacksProp = property.FindPropertyRelative("stacks");
        Rect stacksRect = new Rect(position.x, currentY, position.width, lineHeight);
        EditorGUI.PropertyField(stacksRect, stacksProp);
        
        EditorGUI.EndProperty();
    }
    
    public override float GetPropertyHeight(SerializedProperty property, GUIContent label)
    {
        float lineHeight = EditorGUIUtility.singleLineHeight;
        float spacing = EditorGUIUtility.standardVerticalSpacing;
        
        // 效果类型选择 + 效果层数
        return (lineHeight + spacing) * 2 - spacing;
    }
}

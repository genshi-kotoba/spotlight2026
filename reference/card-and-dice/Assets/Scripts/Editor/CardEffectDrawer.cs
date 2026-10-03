using UnityEngine;
using UnityEditor;

/// <summary>
/// 卡牌效果属性抽屉
/// 控制效果类型对应的字段显示
/// </summary>
[CustomPropertyDrawer(typeof(CardEffect))]
public class CardEffectDrawer : PropertyDrawer
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
        
        // 效果类型属性
        SerializedProperty effectTypeProp = property.FindPropertyRelative("effectType");
        
        // 绘制效果类型
        Rect effectTypeRect = new Rect(position.x, currentY, position.width, lineHeight);
        EditorGUI.PropertyField(effectTypeRect, effectTypeProp);
        currentY += lineHeight + spacing;
        
        // 获取当前效果类型
        CardEffectType effectType = (CardEffectType)effectTypeProp.enumValueIndex;
        
        // 当效果类型为伤害时，显示目标类型、伤害配置和攻击次数配置
        if (effectType == CardEffectType.伤害)
        {
            // 目标类型
            SerializedProperty targetTypeProp = property.FindPropertyRelative("targetType");
            Rect targetTypeRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(targetTypeRect, targetTypeProp);
            currentY += lineHeight + spacing;
            
            // 伤害配置
            SerializedProperty damageConfigProp = property.FindPropertyRelative("damageConfig");
            Rect damageConfigRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(damageConfigRect, damageConfigProp, true);
            currentY += EditorGUI.GetPropertyHeight(damageConfigProp, true) + spacing;
            
            // 攻击次数配置
            SerializedProperty attackCountConfigProp = property.FindPropertyRelative("attackCountConfig");
            Rect attackCountConfigRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(attackCountConfigRect, attackCountConfigProp, true);
        }
        // 当效果类型为防御时，显示防御数值配置和次数配置
        else if (effectType == CardEffectType.防御)
        {
            // 防御数值配置
            SerializedProperty defenseConfigProp = property.FindPropertyRelative("defenseConfig");
            Rect defenseConfigRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(defenseConfigRect, defenseConfigProp, true);
            currentY += EditorGUI.GetPropertyHeight(defenseConfigProp, true) + spacing;
            
            // 防御次数配置
            SerializedProperty defenseCountConfigProp = property.FindPropertyRelative("defenseCountConfig");
            Rect defenseCountConfigRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(defenseCountConfigRect, defenseCountConfigProp, true);
        }
        // 当效果类型为效果时，显示目标类型、效果类型选择、效果层数配置和效果次数配置
        else if (effectType == CardEffectType.效果)
        {
            // 目标类型
            SerializedProperty targetTypeProp = property.FindPropertyRelative("targetType");
            Rect targetTypeRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(targetTypeRect, targetTypeProp);
            currentY += lineHeight + spacing;
            
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
            
            // 效果层数配置
            SerializedProperty effectStacksConfigProp = property.FindPropertyRelative("effectStacksConfig");
            Rect effectStacksConfigRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(effectStacksConfigRect, effectStacksConfigProp, true);
            currentY += EditorGUI.GetPropertyHeight(effectStacksConfigProp, true) + spacing;
            
            // 效果次数配置
            SerializedProperty effectCountConfigProp = property.FindPropertyRelative("effectCountConfig");
            Rect effectCountConfigRect = new Rect(position.x, currentY, position.width, lineHeight);
            EditorGUI.PropertyField(effectCountConfigRect, effectCountConfigProp, true);
        }
        
        EditorGUI.EndProperty();
    }
    
    public override float GetPropertyHeight(SerializedProperty property, GUIContent label)
    {
        float lineHeight = EditorGUIUtility.singleLineHeight;
        float spacing = EditorGUIUtility.standardVerticalSpacing;
        float totalHeight = 0;
        
        // 效果类型属性
        SerializedProperty effectTypeProp = property.FindPropertyRelative("effectType");
        CardEffectType effectType = (CardEffectType)effectTypeProp.enumValueIndex;
        
        // 效果类型的高度
        totalHeight += lineHeight;
        
        // 根据效果类型返回不同的高度
        if (effectType == CardEffectType.伤害)
        {
            // 目标类型的高度
            totalHeight += spacing + lineHeight;
            
            // 伤害配置的高度
            SerializedProperty damageConfigProp = property.FindPropertyRelative("damageConfig");
            totalHeight += spacing + EditorGUI.GetPropertyHeight(damageConfigProp, true);
            
            // 攻击次数配置的高度
            SerializedProperty attackCountConfigProp = property.FindPropertyRelative("attackCountConfig");
            totalHeight += spacing + EditorGUI.GetPropertyHeight(attackCountConfigProp, true);
        }
        // 当效果类型为防御时
        else if (effectType == CardEffectType.防御)
        {
            // 防御配置的高度
            SerializedProperty defenseConfigProp = property.FindPropertyRelative("defenseConfig");
            totalHeight += spacing + EditorGUI.GetPropertyHeight(defenseConfigProp, true);
            
            // 防御次数配置的高度
            SerializedProperty defenseCountConfigProp = property.FindPropertyRelative("defenseCountConfig");
            totalHeight += spacing + EditorGUI.GetPropertyHeight(defenseCountConfigProp, true);
        }
        // 当效果类型为效果时
        else if (effectType == CardEffectType.效果)
        {
            // 目标类型的高度
            totalHeight += spacing + lineHeight;
            
            // 效果类型选择的高度
            totalHeight += spacing + lineHeight;
            
            // 效果层数配置的高度
            SerializedProperty effectStacksConfigProp = property.FindPropertyRelative("effectStacksConfig");
            totalHeight += spacing + EditorGUI.GetPropertyHeight(effectStacksConfigProp, true);
            
            // 效果次数配置的高度
            SerializedProperty effectCountConfigProp = property.FindPropertyRelative("effectCountConfig");
            totalHeight += spacing + EditorGUI.GetPropertyHeight(effectCountConfigProp, true);
        }
        
        return totalHeight;
    }
}

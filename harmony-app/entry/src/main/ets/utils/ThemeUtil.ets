import { Configuration } from '@ohos.app.ability.Configuration';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';

/**
 * 主题偏好与生效值：
 * - themeMode：用户偏好（system / light / dark）
 * - theme：实际生效值（light / dark），各页面继续只读这个
 */
export class ThemeUtil {
  static readonly MODE_SYSTEM: string = 'system';
  static readonly MODE_LIGHT: string = 'light';
  static readonly MODE_DARK: string = 'dark';

  static normalizeMode(mode: string): string {
    return (mode === ThemeUtil.MODE_LIGHT || mode === ThemeUtil.MODE_DARK)
      ? mode : ThemeUtil.MODE_SYSTEM;
  }

  static isDarkConfiguration(config: Configuration): boolean {
    return config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  static resolve(mode: string, systemDark: boolean): string {
    if (mode === ThemeUtil.MODE_DARK) { return ThemeUtil.MODE_DARK; }
    if (mode === ThemeUtil.MODE_LIGHT) { return ThemeUtil.MODE_LIGHT; }
    return systemDark ? ThemeUtil.MODE_DARK : ThemeUtil.MODE_LIGHT;
  }

  static apply(mode: string, systemDark: boolean): void {
    const normalized: string = ThemeUtil.normalizeMode(mode);
    AppStorage.setOrCreate('systemDark', systemDark);
    AppStorage.setOrCreate('themeMode', normalized);
    AppStorage.setOrCreate('theme', ThemeUtil.resolve(normalized, systemDark));
  }
}

/**
 * 集中配色：所有页面/组件都从这里取色，避免切换深浅色时部分模块仍是白底。
 * 参数统一传 AppStorage 的 theme（'light' / 'dark'）。
 */
export class ThemeColors {
  static isDark(theme: string): boolean { return theme === ThemeUtil.MODE_DARK; }

  static pageBg(theme: string): string { return ThemeColors.isDark(theme) ? '#111111' : '#F8F8F8'; }
  static chatBg(theme: string): string { return ThemeColors.isDark(theme) ? '#111111' : '#F0F0F0'; }
  static card(theme: string): string { return ThemeColors.isDark(theme) ? '#1F1F1F' : '#FFFFFF'; }
  static cardSoft(theme: string): string { return ThemeColors.isDark(theme) ? '#262626' : '#FAFAFA'; }
  static inputBg(theme: string): string { return ThemeColors.isDark(theme) ? '#2A2A2A' : '#F5F5F5'; }
  static chipBg(theme: string): string { return ThemeColors.isDark(theme) ? '#2A2A2A' : '#F2F2F2'; }
  static chipText(theme: string): string { return ThemeColors.isDark(theme) ? '#CCCCCC' : '#666666'; }
  static primarySoft(theme: string): string { return ThemeColors.isDark(theme) ? '#13324F' : '#E8F4FF'; }
  static selectedCard(theme: string): string { return ThemeColors.isDark(theme) ? '#14314A' : '#E8F4FF'; }

  static text(theme: string): string { return ThemeColors.isDark(theme) ? '#E6E6E6' : '#333333'; }
  static textStrong(theme: string): string { return ThemeColors.isDark(theme) ? '#F5F5F5' : '#333333'; }
  static textSecondary(theme: string): string { return ThemeColors.isDark(theme) ? '#9A9A9A' : '#999999'; }
  static textTertiary(theme: string): string { return ThemeColors.isDark(theme) ? '#6E6E6E' : '#CCCCCC'; }
  static quoteText(theme: string): string { return ThemeColors.isDark(theme) ? '#AAAAAA' : '#666666'; }
  static placeholder(theme: string): string { return ThemeColors.isDark(theme) ? '#8A8A8A' : '#8C8C8C'; }

  // 状态文字：小字号下保证对比度（浅色不用 #4CAF50/#FF9800/#F44336）
  static successText(theme: string): string { return ThemeColors.isDark(theme) ? '#81C784' : '#2E7D32'; }
  static warningText(theme: string): string { return ThemeColors.isDark(theme) ? '#FFB74D' : '#B45309'; }
  static dangerText(theme: string): string { return ThemeColors.isDark(theme) ? '#FF8A80' : '#C62828'; }
  static successDot(theme: string): string { return ThemeColors.isDark(theme) ? '#66BB6A' : '#43A047'; }
  static warningDot(theme: string): string { return ThemeColors.isDark(theme) ? '#FFA726' : '#FB8C00'; }
  static dangerDot(theme: string): string { return ThemeColors.isDark(theme) ? '#EF5350' : '#E53935'; }
  static onPrimary(_theme: string): string { return '#FFFFFF'; }

  static border(theme: string): string { return ThemeColors.isDark(theme) ? '#333333' : '#E5E5E5'; }
  static divider(theme: string): string { return ThemeColors.isDark(theme) ? '#2A2A2A' : '#F0F0F0'; }
  static shadow(theme: string): string {
    return ThemeColors.isDark(theme) ? 'rgba(0,0,0,0.45)' : 'rgba(0,0,0,0.06)';
  }
  static popupShadow(theme: string): string {
    return ThemeColors.isDark(theme) ? 'rgba(0,0,0,0.55)' : 'rgba(0,0,0,0.12)';
  }
  static dialogMask(_theme: string): string { return 'rgba(0,0,0,0.6)'; }

  static userBubble(_theme: string): string { return '#1677FF'; }
  static userText(_theme: string): string { return '#FFFFFF'; }
  static assistantBubble(theme: string): string { return ThemeColors.isDark(theme) ? '#1F1F1F' : '#FFFFFF'; }
  static assistantText(theme: string): string { return ThemeColors.isDark(theme) ? '#E6E6E6' : '#333333'; }
  static systemBubble(theme: string): string { return ThemeColors.isDark(theme) ? '#2A2A2A' : '#F5F5F5'; }
  static systemText(theme: string): string { return ThemeColors.isDark(theme) ? '#B0B0B0' : '#666666'; }

  static codeBg(theme: string): string { return ThemeColors.isDark(theme) ? '#2A2A2A' : '#F5F5F5'; }
  static inlineCodeBg(theme: string): string { return ThemeColors.isDark(theme) ? '#333333' : '#F0F0F0'; }
  static neutralBg(theme: string): string { return ThemeColors.isDark(theme) ? '#262626' : '#FAFAFA'; }
  static toolBg(theme: string): string { return ThemeColors.isDark(theme) ? '#1B2430' : '#F8FBFF'; }
  static toolErrorBg(theme: string): string { return ThemeColors.isDark(theme) ? '#2E1B1B' : '#FFF5F5'; }
  static thinkingBg(theme: string): string {
    return ThemeColors.isDark(theme) ? 'rgba(156,39,176,0.14)' : 'rgba(156,39,176,0.05)';
  }
  static thinkingBorder(theme: string): string {
    return ThemeColors.isDark(theme) ? 'rgba(206,147,216,0.45)' : 'rgba(156,39,176,0.15)';
  }
  static thinkingText(theme: string): string {
    return ThemeColors.isDark(theme) ? '#CE93D8' : '#9C27B0';
  }
  static warningBg(theme: string): string { return ThemeColors.isDark(theme) ? '#3A2E1A' : '#FFF7E6'; }
  static errorBg(theme: string): string { return ThemeColors.isDark(theme) ? '#3A1F1F' : '#FFF1F0'; }
  static dangerBg(theme: string): string { return ThemeColors.isDark(theme) ? '#3A1F1F' : '#FFF5F5'; }

  static primary: string = '#1677FF';
  static success: string = '#4CAF50';
  static warning: string = '#FF9800';
  static danger: string = '#F44336';
  static tabBarBg(theme: string): string { return ThemeColors.isDark(theme) ? '#1A1A1A' : '#FFFFFF'; }
}

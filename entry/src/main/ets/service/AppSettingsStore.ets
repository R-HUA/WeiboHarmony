import { common } from '@kit.AbilityKit';
import { CacheManager } from '../cache/CacheManager';
import { refreshAppAccentMaterials } from '../common/Theme';

export const DEFAULT_APP_ACCENT: string = '#E6162D';
export const DEFAULT_APP_LANGUAGE: string = 'zh-cn';
export const DEFAULT_HOME_TAB_MATERIAL_LEVEL: number = 10;
/** 当前版本尚未实现消息、我的收藏与我的点赞，默认隐藏这些入口。 */
export const DEFAULT_HIDE_UNSUPPORTED: boolean = true;
export const APP_LANGUAGE_ZH_CN: string = 'zh-cn';
export const APP_LANGUAGE_EN: string = 'en';

const ACCENT_KEY: string = 'weibo_app_accent';
const LANGUAGE_KEY: string = 'weibo_app_language';
const HOME_TAB_MATERIAL_LEVEL_KEY: string = 'weibo_home_tab_material_level';
const HIDE_UNSUPPORTED_KEY: string = 'weibo_hide_unsupported_features';
/** 全局开关的 AppStorage 键，UI 与路由共用同一份真相。 */
export const HIDE_UNSUPPORTED_KEY_STORAGE: string = 'hideUnsupportedFeatures';

/**
 * The small set of app-wide preferences that are not tied to a Weibo account.
 * AppStorage makes changes visible immediately, while CacheManager restores
 * them on the next launch without sharing Tieba account data.
 */
export class AppSettingsStore {
  private static instance: AppSettingsStore | null = null;

  static getInstance(): AppSettingsStore {
    if (AppSettingsStore.instance === null) {
      AppSettingsStore.instance = new AppSettingsStore();
    }
    return AppSettingsStore.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    const cache: CacheManager = CacheManager.getInstance();
    await cache.init(context);
    const savedAccent: string | undefined = await cache.get(ACCENT_KEY);
    const savedLanguage: string | undefined = await cache.get(LANGUAGE_KEY);
    const savedHomeTabMaterialLevel: string | undefined = await cache.get(HOME_TAB_MATERIAL_LEVEL_KEY);
    const savedHideUnsupported: string | undefined = await cache.get(HIDE_UNSUPPORTED_KEY);
    AppStorage.setOrCreate<string>('appAccentColor', this.isAccent(savedAccent) ? savedAccent : DEFAULT_APP_ACCENT);
    AppStorage.setOrCreate<number>('appAccentTick', AppStorage.get<number>('appAccentTick') ?? 0);
    AppStorage.setOrCreate<string>('appLanguage', this.isLanguage(savedLanguage) ? savedLanguage : DEFAULT_APP_LANGUAGE);
    AppStorage.setOrCreate<number>('homeTabMaterialLevel',
      this.parseHomeTabMaterialLevel(savedHomeTabMaterialLevel));
    AppStorage.setOrCreate<boolean>(HIDE_UNSUPPORTED_KEY_STORAGE,
      this.parseHideUnsupported(savedHideUnsupported));
  }

  async setAccent(color: string): Promise<void> {
    if (!this.isAccent(color)) {
      return;
    }
    AppStorage.setOrCreate<string>('appAccentColor', color);
    refreshAppAccentMaterials();
    AppStorage.setOrCreate<number>('appAccentTick', (AppStorage.get<number>('appAccentTick') ?? 0) + 1);
    await CacheManager.getInstance().put(ACCENT_KEY, color);
  }

  async setLanguage(context: common.UIAbilityContext, language: string): Promise<boolean> {
    if (!this.isLanguage(language)) {
      return false;
    }
    try {
      context.getApplicationContext().setLanguage(language);
      AppStorage.setOrCreate<string>('appLanguage', language);
      await CacheManager.getInstance().put(LANGUAGE_KEY, language);
      return true;
    } catch (error) {
      return false;
    }
  }

  async setHomeTabMaterialLevel(level: number): Promise<void> {
    if (!this.isHomeTabMaterialLevel(level)) {
      return;
    }
    AppStorage.setOrCreate<number>('homeTabMaterialLevel', level);
    await CacheManager.getInstance().put(HOME_TAB_MATERIAL_LEVEL_KEY, level.toString());
  }

  /** 隐藏/显示当前版本尚未实现的入口；写入 AppStorage 让所有页面立即生效。 */
  async setHideUnsupported(hidden: boolean): Promise<void> {
    AppStorage.setOrCreate<boolean>(HIDE_UNSUPPORTED_KEY_STORAGE, hidden);
    await CacheManager.getInstance().put(HIDE_UNSUPPORTED_KEY, hidden ? '1' : '0');
  }

  /** 读取当前开关值，供非 UI 层（如路由判断）使用。 */
  areUnsupportedFeaturesHidden(): boolean {
    return AppStorage.get<boolean>(HIDE_UNSUPPORTED_KEY_STORAGE) ?? DEFAULT_HIDE_UNSUPPORTED;
  }

  async restoreLanguage(context: common.UIAbilityContext): Promise<void> {
    await this.init(context);
    const language: string = AppStorage.get<string>('appLanguage') ?? DEFAULT_APP_LANGUAGE;
    try {
      context.getApplicationContext().setLanguage(language);
    } catch (error) {
    }
  }

  private isAccent(value: string | undefined): boolean {
    if (value === undefined) {
      return false;
    }
    return value === '#E6162D' || value === '#007DFF' || value === '#7856FF'
      || value === '#00A870' || value === '#F59E0B';
  }

  private isLanguage(value: string | undefined): boolean {
    return value === APP_LANGUAGE_ZH_CN || value === APP_LANGUAGE_EN;
  }

  private parseHomeTabMaterialLevel(value: string | undefined): number {
    if (value === '0') {
      return 0;
    }
    if (value === '1') {
      return 1;
    }
    if (value === '2') {
      return 2;
    }
    return DEFAULT_HOME_TAB_MATERIAL_LEVEL;
  }

  private isHomeTabMaterialLevel(value: number): boolean {
    return value === 0 || value === 1 || value === 2 || value === DEFAULT_HOME_TAB_MATERIAL_LEVEL;
  }

  /** 未写入过（undefined）时按默认隐藏处理。 */
  private parseHideUnsupported(value: string | undefined): boolean {
    if (value === undefined) {
      return DEFAULT_HIDE_UNSUPPORTED;
    }
    return value === '1';
  }
}

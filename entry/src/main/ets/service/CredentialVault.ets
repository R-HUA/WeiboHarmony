import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const ALIAS: string = 'weiboharmony.session.aesgcm.v1';
const KEY: string = 'session.v1';
interface Envelope { version: number; nonce: string; ciphertext: string; }
export interface StoredSession { mobile: string; desktop: string; uid: string; }

/** HUKS authenticates the version and ciphertext. Preferences never receives plaintext credentials. */
export class CredentialVault {
  private store: preferences.Preferences | null = null;
  private legacy: preferences.Preferences | null = null;
  private encoder: util.TextEncoder = new util.TextEncoder();
  private base64: util.Base64Helper = new util.Base64Helper();

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, 'weiboharmony_credentials');
    this.legacy = await preferences.getPreferences(context, 'tieba_cache');
  }
  async read(): Promise<StoredSession | null> {
    const raw: string = await this.requiredStore().get(KEY, '') as string;
    if (raw.length > 0) {
      const result: StoredSession = await this.decrypt(raw);
      await this.removeLegacy();
      return result;
    }
    const old: string = await this.legacy!.get('weibo_readonly_cookie', '') as string;
    if (old.length === 0) { return null; }
    // Migration is local and can complete offline. A legacy cookie has no verified UID.
    const migrated: StoredSession = { mobile: old, desktop: '', uid: '' };
    await this.write(migrated);
    await this.removeLegacy();
    return migrated;
  }
  async write(session: StoredSession): Promise<void> {
    await this.ensureKey();
    const nonce: Uint8Array = (await cryptoFramework.createRandom().generateRandom(12)).data;
    const cipher: Uint8Array = await this.crypt(this.encoder.encodeInto(JSON.stringify(session)), nonce, true);
    const envelope: Envelope = { version: 1, nonce: this.base64.encodeToStringSync(nonce), ciphertext: this.base64.encodeToStringSync(cipher) };
    const raw: string = JSON.stringify(envelope);
    const store: preferences.Preferences = this.requiredStore();
    await store.put(KEY, raw);
    await store.flush();
    const readback: string = await store.get(KEY, '') as string;
    const verified: StoredSession = await this.decrypt(readback);
    if (JSON.stringify(verified) !== JSON.stringify(session)) { throw new Error('安全存储校验失败'); }
  }
  async clear(): Promise<void> {
    // Keep a verified encrypted empty tombstone until legacy deletion completes.
    // A crash at any intermediate step must not migrate a logged-out cookie back.
    await this.write({ mobile: '', desktop: '', uid: '' });
    await this.removeLegacy();
  }
  private requiredStore(): preferences.Preferences {
    if (this.store === null) { throw new Error('安全存储尚未初始化'); }
    return this.store;
  }
  private async removeLegacy(): Promise<void> {
    if (this.legacy === null) { throw new Error('安全存储尚未初始化'); }
    await this.legacy.delete('weibo_readonly_cookie');
    await this.legacy.flush();
  }
  private properties(purpose: number): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE }
    ];
  }
  private async ensureKey(): Promise<void> {
    let exists: boolean = false;
    try { exists = await huks.isKeyItemExist(ALIAS, { properties: [] }); }
    catch (error) { if ((error as BusinessError).code !== 12000011) { throw new Error((error as Error).message); } }
    if (!exists) {
      await huks.generateKeyItem(ALIAS, { properties: this.properties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT) });
    }
  }
  private async decrypt(raw: string): Promise<StoredSession> {
    const envelope: Envelope = JSON.parse(raw) as Envelope;
    if (envelope.version !== 1) { throw new Error('不支持的凭据版本'); }
    const nonce: Uint8Array = this.base64.decodeSync(envelope.nonce);
    const cipher: Uint8Array = this.base64.decodeSync(envelope.ciphertext);
    if (nonce.length !== 12 || cipher.length <= 16) { throw new Error('凭据记录已损坏'); }
    const plain: Uint8Array = await this.crypt(cipher, nonce, false);
    const session: StoredSession = JSON.parse(new util.TextDecoder().decodeWithStream(plain)) as StoredSession;
    if (typeof session.mobile !== 'string' || typeof session.desktop !== 'string' || typeof session.uid !== 'string') {
      throw new Error('凭据记录已损坏');
    }
    return session;
  }
  private async crypt(input: Uint8Array, nonce: Uint8Array, encrypt: boolean): Promise<Uint8Array> {
    const props: huks.HuksParam[] = this.properties(encrypt ? huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT : huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT);
    props.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
    props.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: this.encoder.encodeInto('weiboharmony.session.v1') });
    if (!encrypt) { props.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: input.slice(input.length - 16) }); }
    const options: huks.HuksOptions = { properties: props, inData: encrypt ? input : input.slice(0, input.length - 16) };
    const handle: number = (await huks.initSession(ALIAS, { properties: props })).handle;
    try {
      const result: huks.HuksReturnResult = await huks.finishSession(handle, options);
      if (result.outData === undefined) { throw new Error('凭据加解密失败'); }
      return result.outData;
    } catch (error) {
      try { await huks.abortSession(handle, { properties: [] }); } catch (abortError) {}
      throw new Error((error as Error).message);
    }
  }
}

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const load = require('./load.cjs');
function setup() {
  const stores = new Map(); const keys = new Map(); const handles = new Map(); let next = 0;
  let failFlush = false, corruptRead = false;
  const tags = ['ALGORITHM','KEY_SIZE','PURPOSE','BLOCK_MODE','PADDING','NONCE','ASSOCIATED_DATA','AE_TAG'];
  const HuksTag = Object.fromEntries(tags.map(t => ['HUKS_TAG_' + t, t]));
  const huks = {
    HuksTag, HuksKeyAlg: { HUKS_ALG_AES: 1 }, HuksKeySize: { HUKS_AES_KEY_SIZE_256: 256 },
    HuksKeyPurpose: { HUKS_KEY_PURPOSE_ENCRYPT: 1, HUKS_KEY_PURPOSE_DECRYPT: 2 },
    HuksCipherMode: { HUKS_MODE_GCM: 1 }, HuksKeyPadding: { HUKS_PADDING_NONE: 0 },
    isKeyItemExist: async alias => keys.has(alias),
    generateKeyItem: async alias => keys.set(alias, crypto.randomBytes(32)),
    initSession: async (alias, options) => { const handle = ++next; handles.set(handle, {alias,options}); return {handle}; },
    finishSession: async (handle, options) => {
      const {alias} = handles.get(handle); const props = Object.fromEntries(options.properties.map(p => [p.tag,p.value]));
      const encrypt = props.PURPOSE === 1;
      const cipher = encrypt ? crypto.createCipheriv('aes-256-gcm',keys.get(alias),props.NONCE) : crypto.createDecipheriv('aes-256-gcm',keys.get(alias),props.NONCE);
      cipher.setAAD(props.ASSOCIATED_DATA); if (!encrypt) cipher.setAuthTag(props.AE_TAG);
      let result = Buffer.concat([cipher.update(options.inData),cipher.final()]);
      if(encrypt) result = Buffer.concat([result,cipher.getAuthTag()]); handles.delete(handle); return {outData:new Uint8Array(result)};
    },
    abortSession: async handle => handles.delete(handle)
  };
  const prefs = name => {
    if (!stores.has(name)) stores.set(name,new Map()); const data=stores.get(name);
    return {
      get: async (k,fallback) => corruptRead && name==='weiboharmony_credentials' ? '{}' : data.get(k) ?? fallback,
      put: async (k,v) => data.set(k,v), delete: async k => data.delete(k),
      flush: async () => { if (failFlush) throw new Error('disk full'); }
    };
  };
  const {CredentialVault} = load('entry/src/main/ets/service/CredentialVault.ets', {
    '@kit.UniversalKeystoreKit':{huks},
    '@kit.CryptoArchitectureKit': {cryptoFramework: {createRandom: () => ({generateRandom: async size => ({data:crypto.randomBytes(size)})})}},
    '@kit.ArkData':{preferences:{getPreferences:async (_,name)=>prefs(name)}},
    '@kit.ArkTS':{util:{
      TextEncoder:class {encodeInto(s){return new TextEncoder().encode(s);}},
      TextDecoder:class {decodeWithStream(b){return new TextDecoder().decode(b);}},
      Base64Helper:class {encodeToStringSync(b){return Buffer.from(b).toString('base64');}decodeSync(s){return new Uint8Array(Buffer.from(s,'base64'));}}
    }}
  });
  return {vault:new CredentialVault(),prefs,stores,handles,setFail:v=>failFlush=v,setCorrupt:v=>corruptRead=v};
}
test('offline legacy migration encrypts then verifies before deleting plaintext',async()=>{
  const f=setup();await f.prefs('tieba_cache').put('weibo_readonly_cookie','SUB=fixture-only');await f.vault.init({});
  assert.equal((await f.vault.read()).mobile,'SUB=fixture-only');
  assert.equal(await f.prefs('tieba_cache').get('weibo_readonly_cookie',''),'');
  const encrypted=await f.prefs('weiboharmony_credentials').get('session.v1','');
  assert.equal(encrypted.includes('fixture-only'),false);assert.equal(JSON.parse(encrypted).version,1);
  assert.equal((await f.vault.read()).uid,''); assert.equal(f.handles.size,0);
});
test('failed migration keeps legacy value and can resume',async()=>{
  const f=setup();await f.prefs('tieba_cache').put('weibo_readonly_cookie','SUB=fixture-only');await f.vault.init({});f.setFail(true);
  await assert.rejects(f.vault.read(),/disk full/);
  assert.equal(await f.prefs('tieba_cache').get('weibo_readonly_cookie',''),'SUB=fixture-only');
  f.setFail(false);assert.equal((await f.vault.read()).mobile,'SUB=fixture-only');
});
test('tampered ciphertext fails closed and releases HUKS session',async()=>{
  const f=setup();await f.vault.init({});await f.vault.write({mobile:'SUB=fake',desktop:'SUB=other',uid:'42'});
  const pref=f.prefs('weiboharmony_credentials');const record=JSON.parse(await pref.get('session.v1',''));
  const bytes=Buffer.from(record.ciphertext,'base64');bytes[0]^=1;record.ciphertext=bytes.toString('base64');await pref.put('session.v1',JSON.stringify(record));
  await assert.rejects(f.vault.read());assert.equal(f.handles.size,0);
});
test('logout tombstone prevents legacy credentials being restored',async()=>{
  const f=setup();await f.vault.init({});await f.vault.write({mobile:'SUB=fake',desktop:'',uid:'42'});await f.vault.clear();
  await f.prefs('tieba_cache').put('weibo_readonly_cookie','SUB=stale');
  assert.deepEqual(await f.vault.read(),{mobile:'',desktop:'',uid:''});
  assert.equal(await f.prefs('tieba_cache').get('weibo_readonly_cookie',''),'');
});

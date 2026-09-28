import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { WeiboPost } from '../model/WeiboModel';
import { RequestQueue } from '../domain/RequestQueue';
export interface CachedFeed { posts: WeiboPost[]; cursor: string | null; anchorId: string; offset: number; }
const MAX_POSTS: number = 500;
const MAX_AGE: number = 7 * 24 * 60 * 60 * 1000;
/** Account IDs are bound parameters. Every multi-table cache update is transactional. */
export class ReaderDatabase {
  private static instance: ReaderDatabase = new ReaderDatabase();
  private db: relationalStore.RdbStore | null = null;
  private initialization: Promise<void> | null = null;
  private writes: RequestQueue = new RequestQueue(0);
  static shared(): ReaderDatabase { return ReaderDatabase.instance; }
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialization === null) { this.initialization = this.open(context); }
    try { await this.initialization; } catch (error) { this.initialization = null; throw new Error((error as Error).message); }
  }
  private async open(context: common.UIAbilityContext): Promise<void> {
    this.db = await relationalStore.getRdbStore(context, { name: 'weiboharmony_reader.db', securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
    const tx: relationalStore.Transaction = await this.db.createTransaction();
    try {
      await tx.execute('CREATE TABLE IF NOT EXISTS posts (account TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, fetched INTEGER NOT NULL, PRIMARY KEY(account,id))');
      await tx.execute('CREATE TABLE IF NOT EXISTS feed_order (account TEXT NOT NULL, feed TEXT NOT NULL, id TEXT NOT NULL, rank INTEGER NOT NULL, PRIMARY KEY(account,feed,id))');
      await tx.execute("CREATE TABLE IF NOT EXISTS feed_meta (account TEXT NOT NULL, feed TEXT NOT NULL, cursor TEXT, anchor TEXT NOT NULL DEFAULT '', offset REAL NOT NULL DEFAULT 0, PRIMARY KEY(account,feed))");
      await tx.execute('CREATE TABLE IF NOT EXISTS local_data (account TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(account,kind,id))');
      await tx.commit();
    } catch (error) { await tx.rollback(); throw new Error((error as Error).message); }
  }
  private store(): relationalStore.RdbStore {
    if (this.db === null) { throw new Error('阅读数据库尚未初始化'); } return this.db;
  }
  async loadFeed(account: string, feed: string): Promise<CachedFeed> {
    const result: CachedFeed = { posts: [], cursor: null, anchorId: '', offset: 0 };
    const rows: relationalStore.ResultSet = await this.store().querySql('SELECT p.body FROM feed_order f JOIN posts p ON p.account=f.account AND p.id=f.id WHERE f.account=? AND f.feed=? AND p.fetched>=? ORDER BY f.rank LIMIT 500', [account, feed, Date.now() - MAX_AGE]);
    try { while (rows.goToNextRow()) { result.posts.push(JSON.parse(rows.getString(0)) as WeiboPost); } }
    finally { rows.close(); }
    const meta: relationalStore.ResultSet = await this.store().querySql('SELECT cursor,anchor,offset FROM feed_meta WHERE account=? AND feed=?', [account,feed]);
    try {
      if (meta.goToNextRow()) {
        result.cursor = meta.isColumnNull(0) ? null : meta.getString(0);
        result.anchorId = meta.getString(1); result.offset = meta.getDouble(2);
      }
    } finally { meta.close(); }
    return result;
  }
  saveFeed(account: string, feed: string, posts: WeiboPost[], cursor: string | null, current: () => boolean): Promise<void> {
    return this.writes.enqueue<void>(async (): Promise<void> => {
      if (!current()) { return; }
      const tx: relationalStore.Transaction = await this.store().createTransaction();
      try {
        await tx.execute('DELETE FROM feed_order WHERE account=? AND feed=?', [account,feed]);
        for (let i: number = 0; i < Math.min(posts.length,MAX_POSTS); i++) {
          const post: WeiboPost = posts[i];
          await tx.execute('INSERT OR REPLACE INTO posts(account,id,body,fetched) VALUES(?,?,?,?)', [account,post.id,JSON.stringify(post),post.fetchedAt ?? Date.now()]);
          await tx.execute('INSERT OR IGNORE INTO feed_order(account,feed,id,rank) VALUES(?,?,?,?)', [account,feed,post.id,i]);
        }
        await tx.execute('INSERT INTO feed_meta(account,feed,cursor) VALUES(?,?,?) ON CONFLICT(account,feed) DO UPDATE SET cursor=excluded.cursor', [account,feed,cursor]);
        await tx.execute('DELETE FROM posts WHERE account=? AND (fetched<? OR id NOT IN (SELECT id FROM posts WHERE account=? ORDER BY fetched DESC LIMIT 500))', [account,Date.now()-MAX_AGE,account]);
        await tx.execute('DELETE FROM feed_order WHERE account=? AND id NOT IN (SELECT id FROM posts WHERE account=?)', [account,account]);
        if (!current()) { await tx.rollback(); return; }
        await tx.commit();
      } catch (error) { await tx.rollback(); throw new Error((error as Error).message); }
    });
  }
  savePosition(account: string, feed: string, id: string, offset: number): Promise<void> {
    return this.writes.enqueue<void>(async (): Promise<void> => {
      await this.store().executeSql('INSERT INTO feed_meta(account,feed,anchor,offset) VALUES(?,?,?,?) ON CONFLICT(account,feed) DO UPDATE SET anchor=excluded.anchor,offset=excluded.offset', [account,feed,id,offset]);
    });
  }
  async clearAccount(account: string): Promise<void> {
    if (this.db === null) { return; }
    await this.writes.enqueue<void>(async (): Promise<void> => {
      const tx: relationalStore.Transaction = await this.store().createTransaction();
      try {
        for (const table of ['posts','feed_order','feed_meta','local_data']) {
          await tx.execute('DELETE FROM ' + table + ' WHERE account=?', [account]);
        }
        await tx.commit();
      } catch (error) { await tx.rollback(); throw new Error((error as Error).message); }
    });
  }
}

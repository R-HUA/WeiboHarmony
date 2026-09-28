class CacheValue<T> {
  constructor(public value: T, public expiresAt: number) {}
}
/** Invalidating a key also prevents an in-flight old response from repopulating it. */
export class ResponseCache<T> {
  private values: Map<string, CacheValue<T>> = new Map();
  private pending: Map<string, Promise<T>> = new Map();
  private revisions: Map<string, number> = new Map();
  constructor(private ttlMs: number = 30000) {}
  invalidate(key: string): void {
    this.revisions.set(key, (this.revisions.get(key) ?? 0) + 1);
    this.values.delete(key);
    this.pending.delete(key);
  }
  async get(key: string, load: () => Promise<T>): Promise<T> {
    const cached: CacheValue<T> | undefined = this.values.get(key);
    if (cached !== undefined && cached.expiresAt > Date.now()) { return cached.value; }
    const active: Promise<T> | undefined = this.pending.get(key);
    if (active !== undefined) { return active; }
    const revision: number = this.revisions.get(key) ?? 0;
    const request: Promise<T> = load();
    this.pending.set(key, request);
    try {
      const result: T = await request;
      if ((this.revisions.get(key) ?? 0) !== revision) { throw new Error('数据已更新，请刷新'); }
      this.values.set(key, new CacheValue<T>(result, Date.now() + this.ttlMs));
      return result;
    } finally {
      if (this.pending.get(key) === request) { this.pending.delete(key); }
    }
  }
}

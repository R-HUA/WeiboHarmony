/** Serialized, priority-aware API work. Media never enters this queue. */
class QueuedRequest {
  priority: number;
  run: () => Promise<void>;
  cancel: () => void;
  constructor(priority: number, run: () => Promise<void>, cancel: () => void) {
    this.priority = priority; this.run = run; this.cancel = cancel;
  }
}
export class RequestQueue {
  private pending: QueuedRequest[] = [];
  private running: boolean = false;
  private lastStart: number = 0;
  private generation: number = 0;
  constructor(private intervalMs: number = 800) {}
  invalidate(): void {
    this.generation++;
    const stale: QueuedRequest[] = this.pending;
    this.pending = [];
    stale.forEach((job: QueuedRequest): void => job.cancel());
  }
  enqueue<T>(action: () => Promise<T>, priority: number = 0): Promise<T> {
    const generation: number = this.generation;
    return new Promise<T>((resolve, reject) => {
      const job: QueuedRequest = new QueuedRequest(priority, async (): Promise<void> => {
        try {
          if (generation !== this.generation) { throw new Error('请求已取消'); }
          const value: T = await action();
          if (generation !== this.generation) { throw new Error('请求已取消'); }
          resolve(value);
        } catch (error) { reject(error); }
      }, (): void => reject(new Error('请求已取消')));
      this.pending.push(job);
      this.pending.sort((a: QueuedRequest, b: QueuedRequest): number => b.priority - a.priority);
      this.drain();
    });
  }
  private async drain(): Promise<void> {
    if (this.running) { return; }
    this.running = true;
    try {
      while (this.pending.length > 0) {
        const wait: number = this.intervalMs - (Date.now() - this.lastStart);
        if (wait > 0) { await new Promise<void>((resolve) => { setTimeout(resolve, wait); }); }
        const job: QueuedRequest | undefined = this.pending.shift();
        if (job === undefined) { continue; }
        this.lastStart = Date.now();
        await job.run();
      }
    } finally { this.running = false; }
  }
}

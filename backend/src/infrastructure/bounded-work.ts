import { ServiceUnavailableException } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";

export function boundedSetting(
  config: ConfigService,
  name: string,
  fallback: number,
  max = 1000000,
) {
  const value = Number(config.get(name, fallback));
  if (!Number.isSafeInteger(value) || value < 1 || value > max)
    throw new Error(`Invalid ${name}`);
  return value;
}

/** Reserves permits before waking waiters; expired work never starts later. */
export class BoundedWork {
  private active = 0;
  private readonly waiting: {
    resolve: () => void;
    reject: () => void;
    timer: NodeJS.Timeout;
  }[] = [];
  constructor(
    private readonly concurrency: number,
    private readonly maxWaiting: number,
  ) {}
  async run<T>(
    work: () => Promise<T>,
    deadline = Date.now() + 10000,
  ): Promise<T> {
    if (deadline <= Date.now())
      throw new ServiceUnavailableException("Work deadline exceeded");
    if (this.active < this.concurrency) this.active++;
    else {
      if (this.waiting.length >= this.maxWaiting)
        throw new ServiceUnavailableException("Work queue is full");
      await new Promise<void>((resolve, reject) => {
        const waiter = {
          resolve,
          reject: () =>
            reject(new ServiceUnavailableException("Work deadline exceeded")),
          timer: undefined as unknown as NodeJS.Timeout,
        };
        waiter.timer = setTimeout(
          () => {
            const index = this.waiting.indexOf(waiter);
            if (index >= 0) this.waiting.splice(index, 1);
            waiter.reject();
          },
          Math.max(1, deadline - Date.now()),
        );
        this.waiting.push(waiter);
      });
    }
    try {
      if (Date.now() >= deadline)
        throw new ServiceUnavailableException("Work deadline exceeded");
      return await work();
    } finally {
      const waiter = this.waiting.shift();
      if (waiter) {
        clearTimeout(waiter.timer);
        waiter.resolve();
      } else this.active--;
    }
  }
}

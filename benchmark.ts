#!/usr/bin/env npx tsx
/**
 * Vision Server Benchmark
 *
 * Maximizes throughput against the vision server while respecting backpressure.
 * Handles 503 errors with exponential backoff, but aggressively retries to
 * keep the server saturated without idling.
 *
 * Usage:
 *   npx tsx benchmark.ts <directory> [options]
 *
 * Options:
 *   --concurrency=N    Max concurrent requests (default: 20)
 *   --server=URL       Server URL (default: http://localhost:3100)
 *   --min-backoff=MS   Min backoff on 503 (default: 50)
 *   --max-backoff=MS   Max backoff on 503 (default: 2000)
 *   --max-retries=N    Max retries per image (default: 10)
 */

import { readdir, stat, readFile } from "fs/promises";
import { join, extname } from "path";

// ============================================================================
// Configuration
// ============================================================================

interface Config {
  directory: string;
  concurrency: number;
  serverUrl: string;
  minBackoffMs: number;
  maxBackoffMs: number;
  maxRetries: number;
}

function parseArgs(): Config {
  const args = process.argv.slice(2);
  const directory = args.find((a) => !a.startsWith("--"));

  if (!directory) {
    console.error(`Usage: npx tsx benchmark.ts <directory> [options]

Options:
  --concurrency=N    Max concurrent requests (default: 20)
  --server=URL       Server URL (default: http://localhost:3100)
  --min-backoff=MS   Min backoff on 503 (default: 50)
  --max-backoff=MS   Max backoff on 503 (default: 2000)
  --max-retries=N    Max retries per image (default: 10)

Example:
  npx tsx benchmark.ts ./test-images --concurrency=30 --server=http://localhost:3100
`);
    process.exit(1);
  }

  const getArg = (name: string, defaultValue: string): string => {
    const arg = args.find((a) => a.startsWith(`--${name}=`));
    return arg ? arg.split("=")[1] : defaultValue;
  };

  return {
    directory,
    concurrency: parseInt(getArg("concurrency", "20"), 10),
    serverUrl: getArg("server", "http://localhost:3100"),
    minBackoffMs: parseInt(getArg("min-backoff", "50"), 10),
    maxBackoffMs: parseInt(getArg("max-backoff", "2000"), 10),
    maxRetries: parseInt(getArg("max-retries", "10"), 10),
  };
}

// ============================================================================
// File Discovery
// ============================================================================

async function findImages(directory: string): Promise<string[]> {
  const files: string[] = [];
  const validExts = new Set([".jpg", ".jpeg", ".png"]);

  async function walk(dir: string): Promise<void> {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(fullPath);
      } else if (validExts.has(extname(entry.name).toLowerCase())) {
        files.push(fullPath);
      }
    }
  }

  await walk(directory);
  return files.sort();
}

// ============================================================================
// HTTP Client with Backoff
// ============================================================================

interface RequestResult {
  success: boolean;
  latencyMs: number;
  statusCode: number;
  retries: number;
  bytesProcessed: number;
  error?: string;
}

async function sendRequest(
  filePath: string,
  imageBuffer: Buffer,
  config: Config
): Promise<RequestResult> {
  const startTime = performance.now();
  let retries = 0;
  let backoffMs = config.minBackoffMs;

  while (retries <= config.maxRetries) {
    const attemptStart = performance.now();

    try {
      const boundary = `----FormBoundary${Date.now()}${Math.random().toString(36)}`;
      const parts: Buffer[] = [];
      parts.push(Buffer.from(`--${boundary}\r\n`));
      parts.push(
        Buffer.from(
          `Content-Disposition: form-data; name="image"; filename="image.jpg"\r\n`
        )
      );
      parts.push(Buffer.from(`Content-Type: image/jpeg\r\n\r\n`));
      parts.push(imageBuffer);
      parts.push(Buffer.from(`\r\n--${boundary}--\r\n`));
      const body = Buffer.concat(parts);

      const response = await fetch(`${config.serverUrl}/analyze`, {
        method: "POST",
        headers: {
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
          "X-Request-Id": `bench-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        },
        body,
      });

      if (response.ok) {
        return {
          success: true,
          latencyMs: performance.now() - startTime,
          statusCode: 200,
          retries,
          bytesProcessed: imageBuffer.length,
        };
      }

      // Handle 503 with backoff
      if (response.status === 503) {
        const retryAfter = response.headers.get("Retry-After");
        const serverBackoff = retryAfter ? parseInt(retryAfter, 10) * 1000 : 0;

        // Use server hint but cap it, and add jitter
        const jitter = Math.random() * backoffMs * 0.5;
        const waitMs = Math.min(
          Math.max(backoffMs, serverBackoff * 0.3), // Use 30% of server suggestion (aggressive)
          config.maxBackoffMs
        ) + jitter;

        await sleep(waitMs);

        // Exponential backoff for next retry
        backoffMs = Math.min(backoffMs * 1.5, config.maxBackoffMs);
        retries++;
        continue;
      }

      // Other errors - don't retry
      return {
        success: false,
        latencyMs: performance.now() - startTime,
        statusCode: response.status,
        retries,
        bytesProcessed: 0,
        error: `HTTP ${response.status}`,
      };
    } catch (err) {
      // Network error - retry with backoff
      const jitter = Math.random() * backoffMs * 0.5;
      await sleep(backoffMs + jitter);
      backoffMs = Math.min(backoffMs * 1.5, config.maxBackoffMs);
      retries++;

      if (retries > config.maxRetries) {
        return {
          success: false,
          latencyMs: performance.now() - startTime,
          statusCode: 0,
          retries,
          bytesProcessed: 0,
          error: err instanceof Error ? err.message : String(err),
        };
      }
    }
  }

  return {
    success: false,
    latencyMs: performance.now() - startTime,
    statusCode: 503,
    retries,
    bytesProcessed: 0,
    error: "Max retries exceeded",
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ============================================================================
// Stats Tracking
// ============================================================================

class Stats {
  private total = 0;
  private success = 0;
  private errors = 0;
  private totalRetries = 0;
  private totalBytesProcessed = 0;
  private latencies: number[] = [];
  private startTime = performance.now();
  private lastProgressTime = 0;

  record(result: RequestResult): void {
    this.total++;
    this.totalRetries += result.retries;

    if (result.success) {
      this.success++;
      this.totalBytesProcessed += result.bytesProcessed;
      this.latencies.push(result.latencyMs);
    } else {
      this.errors++;
    }

    // Print progress every second
    const now = performance.now();
    if (now - this.lastProgressTime > 1000) {
      this.lastProgressTime = now;
      const elapsed = (now - this.startTime) / 1000;
      const throughput = this.success / elapsed;
      const mbProcessed = this.totalBytesProcessed / (1024 * 1024);
      const mbPerSec = mbProcessed / elapsed;
      console.log(
        `[${elapsed.toFixed(1)}s] ${this.total} requests | ` +
          `${this.success} ok | ${this.errors} err | ` +
          `${throughput.toFixed(1)} img/s | ${mbPerSec.toFixed(2)} MB/s`
      );
    }
  }

  getSummary() {
    const elapsed = (performance.now() - this.startTime) / 1000;
    const sorted = [...this.latencies].sort((a, b) => a - b);

    return {
      total: this.total,
      success: this.success,
      errors: this.errors,
      totalRetries: this.totalRetries,
      elapsedSec: elapsed,
      throughputImgSec: this.success / elapsed,
      throughputMBSec: this.totalBytesProcessed / (1024 * 1024) / elapsed,
      totalMB: this.totalBytesProcessed / (1024 * 1024),
      latency: sorted.length > 0
        ? {
            avg: sorted.reduce((a, b) => a + b, 0) / sorted.length,
            p50: sorted[Math.floor(sorted.length * 0.5)],
            p95: sorted[Math.floor(sorted.length * 0.95)],
            p99: sorted[Math.floor(sorted.length * 0.99)],
            min: sorted[0],
            max: sorted[sorted.length - 1],
          }
        : null,
    };
  }
}

// ============================================================================
// Semaphore for Concurrency Control
// ============================================================================

class Semaphore {
  private permits: number;
  private waiting: Array<() => void> = [];

  constructor(permits: number) {
    this.permits = permits;
  }

  async acquire(): Promise<void> {
    if (this.permits > 0) {
      this.permits--;
      return;
    }
    return new Promise((resolve) => {
      this.waiting.push(resolve);
    });
  }

  release(): void {
    const next = this.waiting.shift();
    if (next) {
      next();
    } else {
      this.permits++;
    }
  }
}

// ============================================================================
// Main
// ============================================================================

async function main() {
  const config = parseArgs();

  console.log("Vision Server Benchmark");
  console.log("=======================");
  console.log(`Directory:   ${config.directory}`);
  console.log(`Server:      ${config.serverUrl}`);
  console.log(`Concurrency: ${config.concurrency}`);
  console.log(`Backoff:     ${config.minBackoffMs}ms - ${config.maxBackoffMs}ms`);
  console.log(`Max retries: ${config.maxRetries}`);
  console.log("");

  // Check server health
  try {
    const health = await fetch(`${config.serverUrl}/health`);
    if (!health.ok) {
      console.error(`Server health check failed: ${health.status}`);
      process.exit(1);
    }
    const healthData = await health.json();
    console.log("Server health:", JSON.stringify(healthData));
  } catch (err) {
    console.error(`Cannot connect to server at ${config.serverUrl}`);
    process.exit(1);
  }

  console.log("");

  // Find images
  console.log("Scanning for images...");
  const files = await findImages(config.directory);
  if (files.length === 0) {
    console.error(`No image files found in ${config.directory}`);
    process.exit(1);
  }

  // Pre-load all images into memory
  console.log(`Found ${files.length} images. Loading into memory...`);
  const images: Array<{ path: string; buffer: Buffer }> = [];
  let totalBytes = 0;
  for (const file of files) {
    const buffer = await readFile(file);
    images.push({ path: file, buffer });
    totalBytes += buffer.length;
  }
  console.log(`Loaded ${(totalBytes / (1024 * 1024)).toFixed(2)} MB`);
  console.log("");
  console.log("Starting benchmark...");
  console.log("---");

  const stats = new Stats();
  const semaphore = new Semaphore(config.concurrency);

  // Process all images concurrently
  const promises = images.map(async ({ path, buffer }) => {
    await semaphore.acquire();
    try {
      const result = await sendRequest(path, buffer, config);
      stats.record(result);
    } finally {
      semaphore.release();
    }
  });

  await Promise.all(promises);

  // Print final results
  const summary = stats.getSummary();
  console.log("");
  console.log("===== RESULTS =====");
  console.log(`Total requests:   ${summary.total}`);
  console.log(`Successful:       ${summary.success}`);
  console.log(`Errors:           ${summary.errors}`);
  console.log(`Total retries:    ${summary.totalRetries}`);
  console.log("");
  console.log(`Wall time:        ${summary.elapsedSec.toFixed(2)}s`);
  console.log(`Throughput:       ${summary.throughputImgSec.toFixed(2)} images/sec`);
  console.log(`Throughput:       ${summary.throughputMBSec.toFixed(2)} MB/sec`);
  console.log(`Total processed:  ${summary.totalMB.toFixed(2)} MB`);

  if (summary.latency) {
    console.log("");
    console.log("Latency (successful requests):");
    console.log(`  avg:  ${summary.latency.avg.toFixed(1)}ms`);
    console.log(`  p50:  ${summary.latency.p50.toFixed(1)}ms`);
    console.log(`  p95:  ${summary.latency.p95.toFixed(1)}ms`);
    console.log(`  p99:  ${summary.latency.p99.toFixed(1)}ms`);
    console.log(`  min:  ${summary.latency.min.toFixed(1)}ms`);
    console.log(`  max:  ${summary.latency.max.toFixed(1)}ms`);
  }
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
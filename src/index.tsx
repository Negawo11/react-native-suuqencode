import { NativeEventEmitter, NativeModules } from 'react-native';

const { Suuqencode } = NativeModules;

const eventEmitter = new NativeEventEmitter(Suuqencode);

export function startEncode(): void {
  Suuqencode.startEncode();
}

export function addEncodedDataListener(
  callback: (data: string) => void
): () => void {
  const subscription = eventEmitter.addListener(
    'onEncodedData',
    (data: any) => {
      callback(data as string);
    }
  );
  return () => {
    subscription.remove();
  };
}

export type AudioEncodeFormat = 'flac' | 'pcm';

export interface AudioFormatInfo {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  codec: string;
}

/**
 * Start recording from the microphone and encoding audio in real time.
 * Each encoded audio packet is base64-encoded and emitted via the onAudioEncodedData event.
 * @param sampleRate Target sample rate in Hz (default: 16000)
 * @param format Encoding format: 'flac' for FLAC compression, 'pcm' for raw 16-bit PCM (default: 'flac')
 * @returns Promise that resolves when recording has started successfully
 */
export function startAudioEncode(
  sampleRate: number = 16000,
  format: AudioEncodeFormat = 'flac'
): Promise<boolean> {
  return Suuqencode.startAudioEncode(sampleRate, format);
}

/**
 * Stop audio recording and encoding.
 */
export function stopAudioEncode(): void {
  Suuqencode.stopAudioEncode();
}

/**
 * Listen for base64-encoded audio packets (FLAC or PCM depending on format chosen).
 */
export function addAudioDataListener(
  callback: (data: string) => void
): () => void {
  const subscription = eventEmitter.addListener(
    'onAudioEncodedData',
    (data: any) => {
      callback(data as string);
    }
  );
  return () => {
    subscription.remove();
  };
}

/**
 * Listen for audio format info emitted once at the start of recording.
 */
export function addAudioFormatInfoListener(
  callback: (info: AudioFormatInfo) => void
): () => void {
  const subscription = eventEmitter.addListener(
    'onAudioFormatInfo',
    (info: any) => {
      callback(info as AudioFormatInfo);
    }
  );
  return () => {
    subscription.remove();
  };
}

// ---------------------------------------------------------------------------
// PCM Streaming Playback
// ---------------------------------------------------------------------------

/**
 * Start the native PCM streaming player. Audio chunks pushed via
 * `writePcmData` are queued on an AVAudioPlayerNode for gapless,
 * sample-accurate playback — no file I/O or JS-side Sound objects.
 *
 * @param sampleRate Sample rate of the PCM data (default 24000 for Gemini output)
 * @param channels   Number of audio channels (default 1 = mono)
 */
export function startPcmPlayer(
  sampleRate: number = 24000,
  channels: number = 1
): Promise<boolean> {
  return Suuqencode.startPcmPlayer(sampleRate, channels);
}

/**
 * Push a base64-encoded chunk of signed-16-bit-LE PCM data to the native
 * player. The chunk is scheduled on the audio graph immediately and will
 * play seamlessly after any previously queued chunks with zero gap.
 */
export function writePcmData(base64Data: string): void {
  Suuqencode.writePcmData(base64Data);
}

/**
 * Stop the PCM player and release audio engine resources.
 */
export function stopPcmPlayer(): void {
  Suuqencode.stopPcmPlayer();
}

/**
 * Listen for the player-stopped event.
 */
export function addPcmPlayerStoppedListener(callback: () => void): () => void {
  const subscription = eventEmitter.addListener('onPcmPlayerStopped', () =>
    callback()
  );
  return () => {
    subscription.remove();
  };
}

// ---------------------------------------------------------------------------
// DeviceCheck
// ---------------------------------------------------------------------------

/**
 * Generate an Apple DeviceCheck token for device attestation.
 * Only available on physical iOS 11+ devices; rejects on simulators.
 * @returns Promise resolving to a base64-encoded DeviceCheck token string.
 */
export function getDeviceToken(): Promise<string> {
  return Suuqencode.getDeviceToken();
}

// ---------------------------------------------------------------------------
// HTTP Streaming
// ---------------------------------------------------------------------------

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface HttpConnectionConfig {
  /** The URL to connect to (http:// or https://) */
  url: string;
  /** HTTP method. Defaults to 'GET'. */
  method?: HttpMethod;
  /** Optional request headers. */
  headers?: Record<string, string>;
  /**
   * Size of the internal stream buffer in bytes.
   * Controls how much data can be buffered before backpressure kicks in.
   * Defaults to 65536 (64 KB).
   */
  bufferSize?: number;
}

/** Event payload for an HTTP response header. */
export interface HttpResponseEvent {
  statusCode: number;
  headers: Record<string, string>;
}

/** Event payload for a chunk of response data. */
export interface HttpDataEvent {
  /** Base-64 encoded chunk */
  data: string;
}

/** Event payload emitted after a queued write has been flushed to the socket. */
export interface HttpWriteCompleteEvent {
  /** Bytes written for this chunk. */
  bytesWritten: number;
  /** Cumulative bytes queued since connection creation. */
  totalBytesQueued: number;
}

let _httpConnectionCounter = 0;

/**
 * Represents a single streaming HTTP connection.
 *
 * ## Usage
 * ```ts
 * const conn = new HttpConnection({
 *   url: 'https://example.com/upload',
 *   method: 'POST',
 *   headers: { 'Content-Type': 'application/octet-stream' },
 *   bufferSize: 131072, // 128 KB
 * });
 *
 * conn.onResponse((statusCode, headers) => { ... });
 * conn.onData((base64Chunk) => { ... });
 * conn.onWriteComplete((bytesWritten, totalBytesQueued) => { ... });
 * conn.onError((error) => { ... });
 * conn.onComplete(() => { ... });
 *
 * conn.write(base64EncodedChunk);
 * conn.finishWriting(); // signal end of request body
 *
 * // When done, or to abort:
 * conn.close();
 * ```
 *
 * If you drop all references without calling `.close()`, the connection
 * will be cleaned up when the native module is invalidated (e.g. on reload).
 * Always prefer calling `.close()` explicitly when done.
 */
export class HttpConnection {
  /** Unique native-side identifier for this connection. */
  readonly connectionId: string;
  private _closed = false;
  private _subscriptions: (() => void)[] = [];

  constructor(config: HttpConnectionConfig) {
    this.connectionId = `http_${++_httpConnectionCounter}_${Date.now()}`;

    Suuqencode.httpCreate(
      this.connectionId,
      config.url,
      config.method ?? 'GET',
      config.headers ?? {},
      config.bufferSize ?? 65536
    );

    // Cleanup of abandoned connections is handled natively via the
    // module's -invalidate method (called on reload / teardown).
  }

  // ---- Write API ----------------------------------------------------------

  /**
   * Enqueue base-64 encoded data to be streamed to the server (POST/PUT/PATCH).
   * The data is buffered internally and flushed as the socket becomes writable.
   * Listen to `onWriteComplete` to manage backpressure.
   */
  write(base64Data: string): void {
    if (this._closed) {
      throw new Error('HttpConnection is closed');
    }
    Suuqencode.httpWrite(this.connectionId, base64Data);
  }

  /**
   * Signal that no more data will be written to the request body.
   * For GET/DELETE this is a no-op.
   */
  finishWriting(): void {
    if (this._closed) return;
    Suuqencode.httpFinishWriting(this.connectionId);
  }

  /**
   * Immediately abort all transfers and close the underlying socket.
   * This is synchronous from the caller's perspective — the native task is
   * cancelled and the session is invalidated before this method returns.
   * Safe to call multiple times.
   */
  close(): void {
    if (this._closed) return;
    this._closed = true;
    // Remove all event subscriptions
    for (const unsub of this._subscriptions) {
      unsub();
    }
    this._subscriptions = [];
    Suuqencode.httpClose(this.connectionId);
  }

  // ---- Event Subscriptions ------------------------------------------------

  /**
   * Fired when the HTTP response headers are received.
   * @returns An unsubscribe function.
   */
  onResponse(
    callback: (statusCode: number, headers: Record<string, string>) => void
  ): () => void {
    return this._on('onHttpResponse', (event: any) => {
      if (event.connectionId === this.connectionId) {
        callback(event.statusCode, event.headers);
      }
    });
  }

  /**
   * Fired for each chunk of response body data received from the server.
   * The `base64Data` parameter is the chunk base-64 encoded.
   * @returns An unsubscribe function.
   */
  onData(callback: (base64Data: string) => void): () => void {
    return this._on('onHttpData', (event: any) => {
      if (event.connectionId === this.connectionId) {
        callback(event.data);
      }
    });
  }

  /**
   * Fired after a previously enqueued write chunk has been fully flushed
   * to the underlying socket. Use this for backpressure management.
   * @returns An unsubscribe function.
   */
  onWriteComplete(
    callback: (bytesWritten: number, totalBytesQueued: number) => void
  ): () => void {
    return this._on('onHttpWriteComplete', (event: any) => {
      if (event.connectionId === this.connectionId) {
        callback(event.bytesWritten, event.totalBytesQueued);
      }
    });
  }

  /**
   * Fired when an error occurs (network failure, invalid URL, etc.).
   * @returns An unsubscribe function.
   */
  onError(callback: (error: string) => void): () => void {
    return this._on('onHttpError', (event: any) => {
      if (event.connectionId === this.connectionId) {
        callback(event.error);
      }
    });
  }

  /**
   * Fired when the HTTP transaction completes successfully
   * (response body fully received, no errors).
   * @returns An unsubscribe function.
   */
  onComplete(callback: () => void): () => void {
    return this._on('onHttpComplete', (event: any) => {
      if (event.connectionId === this.connectionId) {
        callback();
      }
    });
  }

  // ---- Internal -----------------------------------------------------------

  private _on(eventName: string, handler: (event: any) => void): () => void {
    const subscription = eventEmitter.addListener(eventName, handler);
    const unsub = () => {
      subscription.remove();
      const idx = this._subscriptions.indexOf(unsub);
      if (idx !== -1) this._subscriptions.splice(idx, 1);
    };
    this._subscriptions.push(unsub);
    return unsub;
  }
}

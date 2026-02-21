import { NativeModules, NativeEventEmitter } from 'react-native';

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

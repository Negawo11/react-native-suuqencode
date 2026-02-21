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

export interface AudioFormatInfo {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  codec: string;
}

/**
 * Start recording from the microphone and encoding audio to FLAC in real time.
 * Each encoded FLAC packet is base64-encoded and emitted via the onAudioEncodedData event.
 * @param sampleRate Target sample rate in Hz (default: 16000)
 * @returns Promise that resolves when recording has started successfully
 */
export function startAudioEncode(sampleRate: number = 16000): Promise<boolean> {
  return Suuqencode.startAudioEncode(sampleRate);
}

/**
 * Stop audio recording and FLAC encoding.
 */
export function stopAudioEncode(): void {
  Suuqencode.stopAudioEncode();
}

/**
 * Listen for base64-encoded FLAC audio packets.
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

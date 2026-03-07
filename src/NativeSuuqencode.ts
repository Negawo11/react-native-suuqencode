import { TurboModuleRegistry, type TurboModule } from 'react-native';

export interface Spec extends TurboModule {
  startEncode(): void;
  startAudioEncode(sampleRate: number, format: string): Promise<boolean>;
  stopAudioEncode(): void;
  addListener(eventName: string): void;
  removeListeners(count: number): void;

  // PCM streaming playback
  startPcmPlayer(sampleRate: number, channels: number): Promise<boolean>;
  writePcmData(base64Data: string): void;
  stopPcmPlayer(): void;

  // HTTP streaming
  httpCreate(
    connectionId: string,
    url: string,
    method: string,
    headers: Object,
    bufferSize: number
  ): void;
  httpWrite(connectionId: string, base64Data: string): void;
  httpFinishWriting(connectionId: string): void;
  httpClose(connectionId: string): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Suuqencode');

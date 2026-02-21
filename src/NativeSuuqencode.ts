import { TurboModuleRegistry, type TurboModule } from 'react-native';

export interface Spec extends TurboModule {
  startEncode(): void;
  startAudioEncode(sampleRate: number): Promise<boolean>;
  stopAudioEncode(): void;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Suuqencode');

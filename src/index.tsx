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

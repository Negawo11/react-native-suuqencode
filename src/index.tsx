import { NativeModules, NativeEventEmitter } from 'react-native';

const { Suuqencode } = NativeModules;

const eventEmitter = new NativeEventEmitter(Suuqencode);

export function encode(
  base64Bitmap: string,
  width: number,
  height: number
): void {
  Suuqencode.encode(base64Bitmap, width, height);
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

import { useState, useEffect } from 'react';
import { View, Text, Button, StyleSheet, ScrollView } from 'react-native';
import { encode, addEncodedDataListener } from 'react-native-suuqencode';

export default function App() {
  const [encodedData, setEncodedData] = useState<string[]>([]);

  useEffect(() => {
    const removeListener = addEncodedDataListener((data) => {
      setEncodedData((prevData) => [...prevData, data]);
    });

    return () => {
      removeListener();
    };
  }, []);

  const handleEncode = () => {
    // 1x1 red pixel
    const base64Bitmap =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==';
    encode(base64Bitmap, 1, 1);
  };

  return (
    <View style={styles.container}>
      <Button title="Encode" onPress={handleEncode} />
      <ScrollView style={styles.scrollView}>
        {encodedData.map((data, index) => (
          <Text key={index} style={styles.dataText}>
            {data}
          </Text>
        ))}
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 20,
  },
  scrollView: {
    marginTop: 20,
    width: '100%',
  },
  dataText: {
    fontFamily: 'monospace',
    fontSize: 10,
  },
});

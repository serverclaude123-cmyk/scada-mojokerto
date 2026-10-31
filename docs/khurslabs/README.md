# Referensi board KhursLabs

Board: **ESP32-S3 IoT Acquisition RS485 Modbus-Ethernet** (ESP32-S3-WROOM-1 + W5500 Lite).
Tidak ada datasheet/pinout resmi di internet, jadi berkas di sini adalah acuan utama.

## `Test_sht20_RS485.ino`
Contoh resmi dari KhursLabs. Dari file inilah pin RS485 dipastikan:

```cpp
const byte rxPin = 16; // RX2
const byte txPin = 15; // TX2
HardwareSerial modul(1);
modul.begin(9600, SERIAL_8N1, rxPin, txPin);
```

- **RS485 transceiver ada di UART1, TX 15 / RX 16.** Bukan 17/18.
- 9600 8N1.
- Tidak ada pin DE/RE yang digerakkan → transceiver **auto-direction**.

> **Komentar header di file itu salah.** Tertulis `RX pin 18, TX pin 19, RTS pin 14`,
> padahal kodenya memakai 16/15 dan tidak pernah menyentuh RTS. Percayai kodenya.

## Terminal "SERIAL 1" (17/18)
Label di casing memisahkan tiga kelompok di terminal atas: `VOUT 5V`, `RS485 (-B- +A+)`,
dan `SERIAL 1 (18, 17)`. **"SERIAL 1" adalah breakout UART TTL yang terpisah**, bukan jalur
ke transceiver RS485. Asumsi awal proyek ini yang memakai 17/18 untuk RS485 karena itu keliru.

## W5500 (dari silkscreen PCB)
```
SS MOSI SCK MISO RST INT  =  5  11  12  13  21  47
```
Cocok dengan isi `firmware/include/config.h`.

Silkscreen lain: TF Card `SS MOSI SCK MISO = 10 11 12 13`, RGB LED di 48,
ADS1115 (ADC 16 bit) di I2C 0x48, RTC DS3231.

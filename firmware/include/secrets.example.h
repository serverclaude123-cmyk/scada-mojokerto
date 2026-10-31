#pragma once
// Salin file ini menjadi secrets.h (tidak ikut Git), lalu isi data broker MQTT.
//
// Broker sekarang ada di PC lokal (PC FUXA), bukan cloud free tier.
// Isi IP PC itu di LAN -- JANGAN "localhost": ESP32 harus menuju PC, bukan dirinya sendiri.
#define MQTT_HOST      "192.168.1.10"
#define MQTT_USER      "isi_user"       // kosongkan ("") kalau broker mengizinkan anonim
#define MQTT_PASS      "isi_password"   // kosongkan ("") kalau broker mengizinkan anonim
#define MQTT_CLIENT_ID "esp32-vsd-mojokerto"

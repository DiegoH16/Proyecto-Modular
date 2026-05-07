/*
 * DISPOSITIVO TOBILLO: MPU6050 (V3.3 OFFLINE AP)
 * Corrección: Validación de clientes y ajuste de umbral SVM.
 */
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>

const char* ssid = "AVA_NEXUS";       
const char* password = "ava_password"; 
const char* ip_matlab = "192.168.4.2"; 

const int puerto_datos = 8888;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
Adafruit_MPU6050 mpu;

const int PIN_EMG = 4; 
const int FRECUENCIA_HZ = 50;
const unsigned long INTERVALO_US = 1000000 / FRECUENCIA_HZ; 

const int TAMANO_LOTE = 5;
int contador = 0;
char payload[512]; 
int payload_len = 0;
unsigned long ultimo_muestreo_us = 0;

uint16_t crc16(const char* data, int len) {
  uint16_t crc = 0xFFFF;
  for (int i = 0; i < len; i++) {
    crc ^= (uint8_t)data[i];
    for (int j = 0; j < 8; j++) {
      if (crc & 0x0001) crc = (crc >> 1) ^ 0xA001;
      else crc >>= 1;
    }
  }
  return crc;
}

void setup() {
  Serial.begin(115200);
  WiFi.mode(WIFI_AP);
  WiFi.softAP(ssid, password);
  delay(500);

  Wire.begin(21, 22);
  Wire.setClock(400000); 

  if (!mpu.begin()) ESP.restart();

  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ); 
  analogReadResolution(12);

  payload_len = 0; memset(payload, 0, sizeof(payload));
  ultimo_muestreo_us = micros();
}

void loop() {
  unsigned long t_actual = micros();

  if (t_actual - ultimo_muestreo_us >= INTERVALO_US) {
    ultimo_muestreo_us = t_actual;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);

    float ax = a.acceleration.x;
    float ay = a.acceleration.y;
    float az = a.acceleration.z;
    int emg_raw = analogRead(PIN_EMG);

    // ✅ MITIGACIÓN CRÍTICA: Umbral ajustado a 50 m/s2
    if (abs(ax) > 50.0 || abs(ay) > 50.0 || abs(az) > 50.0) return;

    struct timeval tv; gettimeofday(&tv, NULL);
    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld,%06ld,%.2f,%.2f,%.2f,%d", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, ax, ay, az, emg_raw);

    uint16_t crc = crc16(linea, len);
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    if (added > 0 && added < (sizeof(payload) - payload_len)) payload_len += added;

    contador++;

    if (contador >= TAMANO_LOTE) {
      // ✅ MITIGACIÓN CRÍTICA: Solo enviar UDP si hay clientes conectados al AP
      if (WiFi.softAPgetStationNum() > 0) {
        udp_datos.beginPacket(ip_matlab, puerto_datos);
        udp_datos.write((const uint8_t*)payload, payload_len);
        udp_datos.endPacket();
      }
      payload_len = 0; contador = 0; 
    }
  }
  yield(); 
}

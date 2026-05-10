/* Copyright 2026 Diego Gutiérrez Hermosillo Medina, Obed Simón Aceves Gutiérrez
    
     Licensed under the Apache License, Version 2.0 (the "License");
     you may not use this file except in compliance with the License.
     You may obtain a copy of the License at
    
         http://www.apache.org/licenses/LICENSE-2.0
    
     Unless required by applicable law or agreed to in writing, software
     distributed under the License is distributed on an "AS IS" BASIS,
     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
     See the License for the specific language governing permissions and
     limitations under the License.
 */
/*
 * DISPOSITIVO TOBILLO: MPU6050 + EMG AD8232 (V4.3 DIAGNÓSTICO PROFUNDO)
 * Solución de Core Dump, problemas de energía y tolerancia a fallos I2C.
 */
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>

const char* ssid = "AVA_NEXUS";        
const char* password = "ava_password"; 
const char* ip_broadcast = "192.168.4.255"; 

const int puerto_datos = 8888;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
Adafruit_MPU6050 mpu;

const int PIN_EMG = 34; 
const int FRECUENCIA_HZ = 400; // Escalado a 400 Hz
const unsigned long INTERVALO_US = 1000000 / FRECUENCIA_HZ; // 2500 us

// 4 muestras a 400Hz = 1 paquete cada 10ms (100 paquetes/seg)
const int TAMANO_LOTE = 4; 
int contador = 0;
char payload[1024]; // Buffer ampliado
int payload_len = 0;
unsigned long ultimo_muestreo_us = 0;

bool mpu_ok = false;

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
  delay(2000); 
  
  Serial.println("\n--- INICIANDO NODO TOBILLO (AP) ---");
  
  Serial.println("[Paso 1] Encendiendo Wi-Fi...");
  WiFi.mode(WIFI_AP);
  delay(100);
  WiFi.softAP(ssid, password);
  delay(1000); 
  Serial.print("IP del Router: "); Serial.println(WiFi.softAPIP());

  // Iniciar I2C en Fast Mode (OBLIGATORIO para 400Hz)
  Serial.println("[Paso 2] Iniciando bus I2C (SDA=21, SCL=22) a 400kHz...");
  Wire.begin(21, 22);
  Wire.setClock(400000); 
  
  Wire.beginTransmission(0x68); 
  byte errorI2C = Wire.endTransmission();
  
  if (errorI2C == 0) {
    Serial.println("  -> Dispositivo detectado en 0x68. Inicializando MPU...");
    if (mpu.begin()) {
        mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
        mpu.setGyroRange(MPU6050_RANGE_500_DEG);
        // Filtro adaptado para 400Hz (evitar sobre-suavizado)
        mpu.setFilterBandwidth(MPU6050_BAND_94_HZ); 
        mpu_ok = true;
        Serial.println("  -> [OK] MPU6050 Configurado.");
    } else {
        Serial.println("  -> [ERROR] Fallo al configurar MPU6050.");
        mpu_ok = false;
    }
  } else {
    Serial.println("  -> [CRÍTICO] No hay respuesta en 0x68. MPU6050 no detectado.");
    Serial.println("  -> El sistema seguirá funcionando SOLO CON EMG.");
    mpu_ok = false;
  }

  analogReadResolution(12);

  Serial.println("[Paso 3] Enviando mensaje SYNC UDP...");
  struct timeval tv; gettimeofday(&tv, NULL);
  char sync_msg[100];
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,TOBILLO,%lld,%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  udp_control.beginPacket(ip_broadcast, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();

  payload_len = 0; memset(payload, 0, sizeof(payload));
  ultimo_muestreo_us = micros();
  
  Serial.println("\n>>> TOBILLO INICIADO - LOOP ACTIVO (400 Hz) <<<");
}

void loop() {
  unsigned long t_actual = micros();

  // El cálculo (t_actual - ultimo_muestreo_us) maneja el desbordamiento de forma nativa
  if (t_actual - ultimo_muestreo_us >= INTERVALO_US) {
    ultimo_muestreo_us += INTERVALO_US; // Mantiene una cadencia matemáticamente perfecta

    float ax = 0, ay = 0, az = 0;
    
    if (mpu_ok) {
        sensors_event_t a, g, temp;
        mpu.getEvent(&a, &g, &temp);
        ax = a.acceleration.x;
        ay = a.acceleration.y;
        az = a.acceleration.z;
    }

    int emg_raw = analogRead(PIN_EMG);

    struct timeval tv; gettimeofday(&tv, NULL);

    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld,%06ld,%.2f,%.2f,%.2f,%d", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, ax, ay, az, emg_raw);

    uint16_t crc = crc16(linea, len);
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    if (added > 0 && added < (sizeof(payload) - payload_len)) payload_len += added;

    contador++;

    if (contador >= TAMANO_LOTE) {
      if (WiFi.softAPgetStationNum() > 0) {
        udp_datos.beginPacket(ip_broadcast, puerto_datos);
        udp_datos.write((const uint8_t*)payload, payload_len);
        udp_datos.endPacket();
        
        // Telemetría ligera: 1 vez por segundo
        static int lotesEnviados = 0;
        lotesEnviados++;
        if (lotesEnviados % 100 == 0) {
           Serial.printf("[TOBILLO] %d lotes enviados (400 Hz)\n", lotesEnviados);
        }
      }
      payload_len = 0; contador = 0; 
    }
  }
  
  // yield() es no bloqueante y alimenta al Watchdog sin perder 1 milisegundo completo
  yield(); 
}

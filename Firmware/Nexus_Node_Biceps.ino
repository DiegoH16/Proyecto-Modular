#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>

const char* ssid = "AVA_NEXUS";       
const char* password = "ava_password"; 
const char* ip_broadcast = "192.168.4.255"; 
const int puerto_datos = 8889;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
MAX30105 particleSensor;
const int TAMANO_LOTE = 5;
int contador = 0;
char payload[512]; 
int payload_len = 0;

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
  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }
  
  Wire.begin(21, 22);
  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) { Serial.println("Error MAX"); while(1); }
  particleSensor.setup(60, 4, 2, 100, 411, 16384);

  struct timeval tv; gettimeofday(&tv, NULL);
  char sync_msg[100];
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,BICEPS,%lld,%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  udp_control.beginPacket(ip_broadcast, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();
  Serial.println("\n>>> BICEPS CONECTADO - MONITOR ACTIVO <<<");
}

void loop() {
  particleSensor.check();
  int samples = particleSensor.available();
  if (samples > 10) samples = 10;
  while (samples--) {
    uint32_t r = particleSensor.getFIFORed();
    uint32_t ir = particleSensor.getFIFOIR();
    struct timeval tv; gettimeofday(&tv, NULL);
    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld,%06ld,%lu,%lu", (long long)tv.tv_sec, (long)tv.tv_usec, r, ir);
    uint16_t crc = crc16(linea, len);
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    if (added > 0) payload_len += added;
    contador++;
    if (contador >= TAMANO_LOTE) {
      udp_datos.beginPacket(ip_broadcast, puerto_datos);
      udp_datos.write((const uint8_t*)payload, payload_len);
      udp_datos.endPacket();
      
      // MONITOR TERMINAL
      Serial.println("\n[TX BICEPS]");
      Serial.print(payload);
      payload_len = 0; contador = 0; 
    }
    particleSensor.nextSample();
  }
}

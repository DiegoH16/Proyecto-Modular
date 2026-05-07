/*
 * DISPOSITIVO BÍCEPS: MAX30105 PPG Sensor
 * V3.1 PRODUCTION (FINAL)
 * Características: Sin Strings, NTP Sync (con Timeout), Buffers Estáticos, Batching, CRC16.
 * Envía: Timestamp_UNIX,Red_RAW,IR_RAW,CRC16\n
 */
#include <Wire.h>
#include "MAX30105.h"
#include <WiFi.h>
#include <WiFiUdp.h>
#include <time.h>
#include <sys/time.h>

// --- CONFIGURACIÓN DE RED ---
const char* ssid = "TU_SSID_AQUI";
const char* password = "TU_PASSWORD_AQUI";
const char* ip_matlab = "192.168.100.30";
const int puerto_datos = 8889;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
MAX30105 particleSensor;

// --- NTP SYNC ---
const char* ntpServer = "pool.ntp.org";
const long  gmtOffset_sec = 0; // Guardamos en UTC puro para sincronizar en MATLAB
const int   daylightOffset_sec = 0;

// --- BATCHING ESTÁTICO (C-Style) ---
const int TAMANO_LOTE = 5;
int contador = 0;
char payload[512]; // Buffer estático en lugar de String dinámica
int payload_len = 0;
bool sensor_ok = true;

// --- FUNCIONES AUXILIARES ---

// Cálculo de CRC16
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
  delay(1000);
  
  // --- CONEXIÓN WIFI ---
  WiFi.begin(ssid, password);
  int intentos = 0;
  while (WiFi.status() != WL_CONNECTED && intentos < 20) {
    delay(500);
    Serial.print(".");
    intentos++;
  }
  
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\n[ERROR] WiFi no conectado. Reiniciando...");
    ESP.restart();
  }
  Serial.println("\n[OK] WiFi Conectado!");
  Serial.print("IP: "); Serial.println(WiFi.localIP());

  // --- SINCRONIZACIÓN NTP (CON TIMEOUT) ---
  configTime(gmtOffset_sec, daylightOffset_sec, ntpServer);
  struct tm timeinfo;
  Serial.print("Sincronizando hora NTP");
  
  unsigned long ntpInicio = millis();
  bool ntpExitoso = false;
  
  // Intentar sincronizar por máximo 10 segundos
  while (millis() - ntpInicio < 10000) {
    if (getLocalTime(&timeinfo, 10)) { 
      ntpExitoso = true;
      break;
    }
    Serial.print(".");
    delay(500);
  }

  if (ntpExitoso) {
    Serial.println("\n[OK] Hora NTP Sincronizada!");
  } else {
    Serial.println("\n[WARN] Timeout NTP. Usando tiempo local Epoch 0.");
  }

  // --- INICIALIZACIÓN DE HARDWARE ---
  Wire.begin(21, 22);
  Wire.setClock(100000); // MAX30105 opera de manera estable a 100kHz

  if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
    Serial.println("[ERROR] MAX30105 no encontrado!");
    sensor_ok = false;
    delay(1000);
    ESP.restart();
  }

  // Configuración de grado médico
  particleSensor.setup(60, 4, 2, 100, 411, 16384);
  particleSensor.setPulseAmplitudeRed(0x7A);
  particleSensor.setPulseAmplitudeIR(0x3F);

  // --- SINCRONIZACIÓN INICIAL CON MATLAB ---
  struct timeval tv;
  gettimeofday(&tv, NULL);
  char sync_msg[100];
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,BICEPS,%lld.%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  
  udp_control.beginPacket(ip_matlab, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();
  Serial.println("[OK] SYNC enviado a MATLAB");

  // Limpiar buffer
  payload_len = 0;
  memset(payload, 0, sizeof(payload));
}

void loop() {
  particleSensor.check();

  // --- VERIFICACIÓN DE SALUD I2C ---
  static int health_check = 0;
  if (++health_check >= 100) {
    Wire.beginTransmission(0x57); // Dirección I2C del MAX30105
    if (Wire.endTransmission() != 0) {
      Serial.println("[WARN] I2C check failed! Posible desconexión del MAX30105.");
      udp_control.beginPacket(ip_matlab, puerto_control);
      udp_control.print("ERROR,I2C_LOST,BICEPS\n");
      udp_control.endPacket();
      // Intentar reconectar sin usar excepciones
      if (!particleSensor.begin(Wire, I2C_SPEED_STANDARD)) {
        ESP.restart();
      }
    }
    health_check = 0;
  }

  // --- VACIADO DEL FIFO Y CONSTRUCCIÓN DE PAQUETES ---
  while (particleSensor.available()) {
    
    // Obtener Tiempo UNIX Real (Segundos + Microsegundos)
    struct timeval tv;
    gettimeofday(&tv, NULL);

    uint32_t red_raw = particleSensor.getFIFORed();
    uint32_t ir_raw = particleSensor.getFIFOIR();

    // Validar rango (MAX30105: típicamente 0-262144)
    if (red_raw > 300000 || ir_raw > 300000) {
      Serial.println("[WARN] Valor fuera de rango detectado, descartando");
      particleSensor.nextSample();
      continue;
    }

    // 1. Formatear datos en una línea temporal
    char linea[128];
    int len = snprintf(linea, sizeof(linea), "%lld.%06ld,%lu,%lu", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, 
                       (unsigned long)red_raw, (unsigned long)ir_raw);

    // 2. Calcular CRC16 de la línea
    uint16_t crc = crc16(linea, len);

    // 3. Añadir línea + CRC al payload estático
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    if (added > 0 && added < (sizeof(payload) - payload_len)) {
        payload_len += added;
    }

    contador++;

    // --- ENVÍO POR LOTE (BATCHING) ---
    if (contador >= TAMANO_LOTE) {
      udp_datos.beginPacket(ip_matlab, puerto_datos);
      udp_datos.write((const uint8_t*)payload, payload_len);
      udp_datos.endPacket();

      // Reiniciar buffer y contador
      payload_len = 0;
      contador = 0;
    }

    particleSensor.nextSample();
  }

  delay(1); // Yield para permitir que el stack de red WiFi procese en background
}

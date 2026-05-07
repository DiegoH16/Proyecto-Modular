/*
 * DISPOSITIVO TOBILLO: MPU6050 + EMG (V3.2 OFFLINE AP MODE FINAL)
 * Funciona como Router (Access Point). No requiere Internet.
 * Envía: Timestamp_UNIX_sec, Timestamp_UNIX_usec, Ax, Ay, Az, EMG_RAW, CRC16\n
 */
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <sys/time.h>

// --- CONFIGURACIÓN DE RED (MODO PUNTO DE ACCESO) ---
const char* ssid = "AVA_NEXUS";        // Nombre de la red Wi-Fi que creará el Tobillo
const char* password = "ava_password"; // Contraseña de la red

// ⚠️ MUY IMPORTANTE: IP DE TU COMPUTADORA ⚠️
// Por defecto, al primer dispositivo en conectarse le suele dar la 192.168.4.2
const char* ip_matlab = "192.168.4.2"; 

const int puerto_datos = 8888;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
Adafruit_MPU6050 mpu;

// --- PINES Y MUESTREO ---
const int PIN_EMG = 4; // ADC1_CH3 en ESP32
const int FRECUENCIA_HZ = 50;
const unsigned long INTERVALO_US = 1000000 / FRECUENCIA_HZ; // 20ms exactos

// --- BATCHING ESTÁTICO ---
const int TAMANO_LOTE = 5;
int contador = 0;
char payload[512]; 
int payload_len = 0;
unsigned long ultimo_muestreo_us = 0;

// Cálculo de CRC16 (Modbus 0xA001)
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
  
  // --- CREAR RED WIFI (MODO PUNTO DE ACCESO) ---
  Serial.println("\n[SETUP] Iniciando Modo Router (Access Point)...");
  WiFi.mode(WIFI_AP);
  WiFi.softAP(ssid, password);
  delay(500);
  
  Serial.println("[OK] Red AVA_NEXUS Creada!");
  Serial.print("IP del Tobillo (Router): ");
  Serial.println(WiFi.softAPIP()); // Normalmente será 192.168.4.1

  // --- INICIALIZACIÓN DE HARDWARE ---
  Wire.begin(21, 22);
  Wire.setClock(400000); // 400kHz Fast I2C para el MPU6050

  if (!mpu.begin()) {
    Serial.println("[ERROR] MPU6050 no encontrado!");
    delay(1000); ESP.restart();
  }

  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ); 

  analogReadResolution(12);

  // --- SYNC INICIAL A MATLAB ---
  struct timeval tv; gettimeofday(&tv, NULL);
  char sync_msg[100];
  // SEPARADO POR COMA: Segundos, Microsegundos
  snprintf(sync_msg, sizeof(sync_msg), "SYNC,TOBILLO,%lld,%06ld\n", (long long)tv.tv_sec, (long)tv.tv_usec);
  udp_control.beginPacket(ip_matlab, puerto_control);
  udp_control.print(sync_msg);
  udp_control.endPacket();

  payload_len = 0; memset(payload, 0, sizeof(payload));
  ultimo_muestreo_us = micros();
}

void loop() {
  unsigned long t_actual = micros();

  // Temporizador estricto de 50 Hz por microsegundos
  if (t_actual - ultimo_muestreo_us >= INTERVALO_US) {
    ultimo_muestreo_us = t_actual;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);

    float ax = a.acceleration.x;
    float ay = a.acceleration.y;
    float az = a.acceleration.z;
    int emg_raw = analogRead(PIN_EMG);

    // Compuerta de seguridad de aceleración (Descartar ruido extremo)
    if (abs(ax) > 40.0 || abs(ay) > 40.0 || abs(az) > 40.0) return;

    struct timeval tv;
    gettimeofday(&tv, NULL);

    char linea[128];
    // SEPARADO POR COMA: Segundos, Microsegundos, Ax, Ay, Az, EMG
    int len = snprintf(linea, sizeof(linea), "%lld,%06ld,%.2f,%.2f,%.2f,%d", 
                       (long long)tv.tv_sec, (long)tv.tv_usec, ax, ay, az, emg_raw);

    // Calcular CRC16
    uint16_t crc = crc16(linea, len);
    
    // Anexar al payload estático
    int added = snprintf(payload + payload_len, sizeof(payload) - payload_len, "%s,%04X\n", linea, crc);
    
    if (added > 0 && added < (sizeof(payload) - payload_len)) {
        payload_len += added;
    }

    contador++;

    // Enviar lote de 5 muestras (Batching)
    if (contador >= TAMANO_LOTE) {
      udp_datos.beginPacket(ip_matlab, puerto_datos);
      udp_datos.write((const uint8_t*)payload, payload_len);
      udp_datos.endPacket();

      payload_len = 0; contador = 0; // Reset
    }
  }
  
  yield(); // Mantener estable el stack Wi-Fi
}

/*
 * DISPOSITIVO TOBILLO: MPU6050 + EMG
 * V3.0 PRODUCTION: Sincronización robusta, filtros desacoplados, validación
 * Envía: Tiempo_ms,Ax,Ay,Az,EMG,CRC16\n
 */
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>

// --- CONFIGURACIÓN ---
const char* ssid = "TU_SSID_AQUI";
const char* password = "TU_PASSWORD_AQUI";
const char* ip_matlab = "192.168.100.30";
const int puerto_datos = 8888;
const int puerto_control = 9999;

WiFiUDP udp_datos, udp_control;
Adafruit_MPU6050 mpu;

// --- PINES ---
const int PIN_EMG = 4; // ADC1_CH3 en ESP32

// --- PARÁMETROS DE MUESTREO ---
const int FRECUENCIA_HZ = 50;
const unsigned long INTERVALO_MS = 1000 / FRECUENCIA_HZ; // 20ms

// --- GESTIÓN DE TIEMPO ROBUSTO ---
struct {
  uint64_t ms_total = 0;
  uint32_t ms_last = 0;
  
  uint64_t getTotalMs() {
    uint32_t ms_now = millis();
    if (ms_now < ms_last) ms_total += 4294967296ULL;
    ms_last = ms_now;
    return ms_total + ms_now;
  }
} timeManager;

// --- FILTRADO SEPARADO ---
// Nota: DLPF nativa en MPU6050 @ 21 Hz ya está activa
// No aplicamos EMA adicional para evitar cascada de filtros
struct {
  float ax_last = 0, ay_last = 0, az_last = 0, emg_last = 0;
  bool first_read = true;
} filters;

// --- BATCHING ---
const int TAMANO_LOTE = 5;
int contador = 0;
String payload = "";
unsigned long ultimo_muestreo = 0;

// --- CRC16 ---
uint16_t crc16(String data) {
  uint16_t crc = 0xFFFF;
  for (int i = 0; i < data.length(); i++) {
    crc ^= (uint16_t)data[i];
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
  
  WiFi.begin(ssid, password);
  int intentos = 0;
  while (WiFi.status() != WL_CONNECTED && intentos < 20) {
    delay(500);
    Serial.print(".");
    intentos++;
  }
  
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\n[ERROR] WiFi no conectado!");
    ESP.restart();
  }
  Serial.println("\n[OK] WiFi Conectado!");

  // Inicializar I2C y MPU6050
  Wire.begin(21, 22);
  Wire.setClock(400000); // MPU6050 soporta 400kHz

  if (!mpu.begin()) {
    Serial.println("[ERROR] MPU6050 no encontrado!");
    delay(1000);
    ESP.restart();
  }

  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ); // DLPF nativa

  analogReadResolution(12);
  payload.reserve(300);

  ultimo_muestreo = millis();

  // Enviar SYNC a MATLAB
  delay(500);
  udp_control.beginPacket(ip_matlab, puerto_control);
  udp_control.print("SYNC,TOBILLO,");
  udp_control.print(timeManager.getTotalMs());
  udp_control.print("\n");
  udp_control.endPacket();
  Serial.println("[OK] SYNC enviado a MATLAB");
}

void loop() {
  unsigned long t_actual = millis();

  if (t_actual - ultimo_muestreo >= INTERVALO_MS) {
    ultimo_muestreo = t_actual;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);

    float ax = a.acceleration.x;
    float ay = a.acceleration.y;
    float az = a.acceleration.z;
    int emg_raw = analogRead(PIN_EMG);

    // Compuerta de aceleración (rechazar spikes)
    if (abs(ax) > 40.0 || abs(ay) > 40.0 || abs(az) > 40.0) {
      Serial.println("[WARN] Aceleración fuera de rango detectada");
      return;
    }

    // Inicializar filtros
    if (filters.first_read) {
      filters.ax_last = ax;
      filters.ay_last = ay;
      filters.az_last = az;
      filters.emg_last = emg_raw;
      filters.first_read = false;
      return; // Saltar la primera muestra
    }

    // NO aplicar EMA adicional - confiar en DLPF del MPU6050
    // Los datos ya están filtrados a 21 Hz

    uint64_t t_ms = timeManager.getTotalMs();
    String linea = String(t_ms) + "," + 
                   String(ax, 2) + "," + 
                   String(ay, 2) + "," + 
                   String(az, 2) + "," + 
                   String(emg_raw);
    String linea_con_crc = linea + "," + String(crc16(linea), HEX) + "\n";
    
    payload += linea_con_crc;
    contador++;

    if (contador >= TAMANO_LOTE) {
      udp_datos.beginPacket(ip_matlab, puerto_datos);
      udp_datos.print(payload);
      udp_datos.endPacket();

      payload = "";
      contador = 0;
    }

    // Verificación de salud I2C cada 100 muestras
    static int health_check = 0;
    if (++health_check >= 100) {
      Wire.beginTransmission(0x68); // Dirección MPU6050
      if (Wire.endTransmission() != 0) {
        Serial.println("[WARN] I2C check failed!");
        udp_control.beginPacket(ip_matlab, puerto_control);
        udp_control.print("ERROR,I2C_LOST\n");
        udp_control.endPacket();
        if (!mpu.begin()) ESP.restart();
      }
      health_check = 0;
    }
  }

  delay(1); // Yield
}

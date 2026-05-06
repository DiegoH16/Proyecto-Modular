/*
 * ========================================================================
 * DISPOSITIVO TOBILLO: Movimientos (MPU6050) + EMG 
 * Hardware: ESP32 + MPU6050 (I2C) + Sensor EMG (Pin Analógico 4)
 * ========================================================================
 */

#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <time.h>

// ─────────────────────────────────────────────────────────────────
// CONFIGURACIÓN WI-FI Y UDP
// ─────────────────────────────────────────────────────────────────
const char* ssid = "TU_SSID";              // ⚠️ CAMBIAR
const char* password = "TU_PASSWORD";      // ⚠️ CAMBIAR
const char* ip_computadora = "192.168.1.100";  // ⚠️ CAMBIAR (IP MATLAB)
const int puerto_udp = 8888;

// NTP Servers
const char* ntpServer = "pool.ntp.org";
const long gmtOffset_sec = -21600;        // México: UTC-6
const int daylightOffset_sec = 0;

WiFiUDP udp;
Adafruit_MPU6050 mpu;

// ─────────────────────────────────────────────────────────────────
// PINES Y CONSTANTES
// ─────────────────────────────────────────────────────────────────
const int PIN_EMG = 4;                     // Pin ADC válido para ESP32
const int FRECUENCIA_MUESTREO_HZ = 50;     // Coincide con MATLAB
const unsigned long INTERVALO_US = 1000000UL / FRECUENCIA_MUESTREO_HZ; // EXACTAMENTE 20,000 us

// ─────────────────────────────────────────────────────────────────
// VARIABLES DE FILTRADO (EMA)
// ─────────────────────────────────────────────────────────────────
float axFiltro = 0, ayFiltro = 0, azFiltro = 0, emgFiltro = 0;

// Filtros para detección AASM
const float ALPHA_IMU = 0.05;   // Filtro suave IMU
const float ALPHA_EMG = 0.20;   // Envolvente EMG

bool primeraLectura = true;

// ─────────────────────────────────────────────────────────────────
// CALIBRACIÓN EMG Y MPU
// ─────────────────────────────────────────────────────────────────
struct {
    float offset = 0.0;
    bool calibrado = false;
    uint32_t muestras_calibracion = 100;  // 2 seg @ 50Hz
} EMG_CAL;

struct {
    float bias_x = 0.0;
    float bias_y = 0.0;
    float bias_z = 0.0;
    bool calibrado = false;
} MPU_CAL;

// ─────────────────────────────────────────────────────────────────
// TIMESTAMPS Y RELOJ DRIFT-FREE
// ─────────────────────────────────────────────────────────────────
bool use_ntp = false;           
unsigned long time_offset_ms = 0; 
unsigned long ultimo_millis_valido = 0;
const unsigned long MAX_MILLIS = 4294967295UL; 

// Acumulador de microsegundos para evitar deriva temporal (Drift-free)
unsigned long previousMicros = 0;

// ─────────────────────────────────────────────────────────────────
// FUNCIONES DE INICIALIZACIÓN
// ─────────────────────────────────────────────────────────────────

void setupWiFi() {
    Serial.print("[SETUP] Conectando WiFi: ");
    Serial.println(ssid);
    
    WiFi.begin(ssid, password);
    int retries = 0;
    
    while (WiFi.status() != WL_CONNECTED && retries < 30) {
        delay(500);
        Serial.print(".");
        retries++;
    }
    
    if (WiFi.status() == WL_CONNECTED) {
        Serial.println("\n[SETUP] WiFi OK. IP: " + WiFi.localIP().toString());
    } else {
        Serial.println("\n[WARN] WiFi FALLO. Usando reloj local.");
        use_ntp = false;
    }
}

void setupNTP() {
    if (!use_ntp) return;
    
    Serial.print("[SETUP] Sincronizando NTP...");
    configTime(gmtOffset_sec, daylightOffset_sec, ntpServer);
    
    time_t now = time(nullptr);
    int ntp_retries = 0;
    
    while (now < 1577836800 && ntp_retries < 30) {  
        delay(100);
        now = time(nullptr);
        ntp_retries++;
    }
    
    if (now > 1577836800) {
        use_ntp = true;
        Serial.printf("\n[SETUP] NTP OK: %lu\n", now);
    } else {
        use_ntp = false;
        Serial.println("\n[WARN] NTP TIMEOUT");
    }
}

void setupMPU6050() {
    Serial.println("[SETUP] Inicializando MPU6050...");
    
    Wire.begin(21, 22);
    Wire.setClock(100000); // 100kHz para estabilidad I2C
    
    if (!mpu.begin()) {
        Serial.println("[ERROR] MPU6050 no detectado. Revisa I2C.");
        while (1) { delay(10); }
    }
    
    mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
    
    Serial.println("[SETUP] MPU6050 configurado");
    Serial.println("[SETUP] Calibrando MPU6050 en 2 segundos...");
    Serial.println("[SETUP] ⚠️  MANTÉN EL SENSOR EN REPOSO TOTAL");
    
    delay(2000);
    calibrateMPU6050();
}

void setupADC() {
    analogReadResolution(12);  // 12-bit: 0-4095
    Serial.println("[SETUP] ADC configurado (12-bit)");
}

void calibrateMPU6050() {
    float ax_sum = 0, ay_sum = 0, az_sum = 0;
    uint32_t samples = 100;  
    
    for (uint32_t i = 0; i < samples; i++) {
        sensors_event_t a, g, temp;
        mpu.getEvent(&a, &g, &temp);
        ax_sum += a.acceleration.x;
        ay_sum += a.acceleration.y;
        az_sum += a.acceleration.z;
        delay(20);
    }
    
    MPU_CAL.bias_x = ax_sum / samples;
    MPU_CAL.bias_y = ay_sum / samples;
    MPU_CAL.bias_z = (az_sum / samples) - 9.81;  // Descontar vector gravedad
    MPU_CAL.calibrado = true;
    
    Serial.printf("[CALIB] MPU Bias: [%.3f, %.3f, %.3f] m/s²\n",
                  MPU_CAL.bias_x, MPU_CAL.bias_y, MPU_CAL.bias_z);
}

void calibrateEMG() {
    Serial.println("[CALIB] Calibrando EMG (2 segundos en reposo)...");
    
    float sum = 0;
    for (uint32_t i = 0; i < EMG_CAL.muestras_calibracion; i++) {
        sum += analogRead(PIN_EMG);
        delay(20);
    }
    
    EMG_CAL.offset = sum / EMG_CAL.muestras_calibracion;
    EMG_CAL.calibrado = true;
    
    Serial.printf("[CALIB] EMG Offset DC (Línea Base): %.1f\n", EMG_CAL.offset);
}

uint32_t getTimestampMs() {
    unsigned long t_now = millis();
    
    if (t_now < ultimo_millis_valido) {
        time_offset_ms += MAX_MILLIS;  
    }
    ultimo_millis_valido = t_now;
    
    if (use_ntp) {
        time_t now = time(nullptr);
        return (uint32_t)(now * 1000);  
    } else {
        return t_now + time_offset_ms;
    }
}

// ─────────────────────────────────────────────────────────────────
// SETUP
// ─────────────────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(1000);
    
    Serial.println("\n╔════════════════════════════════════════════╗");
    Serial.println("║  AVA NEXUS V6.2 | TOBILLO v2.2 DRIFT-FREE  ║");
    Serial.println("╚════════════════════════════════════════════╝\n");
    
    setupADC();
    setupWiFi();
    
    if (WiFi.status() == WL_CONNECTED) {
        use_ntp = true;
        setupNTP();
    }
    
    setupMPU6050();
    delay(1000);
    calibrateEMG();
    
    Serial.println("[SETUP] ✅ LISTO. Iniciando adquisición estricta a 50Hz...\n");
    previousMicros = micros();
}

// ─────────────────────────────────────────────────────────────────
// LOOP PRINCIPAL (ZERO-DRIFT TIMING)
// ─────────────────────────────────────────────────────────────────
void loop() {
    unsigned long currentMicros = micros();
    
    // Ejecución EXACTA a 50.00 Hz (Cero Deriva Temporal en 10 horas)
    if (currentMicros - previousMicros >= INTERVALO_US) {
        // En lugar de resetear a currentMicros, SUMAMOS el intervalo.
        // Esto recupera cualquier microsegundo perdido por latencia WiFi.
        previousMicros += INTERVALO_US;
        
        // 1. Leer Sensores
        sensors_event_t a, g, temp;
        mpu.getEvent(&a, &g, &temp);
        int emgCrudo = analogRead(PIN_EMG);
        
        // 2. Filtro de Picos Anómalos de Hardware
        if (abs(a.acceleration.x) < 40.0 && abs(a.acceleration.y) < 40.0 && abs(a.acceleration.z) < 40.0) {
            
            if (primeraLectura) {
                axFiltro = a.acceleration.x; ayFiltro = a.acceleration.y; azFiltro = a.acceleration.z;
                emgFiltro = emgCrudo;
                primeraLectura = false;
            } else {
                axFiltro = (ALPHA_IMU * a.acceleration.x) + ((1.0 - ALPHA_IMU) * axFiltro);
                ayFiltro = (ALPHA_IMU * a.acceleration.y) + ((1.0 - ALPHA_IMU) * ayFiltro);
                azFiltro = (ALPHA_IMU * a.acceleration.z) + ((1.0 - ALPHA_IMU) * azFiltro);
                emgFiltro = (ALPHA_EMG * emgCrudo)   + ((1.0 - ALPHA_EMG) * emgFiltro);
            }
            
            // 3. Calibración y Corrección
            float ax_corrected = axFiltro - MPU_CAL.bias_x;
            float ay_corrected = ayFiltro - MPU_CAL.bias_y;
            float az_corrected = azFiltro - MPU_CAL.bias_z;
            
            // Centrar el EMG (Quitar el DC Offset para MATLAB)
            float emg_centrado = emgFiltro - EMG_CAL.offset;
            
            // 4. Timestamp y Envío UDP
            uint32_t t_send = getTimestampMs();
            
            udp.beginPacket(ip_computadora, puerto_udp);
            udp.print(t_send);           udp.print(",");
            udp.print(ax_corrected, 3);  udp.print(",");
            udp.print(ay_corrected, 3);  udp.print(",");
            udp.print(az_corrected, 3);  udp.print(",");
            udp.print(emg_centrado, 2);  udp.print("\n");
            udp.endPacket();
            
            // 5. Debug (Cada ~2 segundos)
            static int debug_counter = 0;
            if (debug_counter++ >= 100) {
                debug_counter = 0;
                Serial.printf("[DATA] t=%lu | ax=%.2f | ay=%.2f | az=%.2f | emg_c=%.2f\n",
                              t_send, ax_corrected, ay_corrected, az_corrected, emg_centrado);
            }
        }
    }
    
    // Evita que el Watchdog del ESP32 se reinicie
    yield();
}

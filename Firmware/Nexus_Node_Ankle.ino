/*
 * =========================================================================
 * DISPOSITIVO TOBILLO: Movimientos (MPU6050) + EMG (Muestreo Continuo)
 * Hardware: ESP32 + MPU6050 (I2C) + Sensor EMG (Pin Analógico 4)
 * =========================================================================
  */
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <time.h>              // Para SNTP
#include <sys/time.h>

// --- CONFIGURACIÓN WI-FI ---
const char* ssid = "TU_SSID_AQUI"; 
const char* password = "TU_PASSWORD_AQUI"; 
const int MAX_REINTENTOS_WIFI = 20;
const unsigned long TIMEOUT_WIFI_MS = 10000;

// --- CONFIGURACIÓN UDP ---
const char* ip_computadora = "192.168.100.30";
const int puerto_udp = 8888;
const unsigned long TIMEOUT_UDP_MS = 3000;
const int MAX_REINTENTOS_UDP = 3;

// --- CONFIGURACIÓN SNTP (Sincronización temporal absoluta) ---
const char* ntpServer = "pool.ntp.org";
const long gmtOffset_sec = -6 * 3600;              // UTC-6 (Centro México)
const int daylightOffset_sec = 0;

WiFiUDP udp;
Adafruit_MPU6050 mpu;

// --- PINES Y CONSTANTES ---
const int PIN_EMG = 4;                     // Pin ADC válido para el ESP32
const int FRECUENCIA_MUESTREO_HZ = 50;      
const unsigned long INTERVALO_MS = 1000 / FRECUENCIA_MUESTREO_HZ;  // 20 ms

// --- VARIABLES DE FILTRADO (EMA) ---
float axFiltro = 0, ayFiltro = 0, azFiltro = 0, emgFiltro = 0;
const float ALPHA_IMU = 0.4;  
const float ALPHA_EMG = 0.15; 
bool primeraLectura = true;   

// --- CONTROL DE TIEMPO ---
unsigned long tiempoInicio = 0;
unsigned long ultimoMuestreo = 0;
unsigned long ultimoEnvioPaquete = 0;
unsigned long ultimoLogDiagnostico = 0;

// --- OPTIMIZACIÓN DE ENVÍO (BATCHING) ---
const int TAMANO_LOTE = 5; 
const unsigned long TIMEOUT_LOTE_MS = 500;  // Envío forzado después de 500ms sin lote completo
int contadorMuestras = 0;
String payloadUDP = "";
unsigned long tiempoInicioLote = 0;

// --- ESTADÍSTICAS ---
unsigned long contadorEnviosTotales = 0;
unsigned long contadorMuestrasTotales = 0;
unsigned long contadorErroresUDP = 0;
unsigned long contadorDesconexiones = 0;

// --- PROTOTIPOS ---
void sincronizarNTP();
bool conectarWiFi();
bool enviarPaqueteUDP();
void logearDiagnosticos();

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println("\n\n========================================");
  Serial.println("AVA NEXUS | ESP32 TOBILLO V3.0");
  Serial.println("Medical Grade EMG + IMU Sensor Node");
  Serial.println("========================================\n");

  // --- Inicializar MPU6050 ---
  Serial.println("[SETUP] Inicializando MPU6050...");
  if (!mpu.begin()) {
    Serial.println("[ERROR] MPU6050 NO DETECTADO. Revisa I2C (SDA=21, SCL=22)");
    while (1) { delay(100); } 
  }
  Serial.println("[OK] MPU6050 inicializado correctamente.");

  // Configuración de Hardware
  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setGyroRange(MPU6050_RANGE_500_DEG);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
  
  Serial.println("[OK] Configuración MPU6050 aplicada (Rango: ±4G, DLPF: 21 Hz).");
  
  analogReadResolution(12); 
  Serial.println("[OK] Resolución ADC ESP32 configurada a 12 bits.");

  // Reservar memoria
  payloadUDP.reserve(300);
  Serial.println("[OK] Memoria preallocada para UDP batching.");

  // --- Conectar WiFi ---
  Serial.println("\n[SETUP] Conectando a WiFi...");
  if (!conectarWiFi()) {
    Serial.println("[ERROR] No se pudo conectar a WiFi. Reiniciando...");
    delay(5000);
    ESP.restart();
  }

  // --- Sincronizar NTP ---
  Serial.println("\n[SETUP] Sincronizando hora (NTP)...");
  sincronizarNTP();
  
  Serial.print("[OK] Hora sincronizada: ");
  time_t ahora = time(nullptr);
  Serial.println(ctime(&ahora));

  tiempoInicio = millis();
  tiempoInicioLote = tiempoInicio;
  ultimoLogDiagnostico = tiempoInicio;

  Serial.println("\n[INFO] Sistema listo. Iniciando captura a 50 Hz...\n");
}

void loop() {
  unsigned long t_actual = millis();

  // --- RECONEXIÓN WIFI AUTOMÁTICA ---
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WARN] WiFi desconectado. Intentando reconectar...");
    contadorDesconexiones++;
    conectarWiFi();
  }

  // --- MUESTREO ESTRICTO A 50 Hz ---
  if (t_actual - ultimoMuestreo >= INTERVALO_MS) {
    ultimoMuestreo = t_actual;

    sensors_event_t a, g, temp;
    
    // Validación: lectura fallida del MPU6050
    if (!mpu.getEvent(&a, &g, &temp)) {
      Serial.println("[ERROR] Fallo en lectura de MPU6050. Saltando muestra.");
      return;
    }
    
    int emgCrudo = analogRead(PIN_EMG);

    // --- VALIDACIÓN DE RANGOS FÍSICOS ---
    if (abs(a.acceleration.x) >= 40.0 || abs(a.acceleration.y) >= 40.0 || abs(a.acceleration.z) >= 40.0) {
      Serial.printf("[WARN] Aceleración fuera de rango: [%.2f, %.2f, %.2f] m/s². Saltando.\n", 
                    a.acceleration.x, a.acceleration.y, a.acceleration.z);
      return;
    }

    // EMG válido: 0-4095 (12-bit)
    if (emgCrudo < 0 || emgCrudo > 4095) {
      Serial.printf("[WARN] EMG fuera de rango: %d. Saltando.\n", emgCrudo);
      return;
    }

    // --- APLICACIÓN DE FILTROS EMA ---
    if (primeraLectura) {
      axFiltro = a.acceleration.x;
      ayFiltro = a.acceleration.y;
      azFiltro = a.acceleration.z;
      emgFiltro = emgCrudo;
      primeraLectura = false;
      Serial.println("[OK] Valores iniciales de filtros establecidos.");
    } else {
      axFiltro = (ALPHA_IMU * a.acceleration.x) + ((1.0 - ALPHA_IMU) * axFiltro);
      ayFiltro = (ALPHA_IMU * a.acceleration.y) + ((1.0 - ALPHA_IMU) * ayFiltro);
      azFiltro = (ALPHA_IMU * a.acceleration.z) + ((1.0 - ALPHA_IMU) * azFiltro);
      emgFiltro = (ALPHA_EMG * emgCrudo) + ((1.0 - ALPHA_EMG) * emgFiltro);
    }

    // --- CONSTRUCCIÓN DE LÍNEA DE DATOS ---
    payloadUDP += String(t_actual - tiempoInicio) + ",";
    payloadUDP += String(axFiltro, 2) + ",";
    payloadUDP += String(ayFiltro, 2) + ",";
    payloadUDP += String(azFiltro, 2) + ",";
    payloadUDP += String((int)emgFiltro) + "\n";
    
    contadorMuestras++;
    contadorMuestrasTotales++;

    // --- LÓGICA DE ENVÍO BATCHING ---
    bool enviarAhora = false;

    // Condición 1: Lote completo
    if (contadorMuestras >= TAMANO_LOTE) {
      enviarAhora = true;
    }
    // Condición 2: Timeout de lote (500 ms sin completar)
    else if ((t_actual - tiempoInicioLote) >= TIMEOUT_LOTE_MS && contadorMuestras > 0) {
      Serial.printf("[INFO] Timeout de lote (%lu ms). Enviando %d muestras.\n", 
                    TIMEOUT_LOTE_MS, contadorMuestras);
      enviarAhora = true;
    }

    if (enviarAhora) {
      if (enviarPaqueteUDP()) {
        contadorEnviosTotales++;
        ultimoEnvioPaquete = t_actual;
      }
      payloadUDP = "";
      contadorMuestras = 0;
      tiempoInicioLote = t_actual;
    }
  }

  // --- LOGGING DE DIAGNÓSTICO CADA 10 SEGUNDOS ---
  if (millis() - ultimoLogDiagnostico >= 10000) {
    logearDiagnosticos();
    ultimoLogDiagnostico = millis();
  }

  yield(); // Permitir que el watchdog y otras tareas se ejecuten
}

// --- FUNCIÓN: Conectar a WiFi con reintentos ---
bool conectarWiFi() {
  int intentos = 0;
  WiFi.begin(ssid, password);
  
  while (WiFi.status() != WL_CONNECTED && intentos < MAX_REINTENTOS_WIFI) {
    delay(500);
    Serial.print(".");
    intentos++;
  }
  
  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\n[OK] WiFi conectado!");
    Serial.print("    IP: "); Serial.println(WiFi.localIP());
    Serial.print("    RSSI: "); Serial.print(WiFi.RSSI()); Serial.println(" dBm");
    return true;
  } else {
    Serial.println("\n[ERROR] No se pudo conectar a WiFi tras " + String(MAX_REINTENTOS_WIFI) + " intentos.");
    return false;
  }
}

// --- FUNCIÓN: Sincronizar hora mediante NTP ---
void sincronizarNTP() {
  configTime(gmtOffset_sec, daylightOffset_sec, ntpServer);
  
  Serial.print("[INFO] Esperando sincronización NTP ");
  time_t ahora = time(nullptr);
  int intentos = 0;
  
  while (ahora < 24 * 3600 && intentos < 20) {
    delay(500);
    Serial.print(".");
    ahora = time(nullptr);
    intentos++;
  }
  
  Serial.println();
  if (ahora > 24 * 3600) {
    Serial.println("[OK] NTP sincronizado exitosamente.");
  } else {
    Serial.println("[WARN] NTP no respondió, usando reloj local.");
  }
}

// --- FUNCIÓN: Enviar paquete UDP con reintentos ---
bool enviarPaqueteUDP() {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WARN] WiFi no conectado. No se puede enviar UDP.");
    contadorErroresUDP++;
    return false;
  }

  int intentos = 0;
  while (intentos < MAX_REINTENTOS_UDP) {
    try {
      udp.beginPacket(ip_computadora, puerto_udp);
      size_t bytesEscritos = udp.print(payloadUDP);
      
      if (udp.endPacket()) {
        // Éxito
        return true;
      } else {
        Serial.printf("[WARN] endPacket() falló en intento %d/%d\n", intentos + 1, MAX_REINTENTOS_UDP);
        intentos++;
        delay(10);
      }
    } catch (...) {
      Serial.printf("[ERROR] Excepción UDP en intento %d/%d\n", intentos + 1, MAX_REINTENTOS_UDP);
      intentos++;
      delay(10);
    }
  }
  
  Serial.println("[ERROR] No se pudo enviar paquete UDP después de " + String(MAX_REINTENTOS_UDP) + " intentos.");
  contadorErroresUDP++;
  return false;
}

// --- FUNCIÓN: Logging de diagnósticos ---
void logearDiagnosticos() {
  Serial.println("\n========== DIAGNÓSTICO (10 seg) ==========");
  Serial.printf("Muestras totales:    %lu\n", contadorMuestrasTotales);
  Serial.printf("Paquetes enviados:   %lu\n", contadorEnviosTotales);
  Serial.printf("Errores UDP:         %lu\n", contadorErroresUDP);
  Serial.printf("Desconexiones WiFi:  %lu\n", contadorDesconexiones);
  Serial.printf("Frecuencia efectiva: %.1f Hz\n", (float)contadorMuestrasTotales / 10.0);
  Serial.printf("WiFi RSSI:           %d dBm\n", WiFi.RSSI());
  
  time_t ahora = time(nullptr);
  Serial.printf("Hora del sistema:    %s\n", ctime(&ahora));
  Serial.println("==========================================\n");
}


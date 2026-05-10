% Copyright 2026 Diego Gutiérrez Hermosillo Medina, Obed Simón Aceves Gutiérrez
    %
    % Licensed under the Apache License, Version 2.0 (the "License");
    % you may not use this file except in compliance with the License.
    % You may obtain a copy of the License at
    %
    %     http://www.apache.org/licenses/LICENSE-2.0
    %
    % Unless required by applicable law or agreed to in writing, software
    % distributed under the License is distributed on an "AS IS" BASIS,
    % WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    % See the License for the specific language governing permissions and
    % limitations under the License.

function AVA_Core_System()
    
    clearvars; clc; close all force;
    
    %% --- 1. CONFIGURACIÓN CLÍNICA ESTRICTA ---
    Config = struct();
    Config.Puertos.Tobillo = 8888; 
    Config.Puertos.Biceps  = 8889; 
    
    Config.Muestreo.Fs_Hz  = 100; 
    Config.Muestreo.VentanaGrafica_s = 60; 
    
    Config.BufferMax.Horas = 10;
    Config.BufferMax.Muestras = Config.Muestreo.Fs_Hz * 3600 * Config.BufferMax.Horas; 
    
    Config.UI.RefrescoGraficas_Muestras = 10; 
    Config.Backup.MuestrasIntervalo = Config.Muestreo.Fs_Hz * 300;
    
    Config.Umbrales.IR_Minimo_Dedo = 3000;
    
    % Umbrales predeterminados
    Config.Umbrales.EMG_Contraccion = 50; 
    Config.Umbrales.SVM_Movimiento = 0.4;  
    
    Config.Filtros.Alpha_SVM = 0.005; 
    Config.Filtros.Alpha_EMG_HP = 0.05; 
    Config.Filtros.Alpha_EMG_LP = 0.1;  
    
    %% --- 2. ESTADO GLOBAL Y RING BUFFER EXPANDIDO ---
    RingBuffer = struct();
    RingBuffer.T       = zeros(1, Config.BufferMax.Muestras);      
    RingBuffer.Ax      = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.Ay      = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.Az      = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.EMG_Raw = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.Red_Raw = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.IR_Raw  = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.EMG_Env = zeros(1, Config.BufferMax.Muestras);   
    RingBuffer.SVM_Ac  = zeros(1, Config.BufferMax.Muestras);  
    RingBuffer.SPO2    = zeros(1, Config.BufferMax.Muestras);   
    RingBuffer.BPM     = zeros(1, Config.BufferMax.Muestras);      
    RingBuffer.Anot    = logical(zeros(1, Config.BufferMax.Muestras));  
    RingBuffer.Idx     = 1;      
    RingBuffer.Count   = 0;  
    RingBuffer.Full    = false; 
    
    Estado = struct();
    Estado.Capturando = false;
    
    % --- TIEMPO LOCAL DE LA PC ---
    Estado.TiempoTobillo = 0.0;
    Estado.TiempoBiceps = 0.0;
    
    Estado.DedoDetectado = false; 
    Estado.UltimoBackupIdx = 1;
    
    % Autocalibración con control de calidad
    Estado.Calibracion = struct('Activa', true, 'Cuenta', 0);
    Estado.Calibracion.MuestrasDescarte = Config.Muestreo.Fs_Hz * 5;  
    Estado.Calibracion.MuestrasRequeridas = Config.Muestreo.Fs_Hz * 30; 
    
    numMuestrasValidas = Estado.Calibracion.MuestrasRequeridas - Estado.Calibracion.MuestrasDescarte;
    Estado.Calibracion.EMG_Data = zeros(1, numMuestrasValidas);
    Estado.Calibracion.SVM_Data = zeros(1, numMuestrasValidas);
    
    Estado.DSP.EMG_Baseline = 0;
    Estado.DSP.EMG_Envelope = 0;
    Estado.DSP.SVM_Baseline = 1.0;    
    
    Estado.Vitales.UltimoRed = 0;
    Estado.Vitales.UltimoIR = 0;
    Estado.Vitales.SPO2 = 98;
    Estado.Vitales.BPM = 70;
    Estado.Vitales.BufferRed = zeros(1, Config.Muestreo.Fs_Hz * 30); 
    Estado.Vitales.BufferIR  = zeros(1, Config.Muestreo.Fs_Hz * 30);
    
    Estado.UI.ContraccionPrevia = false;
    Estado.UI.MuestrasRecibidas = 0;
    Estado.UI.MuestrasDesdeUltimoBackup = 0;
    Estado.UI.SPO2Text = '';
    Estado.UI.BPMText = '';
    
    Analisis = struct('T', [], 'Anotaciones', [], 'EventosPLM', [], 'IdxNav', 0, 'TotPLM', 0, 'TotEpisodios', 0);
    Archivos = struct('Senales', "", 'Anotaciones', "");
    Red = struct('UdpTobillo', [], 'UdpBiceps', []);
    
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));
    
    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA ---
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus V7.5 | Host-Sync Telemetry', 'Color', 'w', 'Position', [50, 50, 1200, 900]);
    UI.Fig.CloseRequestFcn = @(src, event) cerrarAplicacion(src, event);
    UI.AxesAnaLista = [];
    
    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    
    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS V7.5', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [450, 650, 400, 60], 'HorizontalAlignment', 'center');
    uibutton(UI.PnlMenu, 'Text', '1. Adquisición de Datos (UDP)', 'FontSize', 18, 'Position', [400, 450, 400, 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clínico (SPI)', 'FontSize', 18, 'Position', [400, 350, 400, 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAna));
    
    gAdq = uigridlayout(UI.PnlAdq, [6, 3], 'RowHeight', {'1x', '1x', 80, 70, 60, 60}, 'Padding', 20);
    
    UI.axEMG_TR = uiaxes(gAdq); title(UI.axEMG_TR, 'EMG Envolvente (AD8232 + DSP)'); UI.axEMG_TR.Layout.Row = 1; UI.axEMG_TR.Layout.Column = [1 3];
    UI.axSVM_TR = uiaxes(gAdq); title(UI.axSVM_TR, 'Actigrafía SVM (DSP)'); UI.axSVM_TR.Layout.Row = 2; UI.axSVM_TR.Layout.Column = [1 3];
    
    numPuntosGrafica = 6000; 
    UI.lineaEMG = animatedline(UI.axEMG_TR, 'Color', [1 0.5 0], 'LineWidth', 1.5, 'MaximumNumPoints', numPuntosGrafica); 
    UI.lineaSVM = animatedline(UI.axSVM_TR, 'Color', [0 0.4 1], 'LineWidth', 1.5, 'MaximumNumPoints', numPuntosGrafica); 
    
    pnlVit = uigridlayout(gAdq, [1, 2]); pnlVit.Layout.Row = 3; pnlVit.Layout.Column = [1 3];
    UI.lblSPO2 = uilabel(pnlVit, 'Text', '--% SpO2', 'FontSize', 45, 'FontWeight', 'bold', 'FontColor', [0 0.4 0.8], 'HorizontalAlignment', 'center'); 
    UI.lblBPM  = uilabel(pnlVit, 'Text', '-- BPM', 'FontSize', 45, 'FontWeight', 'bold', 'HorizontalAlignment', 'center'); 
    
    pnlDet = uipanel(gAdq, 'BackgroundColor', [0.95 0.95 0.95]); pnlDet.Layout.Row = 4; pnlDet.Layout.Column = [1 3];
    gDet = uigridlayout(pnlDet, [1, 1]);
    UI.lblLed = uilabel(gDet, 'Text', ' EN ESPERA ', 'FontSize', 22, 'FontWeight', 'bold', 'BackgroundColor', [0.5 0.5 0.5], 'FontColor', 'w', 'HorizontalAlignment', 'center');
    UI.lblInfo = uilabel(gAdq, 'Text', 'Listo.', 'FontSize', 12, 'HorizontalAlignment', 'center');
    UI.lblInfo.Layout.Row = 5; UI.lblInfo.Layout.Column = [1 2];
    
    UI.lblMemoria = uilabel(gAdq, 'Text', 'RAM: --', 'FontSize', 12, 'HorizontalAlignment', 'right');
    UI.lblMemoria.Layout.Row = 5; UI.lblMemoria.Layout.Column = 3;
    UI.btnUDP = uibutton(gAdq, 'Text', '▶ Conectar Hardware', 'FontSize', 16, 'FontWeight', 'bold', 'BackgroundColor', [0.2 0.6 0.2], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) alternarCaptura());
    UI.btnUDP.Layout.Row = 6; UI.btnUDP.Layout.Column = [1 2];
    
    btnExp = uibutton(gAdq, 'Text', 'Finalizar y Exportar', 'FontSize', 14, 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) detenerYExportar());
    btnExp.Layout.Row = 6; btnExp.Layout.Column = 3;
    
    gAna = uigridlayout(UI.PnlAna, [2, 1], 'RowHeight', {45, '1x'}, 'Padding', 5);
    gToolbar = uigridlayout(gAna, [1, 10], 'ColumnWidth', {120, 120, 120, 40, 80, 80, 60, '1x', 140, 80}, 'Padding', 2);
    
    uibutton(gToolbar, 'Text', '📁 Cargar CSV', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) cargarArchivo('DATOS'));
    uibutton(gToolbar, 'Text', '📝 Cargar TXT', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) cargarArchivo('ANOT'));
    
    UI.lblArchivoData = uilabel(gToolbar, 'Text', '...', 'FontSize', 9, 'FontColor', [0.4 0.4 0.4], 'WordWrap', 'off');
    
    uilabel(gToolbar, 'Text', '|', 'HorizontalAlignment', 'center');
    uibutton(gToolbar, 'Text', '<< Ant', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) navegarEpisodios(-1));
    uibutton(gToolbar, 'Text', 'Sig >>', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) navegarEpisodios(1));
    uibutton(gToolbar, 'Text', 'Todo', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) verTodoAnalisis());
    
    UI.lblEpi = uilabel(gToolbar, 'Text', 'SPI: 0 / 0 | Episodios: --', 'FontSize', 13, 'FontWeight', 'bold', 'FontColor', [0.7 0.1 0.1], 'HorizontalAlignment', 'center');
    
    uibutton(gToolbar, 'Text', '⚙️ PROCESAR', 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'FontSize', 12, 'FontWeight', 'bold', 'ButtonPushedFcn', @(src, event) ejecutarAnalisisPro());
    uibutton(gToolbar, 'Text', 'Volver', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlMenu));
    UI.pnlGraficasAna = uipanel(gAna, 'BorderType', 'none', 'BackgroundColor', 'w');
    
    %% --- 4. BUCLE PRINCIPAL (OOM-Safe & Batching) ---
    while ishandle(UI.Fig)
        try
            if Estado.Capturando 
                
                % Lectura de paquetes (Ignorando las marcas de tiempo del ESP32 internamente)
                lineasB = leerYValidarBatch(Red.UdpBiceps, 5, 'BICEPS'); 
                lineasT = leerYValidarBatch(Red.UdpTobillo, 7, 'TOBILLO'); 
                
                % --- PROCESAMIENTO DEL BÍCEPS (SPO2/BPM) ---
                if ~isempty(lineasB)
                    for i = 1:size(lineasB, 1)
                        datosB = lineasB(i,:);
                        % datosB = [Sec, uSec, Red_Raw, IR_Raw, CRC] (Parseado parcial)
                        
                        red_raw = datosB(3);
                        ir_raw = datosB(4);
                        
                        Estado.Vitales.UltimoRed = red_raw;
                        Estado.Vitales.UltimoIR  = ir_raw;
                        Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed(2:end), red_raw]; 
                        Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR(2:end), ir_raw];
                        Estado.DedoDetectado = (ir_raw > Config.Umbrales.IR_Minimo_Dedo);
                        
                        % Avanzamos el reloj interno del Biceps a 100Hz
                        Estado.TiempoBiceps = Estado.TiempoBiceps + (1.0 / Config.Muestreo.Fs_Hz);
                    end
                end

                % --- PROCESAMIENTO DEL TOBILLO (EMG/SVM) ---
                if ~isempty(lineasT)
                    for i = 1:size(lineasT, 1)
                        datosT = lineasT(i,:);
                        
                        % Tiempo generado localmente, fluido y perfecto
                        tRelativo = Estado.TiempoTobillo;
                        Estado.TiempoTobillo = Estado.TiempoTobillo + (1.0 / Config.Muestreo.Fs_Hz);
                        
                        ax = datosT(3); ay = datosT(4); az = datosT(5);
                        emg_crudo = datosT(6);
                        
                        Estado.DSP.EMG_Baseline = (1 - Config.Filtros.Alpha_EMG_HP) * Estado.DSP.EMG_Baseline + (Config.Filtros.Alpha_EMG_HP * emg_crudo);
                        emg_ac = abs(emg_crudo - Estado.DSP.EMG_Baseline); 
                        Estado.DSP.EMG_Envelope = (1 - Config.Filtros.Alpha_EMG_LP) * Estado.DSP.EMG_Envelope + (Config.Filtros.Alpha_EMG_LP * emg_ac);
                        
                        svm_crudo = sqrt(sum([ax, ay, az].^2));
                        Estado.DSP.SVM_Baseline = (1 - Config.Filtros.Alpha_SVM) * Estado.DSP.SVM_Baseline + (Config.Filtros.Alpha_SVM * svm_crudo);
                        svm_ac = abs(svm_crudo - Estado.DSP.SVM_Baseline);
                        
                        if Estado.Calibracion.Activa
                            Estado.Calibracion.Cuenta = Estado.Calibracion.Cuenta + 1;
                            
                            if Estado.Calibracion.Cuenta > Estado.Calibracion.MuestrasDescarte
                                idx = Estado.Calibracion.Cuenta - Estado.Calibracion.MuestrasDescarte;
                                Estado.Calibracion.EMG_Data(idx) = Estado.DSP.EMG_Envelope;
                                Estado.Calibracion.SVM_Data(idx) = svm_ac;
                            end
                            
                            pct = round(100 * Estado.Calibracion.Cuenta / Estado.Calibracion.MuestrasRequeridas);
                            
                            if Estado.Calibracion.Cuenta <= Estado.Calibracion.MuestrasDescarte
                                UI.lblInfo.Text = sprintf('ESTABILIZANDO SEÑAL... %d%%', pct);
                                UI.lblInfo.FontColor = [0.8 0.1 0];
                            else
                                UI.lblInfo.Text = sprintf('CALIBRANDO UMBRALES... %d%%', pct);
                                UI.lblInfo.FontColor = [0.8 0.4 0];
                            end
                            
                            if Estado.Calibracion.Cuenta >= Estado.Calibracion.MuestrasRequeridas
                                std_emg = std(Estado.Calibracion.EMG_Data);
                                std_svm = std(Estado.Calibracion.SVM_Data);
                                
                                if std_emg > 80 || std_svm > 0.5 
                                    logSistema('WARN', 'Exceso de movimiento en calibración. Reiniciando.');
                                    UI.lblInfo.Text = '¡RUIDO EXCESIVO! REINICIANDO...';
                                    UI.lblInfo.FontColor = [1 0 0];
                                    Estado.Calibracion.Cuenta = 0; 
                                else
                                    Config.Umbrales.EMG_Contraccion = mean(Estado.Calibracion.EMG_Data) + 5 * std_emg;
                                    Config.Umbrales.SVM_Movimiento  = mean(Estado.Calibracion.SVM_Data) + 5 * std_svm;
                                    
                                    Config.Umbrales.EMG_Contraccion = max(10, Config.Umbrales.EMG_Contraccion);
                                    Config.Umbrales.SVM_Movimiento  = max(0.1, Config.Umbrales.SVM_Movimiento);
                                    
                                    Estado.Calibracion.Activa = false;
                                    UI.lblInfo.Text = sprintf('Thr EMG: %.1f | Thr SVM: %.2f', Config.Umbrales.EMG_Contraccion, Config.Umbrales.SVM_Movimiento);
                                    UI.lblInfo.FontColor = [0 0.6 0];
                                end
                            end
                        end
                        
                        contraccionActual = (Estado.DSP.EMG_Envelope > Config.Umbrales.EMG_Contraccion) && (svm_ac > Config.Umbrales.SVM_Movimiento);
                        
                        addpoints(UI.lineaEMG, tRelativo, Estado.DSP.EMG_Envelope);
                        addpoints(UI.lineaSVM, tRelativo, svm_ac);
                        
                        if mod(Estado.UI.MuestrasRecibidas, Config.UI.RefrescoGraficas_Muestras) == 0
                            if contraccionActual ~= Estado.UI.ContraccionPrevia
                                if contraccionActual
                                    UI.lblLed.BackgroundColor = [0.2 0.8 0.2]; UI.lblLed.Text = ' CONTRACCIÓN ';
                                else
                                    UI.lblLed.BackgroundColor = [0.8 0.2 0.2]; UI.lblLed.Text = ' REPOSO ';
                                end
                                Estado.UI.ContraccionPrevia = contraccionActual;
                            end
                            actualizarEjesGrafica([UI.axEMG_TR, UI.axSVM_TR], tRelativo, Config.Muestreo.VentanaGrafica_s);
                        end
                        
                        if mod(Estado.UI.MuestrasRecibidas, 100) == 0 
                            [tempSPO2, tempBPM, is_artifact] = detectarBPMRobusto(Estado.Vitales.BufferRed, Estado.Vitales.BufferIR, Config.Muestreo.Fs_Hz); 
                            
                            if Estado.Calibracion.Activa
                                nuevoSPO2 = '--% (Calibrando)';
                                nuevoBPM  = '-- (Calibrando)';
                                UI.lblSPO2.FontColor = [0.5 0.5 0.5]; 
                                Estado.Vitales.SPO2 = 0; 
                                Estado.Vitales.BPM = 0;
                            else
                                if Estado.DedoDetectado
                                    if ~is_artifact && tempSPO2 > 0 && tempBPM > 0
                                        Estado.Vitales.SPO2 = tempSPO2;
                                        Estado.Vitales.BPM = tempBPM;
                                        nuevoSPO2 = sprintf('%d%% SpO2', round(Estado.Vitales.SPO2));
                                        nuevoBPM  = sprintf('%d BPM', round(Estado.Vitales.BPM));
                                        UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                                    else
                                        nuevoSPO2 = sprintf('%d%% (RUIDO)', round(Estado.Vitales.SPO2));
                                        nuevoBPM  = sprintf('%d (RUIDO)', round(Estado.Vitales.BPM));
                                        UI.lblSPO2.FontColor = [0.8 0.4 0]; 
                                    end
                                else
                                    nuevoSPO2 = 'SIN DEDO'; nuevoBPM = '--- BPM'; 
                                    UI.lblSPO2.FontColor = [0.8 0.2 0.2]; 
                                    Estado.Vitales.SPO2 = 0;
                                    Estado.Vitales.BPM = 0;
                                end
                            end
                            
                            if ~strcmp(Estado.UI.SPO2Text, nuevoSPO2)
                                UI.lblSPO2.Text = nuevoSPO2; Estado.UI.SPO2Text = nuevoSPO2;
                            end
                            if ~strcmp(Estado.UI.BPMText, nuevoBPM)
                                UI.lblBPM.Text = nuevoBPM; Estado.UI.BPMText = nuevoBPM;
                            end
                            mostrarMemoriaSegura();
                        end
                        
                        Estado.UI.MuestrasDesdeUltimoBackup = Estado.UI.MuestrasDesdeUltimoBackup + 1;
                        if Estado.UI.MuestrasDesdeUltimoBackup > Config.Backup.MuestrasIntervalo
                            backupIncrementalOptimizado(RingBuffer, Estado.UltimoBackupIdx, Config.BufferMax.Muestras);
                            Estado.UltimoBackupIdx = RingBuffer.Idx;
                            Estado.UI.MuestrasDesdeUltimoBackup = 0;
                        end
                        
                        guardarEnRingBuffer(tRelativo, ax, ay, az, emg_crudo, Estado.Vitales.UltimoRed, Estado.Vitales.UltimoIR, ...
                                            Estado.DSP.EMG_Envelope, svm_ac, Estado.Vitales.SPO2, Estado.Vitales.BPM, contraccionActual, Config);
                        Estado.UI.MuestrasRecibidas = Estado.UI.MuestrasRecibidas + 1;
                    end
                end
            end
        catch excepcionMain
            logSistema('WARN', ['Excepción principal: ', excepcionMain.message]);
        end
        drawnow limitrate; 
        pause(0.001); 
    end
    
    %% --- 5. FUNCIONES PRINCIPALES DE CONTROL ---
    
    function alternarCaptura()
        Estado.Capturando = ~Estado.Capturando;
        if Estado.Capturando
            % REINICIO DE RELOJES MAESTROS PC-SIDE
            Estado.TiempoTobillo = 0.0;
            Estado.TiempoBiceps = 0.0;
            
            Estado.Calibracion.Activa = true;
            Estado.Calibracion.Cuenta = 0;
            
            Estado.DSP.EMG_Baseline = 0;
            Estado.DSP.EMG_Envelope = 0;
            Estado.DSP.SVM_Baseline = 1.0; 
            
            Estado.UI.ContraccionPrevia = false; Estado.UI.MuestrasRecibidas = 0;
            Estado.UI.MuestrasDesdeUltimoBackup = 0;
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.EventosPLM = []; Analisis.IdxNav = 0;

            try 
                Red.UdpTobillo = udpport("datagram", "LocalPort", Config.Puertos.Tobillo);
                Red.UdpTobillo.Timeout = 0.5;
            catch ME
                uialert(UI.Fig, ['Error Tobillo: ', ME.message], 'Error UDP'); 
                Estado.Capturando = false; return;
            end
            
            try 
                Red.UdpBiceps  = udpport("datagram", "LocalPort", Config.Puertos.Biceps);
                Red.UdpBiceps.Timeout = 0.5;
            catch ME
                clear Red.UdpTobillo; 
                uialert(UI.Fig, ['Error Bíceps: ', ME.message], 'Error UDP'); 
                Estado.Capturando = false; return;
            end
            
            UI.lblInfo.Text = "ESTABILIZANDO SEÑAL..."; UI.lblInfo.FontColor = [0.8 0.1 0];
            clearpoints(UI.lineaEMG); clearpoints(UI.lineaSVM); 
            UI.btnUDP.Text = "⏹ Detener"; UI.btnUDP.BackgroundColor = [1 0.4 0.4];
            
            fprintf('\n--- INICIANDO LECTURA DE SENSORES ---\n');
        else
            liberarRecursos(Red);
            UI.btnUDP.Text = "▶ Conectar Hardware"; UI.btnUDP.BackgroundColor = [0.2 0.6 0.2];
            UI.lblInfo.Text = "EN ESPERA"; UI.lblInfo.FontColor = [0.5 0.5 0.5];
            fprintf('\n*** ESCUCHA UDP DETENIDA ***\n');
        end
    end

    function detenerYExportar()
        Estado.Capturando = false; liberarRecursos(Red);
        if RingBuffer.Count == 0, uialert(UI.Fig, 'Sin datos.', 'Aviso'); return; end
        
        fStr = char(datetime('now', 'Format', 'yyyyMMdd_HHmm'));
        rutaSalida = fullfile(pwd, 'AVA_Nexus_Data');
        if ~isfolder(rutaSalida), mkdir(rutaSalida); end
        
        backupIncrementalOptimizado(RingBuffer, Estado.UltimoBackupIdx, Config.BufferMax.Muestras); 
        
        [t_d, ax_d, ay_d, az_d, emgRaw_d, red_d, ir_d, emgEnv_d, svmAc_d, spo2_d, bpm_d, anot_d] = descomprimirRingBufferCorregido();
        if isempty(t_d), return; end
        
        try
            nameCSV = fullfile(rutaSalida, sprintf('AVA_Estudio_DataLake_%s.csv', fStr));
            nameTXT = fullfile(rutaSalida, sprintf('AVA_Anotaciones_%s.txt', fStr));
            
            [anotFinal, epi, validosPLM] = procesarAASM(t_d, emgEnv_d, svmAc_d, spo2_d, Config.Muestreo.Fs_Hz, Config);
            
            fid = fopen(nameCSV, 'w');
            fprintf(fid, '# AVA Nexus V7.5 Data Lake (Host-Timed Edition)\n');
            fprintf(fid, '# Exportado: %s\n', char(datetime('now')));
            fprintf(fid, '# Fs_Hz: %d\n', Config.Muestreo.Fs_Hz);
            fprintf(fid, '# Thr_EMG: %.4f\n', Config.Umbrales.EMG_Contraccion);
            fprintf(fid, '# Thr_SVM: %.4f\n', Config.Umbrales.SVM_Movimiento);
            fprintf(fid, 'Time_s_Local,Ax,Ay,Az,EMG_Raw,Red_Raw,IR_Raw,EMG_Env,SVM_ac,SpO2_pct,BPM_bpm,AASM_SPI\n');
            
            for i = 1:length(t_d)
                fprintf(fid, '%.6f,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%.6f,%.6f,%d,%d,%d\n', ...
                        t_d(i), ax_d(i), ay_d(i), az_d(i), emgRaw_d(i), red_d(i), ir_d(i), emgEnv_d(i), svmAc_d(i), round(spo2_d(i)), round(bpm_d(i)), anotFinal(i));
            end
            fclose(fid);
            
            fidTxt = fopen(nameTXT, 'w');
            fprintf(fidTxt, 'Tiempo_s_Local,Anot_SPI\n');
            for i = 1:length(t_d), fprintf(fidTxt, '%.6f,%d\n', t_d(i), anotFinal(i)); end
            fclose(fidTxt);
            uialert(UI.Fig, sprintf('Exportado Correctamente:\n%d muestras', length(t_d)), 'Éxito');
        catch ME
            uialert(UI.Fig, sprintf('Error crítico de escritura.\nDetalle: %s', ME.message), 'Fallo Sistema');
        end
        cambiarPanel(UI.PnlMenu);
    end

    function ejecutarAnalisisPro()
        if Archivos.Senales == "", uialert(UI.Fig, 'Seleccione un CSV.', 'Aviso'); return; end
        try
            fid = fopen(Archivos.Senales, 'r');
            while ~feof(fid)
                lin = fgetl(fid);
                if ~ischar(lin) || ~startsWith(lin, '#'), break; end
                if contains(lin, 'Thr_EMG:')
                    partes = strsplit(lin, ':'); Config.Umbrales.EMG_Contraccion = str2double(partes{2});
                elseif contains(lin, 'Thr_SVM:')
                    partes = strsplit(lin, ':'); Config.Umbrales.SVM_Movimiento = str2double(partes{2});
                elseif contains(lin, 'Fs_Hz:')
                    partes = strsplit(lin, ':'); Config.Muestreo.Fs_Hz = str2double(partes{2});
                end
            end
            fclose(fid);
            
            logSistema('INFO', sprintf('Análisis Offline con Thr_EMG: %.2f y Thr_SVM: %.2f', Config.Umbrales.EMG_Contraccion, Config.Umbrales.SVM_Movimiento));

            data = readmatrix(Archivos.Senales, 'CommentStyle', '#');
            if size(data, 1) < 10, uialert(UI.Fig, 'CSV inválido o muy corto.', 'Error'); return; end
            
            numCols = size(data, 2);
            tieneSpO2 = true;
            
            if numCols == 12 
                vT = data(:,1); vEMG = data(:,8); vSVM = data(:,9); vSPO2 = data(:,10); vBPM = data(:,11);
            elseif numCols >= 6 
                vT = data(:,1); vEMG = data(:,2); vSVM = data(:,3); vSPO2 = data(:,4); vBPM = data(:,5);
            elseif numCols == 5 
                vT = data(:,1); vEMG = data(:,2); vSVM = data(:,3); 
                vSPO2 = ones(size(vT)) * 98; vBPM = data(:,4); tieneSpO2 = false;
                logSistema('WARN', 'CSV legado detectado sin SpO2. Exclusión respiratoria deshabilitada.');
            else
                uialert(UI.Fig, 'Formato CSV no reconocido.', 'Error'); return;
            end
            
            fsReal = 1 / mean(diff(vT), 'omitnan');
            [Analisis.Anotaciones, mEpi, validosPLM] = procesarAASM(vT, vEMG, vSVM, vSPO2, fsReal, Config);
            
            Analisis.EventosPLM = validosPLM; 
            Analisis.TotPLM = size(validosPLM, 1);
            Analisis.TotEpisodios = size(mEpi, 1);
            Analisis.T = vT; Analisis.IdxNav = 0;
            actualizarEtiquetaEpisodio(0, Analisis.TotPLM, Analisis.TotEpisodios);
            
            delete(UI.pnlGraficasAna.Children); 
            gGrid = uigridlayout(UI.pnlGraficasAna, [4, 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG Envolvente + PLM (AASM)'); hold(ax1,'on'); grid(ax1, 'on');
            plot(ax1, vT, vEMG, 'Color', [0.6 0.6 0.6]); 
            plot(ax1, vT, Analisis.Anotaciones * max(10, max(vEMG)), 'r', 'LineWidth', 1.5);
            
            ax2 = uiaxes(gGrid); title(ax2, 'Actigrafía SVM (Filtrada)'); plot(ax2, vT, vSVM, 'Color', [0 0.4 0.8]); grid(ax2, 'on');
            
            ax3 = uiaxes(gGrid); 
            if tieneSpO2
                title(ax3, 'SpO2 % (Detección Hipoxia)'); hold(ax3, 'on'); 
                plot(ax3, vT, vSPO2, 'g'); plot(ax3, vT, movmean(vSPO2, fsReal * 120), 'k--', 'LineWidth', 1); ylim(ax3, [85 100]); 
            else
                title(ax3, 'SpO2 % (Datos no disponibles en CSV)'); ylim(ax3, [0 100]);
            end
            
            ax4 = uiaxes(gGrid); title(ax4, 'BPM'); plot(ax4, vT, vBPM, 'r'); ylim(ax4, [40 160]); 
            
            UI.AxesAnaLista = [ax1, ax2, ax3, ax4]; 
            cambiarPanel(UI.PnlAna); navegarEpisodios(0);
        catch ME
            uialert(UI.Fig, sprintf('Error al procesar:\n%s', ME.message), 'Error');
        end
    end
    
    %% --- 6. FUNCIONES SECUNDARIAS (INCLUYE TELEMETRÍA) ---
    
    function dataOut = leerYValidarBatch(puerto, expectedCols, origenLog)
        dataOut = [];
        if isempty(puerto) || ~isvalid(puerto) || puerto.NumDatagramsAvailable == 0, return; end
        try
            paquetes = read(puerto, min(puerto.NumDatagramsAvailable, 50)); 
        catch, return; end
        
        columnasFinales = expectedCols - 1; % Solo exigimos las columnas de datos (sin el CRC)
        matrizTemporal = NaN(length(paquetes) * 10, columnasFinales);
        indiceValido = 0;
        
        for p = 1:length(paquetes)
            lineas = strsplit(char(paquetes(p).Data), '\n'); 
            for i = 1:length(lineas)
                strLine = strtrim(lineas{i});
                if isempty(strLine) || startsWith(strLine, '#'), continue; end
                
                % --- MONITOREO EN TERMINAL ---
                % Imprimimos aproximadamente 1 de cada 20 paquetes para visualizar sin trabar MATLAB
                if rand() < 0.05 
                    fprintf('[%s] %s\n', origenLog, strLine);
                end
                
                partes = strsplit(strLine, ',');
                
                % --- FLEXIBILIDAD EN LAS COLUMNAS Y CRC ---
                % Si el ESP manda menos columnas de las necesarias, avisamos y descartamos.
                if length(partes) < columnasFinales
                    if rand() < 0.05
                        fprintf('⚠️ ALERTA: [%s] trama incompleta. Recibido: %s\n', origenLog, strLine);
                    end
                    continue; 
                end

                % Extraemos únicamente las columnas numéricas que nos interesan,
                % ignorando silenciosamente si el CRC falla o no viene.
                nums = str2double(partes(1:columnasFinales));
                if any(isnan(nums)), continue; end
                
                indiceValido = indiceValido + 1;
                if indiceValido <= size(matrizTemporal, 1)
                    matrizTemporal(indiceValido, :) = nums;
                else
                    matrizTemporal = [matrizTemporal; nums]; %#ok<AGROW> 
                end
            end
        end
        if indiceValido > 0, dataOut = matrizTemporal(1:indiceValido, :); end
    end

    function crcHex = m_crc16(data)
        crc = uint16(hex2dec('FFFF'));
        bytes = uint8(char(data)); 
        for i = 1:length(bytes)
            crc = bitxor(crc, uint16(bytes(i)));
            for j = 1:8
                if bitand(crc, uint16(1)), crc = bitxor(bitshift(crc, -1), uint16(hex2dec('A001')));
                else, crc = bitshift(crc, -1); end
            end
        end
        crcHex = sprintf('%04X', crc);
    end

    function mostrarMemoriaSegura()
        if ispc
            try
                mem = memory();
                UI.lblMemoria.Text = sprintf('RAM: %.0f MB', mem.MemUsedMATLAB / 1024^2);
            catch
                UI.lblMemoria.Text = 'RAM: N/A';
            end
        end
    end

    function guardarEnRingBuffer(t, ax, ay, az, emgRaw, redRaw, irRaw, emgEnv, svm, spo2, bpm, anot, cfg)
        try
            idx = RingBuffer.Idx;
            if idx < 1 || idx > cfg.BufferMax.Muestras, return; end
            RingBuffer.T(idx) = t; RingBuffer.Ax(idx) = ax; RingBuffer.Ay(idx) = ay; RingBuffer.Az(idx) = az;
            RingBuffer.EMG_Raw(idx) = emgRaw; RingBuffer.Red_Raw(idx) = redRaw; RingBuffer.IR_Raw(idx) = irRaw;
            RingBuffer.EMG_Env(idx) = emgEnv; RingBuffer.SVM_Ac(idx) = svm; 
            RingBuffer.SPO2(idx) = spo2; RingBuffer.BPM(idx) = bpm; RingBuffer.Anot(idx) = anot;
            
            RingBuffer.Idx = uint32(mod(uint64(idx), uint64(cfg.BufferMax.Muestras))) + 1;
            if RingBuffer.Count < cfg.BufferMax.Muestras, RingBuffer.Count = RingBuffer.Count + 1;
            else, RingBuffer.Full = true; end
        catch, end
    end

    function [t, ax, ay, az, er, rr, ir, ee, sv, sp, b, a] = descomprimirRingBufferCorregido()
        c = RingBuffer.Count; nMax = Config.BufferMax.Muestras;
        if c == 0, t=[]; ax=[]; ay=[]; az=[]; er=[]; rr=[]; ir=[]; ee=[]; sv=[]; sp=[]; b=[]; a=[]; return; end
        if RingBuffer.Full, idxT = mod((0:c-1) + RingBuffer.Idx - 1, nMax) + 1; else, idxT = 1:c; end
        
        t = RingBuffer.T(idxT)'; ax = RingBuffer.Ax(idxT)'; ay = RingBuffer.Ay(idxT)'; az = RingBuffer.Az(idxT)';
        er = RingBuffer.EMG_Raw(idxT)'; rr = RingBuffer.Red_Raw(idxT)'; ir = RingBuffer.IR_Raw(idxT)';
        ee = RingBuffer.EMG_Env(idxT)'; sv = RingBuffer.SVM_Ac(idxT)'; 
        sp= RingBuffer.SPO2(idxT)'; b = RingBuffer.BPM(idxT)'; a = double(RingBuffer.Anot(idxT))';
    end

    function backupIncrementalOptimizado(RB, ultimoIdx, nMax)
        if RB.Count == 0, return; end
        if RB.Idx > ultimoIdx, idxs = ultimoIdx:(RB.Idx - 1); else, idxs = [ultimoIdx:nMax, 1:(RB.Idx - 1)]; end
        T_nuevo = RB.T(idxs); EMG_nuevo = RB.EMG_Env(idxs); SVM_nuevo = RB.SVM_Ac(idxs); %#ok<NASGU>
        rutaCache = fullfile(pwd, 'AVA_Nexus_Data', '.cache_incremental');
        if ~isfolder(rutaCache), mkdir(rutaCache); end
        try
            save(fullfile(rutaCache, sprintf('bkp_%s.mat', char(datetime('now', 'Format', 'HHmmss')))), 'T_nuevo', 'EMG_nuevo', 'SVM_nuevo', '-v6');
        catch, end
    end

    function [spo2, bpm, is_artifact] = detectarBPMRobusto(bR, bI, fs)
        spo2 = 0; bpm = 0; is_artifact = true;
        
        % Se requieren al menos 3 segundos de datos para estabilizar
        if length(bR) < fs * 3 || length(bI) < fs * 3, return; end
        
        % Filtro Pasa-Banda rústico para aislar el latido del corazón
        bI_DC = movmean(bI, fs * 2); 
        bI_AC = bI - bI_DC;
        bI_Filt = movmean(bI_AC, round(fs/10)); % Suavizado de alta frecuencia

        % Detección matemática de picos de pulso
        umbral = std(bI_Filt);
        [pks, locs] = findpeaks(bI_Filt, 'MinPeakHeight', umbral, 'MinPeakDistance', fs*0.3);
        
        if length(locs) < 2 || length(locs) > 10
            is_artifact = true;
            return;
        end
        
        % Calcular BPM
        intProm = mean(diff(locs)) / fs;
        bpmCalculado = 60 / intProm;
        
        if bpmCalculado < 40 || bpmCalculado > 200
             is_artifact = true;
             return;
        end
        
        bpm = bpmCalculado;
        
        % Calcular SPO2 via 'Ratio of Ratios'
        bR_DC = movmean(bR, fs * 2);
        bR_AC = bR - bR_DC;
        
        acR_RMS = rms(bR_AC); 
        acI_RMS = rms(bI_AC);
        dcR_mean = mean(bR_DC);
        dcI_mean = mean(bI_DC);
        
        if dcR_mean > 0 && dcI_mean > 0
            R = (acR_RMS / dcR_mean) / (acI_RMS / dcI_mean);
            spo2_calc = -45.060 * (R^2) + 30.354 * R + 94.845;
            
            spo2 = max(80, min(100, spo2_calc));
            is_artifact = false;
        end
    end
    
    function [anotFinal, mEpi, validosPLM] = procesarAASM(t, e, s, spo2_data, fs, cfg)
        t = t(:); e = e(:); s = s(:); spo2_data = spo2_data(:);
        
        emg_activo = e > cfg.Umbrales.EMG_Contraccion;
        svm_activo = s > cfg.Umbrales.SVM_Movimiento;
        fus = emg_activo & svm_activo;
        
        spo2_base = movmean(spo2_data, fs * 120);
        es_hipoxia = (spo2_base - spo2_data) >= 3;
        
        ventanaExclusion = round(fs * 10);
        exclusionRespiratoria = movmax(double(es_hipoxia), ventanaExclusion * 2) > 0;
        
        fl = diff([0; fus; 0]); iI = find(fl==1); iF = find(fl==-1)-1;
        iIU = []; iFU = [];
        
        if ~isempty(iI)
            cA = iI(1); cF = iF(1);
            for i = 2:length(iI)
                if (iI(i) - cF)/fs < 0.5, cF = iF(i); 
                else, iIU(end+1,1)=cA; iFU(end+1,1)=cF; cA=iI(i); cF=iF(i); end 
            end
            iIU(end+1,1)=cA; iFU(end+1,1)=cF;
        end
        
        mPlm_Candidatos = []; 
        for i = 1:length(iIU)
            dur = (iFU(i) - iIU(i)) / fs; 
            if dur >= 0.5 && dur <= 10.0
                if sum(exclusionRespiratoria(iIU(i):iFU(i))) == 0
                    mPlm_Candidatos = [mPlm_Candidatos; iIU(i), iFU(i)]; %#ok<AGROW>
                end
            end 
        end
        
        mEpi = []; validosPLM = []; 
        
        if ~isempty(mPlm_Candidatos)
            rt = mPlm_Candidatos(1,:);
            for j = 2:size(mPlm_Candidatos,1)
                inter = (mPlm_Candidatos(j,1) - rt(end,1)) / fs;
                if inter >= 5.0 && inter <= 90.0
                    rt = [rt; mPlm_Candidatos(j,:)]; %#ok<AGROW>
                else
                    if size(rt,1) >= 4 
                        mEpi = [mEpi; rt(1,1), rt(end,2), size(rt,1)]; %#ok<AGROW>
                        validosPLM = [validosPLM; rt]; %#ok<AGROW>
                    end
                    rt = mPlm_Candidatos(j,:); 
                end
            end
            if size(rt,1) >= 4 
                mEpi = [mEpi; rt(1,1), rt(end,2), size(rt,1)]; %#ok<AGROW>
                validosPLM = [validosPLM; rt]; %#ok<AGROW>
            end
        end
        
        anotFinal = zeros(length(t), 1); 
        for k = 1:size(validosPLM,1), anotFinal(validosPLM(k,1):validosPLM(k,2)) = 1; end
        anotFinal = anotFinal(:); 
    end
    
    function cargarArchivo(tipo)
        [n, r] = uigetfile({'*.csv;*.txt'});
        if ~isequal(n, 0)
            if strcmp(tipo, 'DATOS'), Archivos.Senales = fullfile(r, n); UI.lblArchivoData.Text = ['CSV: ' n];
            else, Archivos.Anotaciones = fullfile(r, n); UI.lblArchivoData.Text = [UI.lblArchivoData.Text ' | TXT: ' n]; end
        end
    end

    function actualizarEtiquetaEpisodio(idx, tPLM, tEpi)
        if idx < 0 || idx > tPLM || tPLM < 0, idx = 0; tPLM = 0; end
        try, UI.lblEpi.Text = sprintf('SPI: %d / %d | Episodios: %d', idx, tPLM, tEpi); catch, end
    end

    function navegarEpisodios(dir)
        if isempty(Analisis.EventosPLM) || isempty(UI.AxesAnaLista), return; end
        Analisis.IdxNav = max(1, min(Analisis.IdxNav + dir, size(Analisis.EventosPLM, 1)));
        actualizarEtiquetaEpisodio(Analisis.IdxNav, Analisis.TotPLM, Analisis.TotEpisodios);
        lim = [Analisis.T(Analisis.EventosPLM(Analisis.IdxNav,1)) - 5, Analisis.T(Analisis.EventosPLM(Analisis.IdxNav,2)) + 5];
        for i=1:length(UI.AxesAnaLista), xlim(UI.AxesAnaLista(i), lim); end
    end

    function verTodoAnalisis()
        if isempty(Analisis.T) || isempty(UI.AxesAnaLista) || length(Analisis.T) < 2, return; end
        lim = [Analisis.T(1), Analisis.T(end)]; 
        for i=1:length(UI.AxesAnaLista), xlim(UI.AxesAnaLista(i), lim); end
    end

    function actualizarEjesGrafica(ejes, tAct, vSeg)
        m = floor(tAct / vSeg); lInf = m * vSeg; lSup = (m + 1) * vSeg;
        for i = 1:length(ejes), xlim(ejes(i), [lInf, lSup]); end
    end

    function cambiarPanel(pTarget)
        cap = Estado.Capturando; if cap, Estado.Capturando = false; pause(0.05); end
        UI.PnlMenu.Visible = 'off'; UI.PnlAdq.Visible = 'off'; UI.PnlAna.Visible = 'off'; 
        pTarget.Visible = 'on'; 
        if cap, Estado.Capturando = true; end
    end

    function liberarRecursos(R)
        if isfield(R, 'UdpTobillo') && ~isempty(R.UdpTobillo) && isvalid(R.UdpTobillo), clear R.UdpTobillo; end
        if isfield(R, 'UdpBiceps') && ~isempty(R.UdpBiceps) && isvalid(R.UdpBiceps), clear R.UdpBiceps; end
    end

    function cerrarAplicacion(src, ~)
        Estado.Capturando = false; liberarRecursos(Red); delete(src);
    end

    function logSistema(nivel, mensaje)
        persistent t0
        if isempty(t0), t0 = datetime('now'); end
        try
            fprintf('[%8.2fs] [%-5s] %s\n', seconds(datetime('now') - t0), nivel, char(mensaje)); 
        catch, end
    end
end

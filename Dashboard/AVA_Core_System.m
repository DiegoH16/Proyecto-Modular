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
    Config = struct(...
        'Puertos', struct('Tobillo', 8888, 'Biceps', 8889), ...
        'Muestreo', struct('Fs_Hz', 100, 'VentanaGrafica_s', 60), ...
        'BufferMax', struct('Horas', 10, 'Muestras', 100 * 3600 * 10), ...
        'UI', struct('RefrescoGraficas_Muestras', 10), ...
        'Backup', struct('MuestrasIntervalo', 100 * 300), ... 
        'Umbrales', struct('IR_Minimo_Dedo', 3000, 'EMG_Contraccion', 50, 'SVM_Movimiento', 0.4), ...
        'Filtros', struct('Alpha_SVM', 0.005, 'Alpha_EMG_HP', 0.05, 'Alpha_EMG_LP', 0.1) ...
    );

    %% --- 2. ESTADO GLOBAL Y RING BUFFER EXPANDIDO ---
    N = Config.BufferMax.Muestras;
    RingBuffer = struct('T', zeros(1, N), 'Ax', zeros(1, N), 'Ay', zeros(1, N), 'Az', zeros(1, N), ...
                        'EMG_Raw', zeros(1, N), 'Red_Raw', zeros(1, N), 'IR_Raw', zeros(1, N), ...
                        'EMG_Env', zeros(1, N), 'SVM_Ac', zeros(1, N), 'SPO2', NaN(1, N), ...
                        'BPM', NaN(1, N), 'Anot', false(1, N), 'Idx', 1, 'Count', 0, 'Full', false);

    numCalibracion = Config.Muestreo.Fs_Hz * 25; 
    Estado = struct(...
        'Capturando', false, 't0_Tobillo', NaN, 'DedoDetectado', false, ...
        'UltimoBackupIdx', 1, ...
        'Calibracion', struct('Activa', true, 'Cuenta', 0, ...
                              'MuestrasDescarte', Config.Muestreo.Fs_Hz * 5, ...
                              'MuestrasRequeridas', Config.Muestreo.Fs_Hz * 30, ...
                              'EMG_Data', zeros(1, numCalibracion), 'SVM_Data', zeros(1, numCalibracion)), ...
        'DSP', struct('EMG_Baseline', 0, 'EMG_Envelope', 0, 'SVM_Baseline', 1.0), ...
        'Vitales', struct('UltimoRed', 0, 'UltimoIR', 0, 'SPO2', NaN, 'BPM', NaN, ...
                          'BufferRed', zeros(1, Config.Muestreo.Fs_Hz * 30), ...
                          'BufferIR', zeros(1, Config.Muestreo.Fs_Hz * 30)), ...
        'UI', struct('ContraccionPrevia', false, 'MuestrasRecibidas', 0, ...
                     'MuestrasDesdeUltimoBackup', 0, 'SPO2Text', '', 'BPMText', '') ...
    );

    Analisis = struct('T', [], 'Anotaciones', [], 'EventosPLM', [], 'IdxNav', 0, 'TotPLM', 0, 'TotEpisodios', 0);
    Archivos = struct('Senales', "", 'Anotaciones', "");
    Red = struct('UdpTobillo', [], 'UdpBiceps', []);
    
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));

    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA ---
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus V7.5 | Host-Sync Telemetry', 'Color', 'w', 'Position', [50, 50, 1200, 900]);
    UI.Fig.CloseRequestFcn = @cerrarAplicacion;
    UI.AxesAnaLista = [];

    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');

    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS V7.5', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [450, 650, 400, 60], 'HorizontalAlignment', 'center');
    uibutton(UI.PnlMenu, 'Text', '1. Adquisición de Datos (UDP)', 'FontSize', 18, 'Position', [400, 450, 400, 60], 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clínico (SPI)', 'FontSize', 18, 'Position', [400, 350, 400, 60], 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlAna));

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
    UI.btnUDP = uibutton(gAdq, 'Text', '▶ Conectar Hardware', 'FontSize', 16, 'FontWeight', 'bold', 'BackgroundColor', [0.2 0.6 0.2], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) alternarCaptura());
    UI.btnUDP.Layout.Row = 6; UI.btnUDP.Layout.Column = [1 2];

    btnExp = uibutton(gAdq, 'Text', 'Finalizar y Exportar', 'FontSize', 14, 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) detenerYExportar());
    btnExp.Layout.Row = 6; btnExp.Layout.Column = 3;

    gAna = uigridlayout(UI.PnlAna, [2, 1], 'RowHeight', {45, '1x'}, 'Padding', 5);
    gToolbar = uigridlayout(gAna, [1, 10], 'ColumnWidth', {120, 120, 120, 40, 80, 80, 60, '1x', 140, 80}, 'Padding', 2);

    uibutton(gToolbar, 'Text', '📁 Cargar CSV', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) cargarArchivo('DATOS'));
    uibutton(gToolbar, 'Text', '📝 Cargar TXT', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) cargarArchivo('ANOT'));

    UI.lblArchivoData = uilabel(gToolbar, 'Text', '...', 'FontSize', 9, 'FontColor', [0.4 0.4 0.4], 'WordWrap', 'off');
    uilabel(gToolbar, 'Text', '|', 'HorizontalAlignment', 'center');
    
    uibutton(gToolbar, 'Text', '<< Ant', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) navegarEpisodios(-1));
    uibutton(gToolbar, 'Text', 'Sig >>', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) navegarEpisodios(1));
    uibutton(gToolbar, 'Text', 'Todo', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) verTodoAnalisis());

    UI.lblEpi = uilabel(gToolbar, 'Text', 'SPI: 0 / 0 | Episodios: --', 'FontSize', 13, 'FontWeight', 'bold', 'FontColor', [0.7 0.1 0.1], 'HorizontalAlignment', 'center');

    uibutton(gToolbar, 'Text', '⚙️ PROCESAR', 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'FontSize', 12, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) ejecutarAnalisisPro());
    uibutton(gToolbar, 'Text', 'Volver', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlMenu));
    UI.pnlGraficasAna = uipanel(gAna, 'BorderType', 'none', 'BackgroundColor', 'w');

    %% --- 4. BUCLE PRINCIPAL (CRC + TIMESTAMPS HARDWARE) ---
    while ishandle(UI.Fig)
        if Estado.Capturando 
            try
                % Columnas esperadas incluyendo el CRC al final
                lineasB = leerYValidarBatch(Red.UdpBiceps, 5); 
                lineasT = leerYValidarBatch(Red.UdpTobillo, 7); 
                
                % --- PROCESAMIENTO DEL BÍCEPS ---
                for i = 1:size(lineasB, 1)
                    red_raw = lineasB(i, 3); ir_raw = lineasB(i, 4);
                    Estado.Vitales.UltimoRed = red_raw;
                    Estado.Vitales.UltimoIR  = ir_raw;
                    Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed(2:end), red_raw]; 
                    Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR(2:end), ir_raw];
                    Estado.DedoDetectado = (ir_raw > Config.Umbrales.IR_Minimo_Dedo);
                end

                % --- PROCESAMIENTO DEL TOBILLO (RELOJ MAESTRO) ---
                for i = 1:size(lineasT, 1)
                    t_abs = lineasT(i, 1) + lineasT(i, 2) / 1e6;
                    % Sincronización a cero y manejo de reinicios del ESP32
                    if isnan(Estado.t0_Tobillo) || t_abs < Estado.t0_Tobillo
                        Estado.t0_Tobillo = t_abs; 
                    end
                    tRelativo = t_abs - Estado.t0_Tobillo;
                    
                    ax = lineasT(i,3); ay = lineasT(i,4); az = lineasT(i,5); emg_crudo = lineasT(i,6);
                    
                    Estado.DSP.EMG_Baseline = (1 - Config.Filtros.Alpha_EMG_HP) * Estado.DSP.EMG_Baseline + (Config.Filtros.Alpha_EMG_HP * emg_crudo);
                    emg_ac = abs(emg_crudo - Estado.DSP.EMG_Baseline); 
                    Estado.DSP.EMG_Envelope = (1 - Config.Filtros.Alpha_EMG_LP) * Estado.DSP.EMG_Envelope + (Config.Filtros.Alpha_EMG_LP * emg_ac);
                    
                    svm_crudo = sqrt(ax^2 + ay^2 + az^2);
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
                            UI.lblInfo.Text = sprintf('ESTABILIZANDO SEÑAL... %d%%', pct); UI.lblInfo.FontColor = [0.8 0.1 0];
                        else
                            UI.lblInfo.Text = sprintf('CALIBRANDO UMBRALES... %d%%', pct); UI.lblInfo.FontColor = [0.8 0.4 0];
                        end
                        
                        if Estado.Calibracion.Cuenta >= Estado.Calibracion.MuestrasRequeridas
                            std_emg = std(Estado.Calibracion.EMG_Data); std_svm = std(Estado.Calibracion.SVM_Data);
                            if std_emg > 80 || std_svm > 0.5 
                                UI.lblInfo.Text = '¡RUIDO EXCESIVO! REINICIANDO...'; UI.lblInfo.FontColor = [1 0 0];
                                Estado.Calibracion.Cuenta = 0; 
                            else
                                Config.Umbrales.EMG_Contraccion = max(10, mean(Estado.Calibracion.EMG_Data) + 5 * std_emg);
                                Config.Umbrales.SVM_Movimiento  = max(0.1, mean(Estado.Calibracion.SVM_Data) + 5 * std_svm);
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
                            nuevoSPO2 = '--% (Calibrando)'; nuevoBPM = '-- (Calibrando)'; UI.lblSPO2.FontColor = [0.5 0.5 0.5]; 
                        elseif Estado.DedoDetectado
                            if ~is_artifact && ~isnan(tempSPO2) && ~isnan(tempBPM)
                                Estado.Vitales.SPO2 = tempSPO2; Estado.Vitales.BPM = tempBPM;
                                nuevoSPO2 = sprintf('%.0f%% SpO2', tempSPO2); nuevoBPM = sprintf('%.0f BPM', tempBPM);
                                UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                            else
                                nuevoSPO2 = sprintf('%.0f%% (RUIDO)', Estado.Vitales.SPO2); nuevoBPM = sprintf('%.0f (RUIDO)', Estado.Vitales.BPM);
                                UI.lblSPO2.FontColor = [0.8 0.4 0]; 
                            end
                        else
                            nuevoSPO2 = 'SIN DEDO'; nuevoBPM = '--- BPM'; UI.lblSPO2.FontColor = [0.8 0.2 0.2]; 
                            Estado.Vitales.SPO2 = NaN; Estado.Vitales.BPM = NaN;
                        end
                        
                        if ~strcmp(Estado.UI.SPO2Text, nuevoSPO2), UI.lblSPO2.Text = nuevoSPO2; Estado.UI.SPO2Text = nuevoSPO2; end
                        if ~strcmp(Estado.UI.BPMText, nuevoBPM), UI.lblBPM.Text = nuevoBPM; Estado.UI.BPMText = nuevoBPM; end
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
            catch ME
                logSistema('WARN', ['Excepción: ', ME.message]);
            end
        end
        drawnow limitrate; 
        pause(0.01); 
    end

    %% --- 5. FUNCIONES DE CONTROL PRINCIPALES ---
    function alternarCaptura()
        Estado.Capturando = ~Estado.Capturando;
        if Estado.Capturando
            Estado.t0_Tobillo = NaN; 
            Estado.Calibracion.Activa = true; Estado.Calibracion.Cuenta = 0;
            Estado.DSP.EMG_Baseline = 0; Estado.DSP.EMG_Envelope = 0; Estado.DSP.SVM_Baseline = 1.0; 
            Estado.UI.ContraccionPrevia = false; Estado.UI.MuestrasRecibidas = 0; Estado.UI.MuestrasDesdeUltimoBackup = 0;
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.EventosPLM = []; Analisis.IdxNav = 0;

            try 
                Red.UdpTobillo = udpport("datagram", "LocalPort", Config.Puertos.Tobillo); Red.UdpTobillo.Timeout = 0.5;
                Red.UdpBiceps  = udpport("datagram", "LocalPort", Config.Puertos.Biceps); Red.UdpBiceps.Timeout = 0.5;
            catch ME
                uialert(UI.Fig, ['Error UDP: ', ME.message], 'Error'); Estado.Capturando = false; return;
            end
            
            UI.lblInfo.Text = "ESTABILIZANDO SEÑAL..."; UI.lblInfo.FontColor = [0.8 0.1 0];
            clearpoints(UI.lineaEMG); clearpoints(UI.lineaSVM); 
            UI.btnUDP.Text = "⏹ Detener"; UI.btnUDP.BackgroundColor = [1 0.4 0.4];
        else
            liberarRecursos(Red);
            UI.btnUDP.Text = "▶ Conectar Hardware"; UI.btnUDP.BackgroundColor = [0.2 0.6 0.2];
            UI.lblInfo.Text = "EN ESPERA"; UI.lblInfo.FontColor = [0.5 0.5 0.5];
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
            [anotFinal, ~, ~] = procesarAASM(t_d, emgEnv_d, svmAc_d, spo2_d, Config.Muestreo.Fs_Hz, Config);
            
            fid = fopen(nameCSV, 'w');
            fprintf(fid, '# AVA Nexus V7.5 Data Lake (Hardware Timestamps)\n# Exportado: %s\n# Fs_Hz: %d\n# Thr_EMG: %.4f\n# Thr_SVM: %.4f\n', char(datetime('now')), Config.Muestreo.Fs_Hz, Config.Umbrales.EMG_Contraccion, Config.Umbrales.SVM_Movimiento);
            fprintf(fid, 'Time_s_Abs,Ax,Ay,Az,EMG_Raw,Red_Raw,IR_Raw,EMG_Env,SVM_ac,SpO2_pct,BPM_bpm,AASM_SPI\n');
            for i = 1:length(t_d)
                % Al usar %.0f los NaNs se registran correctamente en texto como 'NaN'
                fprintf(fid, '%.6f,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%.6f,%.6f,%.0f,%.0f,%d\n', t_d(i), ax_d(i), ay_d(i), az_d(i), emgRaw_d(i), red_d(i), ir_d(i), emgEnv_d(i), svmAc_d(i), spo2_d(i), bpm_d(i), anotFinal(i));
            end
            fclose(fid);
            
            fidTxt = fopen(nameTXT, 'w');
            fprintf(fidTxt, 'Tiempo_s_Abs,Anot_SPI\n');
            for i = 1:length(t_d), fprintf(fidTxt, '%.6f,%d\n', t_d(i), anotFinal(i)); end
            fclose(fidTxt);
            
            uialert(UI.Fig, sprintf('Exportado Correctamente:\n%d muestras', length(t_d)), 'Éxito');
        catch ME
            uialert(UI.Fig, ['Error crítico: ', ME.message], 'Fallo Sistema');
        end
        cambiarPanel(UI.PnlMenu);
    end

    function ejecutarAnalisisPro()
        if Archivos.Senales == "", uialert(UI.Fig, 'Seleccione un CSV.', 'Aviso'); return; end
        try
            data = readmatrix(Archivos.Senales, 'CommentStyle', '#');
            if size(data, 1) < 10, uialert(UI.Fig, 'CSV inválido o muy corto.', 'Error'); return; end
            
            numCols = size(data, 2); tieneSpO2 = true;
            if numCols >= 11
                vT = data(:,1); vEMG = data(:,8); vSVM = data(:,9); vSPO2 = data(:,10); vBPM = data(:,11);
            elseif numCols >= 5
                vT = data(:,1); vEMG = data(:,2); vSVM = data(:,3); vSPO2 = data(:,4); vBPM = data(:,5);
            else
                uialert(UI.Fig, 'Formato CSV no reconocido.', 'Error'); return;
            end
            
            fsReal = 1 / mean(diff(vT), 'omitnan');
            [Analisis.Anotaciones, mEpi, validosPLM] = procesarAASM(vT, vEMG, vSVM, vSPO2, fsReal, Config);
            
            Analisis.EventosPLM = validosPLM; Analisis.TotPLM = size(validosPLM, 1);
            Analisis.TotEpisodios = size(mEpi, 1); Analisis.T = vT; Analisis.IdxNav = 0;
            actualizarEtiquetaEpisodio(0, Analisis.TotPLM, Analisis.TotEpisodios);
            
            delete(UI.pnlGraficasAna.Children); 
            gGrid = uigridlayout(UI.pnlGraficasAna, [4, 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG Envolvente + PLM (AASM)'); hold(ax1,'on'); grid(ax1, 'on');
            plot(ax1, vT, vEMG, 'Color', [0.6 0.6 0.6]); plot(ax1, vT, Analisis.Anotaciones * max(10, max(vEMG)), 'r', 'LineWidth', 1.5);
            ax2 = uiaxes(gGrid); title(ax2, 'Actigrafía SVM'); plot(ax2, vT, vSVM, 'Color', [0 0.4 0.8]); grid(ax2, 'on');
            ax3 = uiaxes(gGrid); title(ax3, 'SpO2 % (Detección Hipoxia)'); hold(ax3, 'on'); 
            plot(ax3, vT, vSPO2, 'g'); plot(ax3, vT, movmean(vSPO2, fsReal * 120, 'omitnan'), 'k--', 'LineWidth', 1); ylim(ax3, [85 100]); 
            ax4 = uiaxes(gGrid); title(ax4, 'BPM'); plot(ax4, vT, vBPM, 'r'); ylim(ax4, [40 160]); 
            
            UI.AxesAnaLista = [ax1, ax2, ax3, ax4]; 
            cambiarPanel(UI.PnlAna); navegarEpisodios(0);
        catch ME
            uialert(UI.Fig, sprintf('Error al procesar:\n%s', ME.message), 'Error');
        end
    end

    %% --- 6. PARSEO, CRC Y NATIVAS ---
    
    function dataOut = leerYValidarBatch(puerto, expectedCols)
        dataOut = [];
        if isempty(puerto) || ~isvalid(puerto) || puerto.NumDatagramsAvailable == 0, return; end
        try paquetes = read(puerto, min(puerto.NumDatagramsAvailable, 50)); catch, return; end
        
        colsData = expectedCols - 1;
        matrizTemporal = NaN(numel(paquetes)*20, colsData);
        idx = 0;
        
        for p = 1:numel(paquetes)
            lineas = split(string(char(paquetes(p).Data)), newline);
            for j = 1:numel(lineas)
                str = strtrim(lineas(j));
                if strlength(str) < 5 || startsWith(str, '#'), continue; end
                
                % Validación CRC de seguridad
                idx_comma = strrfind(str, ',');
                if isempty(idx_comma), continue; end
                data_str = extractBefore(str, idx_comma);
                crc_str = extractAfter(str, idx_comma);
                
                if ~strcmpi(m_crc16(char(data_str)), crc_str), continue; end
                
                partes = split(str, ',');
                if numel(partes) >= colsData
                    nums = str2double(partes(1:colsData));
                    if ~any(isnan(nums))
                        idx = idx + 1;
                        matrizTemporal(idx, :) = nums';
                    end
                end
            end
        end
        if idx > 0, dataOut = matrizTemporal(1:idx, :); end
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

    function [spo2, bpm, is_artifact] = detectarBPMRobusto(bR, bI, fs)
        spo2 = NaN; bpm = NaN; is_artifact = true;
        if length(bR) < fs * 3 || length(bI) < fs * 3, return; end
        
        f_rms = @(x) sqrt(mean(x.^2, 'omitnan')); % RMS nativo sin Toolbox
        
        bI_DC = movmean(bI, fs * 2); bI_AC = bI - bI_DC; 
        bI_Filt = movmean(bI_AC, round(fs/10));
        
        % Detección de picos nativa
        umbral = std(bI_Filt, 'omitnan') * 0.5;
        dx = diff(bI_Filt);
        locs = find(dx(1:end-1) > 0 & dx(2:end) <= 0) + 1;
        locs = locs(bI_Filt(locs) > umbral);
        
        % MinPeakDistance restrictivo (~170 BPM Max)
        min_dist = fs * 0.35;
        valid_locs = [];
        if ~isempty(locs)
            valid_locs = locs(1);
            for p_idx = 2:length(locs)
                if (locs(p_idx) - valid_locs(end)) >= min_dist
                    valid_locs(end+1) = locs(p_idx);
                end
            end
        end
        locs = valid_locs;
        
        if length(locs) < 2 || length(locs) > 15, return; end
        bpmCalculado = 60 / (mean(diff(locs)) / fs);
        if bpmCalculado < 40 || bpmCalculado > 200, return; end
        
        bR_DC = movmean(bR, fs * 2); bR_AC = bR - bR_DC;
        dcR = mean(bR_DC, 'omitnan'); dcI = mean(bI_DC, 'omitnan');
        
        if dcR > 0 && dcI > 0
            R = (f_rms(bR_AC) / dcR) / (f_rms(bI_AC) / dcI);
            spo2 = max(80, min(100, -45.060 * (R^2) + 30.354 * R + 94.845));
            bpm = bpmCalculado; is_artifact = false;
        end
    end
    
    function [anotFinal, mEpi, validosPLM] = procesarAASM(t, e, s, spo2_data, fs, cfg)
        fus = (e > cfg.Umbrales.EMG_Contraccion) & (s > cfg.Umbrales.SVM_Movimiento);
        
        % Soporta NaNs en la detección
        spo2_base = movmean(spo2_data, fs * 120, 'omitnan');
        exclusionRespiratoria = movmax(double((spo2_base - spo2_data) >= 3), round(fs * 10) * 2) > 0;
        
        fl = diff([0; fus(:); 0]); iI = find(fl==1); iF = find(fl==-1)-1;
        mPlm_Candidatos = []; mEpi = []; validosPLM = [];
        
        if isempty(iI), anotFinal = zeros(size(t)); return; end
        
        cA = iI(1); cF = iF(1); iIU = []; iFU = [];
        for i = 2:length(iI)
            if (iI(i) - cF)/fs < 0.5, cF = iF(i); else, iIU(end+1,1)=cA; iFU(end+1,1)=cF; cA=iI(i); cF=iF(i); end %#ok<AGROW>
        end
        iIU(end+1,1)=cA; iFU(end+1,1)=cF;
        
        for i = 1:length(iIU)
            dur = (iFU(i) - iIU(i)) / fs; 
            if dur >= 0.5 && dur <= 10.0 && sum(exclusionRespiratoria(iIU(i):iFU(i))) == 0
                mPlm_Candidatos = [mPlm_Candidatos; iIU(i), iFU(i)]; %#ok<AGROW>
            end 
        end
        
        if ~isempty(mPlm_Candidatos)
            rt = mPlm_Candidatos(1,:);
            for j = 2:size(mPlm_Candidatos,1)
                inter = (mPlm_Candidatos(j,1) - rt(end,1)) / fs;
                if inter >= 5.0 && inter <= 90.0
                    rt = [rt; mPlm_Candidatos(j,:)]; %#ok<AGROW>
                else
                    if size(rt,1) >= 4, mEpi = [mEpi; rt(1,1), rt(end,2), size(rt,1)]; validosPLM = [validosPLM; rt]; end %#ok<AGROW>
                    rt = mPlm_Candidatos(j,:); 
                end
            end
            if size(rt,1) >= 4, mEpi = [mEpi; rt(1,1), rt(end,2), size(rt,1)]; validosPLM = [validosPLM; rt]; end
        end
        
        anotFinal = zeros(size(t)); 
        for k = 1:size(validosPLM,1), anotFinal(validosPLM(k,1):validosPLM(k,2)) = 1; end
    end

    %% --- 7. UTILIDADES DE MEMORIA Y ESTADO ---
    
    function guardarEnRingBuffer(t, ax, ay, az, emgRaw, redRaw, irRaw, emgEnv, svm, spo2, bpm, anot, cfg)
        idx = RingBuffer.Idx;
        RingBuffer.T(idx) = t; RingBuffer.Ax(idx) = ax; RingBuffer.Ay(idx) = ay; RingBuffer.Az(idx) = az;
        RingBuffer.EMG_Raw(idx) = emgRaw; RingBuffer.Red_Raw(idx) = redRaw; RingBuffer.IR_Raw(idx) = irRaw;
        RingBuffer.EMG_Env(idx) = emgEnv; RingBuffer.SVM_Ac(idx) = svm; 
        RingBuffer.SPO2(idx) = spo2; RingBuffer.BPM(idx) = bpm; RingBuffer.Anot(idx) = anot;
        
        RingBuffer.Idx = mod(idx, cfg.BufferMax.Muestras) + 1;
        if RingBuffer.Count < cfg.BufferMax.Muestras, RingBuffer.Count = RingBuffer.Count + 1; else, RingBuffer.Full = true; end
    end

    function [t, ax, ay, az, er, rr, ir, ee, sv, sp, b, a] = descomprimirRingBufferCorregido()
        c = RingBuffer.Count; nMax = Config.BufferMax.Muestras;
        if c == 0, t=[]; ax=[]; ay=[]; az=[]; er=[]; rr=[]; ir=[]; ee=[]; sv=[]; sp=[]; b=[]; a=[]; return; end
        if RingBuffer.Full, idxT = mod((0:c-1) + RingBuffer.Idx - 1, nMax) + 1; else, idxT = 1:c; end
        t = RingBuffer.T(idxT)'; ax = RingBuffer.Ax(idxT)'; ay = RingBuffer.Ay(idxT)'; az = RingBuffer.Az(idxT)';
        er = RingBuffer.EMG_Raw(idxT)'; rr = RingBuffer.Red_Raw(idxT)'; ir = RingBuffer.IR_Raw(idxT)';
        ee = RingBuffer.EMG_Env(idxT)'; sv = RingBuffer.SVM_Ac(idxT)'; 
        sp = RingBuffer.SPO2(idxT)'; b = RingBuffer.BPM(idxT)'; a = double(RingBuffer.Anot(idxT))';
    end

    function backupIncrementalOptimizado(RB, ultimoIdx, nMax)
        if RB.Count == 0, return; end
        if RB.Idx > ultimoIdx, idxs = ultimoIdx:(RB.Idx - 1); else, idxs = [ultimoIdx:nMax, 1:(RB.Idx - 1)]; end
        T_nuevo = RB.T(idxs); EMG_nuevo = RB.EMG_Env(idxs); SVM_nuevo = RB.SVM_Ac(idxs); %#ok<NASGU>
        rutaCache = fullfile(pwd, 'AVA_Nexus_Data', '.cache_incremental');
        if ~isfolder(rutaCache), mkdir(rutaCache); end
        try save(fullfile(rutaCache, sprintf('bkp_%s.mat', char(datetime('now', 'Format', 'HHmmss')))), 'T_nuevo', 'EMG_nuevo', 'SVM_nuevo', '-v6'); catch, end
    end

    function mostrarMemoriaSegura()
        if ispc
            try mem = memory(); UI.lblMemoria.Text = sprintf('RAM: %.0f MB', mem.MemUsedMATLAB / 1024^2); catch, UI.lblMemoria.Text = 'RAM: N/A'; end
        end
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
        try UI.lblEpi.Text = sprintf('SPI: %d / %d | Episodios: %d', idx, tPLM, tEpi); catch, end
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
        for i=1:length(UI.AxesAnaLista), xlim(UI.AxesAnaLista(i), [Analisis.T(1), Analisis.T(end)]); end
    end

    function actualizarEjesGrafica(ejes, tAct, vSeg)
        m = floor(tAct / vSeg); 
        for i = 1:length(ejes), xlim(ejes(i), [m * vSeg, (m + 1) * vSeg]); end
    end

    function cambiarPanel(pTarget)
        cap = Estado.Capturando; if cap, Estado.Capturando = false; pause(0.05); end
        UI.PnlMenu.Visible = 'off'; UI.PnlAdq.Visible = 'off'; UI.PnlAna.Visible = 'off'; pTarget.Visible = 'on'; 
        if cap, Estado.Capturando = true; end
    end

    function liberarRecursos(R)
        if isfield(R, 'UdpTobillo') && isvalid(R.UdpTobillo), clear R.UdpTobillo; end
        if isfield(R, 'UdpBiceps') && isvalid(R.UdpBiceps), clear R.UdpBiceps; end
    end

    function cerrarAplicacion(src, ~)
        Estado.Capturando = false; liberarRecursos(Red); delete(src);
    end

    function logSistema(nivel, mensaje)
        persistent t0; if isempty(t0), t0 = datetime('now'); end
        try fprintf('[%8.2fs] [%-5s] %s\n', seconds(datetime('now') - t0), nivel, char(mensaje)); catch, end
    end
end

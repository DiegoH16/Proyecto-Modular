%{
 Copyright 2026 Diego Gutiérrez Hermosillo Medina, Obed Simón Aceves Gutiérrez
  
    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at
   
        http://www.apache.org/licenses/LICENSE-2.0
    
    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
%}

function AVA_Core_System()
    clearvars; clc; close all force;
    
    %% --- 1. CONFIGURACIÓN CLÍNICA ESTRICTA (100 Hz) ---
    Config = struct();
    Config.Puertos.Tobillo = 8888;
    Config.Puertos.Biceps = 8889;
    Config.Muestreo.Fs_Hz = 100;
    Config.Muestreo.VentanaGrafica_s = 60;
    Config.BufferMax.Horas = 10;
    Config.BufferMax.Muestras = 100 * 3600 * 10;
    Config.UI.RefrescoGraficas_Muestras = 3; 
    Config.UI.RefrescoVitales_Muestras = 25;
    Config.Backup.MuestrasIntervalo = 100 * 300;
    Config.Umbrales.IR_Minimo_Dedo = 10000;
    Config.Umbrales.EMG_Contraccion = 50;
    Config.Umbrales.SVM_Movimiento = 0.4;
    Config.Filtros.Alpha_SVM = 0.005;
    Config.Filtros.Alpha_EMG_HP = 0.05;
    Config.Filtros.Alpha_EMG_LP = 0.1;

    %% --- 2. ESTADO GLOBAL Y RING BUFFER EXPANDIDO ---
    N = Config.BufferMax.Muestras;
    
    RingBuffer = struct();
    RingBuffer.T = zeros(1, N);
    RingBuffer.Ax = zeros(1, N);
    RingBuffer.Ay = zeros(1, N);
    RingBuffer.Az = zeros(1, N);
    RingBuffer.EMG_Raw = zeros(1, N);
    RingBuffer.Red_Raw = zeros(1, N);
    RingBuffer.IR_Raw = zeros(1, N);
    RingBuffer.EMG_Env = zeros(1, N);
    RingBuffer.SVM_Ac = zeros(1, N);
    RingBuffer.SPO2 = NaN(1, N);
    RingBuffer.BPM = NaN(1, N);
    RingBuffer.Anot = false(1, N);
    RingBuffer.Idx = 1;
    RingBuffer.Count = 0;
    RingBuffer.Full = false;

    numCalibracion = Config.Muestreo.Fs_Hz * 25; 
    
    Estado = struct();
    Estado.Capturando = false;
    Estado.t0_Tobillo = NaN;
    Estado.DedoDetectado = false;
    Estado.UltimoBackupIdx = 1;
    Estado.TiempoUltimoPaquete = tic;
    
    Estado.Calibracion.Activa = true;
    Estado.Calibracion.Cuenta = 0;
    Estado.Calibracion.MuestrasDescarte = Config.Muestreo.Fs_Hz * 5;
    Estado.Calibracion.MuestrasRequeridas = Config.Muestreo.Fs_Hz * 30;
    Estado.Calibracion.EMG_Data = zeros(1, numCalibracion);
    Estado.Calibracion.SVM_Data = zeros(1, numCalibracion);
    
    Estado.DSP.EMG_Baseline = 0;
    Estado.DSP.EMG_Envelope = 0;
    Estado.DSP.SVM_Baseline = 1.0;
    
    Estado.Vitales.UltimoRed = 0;
    Estado.Vitales.UltimoIR = 0;
    Estado.Vitales.SPO2 = NaN;
    Estado.Vitales.BPM = NaN;
    Estado.Vitales.SPO2_UI = NaN;
    Estado.Vitales.BPM_UI = NaN;
    Estado.Vitales.BufferRed = [];
    Estado.Vitales.BufferIR = [];
    
    Estado.UI.ContraccionPrevia = false;
    Estado.UI.MuestrasTobillo = 0;
    Estado.UI.MuestrasBiceps = 0;
    Estado.UI.MuestrasDesdeUltimoBackup = 0;
    Estado.UI.SPO2Text = '';
    Estado.UI.BPMText = '';

    Analisis = struct();
    Analisis.T = [];
    Analisis.Anotaciones = [];
    Analisis.EventosNav = []; 
    Analisis.IdxNav = 0;
    Analisis.TotNav = 0;
    Analisis.LineasGuia = []; 
    
    Archivos = struct();
    Archivos.Senales = "";
    Archivos.EDF_Input = "";
    Archivos.EDF_Ruta = "";
    
    Red = struct();
    Red.UdpTobillo = [];
    Red.UdpBiceps = [];
    
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));

    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA ---
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus V7.8 | Spectral Edition (100 Hz)', 'Color', 'w', 'Position', [50, 50, 1200, 900]);
    UI.Fig.CloseRequestFcn = @cerrarAplicacion;
    UI.AxesAnaLista = [];

    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlConv = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');

    % --- MENÚ PRINCIPAL ---
    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS V7.8', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [450, 650, 400, 60], 'HorizontalAlignment', 'center');
    uibutton(UI.PnlMenu, 'Text', '1. Adquisicion de Datos (UDP)', 'FontSize', 18, 'Position', [400, 450, 400, 60], 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clinico (SPI)', 'FontSize', 18, 'Position', [400, 350, 400, 60], 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlAna));
    uibutton(UI.PnlMenu, 'Text', '3. Convertidor EDF a CSV', 'FontSize', 18, 'Position', [400, 250, 400, 60], 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlConv));

    % --- PANEL DE ADQUISICIÓN ---
    gAdq = uigridlayout(UI.PnlAdq, [6, 4], 'RowHeight', {'1x', '1x', 80, 70, 60, 60}, 'ColumnWidth', {'1x', '1x', '1x', 140}, 'Padding', 20);

    UI.axEMG_TR = uiaxes(gAdq); title(UI.axEMG_TR, 'EMG Envolvente (AD8232 + DSP)'); UI.axEMG_TR.Layout.Row = 1; UI.axEMG_TR.Layout.Column = [1 4];
    UI.axSVM_TR = uiaxes(gAdq); title(UI.axSVM_TR, 'Actigrafia SVM (DSP)'); UI.axSVM_TR.Layout.Row = 2; UI.axSVM_TR.Layout.Column = [1 4];

    numPuntosGrafica = 6000; 
    UI.lineaEMG = animatedline(UI.axEMG_TR, 'Color', [1 0.5 0], 'LineWidth', 1.5, 'MaximumNumPoints', numPuntosGrafica); 
    UI.lineaSVM = animatedline(UI.axSVM_TR, 'Color', [0 0.4 1], 'LineWidth', 1.5, 'MaximumNumPoints', numPuntosGrafica); 

    pnlVit = uigridlayout(gAdq, [1, 2]); pnlVit.Layout.Row = 3; pnlVit.Layout.Column = [1 4];
    UI.lblSPO2 = uilabel(pnlVit, 'Text', '--% SpO2', 'FontSize', 45, 'FontWeight', 'bold', 'FontColor', [0 0.4 0.8], 'HorizontalAlignment', 'center'); 
    UI.lblBPM  = uilabel(pnlVit, 'Text', '-- BPM', 'FontSize', 45, 'FontWeight', 'bold', 'HorizontalAlignment', 'center'); 

    pnlDet = uipanel(gAdq, 'BackgroundColor', [0.95 0.95 0.95]); pnlDet.Layout.Row = 4; pnlDet.Layout.Column = [1 4];
    gDet = uigridlayout(pnlDet, [1, 1]);
    UI.lblLed = uilabel(gDet, 'Text', ' EN ESPERA ', 'FontSize', 22, 'FontWeight', 'bold', 'BackgroundColor', [0.5 0.5 0.5], 'FontColor', 'w', 'HorizontalAlignment', 'center');
    
    UI.lblInfo = uilabel(gAdq, 'Text', 'Listo para conectar.', 'FontSize', 12, 'HorizontalAlignment', 'center');
    UI.lblInfo.Layout.Row = 5; UI.lblInfo.Layout.Column = [1 3];

    UI.lblMemoria = uilabel(gAdq, 'Text', 'RAM: --', 'FontSize', 12, 'HorizontalAlignment', 'right');
    UI.lblMemoria.Layout.Row = 5; UI.lblMemoria.Layout.Column = 4;
    
    UI.btnUDP = uibutton(gAdq, 'Text', 'Conectar Hardware', 'FontSize', 16, 'FontWeight', 'bold', 'BackgroundColor', [0.2 0.6 0.2], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) alternarCaptura());
    UI.btnUDP.Layout.Row = 6; UI.btnUDP.Layout.Column = [1 2];

    btnExp = uibutton(gAdq, 'Text', 'Finalizar y Exportar', 'FontSize', 14, 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) detenerYExportar());
    btnExp.Layout.Row = 6; btnExp.Layout.Column = 3;
    
    btnVolverAdq = uibutton(gAdq, 'Text', '🏠 VOLVER', 'FontSize', 14, 'BackgroundColor', [0.8 0.2 0.2], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlMenu));
    btnVolverAdq.Layout.Row = 6; btnVolverAdq.Layout.Column = 4;

    % --- PANEL DE ANÁLISIS ---
    gAna = uigridlayout(UI.PnlAna, [2, 1], 'RowHeight', {45, '1x'}, 'Padding', 5);
    gToolbar = uigridlayout(gAna, [1, 10], 'ColumnWidth', {120, 140, 30, 60, 60, 60, '1x', 140, 120, 160}, 'Padding', 2);

    uibutton(gToolbar, 'Text', '📁 Cargar CSV', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) cargarArchivo());
    
    UI.lblArchivoData = uilabel(gToolbar, 'Text', 'Ningun archivo', 'FontSize', 9, 'FontColor', [0.4 0.4 0.4], 'WordWrap', 'off');
    uilabel(gToolbar, 'Text', '|', 'HorizontalAlignment', 'center');
    
    uibutton(gToolbar, 'Text', '<< Ant', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) navegarEpisodios(-1));
    uibutton(gToolbar, 'Text', 'Sig >>', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) navegarEpisodios(1));
    uibutton(gToolbar, 'Text', 'Todo', 'FontSize', 12, 'ButtonPushedFcn', @(~,~) verTodoAnalisis());

    UI.lblEpi = uilabel(gToolbar, 'Text', 'Nav Serie PLM: 0 / 0 | LMs: 0', 'FontSize', 13, 'FontWeight', 'bold', 'FontColor', [0.7 0.1 0.1], 'HorizontalAlignment', 'center');

    uibutton(gToolbar, 'Text', 'ℹ️ Reglas AASM', 'FontSize', 12, 'BackgroundColor', [0.9 0.9 0.9], 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) mostrarReglasAASM());
    
    uibutton(gToolbar, 'Text', '⚙️ PROCESAR', 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'FontSize', 12, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) ejecutarAnalisisPro());
    uibutton(gToolbar, 'Text', '🏠 VOLVER', 'FontSize', 12, 'BackgroundColor', [0.8 0.2 0.2], 'FontColor', 'w', 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlMenu));
    
    UI.pnlGraficasAna = uipanel(gAna, 'BorderType', 'none', 'BackgroundColor', 'w');

    % --- PANEL DE CONVERSIÓN EDF ---
    gConv = uigridlayout(UI.PnlConv, [4, 3], 'RowHeight', {60, 60, '1x', 60}, 'ColumnWidth', {200, '1x', 200}, 'Padding', 50);
    
    uibutton(gConv, 'Text', '📁 Cargar Archivo EDF', 'FontSize', 14, 'ButtonPushedFcn', @(~,~) cargarEDFParaConvertir());
    UI.lblArchivoEDF = uilabel(gConv, 'Text', 'Ningun archivo seleccionado', 'FontSize', 12);
    UI.lblArchivoEDF.Layout.Column = [2 3];
    
    UI.btnConvertirEDF = uibutton(gConv, 'Text', '⚙️ CONVERTIR A CSV', 'FontSize', 14, 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'Enable', 'off', 'ButtonPushedFcn', @(~,~) procesarEDF_UI());
    UI.btnConvertirEDF.Layout.Row = 2; UI.btnConvertirEDF.Layout.Column = 2;

    UI.txtConsola = uitextarea(gConv, 'Value', 'Listo para convertir. Por favor cargue un archivo EDF.', 'Editable', 'off', 'FontSize', 12, 'FontName', 'Consolas');
    UI.txtConsola.Layout.Row = 3; UI.txtConsola.Layout.Column = [1 3];

    btnVolverConv = uibutton(gConv, 'Text', '🏠 VOLVER', 'FontSize', 14, 'BackgroundColor', [0.8 0.2 0.2], 'FontColor', 'w', 'ButtonPushedFcn', @(~,~) cambiarPanel(UI.PnlMenu));
    btnVolverConv.Layout.Row = 4; btnVolverConv.Layout.Column = 3;

    %% --- 4. BUCLE PRINCIPAL (DESACOPLADO) ---
    while ishandle(UI.Fig)
        if Estado.Capturando 
            try
                lineasB = leerYValidarBatch(Red.UdpBiceps, 5); 
                lineasT = leerYValidarBatch(Red.UdpTobillo, 7); 
                
                if isempty(lineasT) && isempty(lineasB)
                    if toc(Estado.TiempoUltimoPaquete) > 2.0 && (Estado.UI.MuestrasTobillo > 0 || Estado.UI.MuestrasBiceps > 0)
                        UI.lblInfo.Text = 'SENSOR DESCONECTADO (Sin datos > 2s)'; 
                        UI.lblInfo.FontColor = [1 0 0];
                    end
                else
                    Estado.TiempoUltimoPaquete = tic;
                end

                if ~isempty(lineasB)
                    for i = 1:size(lineasB, 1)
                        red_raw = lineasB(i, 3); ir_raw = lineasB(i, 4);
                        Estado.Vitales.UltimoRed = red_raw;
                        Estado.Vitales.UltimoIR  = ir_raw;
                        
                        Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed, red_raw]; 
                        Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR, ir_raw];
                        
                        % Reducimos la ventana requerida en el buffer para la FFT
                        % 5 segundos es más que suficiente para buena resolución
                        if length(Estado.Vitales.BufferRed) > Config.Muestreo.Fs_Hz * 5
                            Estado.Vitales.BufferRed = Estado.Vitales.BufferRed(2:end);
                            Estado.Vitales.BufferIR  = Estado.Vitales.BufferIR(2:end);
                        end
                        
                        Estado.DedoDetectado = (ir_raw > Config.Umbrales.IR_Minimo_Dedo);
                        Estado.UI.MuestrasBiceps = Estado.UI.MuestrasBiceps + 1;

                        if mod(Estado.UI.MuestrasBiceps, Config.UI.RefrescoVitales_Muestras) == 0 
                            [tempSPO2, tempBPM, is_artifact] = detectarBPMRobusto(Estado.Vitales.BufferRed, Estado.Vitales.BufferIR, Config.Muestreo.Fs_Hz); 
                            
                            if Estado.Calibracion.Activa
                                nuevoSPO2 = '--% (Calibrando)'; 
                                nuevoBPM = '-- (Calibrando)'; 
                                UI.lblSPO2.FontColor = [0.5 0.5 0.5]; 
                            elseif Estado.DedoDetectado
                                if ~is_artifact && ~isnan(tempSPO2) && ~isnan(tempBPM)
                                    Estado.Vitales.SPO2 = tempSPO2; Estado.Vitales.BPM = tempBPM;
                                    
                                    if isnan(Estado.Vitales.SPO2_UI)
                                        Estado.Vitales.SPO2_UI = tempSPO2;
                                        Estado.Vitales.BPM_UI = tempBPM;
                                    else
                                        % Filtro de suavizado visual
                                        Estado.Vitales.SPO2_UI = 0.8 * Estado.Vitales.SPO2_UI + 0.2 * tempSPO2;
                                        Estado.Vitales.BPM_UI  = 0.8 * Estado.Vitales.BPM_UI  + 0.2 * tempBPM;
                                    end
                                    
                                    nuevoSPO2 = sprintf('%.0f%% SpO2', Estado.Vitales.SPO2_UI); 
                                    nuevoBPM = sprintf('%.0f BPM', Estado.Vitales.BPM_UI);
                                    UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                                else
                                    nuevoSPO2 = sprintf('%.0f%% (RUIDO)', Estado.Vitales.SPO2_UI); 
                                    nuevoBPM = sprintf('%.0f (RUIDO)', Estado.Vitales.BPM_UI);
                                    UI.lblSPO2.FontColor = [0.8 0.4 0]; 
                                end
                            else
                                nuevoSPO2 = 'SIN DEDO'; nuevoBPM = '--- BPM'; UI.lblSPO2.FontColor = [0.8 0.2 0.2]; 
                                Estado.Vitales.SPO2 = NaN; Estado.Vitales.BPM = NaN;
                                Estado.Vitales.SPO2_UI = NaN; Estado.Vitales.BPM_UI = NaN;
                            end
                            
                            if ~strcmp(Estado.UI.SPO2Text, nuevoSPO2), UI.lblSPO2.Text = nuevoSPO2; Estado.UI.SPO2Text = nuevoSPO2; end
                            if ~strcmp(Estado.UI.BPMText, nuevoBPM), UI.lblBPM.Text = nuevoBPM; Estado.UI.BPMText = nuevoBPM; end
                        end
                    end
                end

                if ~isempty(lineasT)
                    for i = 1:size(lineasT, 1)
                        t_abs = lineasT(i, 1) + lineasT(i, 2) / 1e6;
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
                                    UI.lblInfo.Text = 'RUIDO EXCESIVO! REINICIANDO...'; UI.lblInfo.FontColor = [1 0 0];
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
                        
                        Estado.UI.MuestrasTobillo = Estado.UI.MuestrasTobillo + 1;

                        if mod(Estado.UI.MuestrasTobillo, Config.UI.RefrescoGraficas_Muestras) == 0
                            if contraccionActual ~= Estado.UI.ContraccionPrevia
                                if contraccionActual
                                    UI.lblLed.BackgroundColor = [0.2 0.8 0.2]; UI.lblLed.Text = ' CONTRACCIÓN ';
                                else
                                    UI.lblLed.BackgroundColor = [0.8 0.2 0.2]; UI.lblLed.Text = ' REPOSO ';
                                end
                                Estado.UI.ContraccionPrevia = contraccionActual;
                            end
                            actualizarEjesGrafica([UI.axEMG_TR, UI.axSVM_TR], tRelativo, Config.Muestreo.VentanaGrafica_s);
                            mostrarMemoriaSegura();
                        end
                        
                        Estado.UI.MuestrasDesdeUltimoBackup = Estado.UI.MuestrasDesdeUltimoBackup + 1;
                        if Estado.UI.MuestrasDesdeUltimoBackup > Config.Backup.MuestrasIntervalo
                            backupIncrementalOptimizado(RingBuffer, Estado.UltimoBackupIdx, Config.BufferMax.Muestras);
                            Estado.UltimoBackupIdx = RingBuffer.Idx;
                            Estado.UI.MuestrasDesdeUltimoBackup = 0;
                        end
                        
                        guardarEnRingBuffer(tRelativo, ax, ay, az, emg_crudo, Estado.Vitales.UltimoRed, Estado.Vitales.UltimoIR, Estado.DSP.EMG_Envelope, svm_ac, Estado.Vitales.SPO2, Estado.Vitales.BPM, contraccionActual, Config);
                    end
                end
            catch ME
                logSistema('WARN', ['Excepcion en Bucle UDP: ', ME.message]);
                if isfield(Red, 'UdpTobillo') && ~isempty(Red.UdpTobillo) && isvalid(Red.UdpTobillo)
                    flush(Red.UdpTobillo);
                end
                if isfield(Red, 'UdpBiceps') && ~isempty(Red.UdpBiceps) && isvalid(Red.UdpBiceps)
                    flush(Red.UdpBiceps);
                end
            end
        end
        drawnow limitrate; 
    end

    %% --- 5. FUNCIONES DE CONTROL PRINCIPALES ---
    function alternarCaptura()
        Estado.Capturando = ~Estado.Capturando;
        if Estado.Capturando
            Estado.t0_Tobillo = NaN; 
            Estado.TiempoUltimoPaquete = tic; 
            Estado.Calibracion.Activa = true; Estado.Calibracion.Cuenta = 0;
            Estado.DSP.EMG_Baseline = 0; Estado.DSP.EMG_Envelope = 0; Estado.DSP.SVM_Baseline = 1.0; 
            Estado.UI.ContraccionPrevia = false; 
            Estado.UI.MuestrasTobillo = 0; Estado.UI.MuestrasBiceps = 0; Estado.UI.MuestrasDesdeUltimoBackup = 0;
            Estado.Vitales.BufferRed = []; Estado.Vitales.BufferIR = [];
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.EventosNav = []; Analisis.IdxNav = 0;

            try 
                Red.UdpTobillo = udpport("datagram", "LocalPort", Config.Puertos.Tobillo); Red.UdpTobillo.Timeout = 0.5;
                Red.UdpBiceps  = udpport("datagram", "LocalPort", Config.Puertos.Biceps); Red.UdpBiceps.Timeout = 0.5;
            catch ME
                uialert(UI.Fig, ['Error UDP: ', ME.message], 'Error'); Estado.Capturando = false; return;
            end
            
            UI.lblInfo.Text = "ESTABILIZANDO SEÑAL..."; UI.lblInfo.FontColor = [0.8 0.1 0];
            clearpoints(UI.lineaEMG); clearpoints(UI.lineaSVM); 
            UI.btnUDP.Text = "Detener"; UI.btnUDP.BackgroundColor = [1 0.4 0.4];
        else
            liberarRecursos(Red);
            UI.btnUDP.Text = "Conectar Hardware"; UI.btnUDP.BackgroundColor = [0.2 0.6 0.2];
            UI.lblInfo.Text = "EN ESPERA"; UI.lblInfo.FontColor = [0.5 0.5 0.5];
        end
    end

    function detenerYExportar()
        Estado.Capturando = false; liberarRecursos(Red);
        if RingBuffer.Count == 0, uialert(UI.Fig, 'Sin datos.', 'Aviso'); return; end
        
        prompt = {'Ingrese el identificador del paciente (Ej. Paciente-1, ID-456):'};
        dlgtitle = 'Guardar Estudio Clinico';
        definput = {'Paciente-1'};
        respuesta = inputdlg(prompt, dlgtitle, [1 50], definput);
        
        if isempty(respuesta)
            uialert(UI.Fig, 'Exportacion cancelada. Los datos siguen en memoria.', 'Aviso');
            return; 
        end
        
        idPaciente = regexprep(strtrim(respuesta{1}), '[\\/:*?"<>| ]', '_');
        if isempty(idPaciente), idPaciente = 'Paciente_Desc'; end
        
        fStr = char(datetime('now', 'Format', 'yyyyMMdd_HHmm'));
        rutaSalida = fullfile(pwd, 'AVA_Nexus_Data');
        if ~isfolder(rutaSalida), mkdir(rutaSalida); end
        backupIncrementalOptimizado(RingBuffer, Estado.UltimoBackupIdx, Config.BufferMax.Muestras); 
        
        [t_d, ax_d, ay_d, az_d, emgRaw_d, red_d, ir_d, emgEnv_d, svmAc_d, spo2_d, bpm_d, anot_d] = descomprimirRingBufferCorregido();
        if isempty(t_d), return; end
        
        try
            nameCSV = fullfile(rutaSalida, sprintf('%s_%s.csv', idPaciente, fStr));
            
            [anotFinal, ~] = procesarAASM(t_d, emgEnv_d, svmAc_d, spo2_d, Config.Muestreo.Fs_Hz, Config);
            
            fid = fopen(nameCSV, 'w');
            if fid == -1
                error('No se pudo crear el archivo CSV. Verifique que no este abierto en otro programa.');
            end
            
            fprintf(fid, '# AVA Nexus V7.5 Data Lake (Hardware Timestamps)\n# Exportado: %s\n# Fs_Hz: %d\n# Thr_EMG: %.4f\n# Thr_SVM: %.4f\n', char(datetime('now')), Config.Muestreo.Fs_Hz, Config.Umbrales.EMG_Contraccion, Config.Umbrales.SVM_Movimiento);
            fprintf(fid, 'Time_s_Abs,Ax,Ay,Az,EMG_Raw,Red_Raw,IR_Raw,EMG_Env,SVM_ac,SpO2_pct,BPM_bpm,AASM_SPI\n');
            
            MatrizSalida = [t_d, ax_d, ay_d, az_d, emgRaw_d, red_d, ir_d, emgEnv_d, svmAc_d, spo2_d, bpm_d, anotFinal]';
            fprintf(fid, '%.6f,%.3f,%.3f,%.3f,%.1f,%.1f,%.1f,%.6f,%.6f,%.0f,%.0f,%d\n', MatrizSalida);
            fclose(fid);
            
            try rmdir(fullfile(pwd, 'AVA_Nexus_Data', '.cache_incremental'), 's'); catch; end
            
            uialert(UI.Fig, sprintf('Exportado Correctamente:\n%d muestras del %s', length(t_d), idPaciente), 'Exito');
        catch ME
            uialert(UI.Fig, ['Error critico: ', ME.message], 'Fallo Sistema');
        end
        cambiarPanel(UI.PnlMenu);
    end

    function mostrarReglasAASM()
        mensaje = [
            "CRITERIOS AASM APLICADOS (Academia Americana de Medicina del Sueno):"
            ""
            "LMs Aislados (Movimiento de Pierna):"
            "   • Amplitud: Al menos 8 uV sobre la linea base de reposo."
            "   • Duracion: Entre 0.5 seg y 10.0 seg."
            "   • Fusion: Contracciones a menos de 0.5 seg se unen en una sola."
            "   *Nota: En esta vista limpia, los LMs que no logran formar una serie se ocultan visualmente.*"
            ""
            "Serie PLM (Movimientos Periodicos - Rojo):"
            "   • Cantidad: Deben agruparse al menos 4 LMs consecutivos."
            "   • Periodicidad: El tiempo entre el inicio de un LM y el siguiente "
            "     debe ser estrictamente de 5.0 a 90.0 seg."
            "   • Excepcion (iLM): Si un LM ocurre a menos de 5.0 seg del anterior,"
            "     NO suma a la serie, pero TAMPOCO la rompe. El sistema lo ignora y"
            "     mide el tiempo hasta el siguiente espasmo valido."
            ""
            "Compuerta de Ruido (Noise Gate):"
            "   Si se cargan datos hospitalarios sin acelerometro (EDF), el sistema"
            "   aplica un umbral dinamico basado en el ruido de fondo para evitar"
            "   falsos positivos."
        ];
        uialert(UI.Fig, strjoin(mensaje, newline), 'Reglas Clinicas AASM', 'Icon', 'info');
    end

    %% --- 5.1 FUNCIONES DEL CONVERTIDOR EDF ---
    function cargarEDFParaConvertir()
        [n, r] = uigetfile('*.edf', 'Seleccione el archivo EDF del hospital');
        if ~isequal(n, 0)
            Archivos.EDF_Input = n;
            Archivos.EDF_Ruta = r;
            UI.lblArchivoEDF.Text = fullfile(r, n);
            UI.btnConvertirEDF.Enable = 'on';
            UI.txtConsola.Value = {'Archivo EDF cargado correctamente.', 'Haga clic en CONVERTIR para seleccionar los canales.'};
        end
    end

    function logConsola(msg)
        if isstring(msg)
            msg = join(msg, "");
        end
        msgTxt = char(msg);
        UI.txtConsola.Value = [UI.txtConsola.Value; {msgTxt}];
        scroll(UI.txtConsola, 'bottom');
        drawnow;
    end

    function procesarEDF_UI()
        UI.btnConvertirEDF.Enable = 'off';
        UI.Fig.Pointer = 'watch';
        drawnow;
        
        rutaCompleta = fullfile(Archivos.EDF_Ruta, Archivos.EDF_Input);
        try
            logConsola('Leyendo cabeceras del EDF...');
            info = edfinfo(rutaCompleta);
            todasLasSenales = string(info.SignalLabels);
            
            nombresMostrar = strings(size(todasLasSenales));
            for k = 1:length(todasLasSenales)
                senal = upper(todasLasSenales(k)); 
                if contains(senal, 'DX') || contains(senal, 'RIGHT LEG') || contains(senal, 'LEG R') || contains(senal, 'RAT')
                    nombresMostrar(k) = "Pierna Derecha (" + todasLasSenales(k) + ")";
                elseif contains(senal, 'SX') || contains(senal, 'LEFT LEG') || contains(senal, 'LEG L') || contains(senal, 'LAT')
                    nombresMostrar(k) = "Pierna Izquierda (" + todasLasSenales(k) + ")";
                elseif contains(senal, 'SAO2') || contains(senal, 'SPO2') || contains(senal, 'O2')
                    nombresMostrar(k) = "SpO2 (" + todasLasSenales(k) + ")";
                elseif contains(senal, 'HR') || contains(senal, 'PULSE') || contains(senal, 'PR') || contains(senal, 'BPM')
                    nombresMostrar(k) = "Frecuencia Cardiaca (" + todasLasSenales(k) + ")";
                elseif contains(senal, 'C3') || contains(senal, 'C4') || contains(senal, 'F3') || contains(senal, 'F4') || contains(senal, 'O1') || contains(senal, 'O2') || contains(senal, 'A1') || contains(senal, 'A2')
                    nombresMostrar(k) = "EEG Cerebro (" + todasLasSenales(k) + ")";
                elseif contains(senal, 'EOG') || contains(senal, 'LOC') || contains(senal, 'ROC')
                    nombresMostrar(k) = "EOG Ojos (" + todasLasSenales(k) + ")";
                elseif contains(senal, 'CHIN') || contains(senal, 'MENT') || contains(senal, 'EMG1')
                    nombresMostrar(k) = "EMG Menton (" + todasLasSenales(k) + ")";
                elseif contains(senal, 'FLOW') || contains(senal, 'NASAL') || contains(senal, 'CHEST') || contains(senal, 'THOR') || contains(senal, 'ABD')
                    nombresMostrar(k) = "Respiracion (" + todasLasSenales(k) + ")";
                else
                    nombresMostrar(k) = todasLasSenales(k);
                end
            end
            
            UI.Fig.Pointer = 'arrow'; 
            mensajeInstruccion = {'Seleccione los canales clinicos a exportar:', '(Use Ctrl o Shift para elegir varios)'};
            [idxSeleccion, ok] = listdlg('ListString', cellstr(nombresMostrar), ...
                                         'PromptString', mensajeInstruccion, ...
                                         'SelectionMode', 'multiple', ...
                                         'Name', 'Selector de Canales EDF', ...
                                         'ListSize', [350 450]);
                                     
            if ok == 0
                logConsola('Operacion cancelada. No se seleccionaron canales.');
                UI.btnConvertirEDF.Enable = 'on';
                return;
            end
            
            UI.Fig.Pointer = 'watch'; 
            drawnow;
            
            senalesValidas = todasLasSenales(idxSeleccion);
            logConsola(sprintf('Extrayendo: %s', strjoin(senalesValidas, ', ')));
            
            data = edfread(rutaCompleta, 'SelectedSignals', senalesValidas);
            Fs_objetivo = 100;
            numRecords = size(data, 1);
            duracionRecord = seconds(info.DataRecordDuration);
            tiempoTotal = numRecords * duracionRecord;
            
            t_master = (0 : (tiempoTotal * Fs_objetivo) - 1)' / Fs_objetivo;
            matrizPlana = zeros(length(t_master), length(senalesValidas));
            
            logConsola('Aplanando y sincronizando senales a 100 Hz (puede tomar un minuto)...');
            
            nombresVariables = data.Properties.VariableNames;
            for i = 1:length(nombresVariables)
                varName = nombresVariables{i};
                senal_bloques = data.(varName);
                
                if iscell(senal_bloques)
                    senal_flat = cell2mat(senal_bloques);
                else
                    senal_flat = reshape(senal_bloques', [], 1);
                end
                
                if any(isnan(senal_flat))
                    senal_flat = fillmissing(senal_flat, 'previous');
                    senal_flat = fillmissing(senal_flat, 'next'); 
                end
                
                Fs_nativa = length(senal_flat) / tiempoTotal;
                t_nativo = (0 : length(senal_flat) - 1)' / Fs_nativa;
                
                [t_nativo_u, idx_uniq] = unique(t_nativo);
                senal_flat_u = double(senal_flat(idx_uniq));
                
                if Fs_nativa < 10
                    senal_sinc = interp1(t_nativo_u, senal_flat_u, t_master, 'previous', 'extrap');
                else
                    senal_sinc = interp1(t_nativo_u, senal_flat_u, t_master, 'linear', 'extrap');
                end
                matrizPlana(:, i) = senal_sinc;
            end
            
            [~, nombreBase, ~] = fileparts(Archivos.EDF_Input);
            nombreCSV = fullfile(Archivos.EDF_Ruta, sprintf('%s_Hospital_100Hz.csv', nombreBase));
            
            logConsola('Escribiendo el archivo CSV limpio...');
            fid = fopen(nombreCSV, 'w');
            if fid == -1
                error('No se pudo crear el archivo CSV. Cierrelo si esta abierto en otro programa.');
            end
            
            fprintf(fid, 'Tiempo_s,%s\n', strjoin(senalesValidas, ','));
            matrizSalida = [t_master, matrizPlana]';
            formato = ['%.4f', repmat(',%.4f', 1, length(senalesValidas)), '\n'];
            fprintf(fid, formato, matrizSalida);
            fclose(fid);
            
            logConsola('==================================================');
            logConsola(sprintf('EXITO! Archivo creado en: %s', nombreCSV));
            logConsola('==================================================');
            
            UI.btnConvertirEDF.Enable = 'on';
            UI.Fig.Pointer = 'arrow';
        catch ME
            logConsola('ERROR CRITICO:');
            logConsola(ME.message);
            UI.btnConvertirEDF.Enable = 'on';
            UI.Fig.Pointer = 'arrow';
        end
    end

    %% --- 5.2 FUNCIONES DEL ANALIZADOR CLÍNICO ---
    function ejecutarAnalisisPro()
        if Archivos.Senales == "", uialert(UI.Fig, 'Seleccione un CSV.', 'Aviso'); return; end
        try
            UI.Fig.Pointer = 'watch'; 
            drawnow;
            
            removerLineasGuia();
            
            opts = detectImportOptions(Archivos.Senales);
            nombresColumnas = opts.VariableNames;
            
            data = readmatrix(Archivos.Senales, 'CommentStyle', '#');
            if size(data, 1) < 10, error('CSV invalido o muy corto.'); end
            
            cfgAn = Config; 
            isEDF = false;
            
            if any(contains(nombresColumnas, 'Ax'))
                logSistema('INFO', 'Procesando archivo nativo AVA Nexus...');
                vT = data(:,1); vEMG = data(:,8); vSVM = data(:,9); vSPO2 = data(:,10); vBPM = data(:,11);
                fsReal = 1 / mean(diff(vT), 'omitnan');

            elseif any(contains(nombresColumnas, 'DX1')) || any(contains(nombresColumnas, 'SX1'))
                logSistema('INFO', 'Procesando archivo de validacion Hospitalaria...');
                isEDF = true;
                vT = data(:,1); 
                fsReal = 1 / mean(diff(vT), 'omitnan');
                
                idxD = find(contains(nombresColumnas, 'DX1'), 1);
                idxS = find(contains(nombresColumnas, 'SX1'), 1);
                idxO2 = find(contains(nombresColumnas, 'SAO2'), 1);
                idxHR = find(contains(nombresColumnas, 'HR'), 1);
                
                if isempty(idxD), idxD = idxS; end
                if isempty(idxS), idxS = idxD; end
                
                base1 = movmean(data(:,idxD), round(fsReal * 2), 'omitnan');
                base2 = movmean(data(:,idxS), round(fsReal * 2), 'omitnan');
                
                e1 = abs(data(:,idxD) - base1);
                e2 = abs(data(:,idxS) - base2);
                
                vEMG_Raw = max(e1, e2);
                vEMG = movmean(vEMG_Raw, round(fsReal * 0.25), 'omitnan'); 
                
                vSVM = ones(size(vT)); 
                
                if ~isempty(idxO2), vSPO2 = data(:,idxO2); else, vSPO2 = NaN(size(vT)); end
                if ~isempty(idxHR), vBPM = data(:,idxHR); else, vBPM = NaN(size(vT)); end
                
                cfgAn.Umbrales.SVM_Movimiento = 0; 
                ruido_fondo = std(vEMG(vEMG < median(vEMG, 'omitnan')), 'omitnan'); 
                cfgAn.Umbrales.EMG_Contraccion = median(vEMG, 'omitnan') + max(8, ruido_fondo * 4); 
            else
                error('Formato no reconocido: Los encabezados no coinciden con AVA ni Hospital.');
            end
            
            [Analisis.Anotaciones, EpisodiosNav] = procesarAASM(vT, vEMG, vSVM, vSPO2, fsReal, cfgAn);
            
            Analisis.EventosNav = EpisodiosNav; 
            Analisis.TotNav = size(EpisodiosNav, 1);
            Analisis.T = vT; 
            Analisis.IdxNav = 0;
            actualizarEtiquetaEpisodio(0, Analisis.TotNav, 0);
            
            delete(UI.pnlGraficasAna.Children); 
            gGrid = uigridlayout(UI.pnlGraficasAna, [4, 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG Envolvente | Serie PLM (Rojo)'); hold(ax1,'on'); grid(ax1, 'on');
            
            plot(ax1, vT, vEMG, 'Color', [0.6 0.6 0.6], 'LineWidth', 0.5); 
            
            vEMG_PLM = vEMG; 
            vEMG_PLM(Analisis.Anotaciones ~= 2) = NaN; 
            plot(ax1, vT, vEMG_PLM, 'r', 'LineWidth', 1.5);
            
            ax2 = uiaxes(gGrid); 
            if isEDF
                title(ax2, 'Actigrafia SVM (No disponible en estudio Hospitalario)'); 
            else
                title(ax2, 'Actigrafia SVM (Sensor Fisico 3D)'); 
            end
            plot(ax2, vT, vSVM, 'Color', [0 0.4 0.8]); grid(ax2, 'on');
            
            ax3 = uiaxes(gGrid); title(ax3, 'SpO2 %'); hold(ax3, 'on'); 
            plot(ax3, vT, vSPO2, 'g'); plot(ax3, vT, movmean(vSPO2, fsReal * 120, 'omitnan'), 'k--', 'LineWidth', 1); ylim(ax3, [85 100]); 
            ax4 = uiaxes(gGrid); title(ax4, 'BPM'); plot(ax4, vT, vBPM, 'r'); ylim(ax4, [40 160]); 
            
            UI.AxesAnaLista = [ax1, ax2, ax3, ax4]; 
            UI.Fig.Pointer = 'arrow';
            cambiarPanel(UI.PnlAna); navegarEpisodios(0);
        catch ME
            UI.Fig.Pointer = 'arrow';
            uialert(UI.Fig, sprintf('Error al procesar:\n%s', ME.message), 'Error');
        end
    end

    %% --- 6. PARSEO Y NATIVAS ---
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
                
                idx_commas = strfind(str, ',');
                if isempty(idx_commas), continue; end
                idx_comma = idx_commas(end);
                
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
        
        N = length(bR);
        % Necesitamos al menos 4 segundos para tener buena resolución espectral
        if N < fs * 4 
            return; 
        end
        
        % 1. APLICAR TRANSFORMADA RÁPIDA DE FOURIER (FFT)
        fft_R = abs(fft(bR)) / N;
        fft_I = abs(fft(bI)) / N;
        
        % 2. COMPONENTE DC
        dc_r = fft_R(1);
        dc_i = fft_I(1);
        
        if dc_r < 1000 || dc_i < 1000 % Dedo no detectado
            return;
        end
        
        % 3. BUSCAR EL PULSO CARDÍACO (0.5 Hz - 3.5 Hz)
        idx_min = floor(0.5 * N / fs) + 1;
        idx_max = ceil(3.5 * N / fs) + 1;
        
        rango_IR = fft_I(idx_min:idx_max);
        [ac_i, max_rel_idx] = max(rango_IR);
        
        idx_HR = idx_min + max_rel_idx - 1;
        
        % 4. COMPONENTE AC PURO
        ac_r = fft_R(idx_HR);
        
        % 5. CÁLCULO CLÍNICO
        R = (ac_r / dc_r) / (ac_i / dc_i);
        
        s_calc = 110 - (25 * R);
        if s_calc > 100, s_calc = 99; end
        if s_calc < 70, s_calc = 70; end
        
        freq_HR = (idx_HR - 1) * (fs / N);
        b_calc = freq_HR * 60;
        
        % 6. EVALUACIÓN DE CALIDAD
        ruido_promedio = mean(fft_I(idx_min:end));
        if ac_i > (ruido_promedio * 2)
            spo2 = s_calc;
            bpm = b_calc;
            is_artifact = false; 
        end
    end
    
    function [anotFinal, EpisodiosNav] = procesarAASM(t, e, s, spo2_data, fs, cfg)
        fus = (e > cfg.Umbrales.EMG_Contraccion) & (s > cfg.Umbrales.SVM_Movimiento);
        
        fl = diff([0; fus(:); 0]); iI = find(fl==1); iF = find(fl==-1)-1;
        mPlm_Candidatos = []; validosPLM = []; EpisodiosNav = [];
        
        if isempty(iI), anotFinal = zeros(size(t)); return; end
        
        % FUSIÓN (< 0.5s)
        cA = iI(1); cF = iF(1); iIU = []; iFU = [];
        for i = 2:length(iI)
            if (iI(i) - cF)/fs < 0.5
                cF = iF(i); 
            else
                iIU(end+1,1) = cA; iFU(end+1,1) = cF; %#ok<AGROW>
                cA = iI(i); cF = iF(i); 
            end
        end
        iIU(end+1,1) = cA; iFU(end+1,1) = cF;
        
        % DURACIÓN (0.5s a 10.0s)
        for i = 1:length(iIU)
            dur = (iFU(i) - iIU(i)) / fs; 
            if dur >= 0.5 && dur <= 10.0
                mPlm_Candidatos = [mPlm_Candidatos; iIU(i), iFU(i)]; %#ok<AGROW>
            end 
        end
        
        % AGRUPACIÓN POR CLUSTERS
        if ~isempty(mPlm_Candidatos)
            rt = mPlm_Candidatos(1,:);
            ultimo_valido_idx = 1;
            
            for j = 2:size(mPlm_Candidatos,1)
                inter = (mPlm_Candidatos(j,1) - rt(ultimo_valido_idx,1)) / fs;
                
                if inter >= 5.0 && inter <= 90.0
                    rt = [rt; mPlm_Candidatos(j,:)]; %#ok<AGROW>
                    ultimo_valido_idx = size(rt,1);
                elseif inter > 90.0
                    num_LMs = size(rt,1);
                    if num_LMs >= 4
                        EpisodiosNav = [EpisodiosNav; rt(1,1), rt(end,2), num_LMs]; %#ok<AGROW>
                        validosPLM = [validosPLM; rt]; %#ok<AGROW>
                    end
                    rt = mPlm_Candidatos(j,:); 
                    ultimo_valido_idx = 1;
                end
            end
            
            num_LMs = size(rt,1);
            if num_LMs >= 4
                EpisodiosNav = [EpisodiosNav; rt(1,1), rt(end,2), num_LMs];
                validosPLM = [validosPLM; rt]; 
            end
        end
        
        anotFinal = zeros(size(t)); 
        for k = 1:size(mPlm_Candidatos,1)
            anotFinal(mPlm_Candidatos(k,1):mPlm_Candidatos(k,2)) = 1; 
        end
        for k = 1:size(validosPLM,1)
            anotFinal(validosPLM(k,1):validosPLM(k,2)) = 2; 
        end
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
        [n, r] = uigetfile('*.csv');
        if ~isequal(n, 0)
            Archivos.Senales = fullfile(r, n); UI.lblArchivoData.Text = ['CSV: ' n];
        end
    end

    function actualizarEtiquetaEpisodio(idx, tNav, countLM)
        if idx < 0 || idx > tNav || tNav < 0, idx = 0; tNav = 0; end
        if idx == 0, countLM = 0; end
        try UI.lblEpi.Text = sprintf('Nav Serie PLM: %d / %d | LMs: %d', idx, tNav, countLM); catch, end
    end

    function removerLineasGuia()
        if ~isempty(Analisis.LineasGuia)
            for k=1:length(Analisis.LineasGuia)
                if ishandle(Analisis.LineasGuia(k))
                    delete(Analisis.LineasGuia(k));
                end
            end
            Analisis.LineasGuia = [];
        end
    end

    function navegarEpisodios(dir)
        if isempty(Analisis.EventosNav) || isempty(UI.AxesAnaLista), return; end
        
        removerLineasGuia();
        
        Analisis.IdxNav = max(1, min(Analisis.IdxNav + dir, size(Analisis.EventosNav, 1)));
        
        countLM = Analisis.EventosNav(Analisis.IdxNav, 3);
        actualizarEtiquetaEpisodio(Analisis.IdxNav, Analisis.TotNav, countLM);
        
        tStart = Analisis.T(Analisis.EventosNav(Analisis.IdxNav,1));
        tEnd   = Analisis.T(Analisis.EventosNav(Analisis.IdxNav,2));
        
        lim = [tStart - 5, tEnd + 5];
        for i=1:length(UI.AxesAnaLista), xlim(UI.AxesAnaLista(i), lim); end
        
        hold(UI.AxesAnaLista(1), 'on'); 
        estiloGuia = '--y'; 
        
        h1 = xline(UI.AxesAnaLista(1), tStart, estiloGuia, 'LineWidth', 1);
        h2 = xline(UI.AxesAnaLista(1), tEnd, estiloGuia, 'LineWidth', 1);
        h3 = xline(UI.AxesAnaLista(2), tStart, estiloGuia, 'LineWidth', 1);
        h4 = xline(UI.AxesAnaLista(2), tEnd, estiloGuia, 'LineWidth', 1);
        h5 = xline(UI.AxesAnaLista(3), tStart, estiloGuia, 'LineWidth', 1);
        h6 = xline(UI.AxesAnaLista(3), tEnd, estiloGuia, 'LineWidth', 1);
        h7 = xline(UI.AxesAnaLista(4), tStart, estiloGuia, 'LineWidth', 1);
        h8 = xline(UI.AxesAnaLista(4), tEnd, estiloGuia, 'LineWidth', 1);
        
        Analisis.LineasGuia = [h1, h2, h3, h4, h5, h6, h7, h8];
    end

    function verTodoAnalisis()
        if isempty(Analisis.T) || isempty(UI.AxesAnaLista) || length(Analisis.T) < 2, return; end
        removerLineasGuia(); 
        for i=1:length(UI.AxesAnaLista), xlim(UI.AxesAnaLista(i), [Analisis.T(1), Analisis.T(end)]); end
    end

    function actualizarEjesGrafica(ejes, tAct, vSeg)
        if tAct < vSeg
            limites = [0, vSeg];
        else
            limites = [tAct - vSeg, tAct];
        end
        for i = 1:length(ejes)
            xlim(ejes(i), limites);
        end
    end

    function cambiarPanel(pTarget)
        cap = Estado.Capturando; if cap, Estado.Capturando = false; pause(0.05); end
        UI.PnlMenu.Visible = 'off'; UI.PnlAdq.Visible = 'off'; UI.PnlAna.Visible = 'off'; UI.PnlConv.Visible = 'off'; pTarget.Visible = 'on'; 
        if cap, Estado.Capturando = true; end
    end

    function liberarRecursos(R)
        if isfield(R, 'UdpTobillo') && ~isempty(R.UdpTobillo) && isvalid(R.UdpTobillo)
            clear R.UdpTobillo; 
        end
        if isfield(R, 'UdpBiceps') && ~isempty(R.UdpBiceps) && isvalid(R.UdpBiceps)
            clear R.UdpBiceps; 
        end
    end

    function cerrarAplicacion(src, ~)
        Estado.Capturando = false; liberarRecursos(Red); delete(src);
    end

    function logSistema(nivel, mensaje)
        persistent t0; if isempty(t0), t0 = datetime('now'); end
        try fprintf('[%8.2fs] [%-5s] %s\n', seconds(datetime('now') - t0), nivel, char(mensaje)); catch, end
    end
end

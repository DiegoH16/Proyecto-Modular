function AVA_Core_System()
    
    clearvars; clc; close all force;
    
    %% --- 0. VALIDACIÓN DE ENTORNO ---
    matlabVersion = version('-release');
    if str2double(matlabVersion(1:4)) < 2018
        error('MATLAB R2018b o superior requerido. Versión actual: %s', matlabVersion);
    end
    
    %% --- 1. CONFIGURACIÓN CLÍNICA ESTRICTA ---
    Config = struct();
    Config.Puertos.Tobillo = 8888; 
    Config.Puertos.Biceps  = 8889; 
    Config.Puertos.Control = 9999; 
    Config.Muestreo.Fs_Hz  = 50; 
    Config.Muestreo.VentanaGrafica_s = 60; 
    
    Config.BufferMax.Horas = 10;
    Config.BufferMax.Muestras = Config.Muestreo.Fs_Hz * 3600 * Config.BufferMax.Horas; 
    Config.UI.RefrescoGraficas_Muestras = 5; 
    Config.Backup.MuestrasIntervalo = Config.Muestreo.Fs_Hz * 300;
    
    Config.Umbrales.IR_Minimo_Dedo = 3000;
    Config.Umbrales.EMG_Contraccion = 50; % Reducido porque la envolvente RMS es más pequeña y limpia
    Config.Umbrales.SVM_Movimiento = 0.4;  
    
    % Constantes para Filtros IIR DSP
    Config.Filtros.Alpha_SVM = 0.005; % Pasa-altos muy lento para gravedad
    Config.Filtros.Alpha_EMG_HP = 0.1; % Pasa-altos para EMG (elimina deriva)
    Config.Filtros.Alpha_EMG_LP = 0.15; % Pasa-bajos para Envolvente (suavizado)
    
    %% --- 2. ESTADO GLOBAL Y RING BUFFER ---
    RingBuffer = struct();
    RingBuffer.T    = zeros(1, Config.BufferMax.Muestras);      
    RingBuffer.EMG  = zeros(1, Config.BufferMax.Muestras);   
    RingBuffer.SVM  = zeros(1, Config.BufferMax.Muestras);  
    RingBuffer.SPO2 = zeros(1, Config.BufferMax.Muestras);    
    RingBuffer.BPM  = zeros(1, Config.BufferMax.Muestras);     
    RingBuffer.Anot = logical(zeros(1, Config.BufferMax.Muestras));  
    RingBuffer.Idx  = 1;      
    RingBuffer.Count = 0;    
    RingBuffer.Full = false; 
    
    Estado = struct();
    Estado.Capturando = false;
    Estado.OffsetTobillo = NaN;
    Estado.OffsetBiceps = NaN;
    Estado.T0_Global = -1; 
    Estado.DedoDetectado = false; 
    Estado.UltimoBackupIdx = 1;
    
    % --- DSP STATE ---
    Estado.DSP.EMG_Baseline = 0;
    Estado.DSP.EMG_Envelope = 0;
    Estado.DSP.SVM_Baseline = 1.0;    
    
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
    Red = struct('UdpTobillo', [], 'UdpBiceps', [], 'UdpControl', []);
    
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));
    
    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA ---
    logSistema('INFO', 'Iniciando AVA Nexus V6.8 | Medical DSP Active');
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus V6.8 | DSP Edition', 'Color', 'w', 'Position', [50, 50, 1200, 900]);
    UI.Fig.CloseRequestFcn = @(src, event) cerrarAplicacion(src, event);
    UI.AxesAnaLista = [];
    
    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    
    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS V6.8', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [450, 650, 400, 60], 'HorizontalAlignment', 'center');
    uibutton(UI.PnlMenu, 'Text', '1. Adquisición de Datos (UDP)', 'FontSize', 18, 'Position', [400, 450, 400, 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clínico (SPI)', 'FontSize', 18, 'Position', [400, 350, 400, 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAna));
    
    gAdq = uigridlayout(UI.PnlAdq, [6, 3], 'RowHeight', {'1x', '1x', 80, 70, 60, 60}, 'Padding', 20);
    
    UI.axEMG_TR = uiaxes(gAdq); title(UI.axEMG_TR, 'EMG Envolvente (DSP)'); UI.axEMG_TR.Layout.Row = 1; UI.axEMG_TR.Layout.Column = [1 3];
    UI.axSVM_TR = uiaxes(gAdq); title(UI.axSVM_TR, 'Actigrafía SVM (DSP)'); UI.axSVM_TR.Layout.Row = 2; UI.axSVM_TR.Layout.Column = [1 3];
    
    numPuntosGrafica = 3000;
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
                
                if isvalid(Red.UdpControl) && Red.UdpControl.NumDatagramsAvailable > 0
                    paquetesSync = read(Red.UdpControl, Red.UdpControl.NumDatagramsAvailable);
                    for ps = 1:length(paquetesSync)
                        txt = char(paquetesSync(ps).Data);
                        partes = strsplit(strtrim(txt), ',');
                        if length(partes) >= 4 && strcmp(partes{1}, 'SYNC')
                            devTime = str2double(partes{3}) + (str2double(partes{4}) / 1e6);
                            localTime = posixtime(datetime('now'));
                            if strcmp(partes{2}, 'TOBILLO') && isnan(Estado.OffsetTobillo)
                                Estado.OffsetTobillo = localTime - devTime;
                            elseif strcmp(partes{2}, 'BICEPS') && isnan(Estado.OffsetBiceps)
                                Estado.OffsetBiceps = localTime - devTime;
                            end
                        end
                    end
                end

                lineasB = leerYValidarBatch(Red.UdpBiceps, 5, true); 
                lineasT = leerYValidarBatch(Red.UdpTobillo, 7, true); 
                
                if ~isempty(lineasB)
                    if isnan(Estado.OffsetBiceps) 
                        Estado.OffsetBiceps = posixtime(datetime('now')) - lineasB(1,1);
                    end
                    lineasB(:,1) = lineasB(:,1) + Estado.OffsetBiceps;
                end
                
                if ~isempty(lineasT)
                    if isnan(Estado.OffsetTobillo) 
                        Estado.OffsetTobillo = posixtime(datetime('now')) - lineasT(1,1);
                    end
                    lineasT(:,1) = lineasT(:,1) + Estado.OffsetTobillo;
                end
                
                if Estado.T0_Global == -1
                    t0s = [];
                    if ~isempty(lineasB), t0s = [t0s, lineasB(1,1)]; end
                    if ~isempty(lineasT), t0s = [t0s, lineasT(1,1)]; end
                    if ~isempty(t0s), Estado.T0_Global = min(t0s); end
                end

                if ~isempty(lineasB) && Estado.T0_Global ~= -1
                    for i = 1:size(lineasB, 1)
                        datosB = lineasB(i,:);
                        Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed(2:end), datosB(2)]; 
                        Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR(2:end), datosB(3)];
                        Estado.DedoDetectado = (datosB(3) > Config.Umbrales.IR_Minimo_Dedo);
                    end
                end

                if ~isempty(lineasT) && Estado.T0_Global ~= -1
                    for i = 1:size(lineasT, 1)
                        datosT = lineasT(i,:);
                        
                        tRelativo = datosT(1) - Estado.T0_Global;
                        if tRelativo < 0, continue; end 
                        
                        % ✅ DSP EMG: Filtro Pasa-Altos (Deriva) -> Rectificación -> Filtro Pasa-Bajos (Envolvente)
                        emg_crudo = datosT(5);
                        Estado.DSP.EMG_Baseline = (1 - Config.Filtros.Alpha_EMG_HP) * Estado.DSP.EMG_Baseline + (Config.Filtros.Alpha_EMG_HP * emg_crudo);
                        emg_ac = abs(emg_crudo - Estado.DSP.EMG_Baseline); % Rectificación
                        Estado.DSP.EMG_Envelope = (1 - Config.Filtros.Alpha_EMG_LP) * Estado.DSP.EMG_Envelope + (Config.Filtros.Alpha_EMG_LP * emg_ac);
                        
                        % ✅ DSP SVM: Filtro Pasa-Altos lento para aislar gravedad
                        svm_crudo = sqrt(sum(datosT(2:4).^2));
                        Estado.DSP.SVM_Baseline = (1 - Config.Filtros.Alpha_SVM) * Estado.DSP.SVM_Baseline + (Config.Filtros.Alpha_SVM * svm_crudo);
                        svm_ac = abs(svm_crudo - Estado.DSP.SVM_Baseline);
                        
                        % Detección basada en envolventes limpias
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
                        
                        % Actualización Vitales
                        if mod(Estado.UI.MuestrasRecibidas, 50) == 0
                            [Estado.Vitales.SPO2, Estado.Vitales.BPM] = detectarBPMRobusto(Estado.Vitales.BufferRed, Estado.Vitales.BufferIR, Config.Muestreo.Fs_Hz); 
                            
                            if Estado.DedoDetectado
                                nuevoSPO2 = sprintf('%d%% SpO2', round(Estado.Vitales.SPO2));
                                nuevoBPM  = sprintf('%d BPM', round(Estado.Vitales.BPM));
                                UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                            else
                                nuevoSPO2 = 'SIN DEDO'; nuevoBPM = '--- BPM'; 
                                UI.lblSPO2.FontColor = [0.8 0.2 0.2]; 
                            end
                            
                            if ~strcmp(Estado.UI.SPO2Text, nuevoSPO2)
                                UI.lblSPO2.Text = nuevoSPO2; Estado.UI.SPO2Text = nuevoSPO2;
                            end
                            if ~strcmp(Estado.UI.BPMText, nuevoBPM)
                                UI.lblBPM.Text = nuevoBPM; Estado.UI.BPMText = nuevoBPM;
                            end
                            mostrarMemoriaSegura();
                        end
                        
                        % Backup
                        Estado.UI.MuestrasDesdeUltimoBackup = Estado.UI.MuestrasDesdeUltimoBackup + 1;
                        if Estado.UI.MuestrasDesdeUltimoBackup > Config.Backup.MuestrasIntervalo
                            backupIncrementalOptimizado(RingBuffer, Estado.UltimoBackupIdx, Config.BufferMax.Muestras);
                            Estado.UltimoBackupIdx = RingBuffer.Idx;
                            Estado.UI.MuestrasDesdeUltimoBackup = 0;
                        end
                        
                        % Guardamos la Envolvente Limpia en el buffer en lugar del EMG bruto ruidoso
                        guardarEnRingBuffer(datosT(1), Estado.DSP.EMG_Envelope, svm_ac, Estado.Vitales.SPO2, Estado.Vitales.BPM, contraccionActual, Config);
                        Estado.UI.MuestrasRecibidas = Estado.UI.MuestrasRecibidas + 1;
                    end
                end
            end
        catch excepcionMain
            logSistema('WARN', ['Excepción principal (mitigada): ', excepcionMain.message]);
        end
        drawnow limitrate; 
        pause(0.001); 
    end
    
    %% --- 5. FUNCIONES PRINCIPALES DE CONTROL ---
    
    function alternarCaptura()
        Estado.Capturando = ~Estado.Capturando;
        if Estado.Capturando
            Estado.OffsetTobillo = NaN;
            Estado.OffsetBiceps = NaN;
            Estado.T0_Global = -1;
            
            Estado.DSP.EMG_Baseline = 0;
            Estado.DSP.EMG_Envelope = 0;
            Estado.DSP.SVM_Baseline = 1.0; 
            
            Estado.UI.ContraccionPrevia = false; Estado.UI.MuestrasRecibidas = 0;
            Estado.UI.MuestrasDesdeUltimoBackup = 0;
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.EventosPLM = []; Analisis.IdxNav = 0;
            
            try
                Red.UdpControl = udpport("datagram", "LocalPort", Config.Puertos.Control);
                Red.UdpControl.Timeout = 0.1;
                logSistema('INFO', 'Puerto de Control 9999 (SYNC) abierto.');
            catch ME
                logSistema('WARN', ['No se pudo abrir el puerto 9999: ', ME.message]);
            end

            try 
                Red.UdpTobillo = udpport("datagram", "LocalPort", Config.Puertos.Tobillo);
                Red.UdpTobillo.Timeout = 0.5;
                logSistema('INFO', 'Puerto UDP Tobillo abierto.');
            catch ME
                uialert(UI.Fig, ['Error Tobillo: ', ME.message], 'Error UDP'); 
                Estado.Capturando = false; return;
            end
            
            try 
                Red.UdpBiceps  = udpport("datagram", "LocalPort", Config.Puertos.Biceps);
                Red.UdpBiceps.Timeout = 0.5;
                logSistema('INFO', 'Puerto UDP Bíceps abierto.');
            catch ME
                clear Red.UdpTobillo; clear Red.UdpControl;
                uialert(UI.Fig, ['Error Bíceps: ', ME.message], 'Error UDP'); 
                Estado.Capturando = false; return;
            end
            
            UI.lblInfo.Text = "ACTIVO"; UI.lblInfo.FontColor = [0 0.5 0];
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
        [t_d, emg_d, svm_d, spo2_d, bpm_d, anot_d] = descomprimirRingBufferCorregido();
        if isempty(t_d), return; end
        
        try
            nameCSV = fullfile(rutaSalida, sprintf('AVA_Estudio_%s.csv', fStr));
            nameTXT = fullfile(rutaSalida, sprintf('AVA_Anotaciones_%s.txt', fStr));
            
            [anotFinal, epi, validosPLM] = procesarAASM(t_d, emg_d, svm_d, Config.Muestreo.Fs_Hz, Config);
            
            fid = fopen(nameCSV, 'w');
            fprintf(fid, '# AVA Nexus V6.8 Estudio DSP\n');
            fprintf(fid, '# Exportado: %s\n', char(datetime('now')));
            fprintf(fid, 'Time_s_UTC,EMG_Env,SVM_ac,SpO2_pct,BPM_bpm,AASM_SPI\n');
            for i = 1:length(t_d)
                fprintf(fid, '%.6f,%.6f,%.6f,%d,%d,%d\n', t_d(i), emg_d(i), svm_d(i), round(spo2_d(i)), round(bpm_d(i)), anotFinal(i));
            end
            fclose(fid);
            
            fidTxt = fopen(nameTXT, 'w');
            fprintf(fidTxt, 'Tiempo_s_UTC,Anot_SPI\n');
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
            [vT, vEMG, vSVM, vSPO2, vBPM] = leerCSVEnChunks(Archivos.Senales);
            if size(vT, 1) < 10, uialert(UI.Fig, 'CSV inválido.', 'Error'); return; end
            
            fsReal = 1 / mean(diff(vT), 'omitnan');
            [Analisis.Anotaciones, mEpi, validosPLM] = procesarAASM(vT, vEMG, vSVM, fsReal, Config);
            
            Analisis.EventosPLM = validosPLM; 
            Analisis.TotPLM = size(validosPLM, 1);
            Analisis.TotEpisodios = size(mEpi, 1);
            Analisis.T = vT; Analisis.IdxNav = 0;
            actualizarEtiquetaEpisodio(0, Analisis.TotPLM, Analisis.TotEpisodios);
            
            delete(UI.pnlGraficasAna.Children); 
            gGrid = uigridlayout(UI.pnlGraficasAna, [2 + (~isempty(vSPO2)) + (~isempty(vBPM)), 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG Envolvente + PLM'); hold(ax1,'on'); grid(ax1, 'on');
            plot(ax1, vT, vEMG, 'Color', [0.6 0.6 0.6]); 
            plot(ax1, vT, Analisis.Anotaciones * max(100, max(vEMG)), 'r', 'LineWidth', 1.5);
            
            ax2 = uiaxes(gGrid); title(ax2, 'Actigrafía SVM (Filtrada)'); plot(ax2, vT, vSVM, 'Color', [0 0.4 0.8]); grid(ax2, 'on');
            listaEjes = [ax1, ax2]; 
            
            if ~isempty(vSPO2)
                ax3 = uiaxes(gGrid); title(ax3, 'SpO2 %'); plot(ax3, vT, vSPO2, 'g'); ylim(ax3, [85 100]); listaEjes = [listaEjes, ax3];
            end
            if ~isempty(vBPM)
                ax4 = uiaxes(gGrid); title(ax4, 'BPM'); plot(ax4, vT, vBPM, 'r'); ylim(ax4, [40 160]); listaEjes = [listaEjes, ax4];
            end
            UI.AxesAnaLista = listaEjes; 
            cambiarPanel(UI.PnlAna); navegarEpisodios(0);
        catch ME
            uialert(UI.Fig, sprintf('Error al procesar:\n%s', ME.message), 'Error');
        end
    end
    
    %% --- 6. FUNCIONES SECUNDARIAS ---
    
    function dataOut = leerYValidarBatch(puerto, expectedCols, fusionarTiempo)
        dataOut = [];
        if isempty(puerto) || ~isvalid(puerto) || puerto.NumDatagramsAvailable == 0, return; end
        try
            paquetes = read(puerto, min(puerto.NumDatagramsAvailable, 50)); 
        catch, return; end
        
        matrizTemporal = NaN(length(paquetes) * 10, expectedCols - fusionarTiempo);
        indiceValido = 0;
        
        for p = 1:length(paquetes)
            lineas = strsplit(char(paquetes(p).Data), '\n'); 
            for i = 1:length(lineas)
                strLine = strtrim(lineas{i});
                if isempty(strLine) || startsWith(strLine, '#'), continue; end
                
                partes = strsplit(strLine, ',');
                if length(partes) ~= expectedCols, continue; end
                if ~strcmp(m_crc16(strjoin(partes(1:end-1), ',')), partes{end}), continue; end
                
                nums = str2double(partes(1:end-1));
                if any(isnan(nums)), continue; end
                
                if fusionarTiempo && length(nums) >= 2
                    nums = [nums(1) + (nums(2) / 1e6), nums(3:end)];
                end
                
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

    function [vT, vE, vS, vSp, vB] = leerCSVEnChunks(archivo)
        vT=[]; vE=[]; vS=[]; vSp=[]; vB=[];
        fid = fopen(archivo, 'r'); if fid < 0, return; end
        while ~feof(fid), if ~startsWith(fgetl(fid), '#'), break; end; end
        
        while ~feof(fid)
            chunk = nan(10000, 6); idxC = 0;
            for i = 1:10000
                lin = fgetl(fid); if ~ischar(lin), break; end
                if startsWith(lin, '#') || isempty(strip(lin)), continue; end 
                try
                    v = str2double(strsplit(lin, ','));
                    if ~isnan(v(1)) && ~isnan(v(2))
                        idxC = idxC + 1; chunk(idxC, 1:min(length(v), 6)) = v(1:min(length(v), 6));
                    end
                catch, end
            end
            if idxC == 0, break; end
            vT=[vT; chunk(1:idxC,1)]; vE=[vE; chunk(1:idxC,2)]; 
            if size(chunk,2)>=3, vS=[vS; chunk(1:idxC,3)]; end
            if size(chunk,2)>=4, vSp=[vSp; chunk(1:idxC,4)]; end
            if size(chunk,2)>=5, vB=[vB; chunk(1:idxC,5)]; end
            clear chunk;
        end
        fclose(fid);
        vT=vT(:); vE=vE(:); vS=vS(:); vSp=vSp(:); vB=vB(:);
    end

    function guardarEnRingBuffer(t, emg, svm, spo2, bpm, anot, cfg)
        try
            idx = RingBuffer.Idx;
            if idx < 1 || idx > cfg.BufferMax.Muestras, return; end
            RingBuffer.T(idx) = t; RingBuffer.EMG(idx) = emg; RingBuffer.SVM(idx) = svm; 
            RingBuffer.SPO2(idx) = spo2; RingBuffer.BPM(idx) = bpm; RingBuffer.Anot(idx) = anot;
            RingBuffer.Idx = uint32(mod(uint64(idx), uint64(cfg.BufferMax.Muestras))) + 1;
            if RingBuffer.Count < cfg.BufferMax.Muestras, RingBuffer.Count = RingBuffer.Count + 1;
            else, RingBuffer.Full = true; end
        catch, end
    end

    function [t, e, s, sp, b, a] = descomprimirRingBufferCorregido()
        c = RingBuffer.Count; nMax = Config.BufferMax.Muestras;
        if c == 0, t=[]; e=[]; s=[]; sp=[]; b=[]; a=[]; return; end
        if RingBuffer.Full, idxTemp = mod((0:c-1) + RingBuffer.Idx - 1, nMax) + 1;
        else, idxTemp = 1:c; end
        t = RingBuffer.T(idxTemp)'; e = RingBuffer.EMG(idxTemp)';
        s = RingBuffer.SVM(idxTemp)'; sp= RingBuffer.SPO2(idxTemp)';
        b = RingBuffer.BPM(idxTemp)'; a = double(RingBuffer.Anot(idxTemp))';
    end

    function backupIncrementalOptimizado(RB, ultimoIdx, nMax)
        if RB.Count == 0, return; end
        if RB.Idx > ultimoIdx, idxs = ultimoIdx:(RB.Idx - 1); else, idxs = [ultimoIdx:nMax, 1:(RB.Idx - 1)]; end
        T_nuevo = RB.T(idxs); EMG_nuevo = RB.EMG(idxs); SVM_nuevo = RB.SVM(idxs); %#ok<NASGU>
        rutaCache = fullfile(pwd, 'AVA_Nexus_Data', '.cache_incremental');
        if ~isfolder(rutaCache), mkdir(rutaCache); end
        try
            save(fullfile(rutaCache, sprintf('bkp_%s.mat', char(datetime('now', 'Format', 'HHmmss')))), 'T_nuevo', 'EMG_nuevo', 'SVM_nuevo', '-v6');
        catch, end
    end

    function [spo2, bpm] = detectarBPMRobusto(bR, bI, fs)
        % ✅ DSP MÉDICO: Filtro Pasa-Banda digital sin Toolboxes
        spo2 = 95; bpm = 70;
        if length(bR) < fs * 5 || length(bI) < fs * 5, return; end
        
        % Pasa-altos (elimina DC y deriva respiratoria) quitando el promedio móvil de 1s
        bI_HP = bI - movmean(bI, fs);
        % Pasa-bajos (suavizado)
        bI_Filt = movmean(bI_HP, round(fs/10));
        
        bI_norm = bI_Filt / (std(bI_Filt) + eps);
        umbral = 0.5 * std(bI_norm);
        picos = [];
        
        for idx = 2:(length(bI_norm)-1)
            if bI_norm(idx) > bI_norm(idx-1) && bI_norm(idx) > bI_norm(idx+1) && bI_norm(idx) > umbral
                picos = [picos, idx];
            end
        end
        
        if length(picos) > 3
            intProm = mean(diff(picos)) / fs;
            if intProm > 0
                bpmCalc = 60 / intProm;
                if bpmCalc >= 40 && bpmCalc <= 200, bpm = bpmCalc; end
            end
        end
        
        % SpO2 con extracción robusta AC/DC
        bR_HP = bR - movmean(bR, fs);
        acR = std(movmean(bR_HP, round(fs/10)));
        dcR = mean(movmean(bR, fs));
        
        acI = std(bI_Filt);
        dcI = mean(movmean(bI, fs));
        
        if dcR > 0 && dcI > 0
            R = (acR / (dcR + eps)) / (acI / (dcI + eps));
            spo2 = max(85, min(99, 110 - 25 * R));
        end
    end
    
    function [anotFinal, mEpi, validosPLM] = procesarAASM(t, e, s, fs, cfg)
        % ✅ AASM ACTUALIZADO: Filtrado de datos brutos a Envolvente antes de procesar
        t = t(:); e = e(:); s = s(:);
        e_hp = e - movmean(e, fs); % Eliminar línea base
        e_env = movmean(abs(e_hp), round(fs/2)); % Envolvente RMS aproximada
        s_ac = abs(s - movmean(s, fs*5)); % Quitar gravedad del SVM
        
        emg_activo = e_env > cfg.Umbrales.EMG_Contraccion;
        svm_activo = s_ac > cfg.Umbrales.SVM_Movimiento;
        fus = emg_activo & svm_activo;
        
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
            if dur >= 0.5 && dur <= 10.0, mPlm_Candidatos = [mPlm_Candidatos; iIU(i), iFU(i)]; end 
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
        if isfield(R, 'UdpControl') && ~isempty(R.UdpControl) && isvalid(R.UdpControl), clear R.UdpControl; end
        if isfield(R, 'UdpTobillo') && ~isempty(R.UdpTobillo) && isvalid(R.UdpTobillo), clear R.UdpTobillo; end
        if isfield(R, 'UdpBiceps') && ~isempty(R.UdpBiceps) && isvalid(R.UdpBiceps), clear R.UdpBiceps; end
        logSistema('INFO', 'CleanUp exitoso.');
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

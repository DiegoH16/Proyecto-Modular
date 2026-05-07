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
    Config.Muestreo.Fs_Hz  = 50; 
    Config.Muestreo.VentanaGrafica_s = 60; 
    
    % Buffer Seguro de 10 Horas
    Config.BufferMax.Horas = 10;
    Config.BufferMax.Muestras = Config.Muestreo.Fs_Hz * 3600 * Config.BufferMax.Horas; 
    
    Config.UI.RefrescoGraficas_Muestras = 5; % 10 FPS
    Config.Backup.MuestrasIntervalo = Config.Muestreo.Fs_Hz * 300;
    
    % Umbrales 
    Config.Umbrales.IR_Minimo_Dedo = 3000;
    Config.Umbrales.EMG_Contraccion = 150; % Umbral estático sobre el promedio
    Config.Umbrales.SVM_Movimiento = 0.4;  
    
    Config.Filtros.Alpha_Base = 0.001; 
    
    Config.Norm.EMG_Min = -500;  Config.Norm.EMG_Max = 5000;   
    Config.Norm.SVM_Min = 0;     Config.Norm.SVM_Max = 40;    
    
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
    Estado.T0_Unix = -1; % Sincronización absoluta
    Estado.PrimeraTramaTobillo = false;
    Estado.PrimeraTramaBiceps = false;
    Estado.DedoDetectado = false; 
    Estado.UltimoBackupIdx = 1;
    
    Estado.ContadorErroresUDP = 0;
    
    % --- BASE EMG PROMEDIO ---
    Estado.EMG_Promedio = 0;
    Estado.EMG_Muestras = 0;
    
    Estado.Filtros.SVM_Base = 1;    
    
    Estado.Vitales.SPO2 = 98;
    Estado.Vitales.BPM = 70;
    Estado.Vitales.BufferRed = zeros(1, Config.Muestreo.Fs_Hz * 10); 
    Estado.Vitales.BufferIR  = zeros(1, Config.Muestreo.Fs_Hz * 10);
    
    Estado.UI.ContraccionPrevia = false;
    Estado.UI.MuestrasRecibidas = 0;
    Estado.UI.MuestrasDesdeUltimoBackup = 0;
    Estado.UI.SPO2Text = '';
    Estado.UI.BPMText = '';
    
    BufferGrafica = struct('T', zeros(1, 300), 'EMG', zeros(1, 300), 'SVM', zeros(1, 300), 'Idx', 1, 'Count', 0);
    
    % Estructura de Análisis Simplificada
    Analisis = struct('T', [], 'Anotaciones', [], 'EventosPLM', [], 'IdxNav', 0, 'TotPLM', 0, 'TotEpisodios', 0);
    Archivos = struct('Senales', "", 'Anotaciones', "");
    Red = struct('UdpTobillo', [], 'UdpBiceps', []);
    
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));
    
    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA ---
    logSistema('INFO', 'Iniciando AVA Nexus V6.5 Medical Grade - DIAGNÓSTICO UDP');
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus V6.5 | Medical Edition', 'Color', 'w', 'Position', [50, 50, 1200, 900]);
    UI.Fig.CloseRequestFcn = @(src, event) cerrarAplicacion(src, event);
    UI.AxesAnaLista = [];
    
    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    
    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS V6.5', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [450, 650, 400, 60], 'HorizontalAlignment', 'center');
    uilabel(UI.PnlMenu, 'Text', 'OOM-Protected PSG Endurance Edition', 'FontSize', 16, 'Position', [250, 600, 700, 30], 'HorizontalAlignment', 'center', 'FontColor', [0.3 0.3 0.3]);
    uibutton(UI.PnlMenu, 'Text', '1. Adquisición de Datos (UDP)', 'FontSize', 18, 'Position', [375, 450, 450, 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clínico (SPI)', 'FontSize', 18, 'Position', [375, 350, 450, 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAna));
    
    gAdq = uigridlayout(UI.PnlAdq, [6, 3], 'RowHeight', {'1x', '1x', 80, 70, 60, 60}, 'Padding', 20);
    
    UI.axEMG_TR = uiaxes(gAdq); title(UI.axEMG_TR, 'EMG Tibial'); UI.axEMG_TR.Layout.Row = 1; UI.axEMG_TR.Layout.Column = [1 3];
    UI.axSVM_TR = uiaxes(gAdq); title(UI.axSVM_TR, 'Actigrafía SVM'); UI.axSVM_TR.Layout.Row = 2; UI.axSVM_TR.Layout.Column = [1 3];
    
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
                
                % 1. PROCESAR BÍCEPS (Batch de N muestras)
                lineasB = leerYValidarBatch(Red.UdpBiceps, 4); % Espera: UNIX, R, IR, CRC
                if ~isempty(lineasB)
                    if Estado.T0_Unix == -1, Estado.T0_Unix = lineasB(1,1); end
                    
                    for i = 1:size(lineasB, 1)
                        datosB = lineasB(i,:);
                        Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed(2:end), datosB(2)]; 
                        Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR(2:end), datosB(3)];
                        Estado.DedoDetectado = (datosB(3) > Config.Umbrales.IR_Minimo_Dedo);
                    end
                end

                % 2. PROCESAR TOBILLO (Batch de N muestras)
                lineasT = leerYValidarBatch(Red.UdpTobillo, 6); % Espera: UNIX, Ax, Ay, Az, EMG, CRC
                if ~isempty(lineasT)
                    if Estado.T0_Unix == -1, Estado.T0_Unix = lineasT(1,1); end
                    
                    for i = 1:size(lineasT, 1)
                        datosT = lineasT(i,:);
                        tRelativo = datosT(1) - Estado.T0_Unix;
                        
                        % EMG y Promedio
                        emg = datosT(5);
                        Estado.EMG_Muestras = Estado.EMG_Muestras + 1;
                        Estado.EMG_Promedio = Estado.EMG_Promedio + (emg - Estado.EMG_Promedio) / Estado.EMG_Muestras;
                        salto = abs(emg - Estado.EMG_Promedio);
                        
                        % SVM
                        svm = sqrt(sum(datosT(2:4).^2));
                        Estado.Filtros.SVM_Base = ((1-Config.Filtros.Alpha_Base) * Estado.Filtros.SVM_Base) + (Config.Filtros.Alpha_Base * svm);
                        svmAC = abs(svm - Estado.Filtros.SVM_Base);
                        
                        contraccionActual = (salto > Config.Umbrales.EMG_Contraccion) && (svmAC > Config.Umbrales.SVM_Movimiento);
                        
                        % Interfaz Grafica Rápida
                        BufferGrafica.T(BufferGrafica.Idx) = tRelativo;
                        BufferGrafica.EMG(BufferGrafica.Idx) = salto;
                        BufferGrafica.SVM(BufferGrafica.Idx) = svm;
                        
                        BufferGrafica.Idx = mod(BufferGrafica.Idx, 300) + 1;
                        BufferGrafica.Count = min(BufferGrafica.Count + 1, 300);
                        
                        if mod(Estado.UI.MuestrasRecibidas, Config.UI.RefrescoGraficas_Muestras) == 0
                            if contraccionActual ~= Estado.UI.ContraccionPrevia
                                if contraccionActual
                                    UI.lblLed.BackgroundColor = [0.2 0.8 0.2]; UI.lblLed.Text = ' CONTRACCIÓN ';
                                else
                                    UI.lblLed.BackgroundColor = [0.8 0.2 0.2]; UI.lblLed.Text = ' REPOSO ';
                                end
                                Estado.UI.ContraccionPrevia = contraccionActual;
                            end
                            
                            if BufferGrafica.Idx > 1
                                addpoints(UI.lineaEMG, BufferGrafica.T(1:BufferGrafica.Idx-1), BufferGrafica.EMG(1:BufferGrafica.Idx-1));
                                addpoints(UI.lineaSVM, BufferGrafica.T(1:BufferGrafica.Idx-1), BufferGrafica.SVM(1:BufferGrafica.Idx-1));
                                actualizarEjesGrafica([UI.axEMG_TR, UI.axSVM_TR], tRelativo, Config.Muestreo.VentanaGrafica_s);
                                BufferGrafica.Idx = 1; 
                            end
                        end
                        
                        % Vitales UI Update
                        if mod(Estado.UI.MuestrasRecibidas, 50) == 0
                            [Estado.Vitales.SPO2, Estado.Vitales.BPM] = detectarBPMRobusto(Estado.Vitales.BufferRed, Estado.Vitales.BufferIR, Config.Muestreo.Fs_Hz); 
                            
                            if Estado.DedoDetectado
                                nuevoSPO2 = sprintf('%d%% SpO2', round(Estado.Vitales.SPO2));
                                nuevoBPM  = sprintf('%d BPM', round(Estado.Vitales.BPM));
                                UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                            else
                                nuevoSPO2 = 'SIN DEDO'; 
                                nuevoBPM = '--- BPM'; 
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
                        
                        guardarEnRingBuffer(tRelativo, salto, svm, Estado.Vitales.SPO2, Estado.Vitales.BPM, contraccionActual, Config);
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
            Estado.T0_Unix = -1; % RESET TIEMPO UNIX
            Estado.PrimeraTramaTobillo = false; Estado.PrimeraTramaBiceps = false;
            Estado.Filtros.PPG_Base = 0; 
            Estado.UI.ContraccionPrevia = false; Estado.UI.MuestrasRecibidas = 0;
            Estado.UI.MuestrasDesdeUltimoBackup = 0;
            
            Estado.EMG_Promedio = 0;
            Estado.EMG_Muestras = 0;
            Estado.Filtros.SVM_Base = 1;
            
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.EventosPLM = []; Analisis.IdxNav = 0;
            
            try 
                Red.UdpTobillo = udpport("datagram", "LocalPort", Config.Puertos.Tobillo); 
                logSistema('INFO', 'Puerto UDP Tobillo abierto.');
            catch ME
                uialert(UI.Fig, ['Error Tobillo: ', ME.message], 'Error UDP'); 
                Estado.Capturando = false;
                return;
            end
            
            try 
                Red.UdpBiceps  = udpport("datagram", "LocalPort", Config.Puertos.Biceps); 
                logSistema('INFO', 'Puerto UDP Bíceps abierto.');
            catch ME
                clear Red.UdpTobillo; 
                uialert(UI.Fig, ['Error Bíceps: ', ME.message], 'Error UDP'); 
                Estado.Capturando = false;
                return;
            end
            
            UI.lblInfo.Text = "ACTIVO"; UI.lblInfo.FontColor = [0 0.5 0];
            clearpoints(UI.lineaEMG); clearpoints(UI.lineaSVM); 
            
            UI.btnUDP.Text = "⏹ Detener"; UI.btnUDP.BackgroundColor = [1 0.4 0.4];
            logSistema('INFO', 'Captura iniciada. Esperando datos UDP...');
        else
            liberarRecursos(Red);
            UI.btnUDP.Text = "▶ Conectar Hardware"; UI.btnUDP.BackgroundColor = [0.2 0.6 0.2];
            UI.lblInfo.Text = "EN ESPERA"; UI.lblInfo.FontColor = [0.5 0.5 0.5];
            logSistema('INFO', 'Captura detenida.');
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
            if isfile(nameCSV), logSistema('WARN', 'Sobrescribiendo archivo existente.'); end
            
            [anotFinal, epi, validosPLM] = procesarAASM(t_d, emg_d, svm_d, Config.Muestreo.Fs_Hz, Config);
            
            logSistema('INFO', 'Iniciando escritura OOM-Safe de CSV...');
            fid = fopen(nameCSV, 'w');
            if fid < 0, logSistema('ERROR', 'Permiso denegado para CSV'); return; end
            
            fprintf(fid, '# AVA Nexus V6.5 Estudio Polisomnográfico\n');
            fprintf(fid, '# Exportado: %s\n', char(datetime('now')));
            fprintf(fid, '# Duración: %.2f horas\n', (t_d(end) - t_d(1)) / 3600);
            fprintf(fid, 'Time_s,EMG_uV,SVM_m_s2,SpO2_pct,BPM_bpm,AASM_SPI\n');
            
            for i = 1:length(t_d)
                fprintf(fid, '%.6f,%.6f,%.6f,%d,%d,%d\n', t_d(i), emg_d(i), svm_d(i), round(spo2_d(i)), round(bpm_d(i)), anotFinal(i));
            end
            fclose(fid);
            
            fidTxt = fopen(nameTXT, 'w');
            fprintf(fidTxt, 'Tiempo_s,Anot_SPI\n');
            for i = 1:length(t_d), fprintf(fidTxt, '%.6f,%d\n', t_d(i), anotFinal(i)); end
            fclose(fidTxt);
            
            uialert(UI.Fig, sprintf('Exportado Correctamente:\n%d muestras\nDirectorio: %s', length(t_d), rutaSalida), 'Éxito');
        catch ME
            logSistema('ERROR', ['Fallo I/O en Exportación: ', ME.message]);
            uialert(UI.Fig, sprintf('Error crítico de escritura.\nDetalle: %s', ME.message), 'Fallo Sistema');
        end
        cambiarPanel(UI.PnlMenu);
    end

    function ejecutarAnalisisPro()
        if Archivos.Senales == "", uialert(UI.Fig, 'Seleccione un CSV.', 'Aviso'); return; end
        try
            logSistema('INFO', 'Cargando archivo masivo por chunks...');
            [vT, vEMG, vSVM, vSPO2, vBPM] = leerCSVEnChunks(Archivos.Senales);
            
            if size(vT, 1) < 10, uialert(UI.Fig, 'CSV inválido o muy corto.', 'Error'); return; end
            
            dtReal = mean(diff(vT), 'omitnan');
            if dtReal <= 0 || isnan(dtReal), uialert(UI.Fig, 'Tiempos nulos o corruptos detectados.', 'Error'); return; end
            fsReal = 1 / dtReal;
            
            [Analisis.Anotaciones, mEpi, validosPLM] = procesarAASM(vT, vEMG, vSVM, fsReal, Config);
            
            totPLM = size(validosPLM, 1);
            totEpisodios = size(mEpi, 1);
            
            Analisis.EventosPLM = validosPLM; 
            Analisis.TotPLM = totPLM;
            Analisis.TotEpisodios = totEpisodios;
            
            Analisis.T = vT; Analisis.IdxNav = 0;
            actualizarEtiquetaEpisodio(0, totPLM, totEpisodios);
            
            delete(UI.pnlGraficasAna.Children); 
            
            numGrafs = 2 + (~isempty(vSPO2)) + (~isempty(vBPM));
            gGrid = uigridlayout(UI.pnlGraficasAna, [numGrafs, 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG + AASM (Regla de 4 Aplicada)'); hold(ax1,'on'); grid(ax1, 'on');
            plot(ax1, vT, vEMG, 'Color', [0.6 0.6 0.6]); 
            
            maxEmgDisplay = max(vEMG); if maxEmgDisplay < 10, maxEmgDisplay = 100; end
            plot(ax1, vT, Analisis.Anotaciones * maxEmgDisplay, 'r', 'LineWidth', 1.5);
            
            ax2 = uiaxes(gGrid); title(ax2, 'SVM Actigrafía'); plot(ax2, vT, vSVM, 'Color', [0 0.4 0.8]); grid(ax2, 'on');
            listaEjes = [ax1, ax2]; 
            
            if ~isempty(vSPO2)
                ax3 = uiaxes(gGrid); title(ax3, 'SpO2 %'); plot(ax3, vT, vSPO2, 'g', 'LineWidth', 1.5); ylim(ax3, [85 100]); grid(ax3, 'on');
                listaEjes = [listaEjes, ax3];
            end
            if ~isempty(vBPM)
                ax4 = uiaxes(gGrid); title(ax4, 'BPM'); plot(ax4, vT, vBPM, 'r', 'LineWidth', 1.5); ylim(ax4, [50 120]); grid(ax4, 'on');
                listaEjes = [listaEjes, ax4];
            end
            
            UI.AxesAnaLista = listaEjes; 
            cambiarPanel(UI.PnlAna); navegarEpisodios(0);
            logSistema('INFO', 'Análisis en memoria renderizado con éxito.');
            
        catch ME
            logSistema('ERROR', ['Crash Analizador: ', ME.message]);
            uialert(UI.Fig, sprintf('Error al procesar los archivos:\n%s', ME.message), 'Error de Análisis');
        end
    end
    
    %% --- 6. FUNCIONES SECUNDARIAS Y CRC16 ---
    
    function dataOut = leerYValidarBatch(puerto, expectedCols)
        dataOut = [];
        if isempty(puerto) || puerto.NumDatagramsAvailable == 0
            return; 
        end
        
        numPaquetes = puerto.NumDatagramsAvailable;
        paquetes = read(puerto, numPaquetes); 
        
        for p = 1:numPaquetes
            payload = char(paquetes(p).Data);
            
            % --- ¡IMPRIMIR EN CONSOLA LO QUE LLEGA! ---
            disp(['[', num2str(puerto.LocalPort), '] Recibido: ', payload]); 
            
            lineas = strsplit(payload, '\n'); 
            
            for i = 1:length(lineas)
                strLine = strtrim(lineas{i});
                if isempty(strLine), continue; end
                
                partes = strsplit(strLine, ',');
                if length(partes) == expectedCols
                    crcRecibidoStr = partes{end};
                    msgOriginal = strjoin(partes(1:end-1), ',');
                    
                    crcCalculado = m_crc16(msgOriginal);
                    if strcmp(crcCalculado, crcRecibidoStr)
                        nums = str2double(partes(1:end-1));
                        if ~any(isnan(nums))
                            dataOut = [dataOut; nums]; %#ok<AGROW>
                        end
                    else
                        disp(['[WARN] CRC Fallido. Recibido: ', crcRecibidoStr, ' Esperado: ', crcCalculado]);
                    end
                else
                    disp(['[WARN] Cols incorrectas. Exp: ', num2str(expectedCols), ' Rx: ', num2str(length(partes))]);
                end
            end
        end
    end

    function crcHex = m_crc16(data)
        crc = uint16(hex2dec('FFFF'));
        bytes = uint8(char(data)); % <-- FORZADO A CHAR
        for i = 1:length(bytes)
            crc = bitxor(crc, uint16(bytes(i)));
            for j = 1:8
                if bitand(crc, 1)
                    crc = bitxor(bitshift(crc, -1), uint16(hex2dec('A001')));
                else
                    crc = bitshift(crc, -1);
                end
            end
        end
        crcHex = sprintf('%04X', crc);
    end

    function mostrarMemoriaSegura()
        try
            mem = memory();
            memMB = mem.MemUsedMATLAB / 1024^2;
            pct = 100 * mem.MemUsedMATLAB / (mem.MemUsedMATLAB + mem.MemAvailableAllArrays);
            UI.lblMemoria.Text = sprintf('RAM: %.0f MB (%.1f%%)', memMB, pct);
        catch
            UI.lblMemoria.Text = 'RAM: N/A';
        end
    end

    function [vT, vE, vS, vSp, vB] = leerCSVEnChunks(archivo)
        chunkMuestras = 15000; 
        vT=[]; vE=[]; vS=[]; vSp=[]; vB=[];
        
        fid = fopen(archivo, 'r'); 
        if fid < 0, return; end
        fgetl(fid); 
        
        while ~feof(fid)
            chunk = zeros(chunkMuestras, 6); 
            idxC = 0;
            for i = 1:chunkMuestras
                lin = fgetl(fid); 
                if ~ischar(lin), break; end
                if startsWith(lin, '#') || isempty(strip(lin)), continue; end 
                
                try
                    v = str2double(strsplit(lin, ','));
                    if length(v) >= 2 && ~isnan(v(1)) && ~isnan(v(2))
                        idxC = idxC + 1;
                        if idxC > size(chunk, 1), chunk = [chunk; zeros(5000, 6)]; end %#ok<AGROW>
                        chunk(idxC, 1:min(length(v), 6)) = v(1:min(length(v), 6));
                    end
                catch
                end
            end
            if idxC == 0, break; end
            vT=[vT; chunk(1:idxC,1)]; vE=[vE; chunk(1:idxC,2)]; 
            if size(chunk,2)>=3, vS=[vS; chunk(1:idxC,3)]; end
            if size(chunk,2)>=4, vSp=[vSp; chunk(1:idxC,4)]; end
            if size(chunk,2)>=5, vB=[vB; chunk(1:idxC,5)]; end
        end
        fclose(fid);
        vT=vT(:); vE=vE(:); vS=vS(:); vSp=vSp(:); vB=vB(:);
    end

    function guardarEnRingBuffer(t, emg, svm, spo2, bpm, anot, cfg)
        try
            idx = RingBuffer.Idx;
            if idx < 1 || idx > cfg.BufferMax.Muestras, return; end
            RingBuffer.T(idx)    = t; RingBuffer.EMG(idx)  = emg;
            RingBuffer.SVM(idx)  = svm; RingBuffer.SPO2(idx) = spo2;
            RingBuffer.BPM(idx)  = bpm; RingBuffer.Anot(idx) = anot;
            RingBuffer.Idx = uint32(mod(uint64(idx), uint64(cfg.BufferMax.Muestras))) + 1;
            if RingBuffer.Count < cfg.BufferMax.Muestras, RingBuffer.Count = RingBuffer.Count + 1;
            else, RingBuffer.Full = true; end
        catch
        end
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
        if RB.Idx > ultimoIdx, idxs = ultimoIdx : (RB.Idx - 1);
        else, idxs = [ultimoIdx : nMax, 1 : (RB.Idx - 1)]; end
        if isempty(idxs) || length(idxs) > nMax, return; end
        T_nuevo = RB.T(idxs); EMG_nuevo = RB.EMG(idxs); SVM_nuevo = RB.SVM(idxs); %#ok<NASGU>
        rutaCache = fullfile(pwd, 'AVA_Nexus_Data', '.cache_incremental');
        if ~isfolder(rutaCache), mkdir(rutaCache); end
        fStr = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
        try
            save(fullfile(rutaCache, sprintf('bkp_chunk_%s.mat', fStr)), 'T_nuevo', 'EMG_nuevo', 'SVM_nuevo', '-v6');
            archivos = dir(fullfile(rutaCache, 'bkp_chunk_*.mat'));
            if length(archivos) > 10
                [~, iSort] = sort([archivos.datenum]); delete(fullfile(rutaCache, archivos(iSort(1)).name));
            end
        catch
        end
    end

    function [s, b] = detectarBPMRobusto(bR, bI, fs)
        s = 95; b = 70; 
        bR_AC = bR - mean(bR); bI_AC = bI - mean(bI);
        acR = std(bR_AC); dcR = mean(abs(bR)); acI = std(bI_AC); dcI = mean(abs(bI));
        if dcR == 0 || dcI == 0, return; end
        R = (acR / dcR) / (acI / dcI); s = max(85, min(99, 110 - 25 * R));
        if length(bI_AC) < 2 * fs, return; end
        try
            bI_norm = (bI_AC - mean(bI_AC)) / (std(bI_AC) + eps);
            umbral = std(bI_norm) * 0.3;
            picos = find(bI_norm(2:end-1) > bI_norm(1:end-2) & bI_norm(2:end-1) > bI_norm(3:end) & bI_norm(2:end-1) > umbral) + 1;
            if length(picos) > 2
                intProm = mean(diff(picos)) / fs; bpmCalc = 60 / intProm;
                if bpmCalc >= 30 && bpmCalc <= 220, b = bpmCalc; end
            end
        catch
        end
    end
    
    %% --- LÓGICA AASM RESTAURADA ---
    function [anotFinal, mEpi, validosPLM] = procesarAASM(t, e, s, fs, cfg)
        t = t(:); e = e(:); s = s(:);
        e_mean = mean(e, 'omitnan'); e_salto = abs(e - e_mean);
        s_mean = movmean(s, fs * 2); s_ac = abs(s - s_mean);
        
        emg_activo = e_salto > cfg.Umbrales.EMG_Contraccion;
        svm_activo = s_ac > cfg.Umbrales.SVM_Movimiento;
        fus = emg_activo & svm_activo;
        
        fl = diff([0; fus; 0]); iI = find(fl==1); iF = find(fl==-1)-1;
        
        iIU = []; iFU = [];
        if ~isempty(iI)
            cA = iI(1); cF = iF(1);
            for i = 2:length(iI)
                if (iI(i) - cF)/fs < 0.5, cF = iF(i); 
                else, iIU(end+1,1)=cA; iFU(end+1,1)=cF; cA=iI(i); cF=iF(i); end %#ok<AGROW>
            end
            iIU(end+1,1)=cA; iFU(end+1,1)=cF;
        end
        
        mPlm_Candidatos = []; 
        for i = 1:length(iIU)
            dur = (iFU(i) - iIU(i)) / fs; 
            if dur >= 0.5 && dur <= 10.0, mPlm_Candidatos = [mPlm_Candidatos; iIU(i), iFU(i)]; end %#ok<AGROW>
        end
        
        mEpi = []; 
        validosPLM = []; 
        
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
            rutaFull = fullfile(r, n);
            if ~isfile(rutaFull)
                uialert(UI.Fig, 'Archivo no encontrado.', 'Error'); return; 
            end
            if strcmp(tipo, 'DATOS')
                Archivos.Senales = rutaFull; UI.lblArchivoData.Text = ['CSV: ' n];
            else
                Archivos.Anotaciones = rutaFull; UI.lblArchivoData.Text = [UI.lblArchivoData.Text ' | TXT: ' n];
            end
            logSistema('INFO', ['Ingesta File I/O: ', n]);
        end
    end

    function actualizarEtiquetaEpisodio(idx, tPLM, tEpi)
        if idx < 0 || idx > tPLM || tPLM < 0, idx = 0; tPLM = 0; end
        try
            UI.lblEpi.Text = sprintf('SPI: %d / %d | Episodios: %d', idx, tPLM, tEpi);
        catch
            UI.lblEpi.Text = 'Datos Analíticos Corruptos';
        end
    end

    function navegarEpisodios(dir)
        if isempty(Analisis.EventosPLM) || isempty(UI.AxesAnaLista), return; end
        
        Analisis.IdxNav = max(1, min(Analisis.IdxNav + dir, size(Analisis.EventosPLM, 1)));
        actualizarEtiquetaEpisodio(Analisis.IdxNav, Analisis.TotPLM, Analisis.TotEpisodios);
        
        tInicioEspasmo = Analisis.T(Analisis.EventosPLM(Analisis.IdxNav,1));
        tFinEspasmo    = Analisis.T(Analisis.EventosPLM(Analisis.IdxNav,2));
        
        lim = [tInicioEspasmo - 5, tFinEspasmo + 5];
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
        logSistema('INFO', 'CleanUp exitoso.');
    end

    function cerrarAplicacion(src, ~)
        Estado.Capturando = false; liberarRecursos(Red); delete(src);
    end

    function logSistema(nivel, mensaje)
        persistent t0
        if isempty(t0), t0 = datetime('now'); end
        try
            tAbs = seconds(datetime('now') - t0); fprintf('[%8.2fs] [%-5s] %s\n', tAbs, nivel, char(mensaje)); 
        catch
        end
    end
end

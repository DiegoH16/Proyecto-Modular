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
    
    % Buffer Seguro de 10 Horas (Pre-asignado)
    Config.BufferMax.Horas = 10;
    Config.BufferMax.Muestras = Config.Muestreo.Fs_Hz * 3600 * Config.BufferMax.Horas; 
    
    Config.UI.RefrescoGraficas_Muestras = 5; % 10 FPS
    Config.UI.MaxPaquetesUDP_Lectura = 20; 
    Config.Backup.MuestrasIntervalo = Config.Muestreo.Fs_Hz * 300; % Chunk Backup 5 min
    
    Config.Umbrales.IR_Minimo_Dedo = 3000;
    Config.Umbrales.EMG_Contraccion = 150;
    Config.Umbrales.SVM_Movimiento = 0.4;
    
    Config.Filtros.Alpha_Base = 0.001;
    Config.Filtros.Alpha_Env  = 0.15;
    
    % Límites Fisiológicos para Normalización y Validación
    Config.Norm.EMG_Min = -500;  Config.Norm.EMG_Max = 500;   % Rango clínico uV/mV
    Config.Norm.SVM_Min = 0;     Config.Norm.SVM_Max = 15;    % Max G-force esperado
    
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
    Estado.T0_Tobillo = -1;
    Estado.T0_Biceps = -1;
    Estado.tCrudoAnterior_Tobillo = -1;
    Estado.PrimeraTramaTobillo = false;
    Estado.PrimeraTramaBiceps = false;
    Estado.DedoDetectado = false; 
    Estado.UltimoBackupIdx = 1;
    
    Estado.ContadorErroresUDP = 0;
    Estado.MaximoErroresPermitidos = 100; 
    
    Estado.Filtros.EMG_Base = 1870; Estado.Filtros.EMG_Env = 0;
    Estado.Filtros.SVM_Base = 1;    Estado.Filtros.SVM_Env = 0;
    Estado.Filtros.PPG_Base = 0;
    
    Estado.Vitales.SPO2 = 98;
    Estado.Vitales.BPM = 70;
    Estado.Vitales.BufferRed = zeros(1, Config.Muestreo.Fs_Hz * 10); 
    Estado.Vitales.BufferIR  = zeros(1, Config.Muestreo.Fs_Hz * 10);
    
    % UI Cache state
    Estado.UI.ContraccionPrevia = false;
    Estado.UI.MuestrasRecibidas = 0;
    Estado.UI.MuestrasDesdeUltimoBackup = 0;
    Estado.UI.SPO2Text = '';
    Estado.UI.BPMText = '';
    
    % Buffer Gráfico (Atómico)
    BufferGrafica = struct('T', zeros(1, 300), 'EMG', zeros(1, 300), 'SVM', zeros(1, 300), 'Idx', 1, 'Count', 0);
    
    Analisis = struct('T', [], 'Anotaciones', [], 'Episodios', [], 'IdxNav', 0, 'TotPLM', 0, 'TotSPI', 0);
    Archivos = struct('Senales', "", 'Anotaciones', "");
    Red = struct('UdpTobillo', [], 'UdpBiceps', []);
    
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));
    
    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA ---
    logSistema('INFO', 'Iniciando AVA Nexus V6.2 Medical Grade');
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus V6.2 | Medical Edition', 'Color', 'w', 'Position', [50, 50, 1200, 900]);
    UI.Fig.CloseRequestFcn = @(src, event) cerrarAplicacion(src, event);
    UI.AxesAnaLista = [];
    
    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    
    % --- Menú ---
    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS V6.2', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [450 650 300 60], 'HorizontalAlignment', 'center');
    uilabel(UI.PnlMenu, 'Text', 'OOM-Protected PSG Endurance Edition', 'FontSize', 16, 'Position', [250, 600, 700, 30], 'HorizontalAlignment', 'center', 'FontColor', [0.3 0.3 0.3]);
    uibutton(UI.PnlMenu, 'Text', '1. Adquisición de Datos (UDP)', 'FontSize', 18, 'Position', [375 450 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clínico (OOM Safe)', 'FontSize', 18, 'Position', [375 350 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAna));
    
    % --- Panel Adquisición ---
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

    % --- Panel Analizador ---
    gAna = uigridlayout(UI.PnlAna, [2, 1], 'RowHeight', {45, '1x'}, 'Padding', 5);
    gToolbar = uigridlayout(gAna, [1, 9], 'ColumnWidth', {120, 120, 40, 80, 80, 60, '1x', 140, 80}, 'Padding', 2);
    
    uibutton(gToolbar, 'Text', '📁 Cargar CSV', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) cargarArchivo('DATOS'));
    uibutton(gToolbar, 'Text', '📝 Cargar TXT', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) cargarArchivo('ANOT'));
    uilabel(gToolbar, 'Text', '|', 'HorizontalAlignment', 'center');
    uibutton(gToolbar, 'Text', '<< Ant', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) navegarEpisodios(-1));
    uibutton(gToolbar, 'Text', 'Sig >>', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) navegarEpisodios(1));
    uibutton(gToolbar, 'Text', 'Todo', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) verTodoAnalisis());
    
    UI.lblEpi = uilabel(gToolbar, 'Text', 'Episodios: 0 / 0 | Totales: --', 'FontSize', 13, 'FontWeight', 'bold', 'FontColor', [0.7 0.1 0.1], 'HorizontalAlignment', 'center');
    
    uibutton(gToolbar, 'Text', '⚙️ PROCESAR', 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'FontSize', 12, 'FontWeight', 'bold', 'ButtonPushedFcn', @(src, event) ejecutarAnalisisPro());
    uibutton(gToolbar, 'Text', 'Volver', 'FontSize', 12, 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlMenu));

    UI.pnlGraficasAna = uipanel(gAna, 'BorderType', 'none', 'BackgroundColor', 'w');

    %% --- 4. BUCLE PRINCIPAL (OOM-Safe) ---
    while ishandle(UI.Fig)
        try
            if Estado.Capturando 
                
                % --- BÍCEPS ---
                [datosBiceps, exitoB] = leerYValidarUDP(Red.UdpBiceps, 3, Config.UI.MaxPaquetesUDP_Lectura);
                if exitoB
                    tCrudo = datosBiceps(1)/1000;
                    if Estado.T0_Biceps == -1, Estado.T0_Biceps = tCrudo; end
                    
                    if ~Estado.PrimeraTramaBiceps
                        logSistema('INFO', 'BÍCEPS conectado y sincronizado.');
                        Estado.PrimeraTramaBiceps = true;
                    end
                    
                    Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed(2:end), datosBiceps(2)]; 
                    Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR(2:end), datosBiceps(3)];
                    
                    if datosBiceps(3) > Config.Umbrales.IR_Minimo_Dedo
                        Estado.DedoDetectado = true;
                    else
                        Estado.DedoDetectado = false;
                    end
                end

                % --- TOBILLO ---
                [datosTobillo, exitoT] = leerYValidarUDP(Red.UdpTobillo, 5, Config.UI.MaxPaquetesUDP_Lectura);
                if exitoT
                    Estado.ContadorErroresUDP = max(0, Estado.ContadorErroresUDP - 1);
                    
                    tCrudo = datosTobillo(1)/1000;
                    if ~validarContinuidadTemporal(tCrudo, 'TOBILLO')
                        continue; 
                    end
                    
                    if Estado.T0_Tobillo == -1, Estado.T0_Tobillo = tCrudo; end
                    
                    if ~Estado.PrimeraTramaTobillo
                        logSistema('INFO', 'TOBILLO conectado.');
                        Estado.PrimeraTramaTobillo = true;
                        
                        % Sincronización Inicial Robusta
                        if Estado.PrimeraTramaBiceps
                            tDif = abs(Estado.T0_Tobillo - Estado.T0_Biceps); 
                            if tDif > 5.0
                                logSistema('ERROR', sprintf('Desfase crítico de nodos: %.3f s', tDif)); 
                            end
                        end
                    end
                    
                    % Validación estricta de rangos (OOM/Crash Protection)
                    if ~validarDatosCrudos(datosTobillo, Config), continue; end
                    
                    tTobillo = tCrudo - Estado.T0_Tobillo;
                    svmCrudo = sqrt(datosTobillo(2)^2 + datosTobillo(3)^2 + datosTobillo(4)^2);
                    emgCrudo = datosTobillo(5);
                    
                    if ~Estado.UI.ContraccionPrevia 
                        Estado.Filtros.EMG_Base = ((1-Config.Filtros.Alpha_Base) * Estado.Filtros.EMG_Base) + (Config.Filtros.Alpha_Base * emgCrudo);
                        Estado.Filtros.SVM_Base = ((1-Config.Filtros.Alpha_Base) * Estado.Filtros.SVM_Base) + (Config.Filtros.Alpha_Base * svmCrudo);
                    end
                    
                    Estado.Filtros.EMG_Env = ((1-Config.Filtros.Alpha_Env) * Estado.Filtros.EMG_Env) + (Config.Filtros.Alpha_Env * abs(emgCrudo - Estado.Filtros.EMG_Base));
                    Estado.Filtros.SVM_Env = ((1-Config.Filtros.Alpha_Env) * Estado.Filtros.SVM_Env) + (Config.Filtros.Alpha_Env * abs(svmCrudo - Estado.Filtros.SVM_Base));
                    
                    contraccionActual = (Estado.Filtros.EMG_Env > Config.Umbrales.EMG_Contraccion) && (Estado.Filtros.SVM_Env > Config.Umbrales.SVM_Movimiento);
                    
                    % Operación Atómica en Buffer Circular Gráfico
                    BufferGrafica.T(BufferGrafica.Idx) = tTobillo;
                    BufferGrafica.EMG(BufferGrafica.Idx) = Estado.Filtros.EMG_Env;
                    BufferGrafica.SVM(BufferGrafica.Idx) = svmCrudo;
                    
                    BufferGrafica.Idx = mod(BufferGrafica.Idx, 300) + 1;
                    BufferGrafica.Count = min(BufferGrafica.Count + 1, 300);
                    
                    % UI Throttling Seguro (Batch Flush)
                    if mod(Estado.UI.MuestrasRecibidas, Config.UI.RefrescoGraficas_Muestras) == 0
                        % Actualización LED
                        if contraccionActual ~= Estado.UI.ContraccionPrevia
                            if contraccionActual
                                UI.lblLed.BackgroundColor = [0.2 0.8 0.2]; UI.lblLed.Text = ' CONTRACCIÓN ';
                            else
                                UI.lblLed.BackgroundColor = [0.8 0.2 0.2]; UI.lblLed.Text = ' REPOSO ';
                            end
                            Estado.UI.ContraccionPrevia = contraccionActual;
                        end
                        
                        % Extraer en orden correcto 
                        if BufferGrafica.Idx > 1
                            addpoints(UI.lineaEMG, BufferGrafica.T(1:BufferGrafica.Idx-1), BufferGrafica.EMG(1:BufferGrafica.Idx-1));
                            addpoints(UI.lineaSVM, BufferGrafica.T(1:BufferGrafica.Idx-1), BufferGrafica.SVM(1:BufferGrafica.Idx-1));
                            actualizarEjesGrafica([UI.axEMG_TR, UI.axSVM_TR], tTobillo, Config.Muestreo.VentanaGrafica_s);
                            BufferGrafica.Idx = 1; % Limpiar Batch tras dibujar
                        end
                    end
                    
                    % Vitales y RAM (~1 segundo)
                    if mod(Estado.UI.MuestrasRecibidas, 50) == 0
                        [Estado.Vitales.SPO2, Estado.Vitales.BPM] = detectarBPMRobusto(Estado.Vitales.BufferRed, Estado.Vitales.BufferIR, Config.Muestreo.Fs_Hz); 
                        
                        if Estado.DedoDetectado
                            nuevoSPO2 = sprintf('%d%%', round(Estado.Vitales.SPO2));
                            nuevoBPM  = sprintf('%d', round(Estado.Vitales.BPM));
                            UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                        else
                            nuevoSPO2 = 'SIN DEDO'; nuevoBPM = '---';
                            UI.lblSPO2.FontColor = [0.8 0.2 0.2]; 
                        end
                        
                        % Caché visual (UI Caching)
                        if ~strcmp(Estado.UI.SPO2Text, nuevoSPO2)
                            UI.lblSPO2.Text = nuevoSPO2; Estado.UI.SPO2Text = nuevoSPO2;
                        end
                        if ~strcmp(Estado.UI.BPMText, nuevoBPM)
                            UI.lblBPM.Text = nuevoBPM; Estado.UI.BPMText = nuevoBPM;
                        end
                        
                        % Fast RAM Check OS-Agnostic
                        mostrarMemoriaSegura();
                    end
                    
                    % BACKUP CHUNKED SEGURO
                    Estado.UI.MuestrasDesdeUltimoBackup = Estado.UI.MuestrasDesdeUltimoBackup + 1;
                    if Estado.UI.MuestrasDesdeUltimoBackup > Config.Backup.MuestrasIntervalo
                        backupIncrementalOptimizado(RingBuffer, Estado.UltimoBackupIdx, Config.BufferMax.Muestras);
                        Estado.UltimoBackupIdx = RingBuffer.Idx;
                        Estado.UI.MuestrasDesdeUltimoBackup = 0;
                    end
                    
                    guardarEnRingBuffer(tTobillo, Estado.Filtros.EMG_Env, svmCrudo, Estado.Vitales.SPO2, Estado.Vitales.BPM, contraccionActual, Config);
                    Estado.UI.MuestrasRecibidas = Estado.UI.MuestrasRecibidas + 1;
                else
                    if Estado.PrimeraTramaTobillo
                        Estado.ContadorErroresUDP = Estado.ContadorErroresUDP + 1;
                        if Estado.ContadorErroresUDP > Estado.MaximoErroresPermitidos
                            logSistema('ERROR', 'Timeout UDP excedido. Desconexión Graceful.');
                            alternarCaptura(); 
                            uialert(UI.Fig, 'Se perdió la conexión con los biosensores. Captura pausada.', 'Alerta Hardware');
                        end
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
            Estado.T0_Tobillo = -1; Estado.T0_Biceps = -1;
            Estado.PrimeraTramaTobillo = false; Estado.PrimeraTramaBiceps = false;
            Estado.Filtros.PPG_Base = 0; Estado.tCrudoAnterior_Tobillo = -1;
            Estado.UI.ContraccionPrevia = false; Estado.UI.MuestrasRecibidas = 0;
            Estado.ContadorErroresUDP = 0; Estado.UI.MuestrasDesdeUltimoBackup = 0;
            
            % Limpiar analizador
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.Episodios = []; Analisis.IdxNav = 0;
            
            try 
                Red.UdpTobillo = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", Config.Puertos.Tobillo); 
                logSistema('INFO', 'Puerto UDP Tobillo abierto.');
            catch ME
                uialert(UI.Fig, sprintf('Puerto %d bloqueado.', Config.Puertos.Tobillo), 'Error UDP'); return;
            end
            
            try 
                Red.UdpBiceps  = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", Config.Puertos.Biceps); 
            catch ME
                clear Red.UdpTobillo; uialert(UI.Fig, sprintf('Puerto %d bloqueado.', Config.Puertos.Biceps), 'Error UDP'); return;
            end
            
            UI.lblInfo.Text = "ACTIVO"; UI.lblInfo.FontColor = [0 0.5 0];
            clearpoints(UI.lineaEMG); clearpoints(UI.lineaSVM); 
            
            UI.btnUDP.Text = "⏹ Detener"; UI.btnUDP.BackgroundColor = [1 0.4 0.4];
            logSistema('INFO', 'Captura iniciada de forma segura.');
        else
            liberarRecursos(Red);
            UI.btnUDP.Text = "▶ Conectar"; UI.btnUDP.BackgroundColor = [0.2 0.6 0.2];
            UI.lblInfo.Text = "EN ESPERA"; UI.lblInfo.FontColor = [0.5 0.5 0.5];
            logSistema('INFO', 'Captura detenida.');
        end
    end

    function detenerYExportar()
        Estado.Capturando = false; liberarRecursos(Red);
        if RingBuffer.Count == 0, uialert(UI.Fig, 'Sin datos.', 'Aviso'); return; end
        
        fStr = char(datetime('now', 'Format', 'yyyyMMdd_HHmm'));
        rutaSalida = fullfile(userpath, 'AVA_Nexus_Data');
        if ~isfolder(rutaSalida), mkdir(rutaSalida); end
        
        backupIncrementalOptimizado(RingBuffer, Estado.UltimoBackupIdx, Config.BufferMax.Muestras); 
        
        [t_d, emg_d, svm_d, spo2_d, bpm_d, anot_d] = descomprimirRingBufferCorregido();
        if isempty(t_d), return; end % Fallo en extracción
        
        try
            nameCSV = fullfile(rutaSalida, sprintf('AVA_Estudio_%s.csv', fStr));
            nameTXT = fullfile(rutaSalida, sprintf('AVA_Anotaciones_%s.txt', fStr));
            
            if isfile(nameCSV), logSistema('WARN', 'Sobrescribiendo archivo existente.'); end
            
            % Procesamiento Clínico
            [anotFinal, epi, ~] = procesarAASM(t_d, emg_d, svm_d, Config.Muestreo.Fs_Hz, Config);
            
            % Exportación robusta con FPRINTF estricto
            logSistema('INFO', 'Iniciando escritura OOM-Safe de CSV...');
            fid = fopen(nameCSV, 'w');
            if fid < 0, logSistema('ERROR', 'Permiso denegado para CSV'); return; end
            
            fprintf(fid, '# AVA Nexus V6.2 Estudio Polisomnográfico\n');
            fprintf(fid, '# Exportado: %s\n', char(datetime('now')));
            fprintf(fid, '# Duración: %.2f horas\n', (t_d(end) - t_d(1)) / 3600);
            fprintf(fid, 'Time_s,EMG_uV,SVM_m_s2,SpO2_pct,BPM_bpm,AASM_SPI\n');
            
            for i = 1:length(t_d)
                % Precision de 6 decimales para evitar overflows
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
            uialert(UI.Fig, 'Error crítico de escritura en disco.', 'Fallo Sistema');
        end
        cambiarPanel(UI.PnlMenu);
    end

    function ejecutarAnalisisPro()
        if Archivos.Senales == "", uialert(UI.Fig, 'Seleccione un CSV.', 'Aviso'); return; end
        try
            % Lector OOM-Safe (Chunking Manual)
            logSistema('INFO', 'Cargando archivo masivo por chunks...');
            [vT, vEMG, vSVM, vSPO2, vBPM] = leerCSVEnChunks(Archivos.Senales);
            
            if size(vT, 1) < 10, uialert(UI.Fig, 'CSV inválido o muy corto.', 'Error'); return; end
            
            dtReal = mean(diff(vT));
            if dtReal <= 0 || isnan(dtReal), uialert(UI.Fig, 'Tiempos nulos detectados.', 'Error'); return; end
            fsReal = 1 / dtReal;
            
            totPLM = 0; totSPI = 0;
            
            % Interpolación Segura
            if Archivos.Anotaciones ~= ""
                if ~isfile(Archivos.Anotaciones), return; end
                matA = readmatrix(Archivos.Anotaciones);
                if size(matA, 1) > 0 && size(matA, 2) >= 2
                    tAno = matA(:, 1); vAno = double(matA(:, 2));
                    [tAnoOrd, idxSort] = sort(tAno); vAnoOrd = vAno(idxSort);
                    
                    if any(diff(tAnoOrd) <= 0)
                        [tAnoUnique, idxUnique] = unique(tAnoOrd, 'stable');
                        vAnoOrd = vAnoOrd(idxUnique); tAnoOrd = tAnoUnique;
                    end
                    
                    Analisis.Anotaciones = interp1(tAnoOrd, vAnoOrd, vT, 'linear', 'extrap');
                    Analisis.Anotaciones = max(0, min(1, Analisis.Anotaciones)); % Bounds Clamping
                    Analisis.Anotaciones(isnan(Analisis.Anotaciones)) = 0;
                    Analisis.Anotaciones = round(Analisis.Anotaciones > 0.5);
                    
                    fl = diff([0; Analisis.Anotaciones > 0.5; 0]); idI = find(fl==1); idF = find(fl==-1)-1;
                    Analisis.Episodios = []; plmTmp = 0;
                    for i = 1:length(idI)
                        plmTmp = plmTmp + 1;
                        if i == length(idI) || (idI(i+1) - idF(i)) / fsReal > 90
                            Analisis.Episodios = [Analisis.Episodios; idI(i-plmTmp+1), idF(i), plmTmp]; %#ok<AGROW>
                            plmTmp = 0;
                        end
                    end
                    totSPI = size(Analisis.Episodios, 1); totPLM = length(idI);
                end
            end
            
            if Archivos.Anotaciones == ""
                [Analisis.Anotaciones, Analisis.Episodios, mPLM] = procesarAASM(vT, vEMG, vSVM, fsReal, Config);
                totSPI = size(Analisis.Episodios, 1); totPLM = size(mPLM, 1);
            end
            
            Analisis.T = vT; Analisis.IdxNav = 0;
            Analisis.TotPLM = totPLM; Analisis.TotSPI = totSPI;
            actualizarEtiquetaEpisodio(0, 0, totPLM, totSPI);
            
            delete(UI.pnlGraficasAna.Children); 
            numGrafs = 2 + (~isempty(vSPO2)) + (~isempty(vBPM));
            gGrid = uigridlayout(UI.pnlGraficasAna, [numGrafs, 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG + AASM'); hold(ax1,'on'); grid(ax1, 'on');
            plot(ax1, vT, vEMG, 'Color', [0.6 0.6 0.6]); 
            plot(ax1, vT, Analisis.Anotaciones * max(vEMG), 'r', 'LineWidth', 1.5);
            
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
            logSistema('ERROR', ['Crash Analizador (OOM/Read): ', ME.message]);
            uialert(UI.Fig, 'El archivo CSV tiene errores de estructura.', 'Error de Parseo');
        end
    end

    %% --- 6. FUNCIONES SECUNDARIAS CRÍTICAS ---
    
    function mostrarMemoriaSegura()
        try
            mem = memory();
            memMB = mem.MemUsedMATLAB / 1024^2;
            pct = 100 * mem.MemUsedMATLAB / (mem.MemUsedMATLAB + mem.MemAvailableAllArrays);
            UI.lblMemoria.Text = sprintf('RAM: %.0f MB (%.1f%%)', memMB, pct);
            if pct > 85, logSistema('WARN', 'Nivel Crítico RAM (>85%)'); end
        catch
            try 
                jRun = java.lang.Runtime.getRuntime();
                memMB = (jRun.totalMemory() - jRun.freeMemory()) / 1024^2;
                UI.lblMemoria.Text = sprintf('RAM: %.0f MB', memMB);
            catch
                UI.lblMemoria.Text = 'RAM: N/A';
            end
        end
    end

    function [vT, vE, vS, vSp, vB] = leerCSVEnChunks(archivo)
        % Lectura incremental sin picos OOM
        chunkMuestras = 15000; % 5 mins a 50Hz
        vT=[]; vE=[]; vS=[]; vSp=[]; vB=[];
        
        fid = fopen(archivo, 'r'); 
        if fid < 0, return; end
        fgetl(fid); % Skip Header o Metadata
        
        while ~feof(fid)
            chunk = zeros(chunkMuestras, 5); 
            idxC = 0;
            for i = 1:chunkMuestras
                lin = fgetl(fid); 
                if ~ischar(lin), break; end
                if startsWith(lin, '#'), continue; end % Salta metadata
                
                try
                    v = str2double(strsplit(lin, ','));
                    if length(v) >= 2
                        idxC = idxC + 1;
                        if idxC > size(chunk, 1), chunk = [chunk; zeros(5000, 5)]; end %#ok<AGROW>
                        chunk(idxC, 1:min(length(v), 5)) = v(1:min(length(v), 5));
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
    end

    function ok = validarDatosCrudos(datos, cfg)
        ok = true; 
        emg = datos(5); 
        svm = sqrt(datos(2)^2 + datos(3)^2 + datos(4)^2);
        
        if emg < cfg.Norm.EMG_Min || emg > cfg.Norm.EMG_Max
            logSistema('WARN', sprintf('EMG Spike excluido: %.1f', emg)); ok = false;
        end
        if isnan(svm) || isinf(svm) || svm > cfg.Norm.SVM_Max
            logSistema('WARN', 'SVM cinemática inválida.'); ok = false;
        end
    end

    function ok = validarContinuidadTemporal(tCrudo, nombre)
        ok = true;
        if tCrudo < 0 || tCrudo > 2^31
            logSistema('ERROR', sprintf('%s: Time OutOfBounds (%d ms)', nombre, tCrudo)); ok = false; return;
        end
        if strcmp(nombre, 'TOBILLO') && Estado.tCrudoAnterior_Tobillo ~= -1
            dt = tCrudo - Estado.tCrudoAnterior_Tobillo;
            if dt < 0, logSistema('ERROR', 'Time travel detectado. Paquete ignorado.'); ok = false; return; end
            if dt > 200, logSistema('WARN', sprintf('Gap Temporal UDP: %.0f ms', dt)); end
        end
        Estado.tCrudoAnterior_Tobillo = tCrudo;
    end

    function guardarEnRingBuffer(t, emg, svm, spo2, bpm, anot, cfg)
        try
            idx = RingBuffer.Idx;
            % Bounds check pre-escritura
            if idx < 1 || idx > cfg.BufferMax.Muestras
                logSistema('ERROR', 'RingBuffer Pointer OutOfBounds.'); return;
            end
            
            RingBuffer.T(idx)    = t;
            RingBuffer.EMG(idx)  = emg;
            RingBuffer.SVM(idx)  = svm;
            RingBuffer.SPO2(idx) = spo2;
            RingBuffer.BPM(idx)  = bpm;
            RingBuffer.Anot(idx) = anot;
            
            RingBuffer.Idx = uint32(mod(uint64(idx), uint64(cfg.BufferMax.Muestras))) + 1;
            if RingBuffer.Count < cfg.BufferMax.Muestras, RingBuffer.Count = RingBuffer.Count + 1;
            else, RingBuffer.Full = true; end
        catch ME
            logSistema('ERROR', ['Fallo en RingBuffer (Write): ', ME.message]);
        end
    end

    function [t, e, s, sp, b, a] = descomprimirRingBufferCorregido()
        % Descompresión Segura con Bounds Checking Exacto
        c = RingBuffer.Count;
        nMax = Config.BufferMax.Muestras;
        
        if c == 0
            t=[]; e=[]; s=[]; sp=[]; b=[]; a=[]; return;
        end
        
        if RingBuffer.Full
            idxTemp = mod((0:c-1) + RingBuffer.Idx - 1, nMax) + 1;
        else
            idxTemp = 1:c;
        end
        
        if any(idxTemp < 1) || any(idxTemp > nMax)
            logSistema('ERROR', 'Índices Corruptos en Descompresión OOM');
            t=[]; e=[]; s=[]; sp=[]; b=[]; a=[]; return;
        end
        
        t = RingBuffer.T(idxTemp);
        e = RingBuffer.EMG(idxTemp);
        s = RingBuffer.SVM(idxTemp);
        sp= RingBuffer.SPO2(idxTemp);
        b = RingBuffer.BPM(idxTemp);
        a = double(RingBuffer.Anot(idxTemp));
    end

    function backupIncrementalOptimizado(RB, ultimoIdx, nMax)
        % Cómputo exacto de índices para chunking sin memory explode
        if RB.Count == 0, return; end
        
        if RB.Idx > ultimoIdx
            idxs = ultimoIdx : (RB.Idx - 1);
        else
            idxs = [ultimoIdx : nMax, 1 : (RB.Idx - 1)];
        end
        
        if isempty(idxs) || length(idxs) > nMax
            return;
        end
        
        T_nuevo = RB.T(idxs); EMG_nuevo = RB.EMG(idxs); SVM_nuevo = RB.SVM(idxs); %#ok<NASGU>
        
        rutaCache = fullfile(userpath, 'AVA_Nexus_Data', '.cache_incremental');
        if ~isfolder(rutaCache), mkdir(rutaCache); end
        fStr = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
        
        try
            save(fullfile(rutaCache, sprintf('bkp_chunk_%s.mat', fStr)), 'T_nuevo', 'EMG_nuevo', 'SVM_nuevo', '-v6');
            logSistema('INFO', sprintf('Chunk Backup: %d muestras extraídas.', length(idxs)));
            archivos = dir(fullfile(rutaCache, 'bkp_chunk_*.mat'));
            if length(archivos) > 10
                [~, iSort] = sort([archivos.datenum]); delete(fullfile(rutaCache, archivos(iSort(1)).name));
            end
        catch
        end
    end

    function [datos, exito] = leerYValidarUDP(puerto, lenE, limPaq)
        datos = []; exito = false;
        if isempty(puerto) || ~isvalid(puerto), return; end
        try
            paqLeidos = 0;
            while puerto.NumDatagramsAvailable > 0 && paqLeidos < limPaq
                paquete = read(puerto, 1); str = strip(string(char(paquete.Data)));
                nums = str2double(split(str, ","))';
                if length(nums) == lenE && ~any(isnan(nums)) && ~any(isinf(nums))
                    datos = nums; exito = true;
                end
                paqLeidos = paqLeidos + 1;
            end
        catch ME
            msgStr = string(ME.message);
            if ~contains(msgStr, 'NumDatagramsAvailable', 'IgnoreCase', true)
                logSistema('WARN', char("UDP Socket Fail: " + msgStr));
            end
        end
    end

    function [s, b] = detectarBPMRobusto(bR, bI, fs)
        % Algoritmo Seguro de Detección en Dominio Temporal (Sin xcorr)
        s = 95; b = 70; 
        
        bR_AC = bR - mean(bR); bI_AC = bI - mean(bI);
        acR = std(bR_AC); dcR = mean(abs(bR));
        acI = std(bI_AC); dcI = mean(abs(bI));
        
        if dcR == 0 || dcI == 0, return; end
        R = (acR / dcR) / (acI / dcI); s = max(85, min(99, 110 - 25 * R));
        
        if length(bI_AC) < 2 * fs, return; end
        
        try
            bI_norm = (bI_AC - mean(bI_AC)) / (std(bI_AC) + eps);
            umbral = std(bI_norm) * 0.3;
            
            picos = find(bI_norm(2:end-1) > bI_norm(1:end-2) & ...
                         bI_norm(2:end-1) > bI_norm(3:end) & ...
                         bI_norm(2:end-1) > umbral) + 1;
                     
            if length(picos) > 2
                intProm = mean(diff(picos)) / fs; 
                bpmCalc = 60 / intProm;
                if bpmCalc >= 30 && bpmCalc <= 220
                    b = bpmCalc;
                end
            end
        catch ME
            logSistema('WARN', ['Error de pulso óptico: ', ME.message]);
        end
    end

    function [anotFinal, mEpi, mPlm] = procesarAASM(t, e, s, fs, cfg)
        % Blindaje Division por Cero
        minE = cfg.Norm.EMG_Min; maxE = cfg.Norm.EMG_Max; rangeE = maxE - minE;
        if rangeE == 0, rangeE = 1; end
        en = (e - minE) / rangeE; en = max(0, min(1, en)); 
        
        minS = cfg.Norm.SVM_Min; maxS = cfg.Norm.SVM_Max; rangeS = maxS - minS;
        if rangeS == 0, rangeS = 1; end
        sn = (s - minS) / rangeS; sn = max(0, min(1, sn));
        
        fus = en .* sn; maxF = max(fus); if maxF > 0, fus = fus / maxF; end
        
        fl = diff([0; fus > 0.15; 0]); iI = find(fl==1); iF = find(fl==-1)-1;
        
        iIU = []; iFU = [];
        if ~isempty(iI)
            cA = iI(1); cF = iF(1);
            for i = 2:length(iI)
                if (iI(i) - cF)/fs < 0.5, cF = iF(i); 
                else, iIU(end+1,1)=cA; iFU(end+1,1)=cF; cA=iI(i); cF=iF(i); end %#ok<AGROW>
            end
            iIU(end+1,1)=cA; iFU(end+1,1)=cF;
        end
        
        mPlm = []; 
        for i = 1:length(iIU)
            dur = (iFU(i) - iIU(i)) / fs; 
            if dur >= 0.5 && dur <= 10.0, mPlm = [mPlm; iIU(i), iFU(i)]; end %#ok<AGROW>
        end
        
        mEpi = []; espSerie = [];
        if ~isempty(mPlm)
            rt = mPlm(1,:);
            for j = 2:size(mPlm,1)
                inter = (mPlm(j,1) - rt(end,1)) / fs;
                if inter >= 5.0 && inter <= 90.0, rt = [rt; mPlm(j,:)]; %#ok<AGROW>
                else
                    if size(rt,1) >= 4, mEpi = [mEpi; rt(1,1), rt(end,2), size(rt,1)]; espSerie = [espSerie; rt]; end %#ok<AGROW>
                    rt = mPlm(j,:); 
                end
            end
            if size(rt,1) >= 4, mEpi = [mEpi; rt(1,1), rt(end,2), size(rt,1)]; espSerie = [espSerie; rt]; end
        end
        anotFinal = zeros(length(t), 1); 
        for k = 1:size(espSerie,1), anotFinal(espSerie(k,1):espSerie(k,2)) = 1; end
    end

    function cargarArchivo(tipo)
        [n, r] = uigetfile({'*.csv;*.txt'});
        if ~isequal(n, 0)
            rutaFull = fullfile(r, n);
            % Verificación de acceso permitido
            if ~isfile(rutaFull)
                uialert(UI.Fig, 'Archivo no encontrado.', 'Error'); return; 
            end
            if strcmp(tipo, 'DATOS'), Archivos.Senales = rutaFull; UI.lblDat.Text = n;
            else, Archivos.Anotaciones = rutaFull; UI.lblAno.Text = n; end
            logSistema('INFO', ['Ingesta File I/O: ', n]);
        end
    end

    function actualizarEtiquetaEpisodio(idx, tEpi, tPlm, tSpi)
        % Bounds y Error Handling seguro
        if idx < 0 || idx > tEpi || tEpi < 0, idx = 0; tEpi = 0; end
        try
            UI.lblEpi.Text = sprintf('Episodio: %d / %d | Totales: %d PLMs | %d SPI', idx, tEpi, tPlm, tSpi);
        catch
            UI.lblEpi.Text = 'Datos Analíticos Corruptos';
        end
    end

    function navegarEpisodios(dir)
        if isempty(Analisis.Episodios) || isempty(UI.AxesAnaLista), return; end
        Analisis.IdxNav = max(1, min(Analisis.IdxNav + dir, size(Analisis.Episodios, 1)));
        
        actualizarEtiquetaEpisodio(Analisis.IdxNav, size(Analisis.Episodios, 1), Analisis.TotPLM, Analisis.TotSPI);
        
        lim = [Analisis.T(Analisis.Episodios(Analisis.IdxNav,1)) - 15, Analisis.T(Analisis.Episodios(Analisis.IdxNav,2)) + 15];
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
            tAbs = seconds(datetime('now') - t0);
            fprintf('[%8.2fs] [%-5s] %s\n', tAbs, nivel, char(mensaje)); 
        catch
        end
    end
end

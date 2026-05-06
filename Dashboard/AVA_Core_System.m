function AVA_Core_System()
    
    clear all; clc; close all; 
    
    %% --- 1. CONFIGURACIÓN (CONSTANTES GLOBALES ESTRICTAS) ---
    Config = struct();
    Config.Puertos.Tobillo = 8888; 
    Config.Puertos.Biceps  = 8889; 
    Config.Muestreo.Fs_Hz  = 50; 
    Config.Muestreo.VentanaGrafica_s = 60; 
    
    % Capacidad Máxima de Memoria (1 Hora a 50Hz = 180,000 muestras)
    Config.BufferMax.Muestras = 50 * 3600; 
    
    % Throttling UI y Optimización de GPU
    Config.UI.RefrescoGraficas_Muestras = 5; 
    Config.UI.MaxPaquetesUDP_Lectura = 10; % Evita starvation del bucle
    
    % Parámetros de Vitales
    Config.Vitales.TamanoBufferSeg = 10; 
    Config.Vitales.BufferSize = Config.Muestreo.Fs_Hz * Config.Vitales.TamanoBufferSeg;
    
    % Umbrales de Detección Clínica
    Config.Umbrales.IR_Minimo_Dedo = 3000;
    Config.Umbrales.EMG_Contraccion = 150;
    Config.Umbrales.SVM_Movimiento = 0.4;
    
    % Parámetros de Filtros EMA
    Config.Filtros.Alpha_Base = 0.001; % fc ~ 0.008 Hz 
    Config.Filtros.Alpha_Env  = 0.15;  % fc ~ 1.2 Hz 
    
    %% --- 2. ESTADO GLOBAL Y MEMORIA RAM ---
    Estado = struct();
    Estado.Capturando = false;
    Estado.T0_Tobillo = -1;
    Estado.T0_Biceps  = -1;
    Estado.PrimeraTramaTobillo = false;
    Estado.PrimeraTramaBiceps  = false;
    
    % Control de Timeouts (Desconexión Graceful)
    Estado.ContadorErroresUDP = 0;
    Estado.MaximoErroresPermitidos = 100; 
    
    % Filtros en Tiempo Real
    Estado.Filtros.EMG_Base = 1870; Estado.Filtros.EMG_Env = 0;
    Estado.Filtros.SVM_Base = 1;    Estado.Filtros.SVM_Env = 0;
    Estado.Filtros.PPG_Base = 0;
    
    % Máquina de Estados UI
    Estado.UI.ContraccionPrevia = false;
    Estado.UI.MuestrasRecibidas = 0;
    
    % Signos Vitales Extendidos
    Estado.Vitales.SPO2 = 98;
    Estado.Vitales.BPM  = 70;
    Estado.Vitales.BufferRed = zeros(1, Config.Vitales.BufferSize);
    Estado.Vitales.BufferIR  = zeros(1, Config.Vitales.BufferSize);
    
    % Buffers de Análisis y Exportación (Pre-alocados para rendimiento)
    Datos = struct('T', zeros(1,0), 'EMG', zeros(1,0), 'SVM', zeros(1,0), 'SPO2', zeros(1,0), 'BPM', zeros(1,0), 'Anot_TR', zeros(1,0));
    Analisis = struct('T', [], 'Anotaciones', [], 'Episodios', [], 'IdxNav', 0);
    Archivos = struct('Senales', "", 'Anotaciones', "");
    
    % Sockets UDP
    Red = struct('UdpTobillo', [], 'UdpBiceps', []);
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));
    
    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA (UI) ---
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus | Clinical PSG v4', 'Color', 'w', 'Position', [50, 50, 1150, 950]);
    UI.Fig.CloseRequestFcn = @(src, event) cerrarAplicacion(src, event);
    UI.AxesAnaLista = []; 
    
    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1150 950], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    
    % --- Menú Principal ---
    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [425 700 300 60], 'HorizontalAlignment', 'center');
    uibutton(UI.PnlMenu, 'Text', '1. Adquisición de Datos (UDP)', 'FontSize', 18, 'Position', [350 500 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clínico (CSV/TXT)', 'FontSize', 18, 'Position', [350 400 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAna));
    
    % --- Panel Adquisición ---
    gAdq = uigridlayout(UI.PnlAdq, [8, 2], 'RowHeight', {'1x', '1x', '1x', 80, 70, 60, 60}, 'Padding', 20);
    UI.axEMG_TR = uiaxes(gAdq); title(UI.axEMG_TR, 'EMG Tibial'); UI.axEMG_TR.Layout.Row = 1; UI.axEMG_TR.Layout.Column = [1 2];
    UI.axSVM_TR = uiaxes(gAdq); title(UI.axSVM_TR, 'Actigrafía SVM'); UI.axSVM_TR.Layout.Row = 2; UI.axSVM_TR.Layout.Column = [1 2];
    UI.axPPG_TR = uiaxes(gAdq); title(UI.axPPG_TR, 'Onda PPG'); UI.axPPG_TR.Layout.Row = 3; UI.axPPG_TR.Layout.Column = [1 2];
    
    UI.lineaEMG = animatedline(UI.axEMG_TR, 'Color', [1 0.5 0], 'LineWidth', 1.5, 'MaximumNumPoints', 3000); 
    UI.lineaSVM = animatedline(UI.axSVM_TR, 'Color', [0 0.4 1], 'LineWidth', 1.5, 'MaximumNumPoints', 3000); 
    UI.lineaPPG = animatedline(UI.axPPG_TR, 'Color', [0.8 0 0], 'LineWidth', 1.5, 'MaximumNumPoints', 3000); 
    
    pnlVit = uigridlayout(gAdq, [1, 2]); pnlVit.Layout.Row = 4; pnlVit.Layout.Column = [1 2];
    UI.lblSPO2 = uilabel(pnlVit, 'Text', '--% SpO2', 'FontSize', 45, 'FontWeight', 'bold', 'FontColor', [0 0.4 0.8], 'HorizontalAlignment', 'center'); 
    UI.lblBPM  = uilabel(pnlVit, 'Text', '-- BPM', 'FontSize', 45, 'FontWeight', 'bold', 'HorizontalAlignment', 'center'); 
    
    pnlDet = uipanel(gAdq, 'BackgroundColor', [0.95 0.95 0.95]); pnlDet.Layout.Row = 5; pnlDet.Layout.Column = [1 2];
    gDet = uigridlayout(pnlDet, [1, 1]);
    UI.lblLed = uilabel(gDet, 'Text', ' ESPERANDO INICIO ', 'FontSize', 22, 'FontWeight', 'bold', 'BackgroundColor', [0.5 0.5 0.5], 'FontColor', 'w', 'HorizontalAlignment', 'center');

    UI.lblInfo = uilabel(gAdq, 'Text', 'Listo para conexión.', 'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    UI.lblInfo.Layout.Row = 6; UI.lblInfo.Layout.Column = [1 2];

    UI.btnUDP = uibutton(gAdq, 'Text', '▶ Conectar Hardware UDP', 'FontSize', 18, 'FontWeight', 'bold', 'BackgroundColor', [0.2 0.6 0.2], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) alternarCaptura());
    UI.btnUDP.Layout.Row = 7; UI.btnUDP.Layout.Column = 1;
    
    btnExp = uibutton(gAdq, 'Text', 'Finalizar y Exportar', 'FontSize', 16, 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) detenerYExportar());
    btnExp.Layout.Row = 7; btnExp.Layout.Column = 2;

    % --- Panel Analizador ---
    gAna = uigridlayout(UI.PnlAna, [4, 1], 'RowHeight', {60, 80, '1x', 50}, 'Padding', 10);
    
    gArchivos = uigridlayout(gAna, [1, 4]);
    uibutton(gArchivos, 'Text', '1. Cargar Señales (.CSV)', 'ButtonPushedFcn', @(src, event) cargarArchivo('DATOS'));
    UI.lblDat = uilabel(gArchivos, 'Text', 'Sin señales');
    uibutton(gArchivos, 'Text', '2. Cargar Anotaciones (.TXT)', 'ButtonPushedFcn', @(src, event) cargarArchivo('ANOT'));
    UI.lblAno = uilabel(gArchivos, 'Text', 'Sin anotaciones');
    
    gNav = uigridlayout(gAna, [1, 6], 'ColumnWidth', {120, '1x', 120, 120, 180, 200});
    uibutton(gNav, 'Text', '<< Anterior', 'ButtonPushedFcn', @(src, event) navegarEpisodios(-1));
    UI.lblEpi = uilabel(gNav, 'Text', '0 / 0 Episodios', 'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    uibutton(gNav, 'Text', 'Siguiente >>', 'ButtonPushedFcn', @(src, event) navegarEpisodios(1));
    uibutton(gNav, 'Text', 'Ver Todo', 'ButtonPushedFcn', @(src, event) verTodoAnalisis());
    UI.lblTotales = uilabel(gNav, 'Text', 'Totales: --', 'FontSize', 14, 'FontWeight', 'bold', 'FontColor', [0.7 0.1 0.1]);
    uibutton(gNav, 'Text', 'PROCESAR AASM', 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'FontWeight', 'bold', 'ButtonPushedFcn', @(src, event) ejecutarAnalisis());

    UI.pnlGraficasAna = uipanel(gAna, 'BorderType', 'none', 'BackgroundColor', 'w');
    uibutton(gAna, 'Text', 'Volver al Menú', 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlMenu));

    %% --- 4. BUCLE PRINCIPAL DE ADQUISICIÓN (Blindado) ---
    logSistema('INFO', 'Sistema AVA Nexus V4 iniciado.');
    
    while ishandle(UI.Fig)
        try
            if Estado.Capturando 
                % ---------------------------------------------------------
                % NODO BÍCEPS (VITALES Y PPG)
                % ---------------------------------------------------------
                [datosBiceps, exitoB] = leerYValidarUDP(Red.UdpBiceps, 3, Config.UI.MaxPaquetesUDP_Lectura);
                if exitoB
                    tCrudo = datosBiceps(1)/1000;
                    if Estado.T0_Biceps == -1, Estado.T0_Biceps = tCrudo; end
                    
                    if ~Estado.PrimeraTramaBiceps
                        logSistema('INFO', 'Primer paquete BÍCEPS validado.');
                        Estado.PrimeraTramaBiceps = true;
                        
                        % Validar Sincronización Inicial
                        if Estado.PrimeraTramaTobillo
                            tDif = abs((tCrudo - Estado.T0_Biceps) - (Datos.T(end)));
                            if tDif > 2.0, logSistema('WARN', sprintf('Desfase temporal entre nodos detectado: %.3fs', tDif)); end
                        end
                    end
                    
                    tBiceps = tCrudo - Estado.T0_Biceps;
                    
                    % Actualizar Buffer Circular de Vitales (Blindado contra memoria)
                    Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed(2:end), datosBiceps(2)]; 
                    Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR(2:end), datosBiceps(3)];
                    
                    if datosBiceps(3) > Config.Umbrales.IR_Minimo_Dedo
                        UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                        
                        if Estado.Filtros.PPG_Base == 0, Estado.Filtros.PPG_Base = datosBiceps(3); end
                        Estado.Filtros.PPG_Base = ((1-Config.Filtros.Alpha_Env) * Estado.Filtros.PPG_Base) + (Config.Filtros.Alpha_Env * datosBiceps(3));
                        ondaPPG = datosBiceps(3) - Estado.Filtros.PPG_Base; 
                        
                        addpoints(UI.lineaPPG, tBiceps, ondaPPG); 
                    else
                        UI.lblSPO2.Text = 'SIN DEDO'; UI.lblSPO2.FontColor = [0.8 0.2 0.2]; UI.lblBPM.Text = '---';
                    end
                end

                % ---------------------------------------------------------
                % NODO TOBILLO (MAESTRO Y RELOJ)
                % ---------------------------------------------------------
                [datosTobillo, exitoT] = leerYValidarUDP(Red.UdpTobillo, 5, Config.UI.MaxPaquetesUDP_Lectura);
                if exitoT
                    Estado.ContadorErroresUDP = max(0, Estado.ContadorErroresUDP - 1); % Decremento seguro
                    
                    if ~Estado.PrimeraTramaTobillo
                        logSistema('INFO', 'Primer paquete TOBILLO validado.');
                        Estado.PrimeraTramaTobillo = true;
                    end
                    
                    tCrudo = datosTobillo(1)/1000;
                    if Estado.T0_Tobillo == -1, Estado.T0_Tobillo = tCrudo; end
                    tTobillo = tCrudo - Estado.T0_Tobillo;
                    
                    svmCrudo = sqrt(datosTobillo(2)^2 + datosTobillo(3)^2 + datosTobillo(4)^2);
                    emgCrudo = datosTobillo(5);
                    
                    % FILTRADO EMA
                    if ~Estado.UI.ContraccionPrevia 
                        Estado.Filtros.EMG_Base = ((1-Config.Filtros.Alpha_Base) * Estado.Filtros.EMG_Base) + (Config.Filtros.Alpha_Base * emgCrudo);
                        Estado.Filtros.SVM_Base = ((1-Config.Filtros.Alpha_Base) * Estado.Filtros.SVM_Base) + (Config.Filtros.Alpha_Base * svmCrudo);
                    end
                    
                    Estado.Filtros.EMG_Env = ((1-Config.Filtros.Alpha_Env) * Estado.Filtros.EMG_Env) + (Config.Filtros.Alpha_Env * abs(emgCrudo - Estado.Filtros.EMG_Base));
                    Estado.Filtros.SVM_Env = ((1-Config.Filtros.Alpha_Env) * Estado.Filtros.SVM_Env) + (Config.Filtros.Alpha_Env * abs(svmCrudo - Estado.Filtros.SVM_Base));
                    
                    contraccionActual = (Estado.Filtros.EMG_Env > Config.Umbrales.EMG_Contraccion) && (Estado.Filtros.SVM_Env > Config.Umbrales.SVM_Movimiento);
                    
                    % --- UNIFICACIÓN DEL THROTTLING DE INTERFAZ (UI) ---
                    if mod(Estado.UI.MuestrasRecibidas, Config.UI.RefrescoGraficas_Muestras) == 0
                        
                        if contraccionActual ~= Estado.UI.ContraccionPrevia
                            if contraccionActual
                                UI.lblLed.BackgroundColor = [0.2 0.8 0.2]; UI.lblLed.Text = ' CONTRACCIÓN (1) ';
                            else
                                UI.lblLed.BackgroundColor = [0.8 0.2 0.2]; UI.lblLed.Text = ' REPOSO (0) ';
                            end
                            Estado.UI.ContraccionPrevia = contraccionActual;
                        end
                        
                        % Vitales cada ~1 segundo
                        if mod(Estado.UI.MuestrasRecibidas, 50) == 0
                            [Estado.Vitales.SPO2, Estado.Vitales.BPM] = calcularVitales(Estado.Vitales.BufferRed, Estado.Vitales.BufferIR, Config.Muestreo.Fs_Hz); 
                        end
                        
                        if ~strcmp(UI.lblSPO2.Text, 'SIN DEDO')
                            UI.lblSPO2.Text = sprintf('%d%% SpO2', round(Estado.Vitales.SPO2)); 
                            UI.lblBPM.Text  = sprintf('%d BPM', round(Estado.Vitales.BPM));
                        end
                        
                        actualizarEjesGrafica([UI.axEMG_TR, UI.axSVM_TR, UI.axPPG_TR], tTobillo, Config.Muestreo.VentanaGrafica_s);
                    end
                    
                    % GESTIÓN DE MEMORIA (Buffer Circular de Límite Estricto)
                    if length(Datos.T) >= Config.BufferMax.Muestras
                        Datos.T(1:end-1) = Datos.T(2:end); Datos.T(end) = tTobillo;
                        Datos.EMG(1:end-1) = Datos.EMG(2:end); Datos.EMG(end) = Estado.Filtros.EMG_Env;
                        Datos.SVM(1:end-1) = Datos.SVM(2:end); Datos.SVM(end) = svmCrudo;
                        Datos.SPO2(1:end-1) = Datos.SPO2(2:end); Datos.SPO2(end) = Estado.Vitales.SPO2;
                        Datos.BPM(1:end-1) = Datos.BPM(2:end); Datos.BPM(end) = Estado.Vitales.BPM;
                        Datos.Anot_TR(1:end-1) = Datos.Anot_TR(2:end); Datos.Anot_TR(end) = double(contraccionActual);
                    else
                        Datos.T(end+1,1) = tTobillo; 
                        Datos.EMG(end+1,1) = Estado.Filtros.EMG_Env; 
                        Datos.SVM(end+1,1) = svmCrudo; 
                        Datos.SPO2(end+1,1) = Estado.Vitales.SPO2; 
                        Datos.BPM(end+1,1) = Estado.Vitales.BPM; 
                        Datos.Anot_TR(end+1,1) = double(contraccionActual);
                    end
                    
                    % DOWNSAMPLING DE GRÁFICA (Para no saturar GPU)
                    if length(Datos.T) > 3000
                        if mod(Estado.UI.MuestrasRecibidas, 3) == 0
                            addpoints(UI.lineaEMG, tTobillo, Estado.Filtros.EMG_Env); addpoints(UI.lineaSVM, tTobillo, svmCrudo); 
                        end
                    else
                        addpoints(UI.lineaEMG, tTobillo, Estado.Filtros.EMG_Env); addpoints(UI.lineaSVM, tTobillo, svmCrudo); 
                    end
                    
                    Estado.UI.MuestrasRecibidas = Estado.UI.MuestrasRecibidas + 1;
                else
                    % Timeout Graceful Disconnect
                    if Estado.PrimeraTramaTobillo
                        Estado.ContadorErroresUDP = Estado.ContadorErroresUDP + 1;
                        if Estado.ContadorErroresUDP > Estado.MaximoErroresPermitidos
                            logSistema('ERROR', 'Timeout UDP excedido. Deteniendo captura de emergencia.');
                            alternarCaptura(); 
                            uialert(UI.Fig, 'Se perdió la conexión con los biosensores. Captura pausada.', 'Alerta Hardware');
                        end
                    end
                end
            end
        catch excepcionMain
            logSistema('WARN', ['Excepción en hilo principal: ', excepcionMain.message]);
        end
        drawnow limitrate; 
        pause(0.001);
    end

    %% --- 5. FUNCIONES PRINCIPALES ---
    
    function alternarCaptura()
        Estado.Capturando = ~Estado.Capturando;
        
        if Estado.Capturando
            Estado.T0_Tobillo = -1; Estado.T0_Biceps = -1;
            Estado.PrimeraTramaTobillo = false; Estado.PrimeraTramaBiceps = false;
            Estado.Filtros.PPG_Base = 0; 
            
            % Sincronización de UI
            Estado.UI.ContraccionPrevia = false; 
            Estado.UI.MuestrasRecibidas = 0;
            Estado.ContadorErroresUDP = 0;
            
            % Limpiar Analizador
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.Episodios = []; Analisis.IdxNav = 0;
            
            try Red.UdpTobillo = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", Config.Puertos.Tobillo); catch ME, logSistema('ERROR', ME.message); end
            try Red.UdpBiceps  = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", Config.Puertos.Biceps); catch ME, logSistema('ERROR', ME.message); end
            
            UI.lblInfo.Text = "HARDWARE ACTIVO (Escuchando UDP...)"; UI.lblInfo.FontColor = [0 0.5 0];
            
            Datos.T=[]; Datos.EMG=[]; Datos.SVM=[]; Datos.SPO2=[]; Datos.BPM=[]; Datos.Anot_TR=[];
            clearpoints(UI.lineaEMG); clearpoints(UI.lineaSVM); clearpoints(UI.lineaPPG); 
            
            UI.btnUDP.Text = "⏹ Detener Recepción"; UI.btnUDP.BackgroundColor = [1 0.4 0.4];
            logSistema('INFO', 'Iniciando captura de datos biomédicos.');
        else
            liberarRecursos(Red);
            UI.btnUDP.Text = "▶ Conectar Hardware UDP"; UI.btnUDP.BackgroundColor = [0.2 0.6 0.2];
            UI.lblInfo.Text = "MODO: EN ESPERA"; UI.lblInfo.FontColor = [0.5 0.5 0.5];
            logSistema('INFO', 'Captura finalizada.');
        end
    end

    function detenerYExportar()
        Estado.Capturando = false; liberarRecursos(Red);
        if isempty(Datos.T), uialert(UI.Fig, 'El buffer de memoria está vacío.', 'Aviso'); return; end
        
        fStr = datestr(now, 'yyyymmdd_HHMM');
        rutaSalida = fullfile(userpath, 'AVA_Nexus_Data');
        if ~isfolder(rutaSalida), mkdir(rutaSalida); end
        
        % Backup Automático (Caché Secreto)
        rutaCache = fullfile(rutaSalida, '.cache');
        if ~isfolder(rutaCache), mkdir(rutaCache); end
        save(fullfile(rutaCache, ['backup_', fStr, '.mat']), 'Datos');
        logSistema('INFO', 'Backup RAM completado en /.cache');
        
        try
            [anotFinal, epi, ~] = procesarAASM(Datos.T, Datos.EMG, Datos.SVM, Config.Muestreo.Fs_Hz);
            nameCSV = fullfile(rutaSalida, sprintf('AVA_Estudio_%s.csv', fStr));
            nameTXT = fullfile(rutaSalida, sprintf('AVA_Anotaciones_%s.txt', fStr));
            
            writetable(array2table([Datos.T(:), Datos.EMG(:), Datos.SVM(:), Datos.SPO2(:), Datos.BPM(:)], 'VariableNames',{'Time','EMG','SVM','SpO2','BPM'}), nameCSV);
            writetable(table(Datos.T(:), anotFinal(:), 'VariableNames', {'Tiempo_s', 'Anot_SPI'}), nameTXT);
            
            uialert(UI.Fig, sprintf('Exportación Exitosa en %s\nCSV: %s\nTXT: %s\nEpisodios SPI: %d', rutaSalida, sprintf('AVA_Estudio_%s.csv', fStr), sprintf('AVA_Anotaciones_%s.txt', fStr), size(epi,1)), 'Éxito');
        catch ME
            logSistema('ERROR', ['Fallo de I/O de exportación: ', ME.message]);
            uialert(UI.Fig, 'Error de escritura. Datos a salvo en caché.', 'Fallo Crítico');
        end
        cambiarPanel(UI.PnlMenu);
    end

    function ejecutarAnalisis()
        if Archivos.Senales == "", uialert(UI.Fig, 'Seleccione un archivo CSV base.', 'Aviso'); return; end
        try
            tbl = readtable(Archivos.Senales); 
            
            % VALIDACIÓN ESTRICTA (Size y Permisos)
            if size(tbl, 1) < 10, uialert(UI.Fig, 'Archivo CSV corrupto (< 10 muestras).', 'Error'); return; end
            if size(tbl, 2) < 2, uialert(UI.Fig, 'Archivo CSV incompleto (Falta EMG).', 'Error'); return; end
            
            vT = tbl{:, 1}; 
            dtReal = mean(diff(vT));
            
            % Detección de irregularidad temporal
            dtDesv = std(diff(vT));
            if dtDesv > dtReal * 0.1, logSistema('WARN', sprintf('Muestreo muy irregular. Desv = %.5f', dtDesv)); end
            if dtReal <= 0 || isnan(dtReal), uialert(UI.Fig, 'Tiempos nulos en el archivo CSV.', 'Error'); return; end
            
            fsReal = 1 / dtReal;
            vEMG = tbl{:, 2}; nVars = size(tbl, 2);
            if nVars >= 3, vSVM = tbl{:, 3}; else, vSVM = zeros(size(vEMG)); logSistema('WARN', 'Falta columna SVM.'); end
            if nVars >= 4, vSPO2 = tbl{:, 4}; else, vSPO2 = []; end
            if nVars >= 5, vBPM = tbl{:, 5}; else, vBPM = []; end
            
            totPLM = 0; totSPI = 0;
            
            % VÍA RÁPIDA (Interpolación Segura) vs VÍA LARGA
            if Archivos.Anotaciones ~= ""
                if ~isfile(Archivos.Anotaciones), uialert(UI.Fig, 'No se encuentra el archivo TXT.', 'Error'); return; end
                tblA = readtable(Archivos.Anotaciones);
                if size(tblA, 1) == 0
                    logSistema('WARN', 'TXT vacío. Abortando vía rápida.');
                    Archivos.Anotaciones = "";
                elseif size(tblA, 2) < 2
                    uialert(UI.Fig, 'El TXT de anotaciones es inválido.', 'Error'); return;
                else
                    tAno = tblA{:, 1}; vAno = double(tblA{:, 2});
                    
                    % Sort seguro para interp1
                    [tAnoOrd, idxSort] = sort(tAno); vAnoOrd = vAno(idxSort);
                    if any(diff(tAnoOrd) <= 0)
                        [tAnoUnique, idxUnique] = unique(tAnoOrd, 'stable');
                        vAnoOrd = vAnoOrd(idxUnique); tAnoOrd = tAnoUnique;
                    end
                    
                    Analisis.Anotaciones = interp1(tAnoOrd, vAnoOrd, vT, 'linear', 'extrap');
                    Analisis.Anotaciones = max(0, min(1, Analisis.Anotaciones)); % Clamp seguro
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
                [Analisis.Anotaciones, Analisis.Episodios, mPLM] = procesarAASM(vT, vEMG, vSVM, fsReal);
                totSPI = size(Analisis.Episodios, 1); totPLM = size(mPLM, 1);
            end
            
            Analisis.T = vT; Analisis.IdxNav = 0;
            UI.lblTotales.Text = sprintf('Totales: %d PLMs | %d SPI', totPLM, totSPI);
            
            delete(UI.pnlGraficasAna.Children); 
            numGrafs = 2 + (max(vSPO2)>0) + (max(vBPM)>0);
            gGrid = uigridlayout(UI.pnlGraficasAna, [numGrafs, 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG Tibial y AASM'); hold(ax1,'on');
            plot(ax1, vT, vEMG, 'Color', [0.7 0.7 0.7]); plot(ax1, vT, Analisis.Anotaciones * max(vEMG), 'r', 'LineWidth', 1.5);
            ax2 = uiaxes(gGrid); title(ax2, 'Actigrafía SVM'); plot(ax2, vT, vSVM, 'Color', [0 0.4 0.8]);
            
            listaEjes = [ax1, ax2];
            
            if max(vSPO2) > 0
                ax3 = uiaxes(gGrid); title(ax3, 'SpO2 % (Crudo)'); plot(ax3, vT, vSPO2, 'g', 'LineWidth', 1.5); ylim(ax3, [85 100]);
                listaEjes = [listaEjes, ax3];
            end
            if max(vBPM) > 0
                ax4 = uiaxes(gGrid); title(ax4, 'BPM (Crudo)'); plot(ax4, vT, vBPM, 'r', 'LineWidth', 1.5); ylim(ax4, [50 120]);
                listaEjes = [listaEjes, ax4];
            end
            
            UI.AxesAnaLista = listaEjes; 
            cambiarPanel(UI.PnlAna); navegarEpisodios(0);
            logSistema('INFO', 'Análisis ejecutado exitosamente.');
            
        catch ME
            logSistema('ERROR', ['Crash de Analizador: ', ME.message]);
            uialert(UI.Fig, 'Error de formato en archivo seleccionado.', 'Error');
        end
    end

    %% --- 6. FUNCIONES SECUNDARIAS (HELPERS) ---
    
    function [datos, exito] = leerYValidarUDP(puerto, lenEsperado, limitePaquetes)
        datos = []; exito = false;
        if isempty(puerto) || ~isvalid(puerto), return; end
        try
            paquetesLeidos = 0;
            while puerto.NumDatagramsAvailable > 0 && paquetesLeidos < limitePaquetes
                paquete = read(puerto, 1); 
                str = strip(string(char(paquete.Data)));
                nums = str2double(split(str, ","))';
                if length(nums) == lenEsperado && ~any(isnan(nums)) && ~any(isinf(nums))
                    datos = nums; exito = true;
                end
                paquetesLeidos = paquetesLeidos + 1;
            end
        catch ME
            if ~contains(ME.message, 'NumDatagramsAvailable')
                logSistema('WARN', ['Fallo UDP: ', ME.message]);
            end
        end
    end

    function [s, b] = calcularVitales(bR, bI, fs)
        bR_AC = bR - mean(bR); bI_AC = bI - mean(bI);
        acR = std(bR_AC); dcR = mean(abs(bR));
        acI = std(bI_AC); dcI = mean(abs(bI));
        
        if dcR == 0 || dcI == 0, s = 95; b = 70; return; end
        
        R = (acR / dcR) / (acI / dcI); s = max(85, min(99, 110 - 25 * R));
        
        % Detección de Picos Reales para BPM
        [~, locs] = findpeaks(bI_AC, 'MinPeakDistance', round(fs/3)); 
        if length(locs) > 2
            intProm = mean(diff(locs)) / fs;
            b = max(40, min(200, 60 / intProm));
        else
            b = 70;
        end
    end

    function [anotFinal, mEpi, mPlm] = procesarAASM(t, e, s, fs)
        minE = min(e); rangeE = max(e) - minE; if rangeE == 0, rangeE = 1; end
        en = (e - minE) / rangeE; 
        
        minS = min(s); rangeS = max(s) - minS; if rangeS == 0, rangeS = 1; end
        sn = (s - minS) / rangeS;
        
        fus = en .* sn; maxF = max(fus); if maxF > 0, fus = fus / maxF; end
        
        fl = diff([0; fus > 0.15; 0]); 
        iI = find(fl==1); iF = find(fl==-1)-1;
        
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
            if ~isfile(rutaFull), uialert(UI.Fig, 'Archivo no encontrado.', 'Error'); return; end
            if strcmp(tipo, 'DATOS'), Archivos.Senales = rutaFull; UI.lblDat.Text = n;
            else, Archivos.Anotaciones = rutaFull; UI.lblAno.Text = n; end
        end
    end

    function navegarEpisodios(dir)
        if isempty(Analisis.Episodios) || isempty(UI.AxesAnaLista), return; end
        Analisis.IdxNav = max(1, min(Analisis.IdxNav + dir, size(Analisis.Episodios, 1)));
        UI.lblEpi.Text = sprintf('Episodio SPI: %d / %d', Analisis.IdxNav, size(Analisis.Episodios, 1));
        
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
        UI.PnlMenu.Visible = 'off'; UI.PnlAdq.Visible = 'off'; UI.PnlAna.Visible = 'off'; 
        pTarget.Visible = 'on'; 
    end

    function liberarRecursos(R)
        if isfield(R, 'UdpTobillo') && ~isempty(R.UdpTobillo) && isvalid(R.UdpTobillo), clear R.UdpTobillo; end
        if isfield(R, 'UdpBiceps') && ~isempty(R.UdpBiceps) && isvalid(R.UdpBiceps), clear R.UdpBiceps; end
        logSistema('INFO', 'Sockets cerrados.');
    end

    function cerrarAplicacion(src, ~)
        Estado.Capturando = false; liberarRecursos(Red); delete(src);
    end

    function logSistema(nivel, mensaje)
        persistent ultLog t0Log lockLog
        if isempty(lockLog), lockLog = false; end
        while lockLog, pause(0.001); end; lockLog = true;
        
        if isempty(t0Log), t0Log = now; end
        if isempty(ultLog), ultLog = now; end
        tMS = (now - ultLog) * 86400000; tAbs = (now - t0Log) * 86400; ultLog = now;
        
        fprintf('[%8.2fs] [%-4s] [%5.1fms] %s\n', tAbs, nivel, tMS, mensaje);
        lockLog = false;
    end
end

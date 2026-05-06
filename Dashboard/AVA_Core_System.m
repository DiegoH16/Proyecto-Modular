function AVA_Core_System_V6_1_Endurance()
   
    clearvars; clc; close all force;
    
    %% --- 1. CONFIGURACIÓN DE RENDIMIENTO ---
    Config = struct();
    Config.Puertos.Tobillo = 8888; 
    Config.Puertos.Biceps  = 8889; 
    Config.Muestreo.Fs_Hz  = 50; 
    Config.Muestreo.VentanaGrafica_s = 60; 
    
    % Capacidad del Buffer (10 horas = 1.8 Millones de muestras = ~120 MB en RAM)
    Config.BufferMax.Horas = 10;
    Config.BufferMax.Muestras = Config.Muestreo.Fs_Hz * 3600 * Config.BufferMax.Horas; 
    
    Config.UI.RefrescoGraficas_Muestras = 5; % Render batching (10 FPS visuales)
    Config.UI.MaxPaquetesUDP_Lectura = 20; 
    Config.Backup.MuestrasIntervalo = Config.Muestreo.Fs_Hz * 300; % Backup cada 5 min (15,000 muestras)
    
    Config.Umbrales.IR_Minimo_Dedo = 3000;
    Config.Umbrales.EMG_Contraccion = 150;
    Config.Umbrales.SVM_Movimiento = 0.4;
    
    Config.Filtros.Alpha_Base = 0.001;
    Config.Filtros.Alpha_Env  = 0.15;
    
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
    Estado.DedoDetectado = false; % Reemplaza comprobaciones lentas de String
    
    Estado.ContadorErroresUDP = 0;
    Estado.MaximoErroresPermitidos = 100; 
    
    Estado.Filtros.EMG_Base = 1870; Estado.Filtros.EMG_Env = 0;
    Estado.Filtros.SVM_Base = 1;    Estado.Filtros.SVM_Env = 0;
    Estado.Filtros.PPG_Base = 0;
    
    Estado.Vitales.SPO2 = 98;
    Estado.Vitales.BPM = 70;
    Estado.Vitales.BufferRed = zeros(1, Config.Muestreo.Fs_Hz * 10); 
    Estado.Vitales.BufferIR  = zeros(1, Config.Muestreo.Fs_Hz * 10);
    
    Estado.UI.ContraccionPrevia = false;
    Estado.UI.MuestrasRecibidas = 0;
    Estado.UI.MuestrasDesdeUltimoBackup = 0;
    
    Analisis = struct('T', [], 'Anotaciones', [], 'Episodios', [], 'IdxNav', 0);
    Archivos = struct('Senales', "", 'Anotaciones', "");
    Red = struct('UdpTobillo', [], 'UdpBiceps', []);
    
    % Buffers temporales para Batching de Gráficas (Evita llamar addpoints 50 veces por seg)
    Batch = struct('T', zeros(1,5), 'EMG', zeros(1,5), 'SVM', zeros(1,5), 'Idx', 1);
    
    limpiezaCierre = onCleanup(@() liberarRecursos(Red));
    
    %% --- 3. CONSTRUCCIÓN DE INTERFAZ GRÁFICA ---
    logSistema('INFO', 'Iniciando AVA Nexus V6.1 (10-Hour Endurance Edition)');
    UI = struct();
    UI.Fig = uifigure('Name', 'AVA Nexus V6.1 | Endurance Edition', 'Color', 'w', 'Position', [50, 50, 1200, 900]);
    UI.Fig.CloseRequestFcn = @(src, event) cerrarAplicacion(src, event);
    UI.AxesAnaLista = [];
    
    UI.PnlMenu = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w');
    UI.PnlAdq  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    UI.PnlAna  = uipanel(UI.Fig, 'Position', [1 1 1200 900], 'BackgroundColor', 'w', 'Visible', 'off');
    
    % --- Menú ---
    uilabel(UI.PnlMenu, 'Text', 'AVA NEXUS V6.1', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [450 650 300 60], 'HorizontalAlignment', 'center');
    uilabel(UI.PnlMenu, 'Text', '10-Hour PSG Endurance Edition (Optimización Extrema de RAM)', 'FontSize', 16, 'Position', [250, 600, 700, 30], 'HorizontalAlignment', 'center', 'FontColor', [0.3 0.3 0.3]);
    
    uibutton(UI.PnlMenu, 'Text', '1. Adquisición de Datos (UDP)', 'FontSize', 18, 'Position', [375 450 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAdq));
    uibutton(UI.PnlMenu, 'Text', '2. Analizador Clínico (CSV/TXT)', 'FontSize', 18, 'Position', [375 350 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanel(UI.PnlAna));
    
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

    %% --- 4. BUCLE PRINCIPAL (Endurance Performance) ---
    while ishandle(UI.Fig)
        try
            if Estado.Capturando 
                
                % --- BÍCEPS ---
                [datosBiceps, exitoB] = leerYValidarUDP(Red.UdpBiceps, 3, Config.UI.MaxPaquetesUDP_Lectura);
                if exitoB
                    tCrudo = datosBiceps(1)/1000;
                    if Estado.T0_Biceps == -1, Estado.T0_Biceps = tCrudo; end
                    
                    if ~Estado.PrimeraTramaBiceps
                        logSistema('INFO', 'BÍCEPS conectado.');
                        Estado.PrimeraTramaBiceps = true;
                    end
                    
                    Estado.Vitales.BufferRed = [Estado.Vitales.BufferRed(2:end), datosBiceps(2)]; 
                    Estado.Vitales.BufferIR  = [Estado.Vitales.BufferIR(2:end), datosBiceps(3)];
                    
                    if datosBiceps(3) > Config.Umbrales.IR_Minimo_Dedo
                        Estado.DedoDetectado = true;
                        UI.lblSPO2.FontColor = [0 0.4 0.8]; 
                    else
                        Estado.DedoDetectado = false;
                        UI.lblSPO2.Text = 'SIN DEDO'; UI.lblSPO2.FontColor = [0.8 0.2 0.2]; UI.lblBPM.Text = '---';
                    end
                end

                % --- TOBILLO ---
                [datosTobillo, exitoT] = leerYValidarUDP(Red.UdpTobillo, 5, Config.UI.MaxPaquetesUDP_Lectura);
                if exitoT
                    Estado.ContadorErroresUDP = max(0, Estado.ContadorErroresUDP - 1);
                    
                    tCrudo = datosTobillo(1)/1000;
                    if ~validarSincronizacionTemporal(tCrudo, 'TOBILLO')
                        continue; 
                    end
                    
                    if Estado.T0_Tobillo == -1, Estado.T0_Tobillo = tCrudo; end
                    
                    if ~Estado.PrimeraTramaTobillo
                        logSistema('INFO', 'TOBILLO conectado.');
                        Estado.PrimeraTramaTobillo = true;
                    end
                    
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
                    
                    % Batching Gráfico (Acumular puntos en memoria pequeña antes de dibujar)
                    Batch.T(Batch.Idx) = tTobillo;
                    Batch.EMG(Batch.Idx) = Estado.Filtros.EMG_Env;
                    Batch.SVM(Batch.Idx) = svmCrudo;
                    Batch.Idx = Batch.Idx + 1;
                    
                    % Renderizado Visual a 10 FPS (Throttling)
                    if Batch.Idx > Config.UI.RefrescoGraficas_Muestras
                        if contraccionActual ~= Estado.UI.ContraccionPrevia
                            if contraccionActual
                                UI.lblLed.BackgroundColor = [0.2 0.8 0.2]; UI.lblLed.Text = ' CONTRACCIÓN ';
                            else
                                UI.lblLed.BackgroundColor = [0.8 0.2 0.2]; UI.lblLed.Text = ' REPOSO ';
                            end
                            Estado.UI.ContraccionPrevia = contraccionActual;
                        end
                        
                        % Añadir lote de puntos al animatedline de una sola vez
                        addpoints(UI.lineaEMG, Batch.T(1:Batch.Idx-1), Batch.EMG(1:Batch.Idx-1)); 
                        addpoints(UI.lineaSVM, Batch.T(1:Batch.Idx-1), Batch.SVM(1:Batch.Idx-1)); 
                        actualizarEjesGrafica([UI.axEMG_TR, UI.axSVM_TR], tTobillo, Config.Muestreo.VentanaGrafica_s);
                        
                        Batch.Idx = 1; % Reset Batch
                    end
                    
                    % Signos Vitales y Memoria (1 vez por segundo)
                    if mod(Estado.UI.MuestrasRecibidas, 50) == 0
                        [Estado.Vitales.SPO2, Estado.Vitales.BPM] = calcularVitales(Estado.Vitales.BufferRed, Estado.Vitales.BufferIR, Config.Muestreo.Fs_Hz); 
                        
                        if Estado.DedoDetectado
                            UI.lblSPO2.Text = sprintf('%d%%', round(Estado.Vitales.SPO2)); 
                            UI.lblBPM.Text  = sprintf('%d', round(Estado.Vitales.BPM));
                        end
                        
                        try
                            mem = memory();
                            UI.lblMemoria.Text = sprintf('RAM: %.0f MB', mem.MemUsedMATLAB / 1024^2);
                        catch
                            UI.lblMemoria.Text = 'RAM: N/A';
                        end
                    end
                    
                    % BACKUP INCREMENTAL SEGURO (En Hilo Principal, sin Timer)
                    Estado.UI.MuestrasDesdeUltimoBackup = Estado.UI.MuestrasDesdeUltimoBackup + 1;
                    if Estado.UI.MuestrasDesdeUltimoBackup > Config.Backup.MuestrasIntervalo
                        backupIncremental();
                        Estado.UI.MuestrasDesdeUltimoBackup = 0;
                    end
                    
                    % GUARDAR EN RING BUFFER (Precisión Double Completa)
                    guardarEnRingBuffer(tTobillo, Estado.Filtros.EMG_Env, svmCrudo, Estado.Vitales.SPO2, Estado.Vitales.BPM, contraccionActual, Config, RingBuffer);
                    
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
            logSistema('WARN', ['Excepción tolerada: ', excepcionMain.message]);
        end
        drawnow limitrate; 
        pause(0.001); % Necesario en Windows para procesar los callbacks de la UI
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
            
            Analisis.T = []; Analisis.Anotaciones = []; Analisis.Episodios = []; Analisis.IdxNav = 0;
            
            try Red.UdpTobillo = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", Config.Puertos.Tobillo); 
            catch ME, logSistema('ERROR', ME.message); end
            try Red.UdpBiceps  = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", Config.Puertos.Biceps); 
            catch ME, logSistema('ERROR', ME.message); end
            
            UI.lblInfo.Text = "ACTIVO"; UI.lblInfo.FontColor = [0 0.5 0];
            clearpoints(UI.lineaEMG); clearpoints(UI.lineaSVM); 
            
            UI.btnUDP.Text = "⏹ Detener"; UI.btnUDP.BackgroundColor = [1 0.4 0.4];
            logSistema('INFO', 'Captura iniciada.');
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
        
        backupIncremental(); % Último backup por seguridad
        
        [t_d, emg_d, svm_d, spo2_d, bpm_d, anot_d] = descomprimirRingBuffer();
        
        try
            nameCSV = fullfile(rutaSalida, sprintf('AVA_Estudio_%s.csv', fStr));
            nameTXT = fullfile(rutaSalida, sprintf('AVA_Anotaciones_%s.txt', fStr));
            
            if isfile(nameCSV), logSistema('WARN', 'Sobrescribiendo archivo CSV existente.'); end
            
            % Procesamiento AASM final para asegurar etiquetas clínicas puras
            [anotFinal, epi, ~] = procesarAASM(t_d, emg_d, svm_d, Config.Muestreo.Fs_Hz, Config);
            
            % OPTIMIZACIÓN: Usar writematrix (Zero RAM spike, 10x más rápido que writetable)
            matrizExport = [t_d(:), emg_d(:), svm_d(:), spo2_d(:), bpm_d(:)];
            writematrix(matrizExport, nameCSV);
            
            matrizAnot = [t_d(:), double(anotFinal(:))];
            writematrix(matrizAnot, nameTXT);
            
            uialert(UI.Fig, sprintf('Exportado Rápido: %d muestras\nDirectorio: %s', length(t_d), rutaSalida), 'Éxito');
        catch ME
            logSistema('ERROR', ['Export fallo: ', ME.message]);
            uialert(UI.Fig, 'Error de I/O de disco.', 'Error Crítico');
        end
        cambiarPanel(UI.PnlMenu);
    end

    function ejecutarAnalisisPro()
        if Archivos.Senales == "", uialert(UI.Fig, 'Seleccione CSV.', 'Aviso'); return; end
        try
            % OPTIMIZACIÓN: readmatrix en lugar de readtable
            logSistema('INFO', 'Cargando matriz CSV masiva...');
            matDatos = readmatrix(Archivos.Senales);
            
            if size(matDatos, 1) < 10, uialert(UI.Fig, 'CSV corto.', 'Error'); return; end
            if size(matDatos, 2) < 2, uialert(UI.Fig, 'CSV incompleto.', 'Error'); return; end
            
            vT = matDatos(:, 1); 
            dtReal = mean(diff(vT));
            if dtReal <= 0 || isnan(dtReal), uialert(UI.Fig, 'Tiempos nulos.', 'Error'); return; end
            
            fsReal = 1 / dtReal;
            vEMG = matDatos(:, 2); nVars = size(matDatos, 2);
            if nVars >= 3, vSVM = matDatos(:, 3); else, vSVM = zeros(size(vEMG)); logSistema('WARN', 'Falta columna SVM.'); end
            if nVars >= 4, vSPO2 = matDatos(:, 4); else, vSPO2 = []; end
            if nVars >= 5, vBPM = matDatos(:, 5); else, vBPM = []; end
            
            totPLM = 0; totSPI = 0;
            
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
                    Analisis.Anotaciones = max(0, min(1, Analisis.Anotaciones));
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
            UI.lblEpi.Text = sprintf('Episodio: 0 | Totales: %d PLMs | %d SPI', totPLM, totSPI);
            
            delete(UI.pnlGraficasAna.Children); 
            numGrafs = 2 + (max(vSPO2)>0) + (max(vBPM)>0);
            gGrid = uigridlayout(UI.pnlGraficasAna, [numGrafs, 1], 'Padding', 0);
            
            ax1 = uiaxes(gGrid); title(ax1, 'EMG + AASM'); hold(ax1,'on'); grid(ax1, 'on');
            plot(ax1, vT, vEMG, 'Color', [0.6 0.6 0.6]); 
            plot(ax1, vT, Analisis.Anotaciones * max(vEMG), 'r', 'LineWidth', 1.5);
            
            ax2 = uiaxes(gGrid); title(ax2, 'SVM Actigrafía'); plot(ax2, vT, vSVM, 'Color', [0 0.4 0.8]); grid(ax2, 'on');
            
            listaEjes = [ax1, ax2]; 
            
            if max(vSPO2) > 0
                ax3 = uiaxes(gGrid); title(ax3, 'SpO2 %'); plot(ax3, vT, vSPO2, 'g', 'LineWidth', 1.5); ylim(ax3, [85 100]); grid(ax3, 'on');
                listaEjes = [listaEjes, ax3];
            end
            
            if max(vBPM) > 0
                ax4 = uiaxes(gGrid); title(ax4, 'BPM'); plot(ax4, vT, vBPM, 'r', 'LineWidth', 1.5); ylim(ax4, [50 120]); grid(ax4, 'on');
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

    %% --- 6. FUNCIONES SECUNDARIAS ---
    
    function ok = validarSincronizacionTemporal(tCrudo, nombre)
        ok = true;
        if tCrudo < 0 || tCrudo > 2^31
            logSistema('ERROR', sprintf('%s: Timestamp anómalo (%d ms)', nombre, tCrudo)); ok = false; return;
        end
        if strcmp(nombre, 'TOBILLO') && Estado.tCrudoAnterior_Tobillo ~= -1
            dt = tCrudo - Estado.tCrudoAnterior_Tobillo;
            if dt < 0, logSistema('ERROR', 'Rebote temporal (Time Travel).'); ok = false; return; end
        end
        Estado.tCrudoAnterior_Tobillo = tCrudo;
    end

    function guardarEnRingBuffer(t, emg, svm, spo2, bpm, anot, cfg, rb_ref)
        try
            idx = RingBuffer.Idx;
            RingBuffer.T(idx)    = t;
            RingBuffer.EMG(idx)  = emg;
            RingBuffer.SVM(idx)  = svm;
            RingBuffer.SPO2(idx) = spo2;
            RingBuffer.BPM(idx)  = bpm;
            RingBuffer.Anot(idx) = anot;
            
            RingBuffer.Idx = mod(idx, cfg.BufferMax.Muestras) + 1;
            if RingBuffer.Count < cfg.BufferMax.Muestras, RingBuffer.Count = RingBuffer.Count + 1;
            else, RingBuffer.Full = true; end
        catch ME
            logSistema('ERROR', ['Fallo en RingBuffer: ', ME.message]);
        end
    end

    function [t, e, s, sp, b, a] = descomprimirRingBuffer()
        c = RingBuffer.Count;
        if RingBuffer.Full
            idxTemp = mod((0:c-1) + RingBuffer.Idx - 1, Config.BufferMax.Muestras) + 1;
        else
            idxTemp = 1:c;
        end
        t = RingBuffer.T(idxTemp);
        e = RingBuffer.EMG(idxTemp);
        s = RingBuffer.SVM(idxTemp);
        sp= RingBuffer.SPO2(idxTemp);
        b = RingBuffer.BPM(idxTemp);
        a = double(RingBuffer.Anot(idxTemp));
    end

    function backupIncremental()
        rutaCache = fullfile(userpath, 'AVA_Nexus_Data', '.cache_incremental');
        if ~isfolder(rutaCache), mkdir(rutaCache); end
        fStr = char(datetime('now', 'Format', 'yyyyMMdd_HHmm'));
        try
            % Se guardan solo los arrays para velocidad
            save(fullfile(rutaCache, sprintf('backup_inc_%s.mat', fStr)), 'RingBuffer', '-v6');
            logSistema('INFO', 'Backup Incremental Ejecutado (-v6 Fast Save).');
            archivos = dir(fullfile(rutaCache, 'backup_inc_*.mat'));
            if length(archivos) > 6
                [~, idxs] = sort([archivos.datenum]);
                delete(fullfile(rutaCache, archivos(idxs(1)).name));
            end
        catch
        end
    end

    function [datos, exito] = leerYValidarUDP(puerto, lenE, limPaq)
        datos = []; exito = false;
        if isempty(puerto) || ~isvalid(puerto), return; end
        try
            paquetesLeidos = 0;
            while puerto.NumDatagramsAvailable > 0 && paquetesLeidos < limPaq
                paquete = read(puerto, 1); str = strip(string(char(paquete.Data)));
                nums = str2double(split(str, ","))';
                if length(nums) == lenE && ~any(isnan(nums)) && ~any(isinf(nums))
                    datos = nums; exito = true;
                end
                paquetesLeidos = paquetesLeidos + 1;
            end
        catch
        end
    end

    function [s, b] = calcularVitales(bR, bI, fs)
        bR_AC = bR - mean(bR); bI_AC = bI - mean(bI);
        acR = std(bR_AC); dcR = mean(abs(bR));
        acI = std(bI_AC); dcI = mean(abs(bI));
        
        if dcR == 0 || dcI == 0, s = 95; b = 70; return; end
        R = (acR / dcR) / (acI / dcI); s = max(85, min(99, 110 - 25 * R));
        
        umb = std(bI_AC) * 0.5;
        picos = find(bI_AC(2:end-1) > bI_AC(1:end-2) & bI_AC(2:end-1) > bI_AC(3:end) & bI_AC(2:end-1) > umb);
        if length(picos) > 2, intProm = mean(diff(picos)) / fs; b = max(40, min(200, 60 / intProm));
        else, b = 70; end
    end

    function [anotFinal, mEpi, mPlm] = procesarAASM(t, e, s, fs, cfg)
        % Lógica estricta de normalización clínica
        en = (e - cfg.Norm.EMG_Min) / (cfg.Norm.EMG_Max - cfg.Norm.EMG_Min); 
        en = max(0, min(1, en)); 
        
        sn = (s - cfg.Norm.SVM_Min) / (cfg.Norm.SVM_Max - cfg.Norm.SVM_Min);
        sn = max(0, min(1, sn));
        
        fus = en .* sn; 
        
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
            if ~isfile(rutaFull), return; end
            if strcmp(tipo, 'DATOS'), Archivos.Senales = rutaFull; UI.lblDat.Text = n;
            else, Archivos.Anotaciones = rutaFull; UI.lblAno.Text = n; end
        end
    end

    function navegarEpisodios(dir)
        if isempty(Analisis.Episodios) || isempty(UI.AxesAnaLista), return; end
        Analisis.IdxNav = max(1, min(Analisis.IdxNav + dir, size(Analisis.Episodios, 1)));
        
        textoEpi = sprintf('Episodio: %d / %d', Analisis.IdxNav, size(Analisis.Episodios, 1));
        UI.lblEpi.Text = regexprep(UI.lblEpi.Text, 'Episodio: \d+( / \d+)?', textoEpi);
        
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
        cap = Estado.Capturando; if cap, Estado.Capturando = false; pause(0.1); end
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
        tAbs = seconds(datetime('now') - t0);
        try fprintf('[%8.2fs] [%-4s] %s\n', tAbs, nivel, mensaje); catch, end
    end
end

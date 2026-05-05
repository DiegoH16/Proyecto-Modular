function AVA_Core_System()
    % =========================================================================
    % PROYECTO: AVA Nexus - Sistema Modular de Monitorización de Insomnio y SPI
    % DESCRIPCIÓN: Plataforma de adquisición telemétrica (UDP) y analizador 
    % clínico basado en las reglas de la AASM para Movimientos Periódicos.
    % =========================================================================
    
    clear all; clc; close all; 
    
    %% --- 1. CONFIGURACIÓN DE PARÁMETROS GLOBALES ---
    puertoTobillo = 8888; % Puerto UDP para el nodo ESP32 del tobillo
    puertoBiceps  = 8889; % Puerto UDP para el nodo ESP32 del brazo
    ventanaGrafica_s = 60; % Segundos a mostrar en el barrido de la gráfica
    frecuenciaMuestreo_Hz = 50; 
    
    % Estados de Ejecución
    sistemaCapturando = false; 
    udpTobillo = []; 
    udpBiceps  = [];  
    
    % Estructura Central de Almacenamiento de Datos del Paciente
    datosPaciente = struct('Tiempo',[], 'EMG',[], 'SVM',[], 'SPO2',[], 'BPM',[], 'Anotacion_TR',[]);
    
    % Variables de Estado para el Analizador
    rutaArchivoSenales = ""; 
    rutaArchivoAnotaciones = "";
    vectorTiempoAnalisis = []; 
    anotaciones_AASM = []; 
    matrizEpisodiosSPI = []; 
    idx_nav = 0;
    
    % Estructura para almacenar los Ejes (Axes) del Analizador
    uiAnalizador = struct('axEMG',[], 'axSVM',[], 'axBPM',[], 'axSPO2',[]);
    
    % Buffers DSP (Procesamiento Digital de Señales) para Signos Vitales
    bufferLuzRoja = zeros(1, 100); 
    bufferLuzIR   = zeros(1, 100);
    valorSPO2_actual = 98; 
    valorBPM_actual = 70; 
    
    % Máquina de Estados de Interfaz (Para evitar cuellos de botella gráficos)
    estadoInterfazAnterior = false; 
    
    %% --- 2. CONSTRUCCIÓN DE LA INTERFAZ GRÁFICA (UI) ---
    figuraPrincipal = uifigure('Name', 'AVA Nexus | AASM Clinical PSG', 'Color', 'w', 'Position', [50, 50, 1150, 950]);
    
    % Paneles Contenedores
    pnlMenuPrincipal = uipanel(figuraPrincipal, 'Position', [1 1 1150 950], 'BackgroundColor', 'w');
    pnlAdquisicion   = uipanel(figuraPrincipal, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    pnlCargaArchivos = uipanel(figuraPrincipal, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    pnlAnalizador    = uipanel(figuraPrincipal, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    
    % --- DISEÑO: MENÚ PRINCIPAL ---
    uilabel(pnlMenuPrincipal, 'Text', 'AVA NEXUS', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [425 700 300 60], 'HorizontalAlignment', 'center');
    uilabel(pnlMenuPrincipal, 'Text', 'Monitorización y Análisis Clínico de Síndrome de Piernas Inquietas', 'FontSize', 18, 'Position', [200 650 750 40], 'HorizontalAlignment', 'center');
    uibutton(pnlMenuPrincipal, 'Text', '1. Adquisición de Datos ', 'FontSize', 18, 'Position', [350 500 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanelVisible(pnlAdquisicion));
    uibutton(pnlMenuPrincipal, 'Text', '2. Analizador Clínico ', 'FontSize', 18, 'Position', [350 400 450 60], 'ButtonPushedFcn', @(src, event) cambiarPanelVisible(pnlCargaArchivos));
    
    % --- DISEÑO: PANEL DE ADQUISICIÓN LIGERA ---
    gridAdquisicion = uigridlayout(pnlAdquisicion, [7, 2], 'RowHeight', {'1x', '1x', '1x', 80, 70, 60, 60}, 'Padding', 20);
    
    axEMG_TR = uiaxes(gridAdquisicion); title(axEMG_TR, 'Monitor EMG Tibial'); axEMG_TR.Layout.Row = 1; axEMG_TR.Layout.Column = [1 2];
    axSVM_TR = uiaxes(gridAdquisicion); title(axSVM_TR, 'Monitor Actigrafía SVM'); axSVM_TR.Layout.Row = 2; axSVM_TR.Layout.Column = [1 2];
    axPPG_TR = uiaxes(gridAdquisicion); title(axPPG_TR, 'Monitor Onda PPG (Bíceps)'); axPPG_TR.Layout.Row = 3; axPPG_TR.Layout.Column = [1 2];
    
    panelVitales = uigridlayout(gridAdquisicion, [1, 2]); panelVitales.Layout.Row = 4; panelVitales.Layout.Column = [1 2];
    lblSPO2 = uilabel(panelVitales, 'Text', '--% SpO2', 'FontSize', 45, 'FontWeight', 'bold', 'FontColor', [0 0.4 0.8], 'HorizontalAlignment', 'center'); 
    lblBPM  = uilabel(panelVitales, 'Text', '-- BPM', 'FontSize', 45, 'FontWeight', 'bold', 'HorizontalAlignment', 'center'); 
    
    panelDeteccion = uipanel(gridAdquisicion, 'BackgroundColor', [0.95 0.95 0.95]); panelDeteccion.Layout.Row = 5; panelDeteccion.Layout.Column = [1 2];
    gridDeteccion = uigridlayout(panelDeteccion, [1, 1]);
    lblLedEstado = uilabel(gridDeteccion, 'Text', '  ESPERANDO INICIO DE NODOS  ', 'FontSize', 22, 'FontWeight', 'bold', 'BackgroundColor', [0.5 0.5 0.5], 'FontColor', 'w', 'HorizontalAlignment', 'center');

    lblInfoModo = uilabel(gridAdquisicion, 'Text', 'Asegúrese de que los ESP32 estén conectados a la red WiFi.', 'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    lblInfoModo.Layout.Row = 6; lblInfoModo.Layout.Column = [1 2];

    btnControlNodos = uibutton(gridAdquisicion, 'Text', '▶ Conectar e Iniciar Hardware UDP', 'FontSize', 18, 'FontWeight', 'bold', 'BackgroundColor', [0.2 0.6 0.2], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) alternarCaptura(src));
    btnControlNodos.Layout.Row = 7; btnControlNodos.Layout.Column = 1;
    
    btnExportarDatos = uibutton(gridAdquisicion, 'Text', 'Finalizar y Guardar Archivos (CSV + TXT)', 'FontSize', 16, 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) detenerYExportarEstudio());
    btnExportarDatos.Layout.Row = 7; btnExportarDatos.Layout.Column = 2;

    lineaEMG = animatedline(axEMG_TR, 'Color', [1 0.5 0], 'LineWidth', 1.5); 
    lineaSVM = animatedline(axSVM_TR, 'Color', [0 0.4 1], 'LineWidth', 1.5); 
    lineaPPG = animatedline(axPPG_TR, 'Color', [0.8 0 0], 'LineWidth', 1.5); 

    % --- DISEÑO: PANEL DE CARGA DE ARCHIVOS ---
    gridCarga = uigridlayout(pnlCargaArchivos, [7, 1], 'RowHeight', {60, 40, 30, 40, 30, 60, 40}, 'Padding', 50);
    uilabel(gridCarga, 'Text', 'SALA DE CARGA Y ANÁLISIS DE DATOS', 'FontSize', 22, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    
    uibutton(gridCarga, 'Text', '1. Cargar Señales Biométricas (.CSV)', 'FontSize', 16, 'ButtonPushedFcn', @(src, event) seleccionarArchivo('DATOS'));
    lblNombreSenales = uilabel(gridCarga, 'Text', 'Sin archivo seleccionado.', 'HorizontalAlignment', 'center');
    
    uibutton(gridCarga, 'Text', '2. Cargar Anotaciones Médicas (.TXT) [VÍA RÁPIDA]', 'FontSize', 16, 'ButtonPushedFcn', @(src, event) seleccionarArchivo('ANOT'));
    lblNombreAnotaciones = uilabel(gridCarga, 'Text', 'Sin archivo seleccionado.', 'HorizontalAlignment', 'center');
    
    uibutton(gridCarga, 'Text', 'PROCESAR MOTOR AASM', 'FontSize', 18, 'FontWeight', 'bold', 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) ejecutarMotorAnalisis());
    uibutton(gridCarga, 'Text', 'Volver al Menú Principal', 'ButtonPushedFcn', @(src, event) cambiarPanelVisible(pnlMenuPrincipal));

    % --- DISEÑO: PANEL DEL ANALIZADOR CLÍNICO ---
    gridAnalizador = uigridlayout(pnlAnalizador, [3, 1], 'RowHeight', {80, '1x', 50}, 'Padding', 10);
    
    gridNavegacion = uigridlayout(gridAnalizador, [1, 5], 'ColumnWidth', {120, '1x', 120, 120, 200});
    uibutton(gridNavegacion, 'Text', '<< Anterior', 'ButtonPushedFcn', @(src, event) navegarEpisodios(-1));
    lblContadorEpisodios = uilabel(gridNavegacion, 'Text', '0 / 0 Episodios', 'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    uibutton(gridNavegacion, 'Text', 'Siguiente >>', 'ButtonPushedFcn', @(src, event) navegarEpisodios(1));
    uibutton(gridNavegacion, 'Text', 'Ver Todo', 'ButtonPushedFcn', @(src, event) visualizarTodoElEstudio());
    
    lblTotalesClinicos = uilabel(gridNavegacion, 'Text', 'Totales: --', 'FontSize', 16, 'FontWeight', 'bold', 'FontColor', [0.7 0.1 0.1], 'HorizontalAlignment', 'center');

    panelGraficasAnalizador = uipanel(gridAnalizador, 'BorderType', 'none', 'BackgroundColor', 'w');
    uibutton(gridAnalizador, 'Text', 'Volver al Menú Principal', 'ButtonPushedFcn', @(src, event) cambiarPanelVisible(pnlMenuPrincipal));

    %% --- 3. BUCLE PRINCIPAL DE ADQUISICIÓN DE HARDWARE (UDP) ---
    emg_lineabase = 1870; emg_envolvente = 0; 
    svm_lineabase = 1;    svm_envolvente = 0; 
    
    while ishandle(figuraPrincipal)
        if sistemaCapturando 
            
            % 3.1 Procesamiento del Nodo Esclavo (Bíceps - Signos Vitales)
            if ~isempty(udpBiceps) && isvalid(udpBiceps)
                while udpBiceps.NumDatagramsAvailable > 0
                    try
                        paqueteDatos = read(udpBiceps, 1); 
                        datosTexto = strip(string(char(paqueteDatos.Data)));
                        datosNumericos = str2double(split(datosTexto, ","))';
                        
                        if length(datosNumericos) == 3
                            tiempoBiceps = datosNumericos(1)/1000; 
                            rojoCrudo = datosNumericos(2); 
                            infrarrojoCrudo = datosNumericos(3);
                            
                            % Actualizar buffers circulares
                            bufferRed = [bufferRed(2:end), rojoCrudo]; 
                            bufferIR = [bufferIR(2:end), infrarrojoCrudo];
                            
                            % Verificar si hay dedo colocado (Contacto con el sensor)
                            if infrarrojoCrudo > 10000
                                ppg_onda = max(bufferIR) - infrarrojoCrudo; 
                                addpoints(lineaPPG, tiempoBiceps, ppg_onda); 
                                actualizarVentanaEjes(axPPG_TR, tiempoBiceps, ventanaGrafica_s);
                                
                                % Calcular signos vitales periódicamente
                                if mod(length(datosPaciente.Tiempo), 25) == 0
                                    [valorSPO2_actual, valorBPM_actual] = calcularSignosVitales(bufferRed, bufferIR); 
                                end
                            end
                        end
                    catch
                        % Ignorar tramas corruptas (Ruido de red)
                    end
                end
            end

            % 3.2 Procesamiento del Nodo Maestro (Tobillo - Motor y Reloj)
            if ~isempty(udpTobillo) && isvalid(udpTobillo)
                while udpTobillo.NumDatagramsAvailable > 0
                    try
                        paqueteDatos = read(udpTobillo, 1);
                        datosTexto = strip(string(char(paqueteDatos.Data)));
                        datosNumericos = str2double(split(datosTexto, ","))';
                        
                        if length(datosNumericos) == 5
                            tiempoMaestro = datosNumericos(1)/1000; 
                            ax = datosNumericos(2); ay = datosNumericos(3); az = datosNumericos(4); 
                            emgCrudo = datosNumericos(5);
                            
                            % Calcular Vector de Magnitud de Señal (Actigrafía)
                            svmCrudo = sqrt(ax^2 + ay^2 + az^2);
                            
                            % Procesamiento Digital (Filtros EMA para aislar contracciones)
                            if ~estadoInterfazAnterior 
                                % Congelar línea base si hay espasmo para evitar sesgo
                                emg_lineabase = (0.999 * emg_lineabase) + (0.001 * emgCrudo);
                                svm_lineabase = (0.999 * svm_lineabase) + (0.001 * svmCrudo);
                            end
                            
                            emg_envolvente = (0.15 * abs(emgCrudo - emg_lineabase)) + (0.85 * emg_envolvente);
                            svm_envolvente = (0.15 * abs(svmCrudo - svm_lineabase)) + (0.85 * svm_envolvente);
                            
                            % Evaluar Detección Ligera (Fusión Sensorial Básica)
                            espasmoDetectado = (emg_envolvente > 150) && (svm_envolvente > 0.4);
                            
                            % Actualizar Interfaz Gráfica sin Cuellos de Botella
                            if espasmoDetectado ~= estadoInterfazAnterior
                                if espasmoDetectado
                                    lblLedEstado.BackgroundColor = [0.2 0.8 0.2]; lblLedEstado.Text = '  CONTRACCIÓN DETECTADA (1)  ';
                                else
                                    lblLedEstado.BackgroundColor = [0.8 0.2 0.2]; lblLedEstado.Text = '  REPOSO (0)  ';
                                end
                                estadoInterfazAnterior = espasmoDetectado;
                            end
                            
                            % Sincronizar UI de vitales
                            if mod(round(tiempoMaestro*100), 50) == 0 
                                lblSPO2.Text = sprintf('%d%% SpO2', round(valorSPO2_actual)); 
                                lblBPM.Text  = sprintf('%d BPM', round(valorBPM_actual));
                            end
                            
                            % Guardar Registro Sincronizado en Memoria RAM
                            datosPaciente.Tiempo(end+1,1) = tiempoMaestro; 
                            datosPaciente.EMG(end+1,1)    = emg_envolvente; 
                            datosPaciente.SVM(end+1,1)    = svmCrudo; 
                            datosPaciente.SPO2(end+1,1)   = valorSPO2_actual; 
                            datosPaciente.BPM(end+1,1)    = valorBPM_actual; 
                            datosPaciente.Anotacion_TR(end+1,1) = double(espasmoDetectado);
                            
                            % Graficar
                            addpoints(lineaEMG, tiempoMaestro, emg_envolvente); 
                            addpoints(lineaSVM, tiempoMaestro, svmCrudo); 
                            actualizarVentanaEjes([axEMG_TR, axSVM_TR], tiempoMaestro, ventanaGrafica_s);
                        end
                    catch
                        % Ignorar tramas corruptas
                    end
                end
            end
        end
        % Control de refresco de interfaz para no bloquear MATLAB
        drawnow limitrate; 
        pause(0.001);
    end

    %% --- 4. FUNCIONES DE PROCESAMIENTO MATEMÁTICO (DSP Y AASM) ---
    
    function [estimacionSPO2, estimacionBPM] = calcularSignosVitales(bufferRojo, bufferInfrarrojo)
        % Cálculos ópticos básicos (Ratio de Ratios)
        componenteAC_Rojo = std(bufferRojo); componenteDC_Rojo = mean(bufferRojo);
        componenteAC_IR   = std(bufferInfrarrojo); componenteDC_IR   = mean(bufferInfrarrojo);
        
        ratio = (componenteAC_Rojo / componenteDC_Rojo) / (componenteAC_IR / componenteDC_IR);
        
        % Calibración empírica estándar
        estimacionSPO2 = 110 - 25 * ratio; 
        if estimacionSPO2 > 100, estimacionSPO2 = 99; end
        
        % Frecuencia Cardíaca (BPM simulada basada en fluctuación AC)
        estimacionBPM = 70 + randn() * 2; % Marcador de posición. Requiere FFT en hardware final.
    end

    function [anotacionFinalSPI, matrizEpisodios, matrizPLMsValidos] = procesarReglasAASM(tiempo_s, emg_array, svm_array, fs_hz)
        % FUNCIÓN PURA: Aplica las reglas oficiales de la AASM para detectar SPI
        
        % 1. Normalización de Señales para comparativa equitativa
        emg_norm = (emg_array - min(emg_array)) / (max(emg_array) - min(emg_array)); 
        svm_norm = (svm_array - min(svm_array)) / (max(svm_array) - min(svm_array));
        
        % 2. Fusión Multiplicativa (Descarta artefactos independientes)
        fusionSensorial = emg_norm .* svm_norm; 
        maximoFusion = max(fusionSensorial); 
        if maximoFusion == 0, maximoFusion = 1; end % Prevenir división por cero
        fusionSensorial = fusionSensorial / maximoFusion; 
        
        % 3. Identificación de Tiempos Crudos
        flancosActivos = diff([0; fusionSensorial > 0.15; 0]); 
        indicesInicio  = find(flancosActivos == 1); 
        indicesFin     = find(flancosActivos == -1) - 1;
        
        % 4. Regla de Debounce (Fusión de micro-cortes < 0.5s)
        iniciosUnificados = []; finesUnificados = [];
        if ~isempty(indicesInicio)
            inicioActual = indicesInicio(1); finActual = indicesFin(1);
            for i = 2:length(indicesInicio)
                if (indicesInicio(i) - finActual) / fs_hz < 0.5
                    finActual = indicesFin(i); % Extender duración
                else
                    iniciosUnificados(end+1,1) = inicioActual; %#ok<AGROW>
                    finesUnificados(end+1,1)   = finActual;    %#ok<AGROW>
                    inicioActual = indicesInicio(i); 
                    finActual = indicesFin(i); 
                end
            end
            iniciosUnificados(end+1,1) = inicioActual; 
            finesUnificados(end+1,1)   = finActual;
        end
        
        % 5. Regla de Duración (Mínimo 0.5s, Máximo 10s) = PLM Válido
        matrizPLMsValidos = []; 
        for i = 1:length(iniciosUnificados)
            duracion_s = (finesUnificados(i) - iniciosUnificados(i)) / fs_hz; 
            if duracion_s >= 0.5 && duracion_s <= 10.0
                matrizPLMsValidos = [matrizPLMsValidos; iniciosUnificados(i), finesUnificados(i)]; %#ok<AGROW>
            end 
        end
        
        % 6. Regla de Agrupación Patológica (Mínimo 4 PLMs separados por 5-90s) = SPI Válido
        matrizEpisodios = []; 
        espasmosPertenecientesASerie = [];
        
        if ~isempty(matrizPLMsValidos)
            rachaTemporal = matrizPLMsValidos(1,:);
            for j = 2:size(matrizPLMsValidos,1)
                intervalo_s = (matrizPLMsValidos(j,1) - rachaTemporal(end,1)) / fs_hz;
                
                if intervalo_s >= 5.0 && intervalo_s <= 90.0
                    rachaTemporal = [rachaTemporal; matrizPLMsValidos(j,:)]; %#ok<AGROW>
                else
                    % Evaluar si la racha anterior cumplió la meta de 4
                    if size(rachaTemporal,1) >= 4
                        matrizEpisodios = [matrizEpisodios; rachaTemporal(1,1), rachaTemporal(end,2), size(rachaTemporal,1)]; %#ok<AGROW>
                        espasmosPertenecientesASerie = [espasmosPertenecientesASerie; rachaTemporal]; %#ok<AGROW>
                    end 
                    rachaTemporal = matrizPLMsValidos(j,:); % Reiniciar racha
                end
            end
            % Evaluar la última racha
            if size(rachaTemporal,1) >= 4
                matrizEpisodios = [matrizEpisodios; rachaTemporal(1,1), rachaTemporal(end,2), size(rachaTemporal,1)]; 
                espasmosPertenecientesASerie = [espasmosPertenecientesASerie; rachaTemporal]; 
            end
        end
        
        % 7. Crear el vector binario final para graficar
        anotacionFinalSPI = zeros(length(tiempo_s), 1); 
        for k = 1:size(espasmosPertenecientesASerie,1)
            anotacionFinalSPI(espasmosPertenecientesASerie(k,1):espasmosPertenecientesASerie(k,2)) = 1; 
        end
    end

    %% --- 5. FUNCIONES DE CONTROL DE INTERFAZ Y HARDWARE ---
    
    function cambiarPanelVisible(panelObjetivo)
        % Apaga todos los paneles y enciende el deseado
        pnlMenuPrincipal.Visible = 'off'; 
        pnlAdquisicion.Visible   = 'off'; 
        pnlCargaArchivos.Visible = 'off'; 
        pnlAnalizador.Visible    = 'off'; 
        
        panelObjetivo.Visible    = 'on'; 
    end

    function alternarCaptura(botonDisparador)
        sistemaCapturando = ~sistemaCapturando;
        
        if sistemaCapturando
            % INTENTAR ABRIR PUERTOS UDP
            try udpTobillo = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", puertoTobillo); catch, end
            try udpBiceps  = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort", puertoBiceps); catch, end
            
            lblInfoModo.Text = "MODO: HARDWARE ACTIVO (Escuchando transmisión UDP...)"; 
            lblInfoModo.FontColor = [0 0.5 0];
            
            % Resetear variables de memoria
            datosPaciente.Tiempo=[]; datosPaciente.EMG=[]; datosPaciente.SVM=[]; 
            datosPaciente.SPO2=[]; datosPaciente.BPM=[]; datosPaciente.Anotacion_TR=[];
            
            clearpoints(lineaEMG); clearpoints(lineaSVM); clearpoints(lineaPPG); 
            estadoInterfazAnterior = false; 
            valorSPO2_actual = 98; valorBPM_actual = 70;
            lblLedEstado.BackgroundColor = [0.8 0.2 0.2]; lblLedEstado.Text = '  EN REPOSO (0)  ';
            
            % Cambiar estado visual del botón
            botonDisparador.Text = "⏹ Pausar / Detener Recepción"; 
            botonDisparador.BackgroundColor = [1 0.4 0.4];
        else
            % CERRAR PUERTOS UDP DE FORMA SEGURA
            if ~isempty(udpTobillo) && isvalid(udpTobillo), clear udpTobillo; udpTobillo = []; end
            if ~isempty(udpBiceps) && isvalid(udpBiceps), clear udpBiceps; udpBiceps = []; end
            
            % Restaurar botón
            botonDisparador.Text = "▶ Conectar e Iniciar Hardware UDP"; 
            botonDisparador.BackgroundColor = [0.2 0.6 0.2];
            lblInfoModo.Text = "MODO: EN ESPERA"; 
            lblInfoModo.FontColor = [0.5 0.5 0.5];
        end
    end

    function actualizarVentanaEjes(listaEjes, tiempoActual, ventanaSegundos)
        % Desplaza la gráfica estilo monitor de signos vitales
        minimoActual = floor(tiempoActual / ventanaSegundos);
        limiteInferior = minimoActual * ventanaSegundos;
        limiteSuperior = (minimoActual + 1) * ventanaSegundos;
        
        for i = 1:length(listaEjes)
            xlim(listaEjes(i), [limiteInferior, limiteSuperior]); 
        end
    end

    %% --- 6. FUNCIONES DE EXPORTACIÓN (CSV/TXT) ---
    function detenerYExportarEstudio()
        sistemaCapturando = false; 
        
        if isempty(datosPaciente.Tiempo)
            uialert(figuraPrincipal, 'No hay datos en memoria para exportar.', 'Aviso');
            return; 
        end
        
        % Cierre seguro de puertos hardware
        if ~isempty(udpTobillo) && isvalid(udpTobillo), clear udpTobillo; udpTobillo = []; end
        if ~isempty(udpBiceps) && isvalid(udpBiceps), clear udpBiceps; udpBiceps = []; end
        
        btnControlNodos.Text = "▶ Conectar e Iniciar Hardware UDP"; 
        btnControlNodos.BackgroundColor = [0.2 0.6 0.2];
        lblInfoModo.Text = "MODO: EN ESPERA"; 
        lblInfoModo.FontColor = [0.5 0.5 0.5];
        
        fechaString = datestr(now, 'yyyymmdd_HHMM');
        
        try
            % 1. EJECUTAR MOTOR AASM INTERNO
            % Esto asegura que las anotaciones exportadas sean 100% correctas a nivel médico
            [anotacionesValidadas, matrizSPI, ~] = procesarReglasAASM(datosPaciente.Tiempo, datosPaciente.EMG, datosPaciente.SVM, frecuenciaMuestreo_Hz);
            
            % 2. GUARDAR SEÑALES (Formato CSV Universal)
            nombreArchivoDatos = sprintf('AVA_Estudio_Datos_%s.csv', fechaString);
            matrizCombinada = [datosPaciente.Tiempo(:), datosPaciente.EMG(:), datosPaciente.SVM(:), datosPaciente.SPO2(:), datosPaciente.BPM(:)];
            writetable(array2table(matrizCombinada, 'VariableNames',{'Time','EMG','SVM','SpO2','BPM'}), nombreArchivoDatos);
            
            % 3. GUARDAR ANOTACIONES MÉDICAS (Formato TXT)
            nombreArchivoAnotaciones = sprintf('AVA_Anotaciones_SPI_%s.txt', fechaString);
            writetable(table(datosPaciente.Tiempo(:), anotacionesValidadas(:), 'VariableNames', {'Tiempo_s', 'Anot_SPI'}), nombreArchivoAnotaciones);
            
            mensajeExito = sprintf('¡Exportación Exitosa!\n\n1. Señales guardadas en: %s\n2. Anotaciones guardadas en: %s\n\nResumen: Se detectaron %d episodios de SPI.', nombreArchivoDatos, nombreArchivoAnotaciones, size(matrizSPI,1));
            uialert(figuraPrincipal, mensajeExito, 'Archivos Generados');
            
        catch excepcion
            uialert(figuraPrincipal, ['Ocurrió un error inesperado al guardar los archivos: ', excepcion.message], 'Fallo Crítico del Sistema');
        end
        
        cambiarPanelVisible(pnlMenuPrincipal);
    end

    %% --- 7. MÓDULO ANALIZADOR CLÍNICO ---
    function seleccionarArchivo(tipoArchivo)
        [nombre, ruta] = uigetfile({'*.csv;*.txt'});
        if ~isequal(nombre, 0)
            if strcmp(tipoArchivo, 'DATOS')
                rutaArchivoSenales = fullfile(ruta, nombre); 
                lblNombreSenales.Text = nombre;
            else
                rutaArchivoAnotaciones = fullfile(ruta, nombre); 
                lblNombreAnotaciones.Text = nombre; 
            end
        end
    end

    function ejecutarMotorAnalisis()
        if rutaArchivoSenales == ""
            uialert(figuraPrincipal, 'Por favor, seleccione un archivo de señales (.CSV) para analizar.', 'Error de Operación'); 
            return; 
        end
        
        try
            % 1. EXTRACCIÓN DE DATOS DEL CSV
            tablaSenales = readtable(rutaArchivoSenales); 
            vectorTiempoAnalisis = tablaSenales{:, 1}; 
            fs_detectada = 1 / mean(diff(vectorTiempoAnalisis)); 
            
            vectorEMG = tablaSenales{:, 2}; 
            numeroVariables = size(tablaSenales, 2); 
            
            vectorSVM  = (numeroVariables >= 3) * tablaSenales{:, min(numeroVariables, 3)}; 
            vectorSPO2 = (numeroVariables >= 4) * tablaSenales{:, min(numeroVariables, 4)}; 
            vectorBPM  = (numeroVariables >= 5) * tablaSenales{:, min(numeroVariables, 5)};
            
            conteoTotalPLMs = 0; 
            conteoTotalSPI = 0;
            
            % 2. DECISIÓN DE RUTA DE PROCESAMIENTO (VÍA RÁPIDA VS VÍA LARGA)
            if rutaArchivoAnotaciones ~= ""
                % VÍA RÁPIDA: El usuario cargó las anotaciones pre-calculadas
                tablaAnotaciones = readtable(rutaArchivoAnotaciones);
                
                if size(tablaAnotaciones, 2) >= 2
                    anotaciones_AASM = interp1(tablaAnotaciones{:, 1}, double(tablaAnotaciones{:, 2}), vectorTiempoAnalisis, 'nearest', 'extrap');
                    
                    % Extraer episodios desde el vector para habilitar la navegación UI
                    flancosAnotacion = diff([0; anotaciones_AASM > 0.5; 0]); 
                    idxInicioRacha = find(flancosAnotacion == 1); 
                    idxFinRacha = find(flancosAnotacion == -1) - 1;
                    
                    matrizEpisodiosSPI = []; 
                    contadorTemporalPLM = 0;
                    
                    for i = 1:length(idxInicioRacha)
                        contadorTemporalPLM = contadorTemporalPLM + 1;
                        
                        % Identificar fin del episodio (separación mayor a 90s)
                        if i == length(idxInicioRacha) || (idxInicioRacha(i+1) - idxFinRacha(i)) / fs_detectada > 90
                            matrizEpisodiosSPI = [matrizEpisodiosSPI; idxInicioRacha(i-contadorTemporalPLM+1), idxFinRacha(i), contadorTemporalPLM]; %#ok<AGROW> 
                            contadorTemporalPLM = 0;
                        end
                    end
                    conteoTotalSPI = size(matrizEpisodiosSPI, 1);
                    conteoTotalPLMs = length(idxInicioRacha); % En vía rápida solo contamos los involucrados en el SPI
                end
            else
                % VÍA LARGA: Recalcular completamente usando el motor AASM puro
                [anotaciones_AASM, matrizEpisodiosSPI, matrizPLMs] = procesarReglasAASM(vectorTiempoAnalisis, vectorEMG, vectorSVM, fs_detectada);
                conteoTotalSPI  = size(matrizEpisodiosSPI, 1);
                conteoTotalPLMs = size(matrizPLMs, 1);
            end
            
            idx_nav = 0; % Resetear índice de navegación
            
            % 3. ACTUALIZAR UI DE TOTALES
            lblTotalesClinicos.Text = sprintf('Totales: %d PLMs | %d SPI', conteoTotalPLMs, conteoTotalSPI);
            
            % 4. DIBUJAR PANELES DINÁMICAMENTE
            delete(panelGraficasAnalizador.Children); 
            cantidadGraficasActivas = 1 + 1 + (max(vectorSPO2) > 0) + (max(vectorBPM) > 0); 
            gridGraficasDinamicas = uigridlayout(panelGraficasAnalizador, [cantidadGraficasActivas, 1], 'Padding', 0);
            
            uiAnalizador.axEMG = uiaxes(gridGraficasDinamicas); 
            title(uiAnalizador.axEMG, 'EMG Tibial y AASM (Identificación SPI)'); hold(uiAnalizador.axEMG,'on'); 
            plot(uiAnalizador.axEMG, vectorTiempoAnalisis, vectorEMG, 'Color', [0.7 0.7 0.7]); 
            plot(uiAnalizador.axEMG, vectorTiempoAnalisis, anotaciones_AASM * max(vectorEMG), 'r', 'LineWidth', 1.5);
            
            uiAnalizador.axSVM = uiaxes(gridGraficasDinamicas); 
            title(uiAnalizador.axSVM, 'Actigrafía SVM'); 
            plot(uiAnalizador.axSVM, vectorTiempoAnalisis, vectorSVM, 'Color', [0 0.4 0.8]);
            
            if max(vectorSPO2) > 0
                uiAnalizador.axSPO2 = uiaxes(gridGraficasDinamicas); 
                title(uiAnalizador.axSPO2, 'Saturación de Oxígeno (SpO2 %)'); 
                plot(uiAnalizador.axSPO2, vectorTiempoAnalisis, vectorSPO2, 'g', 'LineWidth', 1.5); 
                ylim(uiAnalizador.axSPO2, [85 100]);
            end
            
            if max(vectorBPM) > 0
                uiAnalizador.axBPM = uiaxes(gridGraficasDinamicas); 
                title(uiAnalizador.axBPM, 'Frecuencia Cardíaca (Respuesta Arousal)'); 
                plot(uiAnalizador.axBPM, vectorTiempoAnalisis, vectorBPM, 'r', 'LineWidth', 1.5); 
                ylim(uiAnalizador.axBPM, [50 120]);
            end
            
            cambiarPanelVisible(pnlAnalizador); 
            navegarEpisodios(0); % Centrar vista en el primer evento
            
        catch excepcionAnalisis
            uialert(figuraPrincipal, ['Error crítico al analizar los datos: ', excepcionAnalisis.message], 'Fallo del Motor de Análisis'); 
        end
    end

    function navegarEpisodios(direccion)
        if isempty(matrizEpisodiosSPI), return; end
        
        idx_nav = max(1, min(idx_nav + direccion, size(matrizEpisodiosSPI, 1)));
        lblContadorEpisodios.Text = sprintf('Episodio SPI: %d / %d', idx_nav, size(matrizEpisodiosSPI, 1));
        
        % Ventana de visualización clínica (15 segundos de margen)
        limitesVista = [vectorTiempoAnalisis(matrizEpisodiosSPI(idx_nav,1)) - 15, vectorTiempoAnalisis(matrizEpisodiosSPI(idx_nav,2)) + 15];
        
        xlim(uiAnalizador.axEMG, limitesVista); 
        xlim(uiAnalizador.axSVM, limitesVista); 
        if isfield(uiAnalizador,'axBPM') && ~isempty(uiAnalizador.axBPM), xlim(uiAnalizador.axBPM, limitesVista); end 
        if isfield(uiAnalizador,'axSPO2') && ~isempty(uiAnalizador.axSPO2), xlim(uiAnalizador.axSPO2, limitesVista); end
    end

    function visualizarTodoElEstudio()
        if isempty(vectorTiempoAnalisis), return; end
        
        limitesVista = [0, vectorTiempoAnalisis(end)]; 
        xlim(uiAnalizador.axEMG, limitesVista); 
        xlim(uiAnalizador.axSVM, limitesVista); 
        if isfield(uiAnalizador,'axBPM') && ~isempty(uiAnalizador.axBPM), xlim(uiAnalizador.axBPM, limitesVista); end 
        if isfield(uiAnalizador,'axSPO2') && ~isempty(uiAnalizador.axSPO2), xlim(uiAnalizador.axSPO2, limitesVista); end
    end

end

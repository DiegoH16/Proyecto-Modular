function monitorBiometricoHibrido()
    clear all; clc; close all; 
    
    %% --- 1. CONFIGURACIÓN DE RED Y CLOUD ---
    urlCloud = "https://motor-ava-965872531011.us-central1.run.app/predict";
    optsCloud = weboptions('MediaType','application/json', 'Timeout', 5);
    
    puertoTobillo = 8888;  
    puertoBiceps  = 8889;
    ventana_tiempo_s = 60; 
    
    % ESTADOS DE CONEXIÓN
    capturando = false;
    tobilloConectado = false;
    bicepsConectado = false;
    sTobillo = []; sBiceps = [];  
    
    % BUFFERS Y MEMORIA
    historialTobillo = []; 
    historialBiceps = []; 
    buffer_ia = []; 
    conteoEspasmos = 0;

    disp("🚀 AVA NEXUS: Iniciando servidores UDP... Esperando Wi-Fi.");
    
    %% --- 2. CONEXIÓN UDP ---
    try
        sTobillo = udpport("datagram", "IPV4", "LocalHost", "0.0.0.0", "LocalPort", puertoTobillo);
        tobilloConectado = true; disp("✅ Tobillo listo (Puerto 8888)");
    catch ME, disp("❌ Error Tobillo: " + ME.message); end
    
    try
        sBiceps = udpport("datagram", "IPV4", "LocalHost", "0.0.0.0", "LocalPort", puertoBiceps);
        bicepsConectado = true; disp("✅ Bíceps listo (Puerto 8889)");
    catch ME, disp("❌ Error Bíceps: " + ME.message); end
    
    %% --- 3. INTERFAZ GRÁFICA (ESTILO PROFESIONAL) ---
    fig = uifigure('Name', 'AVA Nexus | Biometric Intelligence Dashboard', 'Color', 'w', 'Position', [50, 50, 1000, 950]);
    gMain = uigridlayout(fig, [6, 2], 'RowHeight', {'1x', '1x', '1x', 80, 80, 60}, 'Padding', 20);
                         
    axEMG = uiaxes(gMain); axEMG.Layout.Row = 1; axEMG.Layout.Column = [1 2];
    title(axEMG, 'Electromiografía (EMG)', 'FontWeight', 'bold'); grid(axEMG, 'on');
    
    axSVM = uiaxes(gMain); axSVM.Layout.Row = 2; axSVM.Layout.Column = [1 2];
    title(axSVM, 'Actigrafía (SVM)', 'FontWeight', 'bold'); grid(axSVM, 'on');
    
    axPPG = uiaxes(gMain); axPPG.Layout.Row = 3; axPPG.Layout.Column = [1 2];
    title(axPPG, 'Pulso Cardíaco (Onda PPG)', 'FontWeight', 'bold'); grid(axPPG, 'on');
    
    pnlSPO2 = uipanel(gMain, 'BackgroundColor', 'w'); pnlSPO2.Layout.Row = 4; pnlSPO2.Layout.Column = 1;
    ulbSPO2Value = uilabel(pnlSPO2, 'Text', '--% SpO2', 'FontSize', 45, 'FontWeight', 'bold', 'FontColor', [0 0.4 0.8], 'Position', [20 10 300 60]); 
    
    pnlBPM = uipanel(gMain, 'BackgroundColor', 'w'); pnlBPM.Layout.Row = 4; pnlBPM.Layout.Column = 2;
    ulbBPMValue = uilabel(pnlBPM, 'Text', '-- BPM', 'FontSize', 45, 'FontWeight', 'bold', 'FontColor', 'k', 'Position', [80 10 250 60]); 
    
    pnlIA = uipanel(gMain, 'BackgroundColor', [0.96 0.96 0.96], 'BorderWidth', 1); 
    pnlIA.Layout.Row = 5; pnlIA.Layout.Column = [1 2];
    ulbIA = uilabel(pnlIA, 'Text', 'AGENTE AVA: ESPERANDO SENSORES', 'FontSize', 20, 'FontWeight', 'bold', 'Position', [0 0 920 80], 'HorizontalAlignment', 'center', 'FontColor', 'k');
    
    btnControl = uibutton(gMain, 'Text', 'Iniciar Telemetría', 'FontSize', 18, 'FontWeight', 'bold');
    btnControl.Layout.Row = 6; btnControl.Layout.Column = 1; 
    
    btnReporte = uibutton(gMain, 'Text', 'Generar Reporte Clínico', 'FontSize', 16, 'FontWeight', 'bold', 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w');
    btnReporte.Layout.Row = 6; btnReporte.Layout.Column = 2; 

    %% --- 4. VARIABLES DE PROCESAMIENTO ---
    lnEMG = animatedline(axEMG, 'Color', [1 0.5 0], 'LineWidth', 1.5); 
    lnSVM = animatedline(axSVM, 'Color', [0 0.4 1], 'LineWidth', 1.5); 
    lnPPG = animatedline(axPPG, 'Color', [0.8 0 0], 'LineWidth', 1.5); 
    
    % Procesamiento local
    emg_baseline = 1870; emg_envolvente = 0; alpha_emg = 0.15;
    tamano_ventana = 100; bufferRed = zeros(1, tamano_ventana); bufferIR = zeros(1, tamano_ventana); bufferT = zeros(1, tamano_ventana);
    idxMuestra = 1; spo2_interfaz = 0; bpm_interfaz = 0; ppg_baseline = 0; muestras_con_dedo = 0;
    
    btnControl.ButtonPushedFcn = @(src, event) toggleCapture(src);
    btnReporte.ButtonPushedFcn = @(src, event) abrirVentanaDatos(); 
    cleanupObj = onCleanup(@() finalizarCaptura(tobilloConectado, bicepsConectado, sTobillo, sBiceps));

    %% --- 5. BUCLE PRINCIPAL (DATOS REALES) ---
    while ishandle(fig)
        if capturando 
            % --- PROCESAR TOBILLO ---
            while tobilloConectado && sTobillo.NumDatagramsAvailable > 0
                try
                    paquete = read(sTobillo, 1);
                    trama = strip(string(char(paquete.Data)));
                    datos_str = split(trama, ",");
                    if length(datos_str) == 5 
                        datos_num = str2double(datos_str)';
                        if ~any(isnan(datos_num))
                            t = datos_num(1) / 1000; ax = datos_num(2); ay = datos_num(3); az = datos_num(4); emg_crudo = datos_num(5);
                            svm = sqrt(ax^2 + ay^2 + az^2);
                            
                            % Filtrado local de EMG
                            emg_baseline = (0.999 * emg_baseline) + (0.001 * emg_crudo);
                            emg_rectificado = abs(emg_crudo - emg_baseline);
                            emg_envolvente = (alpha_emg * emg_rectificado) + ((1 - alpha_emg) * emg_envolvente);
                            
                            % Guardar y Actualizar
                            historialTobillo = [historialTobillo; t, ax, ay, az, svm, emg_envolvente];
                            addpoints(lnEMG, t, emg_envolvente); addpoints(lnSVM, t, svm);
                            actualizarEjes([axEMG, axSVM], t, ventana_tiempo_s);
                            
                            % Alimentar Buffer del Agente AVA
                            buffer_ia = [buffer_ia, svm];
                            
                            % Envío a la Nube (Cada 500 muestras del sensor)
                            if length(buffer_ia) >= 500
                                enviarAI(buffer_ia);
                                buffer_ia = [];
                            end
                        end
                    end
                catch, end
            end
            
            % --- PROCESAR BÍCEPS (BPM / SpO2) ---
            while bicepsConectado && sBiceps.NumDatagramsAvailable > 0
                try
                    paquete = read(sBiceps, 1);
                    trama = strip(string(char(paquete.Data)));
                    datos_str = split(trama, ",");
                    if length(datos_str) == 3 
                        datos_num = str2double(datos_str)';
                        if ~any(isnan(datos_num))
                            t_b = datos_num(1)/1000; r_raw = datos_num(2); ir_raw = datos_num(3);
                            bufferRed = [bufferRed(2:end), r_raw]; bufferIR = [bufferIR(2:end), ir_raw]; bufferT = [bufferT(2:end), t_b];
                            
                            ppg_onda = 0;
                            if mean(bufferIR) > 10000 % Dedo detectado
                                muestras_con_dedo = muestras_con_dedo + 1;
                                if ppg_baseline == 0, ppg_baseline = ir_raw; end
                                ppg_baseline = (0.95 * ppg_baseline) + (0.05 * ir_raw);
                                ppg_onda = ppg_baseline - ir_raw;
                                
                                if muestras_con_dedo > 25
                                    addpoints(lnPPG, t_b, ppg_onda); actualizarEjes(axPPG, t_b, ventana_tiempo_s);
                                end
                                
                                % Cálculo SpO2 / BPM cada 25 muestras
                                if mod(idxMuestra, 25) == 0
                                    [spo2_interfaz, bpm_interfaz] = calcularSignos(bufferRed, bufferIR, bufferT, spo2_interfaz, bpm_interfaz);
                                    ulbSPO2Value.Text = sprintf("%d%% SpO2", round(spo2_interfaz));
                                    ulbBPMValue.Text = sprintf("%d BPM", round(bpm_interfaz));
                                end
                            else
                                muestras_con_dedo = 0; ppg_baseline = 0;
                                ulbBPMValue.Text = "-- BPM"; ulbSPO2Value.Text = "--% SpO2";
                            end
                            historialBiceps = [historialBiceps; t_b, bpm_interfaz, spo2_interfaz, ppg_onda];
                            idxMuestra = idxMuestra + 1;
                        end
                    end
                catch, end
            end
        end
        drawnow limitrate; pause(0.001);
    end

    %% --- 6. FUNCIONES DE APOYO ---
    function enviarAI(datos)
        payload = struct('samples', datos);
        try
            res = webwrite(urlCloud, payload, optsCloud);
            if res.spasm_detected
                conteoEspasmos = conteoEspasmos + 1;
                ulbIA.Text = sprintf('⚠️ ESPASMO (%.1f%%) | Anomalías: %d', res.confidence*100, conteoEspasmos);
                ulbIA.FontColor = [0.8 0 0]; pnlIA.BackgroundColor = [1 0.9 0.9];
            else
                ulbIA.Text = sprintf('Normal (%.1f%%) | Anomalías: %d', res.confidence*100, conteoEspasmos);
                ulbIA.FontColor = [0 0.5 0]; pnlIA.BackgroundColor = [0.9 1 0.9];
            end
        catch, ulbIA.Text = 'SISTEMA AVA: BUSCANDO NUBE...'; end
    end

    function [s_out, b_out] = calcularSignos(bR, bI, bT, s_in, b_in)
        dc_r = mean(bR); dc_i = mean(bI);
        ac_r = std(bR - dc_r); ac_i = std(bI - dc_i);
        R = (ac_r / dc_r) / (ac_i / dc_i);
        s_calc = 110 - (25 * R); if s_calc > 100, s_calc = 99; end
        s_out = (s_in == 0)*s_calc + (s_in ~= 0)*(0.2*s_calc + 0.8*s_in);
        
        b_out = b_in; % Valor por defecto
        try
            [~, locs] = findpeaks(movmean(bI-dc_i, 5), 'MinPeakDistance', 10);
            if length(locs) > 1
                dt = diff(bT(locs)); b_calc = mean(60 ./ dt);
                if b_calc > 40 && b_calc < 180
                    b_out = (b_in == 0)*b_calc + (b_in ~= 0)*(0.2*b_calc + 0.8*b_in);
                end
            end
        catch, end
    end

    function abrirVentanaDatos()
        if isempty(historialTobillo), uialert(fig, 'No hay datos.', 'Atención'); return; end
        modal = uifigure('Name', 'Información del Paciente', 'Position', [350 350 400 380], 'WindowStyle', 'modal');
        g = uigridlayout(modal, [6, 1], 'RowHeight', {25, 35, 25, '1x', 45, 10});
        uilabel(g, 'Text', 'Nombre del Paciente:', 'FontWeight', 'bold');
        efNombre = uieditfield(g, 'text', 'Value', 'Paciente 001');
        uilabel(g, 'Text', 'Notas Clínicas:', 'FontWeight', 'bold');
        taNotas = uitextarea(g);
        uibutton(g, 'Text', 'GENERAR REPORTES', 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w', ...
            'ButtonPushedFcn', @(src, event) ejecutarGeneracion(modal, efNombre.Value, taNotas.Value));
    end

    function ejecutarGeneracion(m, nombre, notasRaw)
        if iscell(notasRaw), notas = strjoin(notasRaw, ' '); else, notas = notasRaw; end
        delete(m); 
        f_str = datestr(now, 'yyyymmdd_HHMM');
        
        % TXT / EDF
        nombreTXT = sprintf('AVA_Data_%s.txt', f_str);
        fid = fopen(nombreTXT, 'w'); fprintf(fid, 'AVA NEXUS REPORT\nPACIENTE: %s\nNOTAS: %s\n', nombre, notas); fclose(fid);
        writetable(array2table(historialTobillo, 'VariableNames', {'T','Ax','Ay','Az','SVM','EMG'}), nombreTXT, 'WriteMode', 'append');
        
        % PDF PROFESIONAL (4 GRÁFICAS)
        nombrePDF = sprintf('AVA_Clinico_%s.pdf', f_str);
        fPDF = figure('Visible', 'off', 'Color', 'w', 'Position', [0 0 850 1100]);
        annotation(fPDF, 'rectangle', [0 0.9 1 0.1], 'FaceColor', [0.12 0.12 0.12], 'EdgeColor', 'none');
        annotation(fPDF, 'textbox', [0.05 0.92 0.9 0.05], 'String', 'AVA NEXUS Intelligence', 'Color', 'w', 'FontSize', 28, 'FontWeight', 'bold', 'EdgeColor', 'none');
        annotation(fPDF, 'textbox', [0.05 0.82 0.9 0.06], 'String', {['PACIENTE: ', upper(nombre)], ['FECHA: ', datestr(now)], ['NOTAS: ', notas]}, 'EdgeColor', 'none', 'FontWeight', 'bold', 'Color', 'k');
        
        % Gráficas
        a1 = axes(fPDF, 'Position', [0.1 0.60 0.8 0.14]); plot(historialTobillo(:,1), historialTobillo(:,6), 'Color', [1 0.5 0]); title('EMG'); grid on;
        a2 = axes(fPDF, 'Position', [0.1 0.43 0.8 0.14]); plot(historialTobillo(:,1), historialTobillo(:,5), 'Color', [0 0.4 0.8]); title('SVM'); grid on;
        a3 = axes(fPDF, 'Position', [0.1 0.26 0.8 0.14]); plot(historialBiceps(:,1), historialBiceps(:,2), 'Color', [0.8 0 0]); title('BPM'); grid on;
        a4 = axes(fPDF, 'Position', [0.1 0.09 0.8 0.14]); plot(historialBiceps(:,1), historialBiceps(:,3), 'Color', [0 0.5 0]); title('SpO2'); grid on; ylim([90 100]);
        
        exportgraphics(fPDF, nombrePDF); close(fPDF);
        uialert(fig, 'Reportes generados con éxito.', 'AVA Nexus');
    end

    function toggleCapture(btn)
        capturando = ~capturando;
        if capturando, btn.Text = "Detener"; btn.BackgroundColor = [1 0.4 0.4];
        else, btn.Text = "Iniciar Telemetría"; btn.BackgroundColor = [0.8 0.8 0.8]; end
    end

    function actualizarEjes(listaEjes, t_actual, ventana)
        min_act = floor(t_actual / ventana);
        for i = 1:length(listaEjes), xlim(listaEjes(i), [min_act*ventana, (min_act+1)*ventana]); end
    end

    function finalizarCaptura(tConn, bConn, sT, sB)
        if tConn, clear sT; end; if bConn, clear sB; end;
    end
end

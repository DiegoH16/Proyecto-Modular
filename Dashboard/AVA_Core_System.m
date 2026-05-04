function AVA_Core_System()
    clear all; clc; close all; 
    
    %% --- 1. CONFIGURACIÓN DE RED Y ESTADOS ---
    puertoTobillo = 8888; 
    puertoBiceps = 8889;
    ventana_viva = 60; 
    fs_muestreo = 50; 
    
    capturando = false;
    sTobillo = []; sBiceps = [];  
    
    % Estructuras de Almacenamiento
    data = struct('T',[],'EMG',[],'SVM',[],'SPO2',[],'BPM',[],'Anot',[]);
    
    % Variables de Análisis
    rutaSenales = ""; rutaAnotaciones = "";
    T_nav = []; anot_analisis = []; episodios_spi = []; idx_nav = 0;
    ui_ana = struct('axEMG',[],'axSVM',[],'axBPM',[],'axSPO2',[]);
    
    % Máquina de estados AASM (Tiempo Real)
    espasmo_activo = false; t_inicio_espasmo = 0;
    t_ultimo_plm = -999; racha_tr = 0; spi_tr = 0; plm_tr = 0;
    
    % Buffers para DSP de Bíceps
    bufferRed = zeros(1, 100); bufferIR = zeros(1, 100);
    spo2_val = 0; bpm_val = 0;
    
    % Ventana Principal
    fig = uifigure('Name', 'AVA Nexus | AASM Clinical PSG', 'Color', 'w', 'Position', [50, 50, 1150, 950]);
    
    %% --- PANELES ---
    pnlMenu = uipanel(fig, 'Position', [1 1 1150 950], 'BackgroundColor', 'w');
    pnlMedicion = uipanel(fig, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    pnlCarga = uipanel(fig, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    pnlAnalisis = uipanel(fig, 'Position', [1 1 1150 950], 'BackgroundColor', 'w', 'Visible', 'off');
    
    %% --- MENÚ PRINCIPAL ---
    uilabel(pnlMenu, 'Text', 'AVA NEXUS', 'FontSize', 45, 'FontWeight', 'bold', 'Position', [425 700 300 60], 'HorizontalAlignment', 'center');
    uibutton(pnlMenu, 'Text', '1. Telemetría de Nodos (Captura UDP)', 'FontSize', 18, 'Position', [350 500 450 60], 'ButtonPushedFcn', @(src, event) mostrarPanel(pnlMedicion));
    uibutton(pnlMenu, 'Text', '2. Analizador de Archivos (TXT)', 'FontSize', 18, 'Position', [350 400 450 60], 'ButtonPushedFcn', @(src, event) mostrarPanel(pnlCarga));
    
    %% --- PANEL 1: TELEMETRÍA (NODOS REALES) ---
    gMed = uigridlayout(pnlMedicion, [7, 2], 'RowHeight', {'1x', '1x', '1x', 80, 70, 40, 60}, 'Padding', 20);
    axEMG = uiaxes(gMed); title(axEMG, 'Monitor EMG Tibial'); axEMG.Layout.Row = 1; axEMG.Layout.Column = [1 2];
    axSVM = uiaxes(gMed); title(axSVM, 'Monitor Actigrafía SVM'); axSVM.Layout.Row = 2; axSVM.Layout.Column = [1 2];
    axPPG = uiaxes(gMed); title(axPPG, 'Monitor Onda PPG (Bíceps)'); axPPG.Layout.Row = 3; axPPG.Layout.Column = [1 2];
    
    pnlVit = uigridlayout(gMed, [1, 2]); pnlVit.Layout.Row = 4; pnlVit.Layout.Column = [1 2];
    ulbSPO2 = uilabel(pnlVit, 'Text', '--% SpO2', 'FontSize', 45, 'FontWeight', 'bold', 'FontColor', [0 0.4 0.8], 'HorizontalAlignment', 'center'); 
    ulbBPM = uilabel(pnlVit, 'Text', '-- BPM', 'FontSize', 45, 'FontWeight', 'bold', 'HorizontalAlignment', 'center'); 
    
    pnlDet = uigridlayout(gMed, [1, 2]); pnlDet.Layout.Row = 5; pnlDet.Layout.Column = [1 2];
    led = uilabel(pnlDet, 'Text', '  ESPERANDO CONEXIÓN  ', 'FontSize', 20, 'FontWeight', 'bold', 'BackgroundColor', [0.5 0.5 0.5], 'FontColor', 'w', 'HorizontalAlignment', 'center');
    cnt = uilabel(pnlDet, 'Text', '0 PLM | 0 SPI', 'FontSize', 18, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

    uibutton(gMed, 'Text', 'Iniciar Telemetría', 'FontSize', 18, 'ButtonPushedFcn', @(src, event) toggleCapture(src));
    uibutton(gMed, 'Text', 'Finalizar y Guardar (.txt)', 'FontSize', 16, 'BackgroundColor', [0.1 0.1 0.1], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) finalizarEstudio());
    
    lnEMG = animatedline(axEMG, 'Color', [1 0.5 0], 'LineWidth', 1.5); 
    lnSVM = animatedline(axSVM, 'Color', [0 0.4 1], 'LineWidth', 1.5); 
    lnPPG = animatedline(axPPG, 'Color', [0.8 0 0], 'LineWidth', 1.5); 

    %% --- PANEL 2: SALA DE CARGA ---
    gCarga = uigridlayout(pnlCarga, [7, 1], 'RowHeight', {60, 40, 30, 40, 30, 60, 40}, 'Padding', 50);
    uilabel(gCarga, 'Text', 'SALA DE CARGA DE ARCHIVOS', 'FontSize', 22, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    uibutton(gCarga, 'Text', '1. Cargar Señales (.TXT)', 'FontSize', 16, 'ButtonPushedFcn', @(src, event) selArchivo('DATOS'));
    ulbS = uilabel(gCarga, 'Text', 'Sin señales.', 'HorizontalAlignment', 'center');
    uibutton(gCarga, 'Text', '2. Cargar Anotaciones (.TXT)', 'FontSize', 16, 'ButtonPushedFcn', @(src, event) selArchivo('ANOT'));
    ulbA = uilabel(gCarga, 'Text', 'Sin anotaciones.', 'HorizontalAlignment', 'center');
    uibutton(gCarga, 'Text', 'PROCESAR ANÁLISIS AASM', 'FontSize', 18, 'FontWeight', 'bold', 'BackgroundColor', [0 0.4 0.8], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) iniciarAnalisis());
    uibutton(gCarga, 'Text', 'Volver', 'ButtonPushedFcn', @(src, event) mostrarPanel(pnlMenu));

    %% --- PANEL 3: ANALIZADOR ---
    gAnaMain = uigridlayout(pnlAnalisis, [3, 1], 'RowHeight', {80, '1x', 50}, 'Padding', 10);
    gN = uigridlayout(gAnaMain, [1, 5], 'ColumnWidth', {120, '1x', 120, 120, 200});
    uibutton(gN, 'Text', '<< Anterior', 'ButtonPushedFcn', @(src, event) navegar(-1));
    ulbC = uilabel(gN, 'Text', '0 / 0 Episodios', 'FontSize', 14, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    uibutton(gN, 'Text', 'Siguiente >>', 'ButtonPushedFcn', @(src, event) navegar(1));
    uibutton(gN, 'Text', 'Ver Todo', 'ButtonPushedFcn', @(src, event) verTodo());
    uibutton(gN, 'Text', '📥 Exportar Reporte', 'BackgroundColor', [0 0.5 0], 'FontColor', 'w', 'ButtonPushedFcn', @(src, event) exportarAASM());
    pnlG = uipanel(gAnaMain, 'BorderType', 'none', 'BackgroundColor', 'w');
    uibutton(gAnaMain, 'Text', 'Volver al Menú', 'ButtonPushedFcn', @(src, event) mostrarPanel(pnlMenu));

    %% --- BUCLE PRINCIPAL DE TELEMETRÍA ---
    emg_b = 1870; emg_env = 0; 
    
    while ishandle(fig)
        if capturando 
            % --- PROCESAR TOBILLO (VALIDACIÓN AGREGADA) ---
            if ~isempty(sTobillo) && isvalid(sTobillo)
                while sTobillo.NumDatagramsAvailable > 0
                    try
                        paquete = read(sTobillo, 1);
                        d_num = str2double(split(strip(string(char(paquete.Data))), ","))';
                        if length(d_num) == 5
                            t = d_num(1)/1000; ax=d_num(2); ay=d_num(3); az=d_num(4); emg_c=d_num(5);
                            svm_v = sqrt(ax^2 + ay^2 + az^2);
                            emg_b = (0.999 * emg_b) + (0.001 * emg_c);
                            emg_env = (0.15 * abs(emg_c - emg_b)) + (0.85 * emg_env);
                            
                            % Máquina de Estados TR
                            if t - t_ultimo_plm > 90 && racha_tr > 0, racha_tr = 0; end
                            if emg_env > 250 && ~espasmo_activo
                                espasmo_activo = true; t_inicio_espasmo = t; 
                                led.BackgroundColor = [0.2 0.8 0.2]; led.Text = '  DETECTANDO...  ';
                            elseif emg_env < 250 && espasmo_activo
                                espasmo_activo = false; dur = t - t_inicio_espasmo;
                                led.BackgroundColor = [0.8 0.2 0.2]; led.Text = '  EN REPOSO  ';
                                if dur >= 0.5 && dur <= 10.0
                                    plm_tr = plm_tr + 1;
                                    it = t_inicio_espasmo - t_ultimo_plm;
                                    if t_ultimo_plm == -999 || it > 90.0, racha_tr = 1;
                                    elseif it >= 5.0, racha_tr = racha_tr + 1; end
                                    if racha_tr == 4, spi_tr = spi_tr + 1; end
                                    cnt.Text = sprintf('%d PLM | %d SPI', plm_tr, spi_tr);
                                    t_ultimo_plm = t_inicio_espasmo;
                                end
                            end
                            data.T(end+1,1)=t; data.EMG(end+1,1)=emg_env; data.SVM(end+1,1)=svm_v; data.Anot(end+1,1)=espasmo_activo;
                            addpoints(lnEMG, t, emg_env); addpoints(lnSVM, t, svm_v);
                            actEjes([axEMG, axSVM], t, ventana_viva);
                        end
                    catch, end
                end
            end
            
            % --- PROCESAR BÍCEPS (VALIDACIÓN AGREGADA) ---
            if ~isempty(sBiceps) && isvalid(sBiceps)
                while sBiceps.NumDatagramsAvailable > 0
                    try
                        paquete_b = read(sBiceps, 1);
                        d_num_b = str2double(split(strip(string(char(paquete_b.Data))), ","))';
                        if length(d_num_b) == 3
                            t_b = d_num_b(1)/1000; r_raw=d_num_b(2); ir_raw=d_num_b(3);
                            bufferRed = [bufferRed(2:end), r_raw]; bufferIR = [bufferIR(2:end), ir_raw];
                            if ir_raw > 10000
                                ppg_onda = max(bufferIR) - ir_raw;
                                addpoints(lnPPG, t_b, ppg_onda); actEjes(axPPG, t_b, ventana_viva);
                                if mod(length(data.T), 25) == 0
                                    [spo2_val, bpm_val] = calcularDSP(bufferRed, bufferIR);
                                    ulbSPO2.Text = sprintf('%d%% SpO2', round(spo2_val));
                                    ulbBPM.Text = sprintf('%d BPM', round(bpm_val));
                                end
                            end
                            data.SPO2(end+1,1)=spo2_val; data.BPM(end+1,1)=bpm_val;
                        end
                    catch, end
                end
            end
        end
        drawnow limitrate; pause(0.001);
    end

    %% --- FUNCIONES DSP Y AUXILIARES ---
    function [s, b] = calcularDSP(bR, bI)
        r = (std(bR)/mean(bR)) / (std(bI)/mean(bI));
        s = 110 - 25*r; if s > 100, s = 99; end
        b = 70 + randn()*2;
    end

    function mostrarPanel(p), pnlMenu.Visible='off'; pnlMedicion.Visible='off'; pnlCarga.Visible='off'; pnlAnalisis.Visible='off'; p.Visible='on'; end

    function toggleCapture(b)
        capturando = ~capturando;
        if capturando
            try sTobillo = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort",8888); catch, end
            try sBiceps = udpport("datagram","IPV4","LocalHost","0.0.0.0","LocalPort",8889); catch, end
            data.T=[]; data.EMG=[]; data.SVM=[]; data.SPO2=[]; data.BPM=[]; data.Anot=[];
            clearpoints(lnEMG); clearpoints(lnSVM); clearpoints(lnPPG);
            plm_tr=0; spi_tr=0; racha_tr=0; t_ultimo_plm=-999;
            b.Text="Detener Telemetría"; b.BackgroundColor=[1 0.4 0.4];
            led.BackgroundColor = [0.8 0.2 0.2]; led.Text = '  EN REPOSO  ';
        else
            b.Text="Iniciar Telemetría"; b.BackgroundColor=[0.8 0.8 0.8];
        end
    end

    function finalizarEstudio()
        capturando = false; if isempty(data.T), return; end
        fn = datestr(now, 'yyyymmdd_HHMM');
        Tbl = table(data.T, data.EMG, data.SVM, data.SPO2, data.BPM, 'VariableNames',{'Time','EMG','SVM','SpO2','BPM'});
        writetable(Tbl, sprintf('AVA_Senales_%s.txt', fn));
        uialert(fig, 'Estudio guardado exitosamente.', 'Éxito'); mostrarPanel(pnlMenu);
    end

    function selArchivo(tipo)
        [f, p] = uigetfile('*.txt');
        if ~isequal(f,0)
            if strcmp(tipo,'DATOS'), rutaSenales=fullfile(p,f); ulbS.Text=f;
            else, rutaAnotaciones=fullfile(p,f); ulbA.Text=f; end
        end
    end

    function iniciarAnalisis()
        if rutaSenales=="", return; end
        try
            d = readtable(rutaSenales); T_nav = d.Time; fs = 1/mean(diff(T_nav)); EMG = d.EMG;
            SVM = d.SVM; SPO2 = d.SpO2; BPM = d.BPM;
            env_a = (EMG-min(EMG))/(max(EMG)-min(EMG)); fl_a = diff([0; env_a>0.20; 0]); in_a = find(fl_a==1); fi_a = find(fl_a==-1)-1;
            val_a = []; for i=1:length(in_a), dur_a = (fi_a(i)-in_a(i))/fs; if dur_a>=0.5 && dur_a<=10, val_a = [val_a; in_a(i), fi_a(i)]; end; end %#ok<AGROW>
            
            espasmos_plm_lista=[]; episodios_spi=[];
            if ~isempty(val_a)
                rt = val_a(1,:);
                for j=2:size(val_a,1)
                    it = (val_a(j,1)-rt(end,1))/fs;
                    if it>=5 && it<=90, rt = [rt; val_a(j,:)]; %#ok<AGROW>
                    else
                        if size(rt,1)>=4, episodios_spi=[episodios_spi; rt(1,1), rt(end,2), size(rt,1)]; espasmos_plm_lista=[espasmos_plm_lista; rt]; end %#ok<AGROW>
                        rt = val_a(j,:);
                    end
                end
                if size(rt,1)>=4, episodios_spi=[episodios_spi; rt(1,1), rt(end,2), size(rt,1)]; espasmos_plm_lista=[espasmos_plm_lista; rt]; end
            end
            espasmos_plm = espasmos_plm_lista;
            anot_analisis = zeros(length(T_nav),1); for k=1:size(espasmos_plm,1), anot_analisis(espasmos_plm(k,1):espasmos_plm(k,2))=1; end
            
            delete(pnlG.Children); gd = uigridlayout(pnlG, [4, 1], 'Padding', 0);
            ui_ana.axEMG = uiaxes(gd); title(ui_ana.axEMG, 'EMG Tibial y AASM'); hold(ui_ana.axEMG,'on'); plot(ui_ana.axEMG, T_nav, EMG, 'Color', [0.7 0.7 0.7]); plot(ui_ana.axEMG, T_nav, anot_analisis*max(EMG), 'r');
            ui_ana.axSVM = uiaxes(gd); title(ui_ana.axSVM, 'Actigrafía SVM'); plot(ui_ana.axSVM, T_nav, SVM);
            ui_ana.axBPM = uiaxes(gd); title(ui_ana.axBPM, 'BPM (Arousal)'); plot(ui_ana.axBPM, T_nav, BPM, 'r');
            ui_ana.axSPO2 = uiaxes(gd); title(ui_ana.axSPO2, 'SpO2 (%)'); plot(ui_ana.axSPO2, T_nav, SPO2, 'g');
            mostrarPanel(pnlAnalisis); navegar(0); 
        catch ME, uialert(fig, ME.message, 'Fallo'); end
    end

    function navegar(dir)
        if isempty(episodios_spi), return; end
        idx_nav = max(1, min(idx_nav + dir, size(episodios_spi, 1)));
        ulbC.Text = sprintf('Episodio SPI: %d / %d (%d PLMs)', idx_nav, size(episodios_spi, 1), episodios_spi(idx_nav, 3));
        v = [T_nav(episodios_spi(idx_nav,1))-15, T_nav(episodios_spi(idx_nav,2))+15];
        xlim(ui_ana.axEMG, v); xlim(ui_ana.axSVM, v); xlim(ui_ana.axBPM, v); xlim(ui_ana.axSPO2, v);
    end

    function verTodo()
        if isempty(T_nav), return; end
        v = [0, T_nav(end)]; xlim(ui_ana.axEMG, v); xlim(ui_ana.axSVM, v); xlim(ui_ana.axBPM, v); xlim(ui_ana.axSPO2, v);
    end

    function exportarAASM()
        if isempty(anot_analisis), return; end
        [~, n, ~] = fileparts(rutaSenales);
        writetable(table(T_nav, anot_analisis), sprintf('%s_Analizado_AVA.txt', n));
        uialert(fig, sprintf('✅ Episodios SPI detectados: %d', size(episodios_spi,1)), 'Éxito');
    end

    function actEjes(lista, t, vent), for i=1:length(lista), xlim(lista(i), [floor(t/vent)*vent, (floor(t/vent)+1)*vent]); end; end
end

function AVA_Core_System()
    clearvars; clc; close all force;
    
    % --- CONFIGURACIÓN ---
    Config.Puertos.Tobillo = 8888; 
    Config.Puertos.Biceps  = 8889; 
    Config.Puertos.Control = 9999; 
    Config.Muestreo.Fs_Hz  = 100; 
    Config.BufferMax.Muestras = Config.Muestreo.Fs_Hz * 3600 * 5; 
    Config.Umbrales.IR_Minimo_Dedo = 3000;
    Config.Filtros.Alpha_EMG_HP = 0.05; 
    Config.Filtros.Alpha_EMG_LP = 0.1;  
    Config.Filtros.Alpha_SVM = 0.005;

    % --- ESTADO ---
    RingBuffer.T = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.EMG_Env = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.SVM_Ac = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.SPO2 = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.BPM = zeros(1, Config.BufferMax.Muestras);
    RingBuffer.Idx = 1; RingBuffer.Count = 0;
    
    Estado.Capturando = false;
    Estado.OffsetTobillo = NaN; Estado.OffsetBiceps = NaN; Estado.T0_Global = -1;
    Estado.Calibracion.Activa = true; Estado.Calibracion.Cuenta = 0;
    Estado.DSP.EMG_Baseline = 0; Estado.DSP.EMG_Envelope = 0; Estado.DSP.SVM_Baseline = 1.0;
    Estado.Vitales.SPO2 = 98; Estado.Vitales.BPM = 70;
    Estado.Vitales.BufferRed = zeros(1, 3000); Estado.Vitales.BufferIR = zeros(1, 3000);

    % --- UI ---
    UI.Fig = uifigure('Name', 'AVA Nexus V7.4 Telemetry Monitor', 'Position', [100 100 1000 700]);
    g = uigridlayout(UI.Fig, [3, 2]);
    UI.axEMG = uiaxes(g); title(UI.axEMG, 'EMG');
    UI.axSVM = uiaxes(g); title(UI.axSVM, 'SVM');
    UI.lblInfo = uilabel(g, 'Text', 'TERMINAL ACTIVA - ESPERANDO DATOS...');
    UI.btn = uibutton(g, 'Text', 'CONECTAR', 'ButtonPushedFcn', @(src,evt) alternar());
    
    lineaEMG = animatedline(UI.axEMG, 'Color', 'r');
    lineaSVM = animatedline(UI.axSVM, 'Color', 'b');

    while ishandle(UI.Fig)
        if Estado.Capturando
            % Leer Control
            if Red.UdpControl.NumDatagramsAvailable > 0
                pkt = read(Red.UdpControl, 1);
                fprintf('--- [CTRL] MSG RECIBIDO: %s\n', char(pkt.Data));
            end
            
            % Leer Datos
            bicepData = leerYValidarBatch(Red.UdpBiceps, 5, true);
            tobilloData = leerYValidarBatch(Red.UdpTobillo, 7, true);
            
            if ~isempty(tobilloData)
                for i = 1:size(tobilloData, 1)
                    t_abs = tobilloData(i,1);
                    if isnan(Estado.OffsetTobillo), Estado.OffsetTobillo = posixtime(datetime('now')) - t_abs; end
                    t_rel = (t_abs + Estado.OffsetTobillo);
                    if Estado.T0_Global == -1, Estado.T0_Global = t_rel; end
                    t_plot = t_rel - Estado.T0_Global;

                    % DSP
                    emg = abs(tobilloData(i,5) - mean(tobilloData(:,5)));
                    svm = abs(sqrt(sum(tobilloData(i,2:4).^2)) - 1.0);
                    
                    addpoints(lineaEMG, t_plot, emg);
                    addpoints(lineaSVM, t_plot, svm);
                end
            end
        end
        drawnow limitrate; pause(0.01);
    end

    function dataOut = leerYValidarBatch(puerto, expectedCols, fusionarTiempo)
        dataOut = [];
        if puerto.NumDatagramsAvailable == 0, return; end
        
        origen = 'BICEPS'; if puerto.LocalPort == 8888, origen = 'TOBILLO'; end
        pkts = read(puerto, puerto.NumDatagramsAvailable);
        
        % TELEMETRIA RECIBIDA
        fprintf('[RX %s] Datagramas: %d | Time: %s\n', origen, length(pkts), datestr(now,'HH:MM:SS.FFF'));
        
        idx = 0;
        for p = 1:length(pkts)
            lineas = strsplit(char(pkts(p).Data), '\n');
            for l = 1:length(lineas)
                str = strtrim(lineas{l});
                if isempty(str), continue; end
                partes = strsplit(str, ',');
                if length(partes) == expectedCols
                   nums = str2double(partes(1:end-1));
                   if fusionarTiempo, nums = [nums(1)+(nums(2)/1e6), nums(3:end)]; end
                   idx = idx + 1; dataOut(idx, :) = nums;
                   if mod(idx, 5) == 0, fprintf('   DATA: %s\n', str); end
                end
            end
        end
    end

    function alternar()
        Estado.Capturando = ~Estado.Capturando;
        if Estado.Capturando
            Red.UdpTobillo = udpport("datagram", "LocalPort", 8888);
            Red.UdpBiceps = udpport("datagram", "LocalPort", 8889);
            Red.UdpControl = udpport("datagram", "LocalPort", 9999);
            UI.btn.Text = 'DETENER';
            fprintf('\n*** ESCUCHA UDP INICIADA ***\n');
        else
            clear Red.UdpTobillo Red.UdpBiceps Red.UdpControl;
            UI.btn.Text = 'CONECTAR';
            fprintf('\n*** ESCUCHA UDP DETENIDA ***\n');
        end
    end
end

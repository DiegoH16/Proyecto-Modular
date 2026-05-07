function dataOut = leerYValidarBatch(puerto, expectedCols)
        dataOut = [];
        if isempty(puerto) || puerto.NumDatagramsAvailable == 0
            return; 
        end
        
        try
            numPaquetes = min(puerto.NumDatagramsAvailable, 50); % Límite anti-flood
            paquetes = read(puerto, numPaquetes); 
        catch
            return;
        end
        
        for p = 1:numPaquetes
            payload = char(paquetes(p).Data);
            lineas = strsplit(payload, '\n'); 
            
            for i = 1:length(lineas)
                strLine = strtrim(lineas{i});
                if isempty(strLine) || startsWith(strLine, '#'), continue; end
                
                partes = strsplit(strLine, ',');
                if length(partes) ~= expectedCols
                    continue;
                end
                
                crcRecibidoStr = partes{end};
                msgOriginal = strjoin(partes(1:end-1), ',');
                
                crcCalculado = m_crc16(msgOriginal);
                if ~strcmp(crcCalculado, crcRecibidoStr)
                    continue;
                end
                
                nums = str2double(partes(1:end-1));
                if any(isnan(nums))
                    continue;
                end
                
                % ✅ MITIGACIÓN CRÍTICA: Refactorización segura de índices
                if expectedCols >= 5 && length(nums) >= 2
                    % nums_out = [Tiempo Absoluto, Eje X/Red, Eje Y/IR, ...]
                    nums = [nums(1) + (nums(2) / 1e6), nums(3:end)];
                end
                
                dataOut = [dataOut; nums]; %#ok<AGROW>
            end
        end
    end

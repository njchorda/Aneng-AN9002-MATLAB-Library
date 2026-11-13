%AnengAN9002  ANENG AN9002 Bluetooth multimeter driver.
% The meter is a Bluetooth LE device that advertises as "Bluetooth DMM".
% Do not pair it in Windows, just connect from here.
%
% Use:
%   dmm = AnengAN9002();                 % first "Bluetooth DMM" found
%   dmm = AnengAN9002('FC58FA44F4F3');   % by address (faster, no scan)
%   v = dmm.readValue();            % number in base units (V, A, ohm, ...)
%   [v, unit] = dmm.readValue();
%   r = dmm.read();                 % struct with everything on the LCD
%   tt = dmm.log(10);               % record 10 s, returns a timetable
%   dmm.start(@(r) disp(r.Display)); dmm.stop();   % background streaming
%   dmm.watch(30);                  % print raw bits when the display changes
%   dmm.deInit();
%
% Credits
% The packet format was not reverse-engineered here. The XOR key, the
% segment/decimal-point/sign layout and the unit bit positions come from
% the following community work, then were cross-checked against packets
% captured from a real AN9002:
%   - ludwich66, "Bluetooth-DMM" wiki (Protocol all Variants, Bluetooth DMM
%     11 Byte Data Protocol): XOR key, packet structure, symbol list and a
%     worked example packet.
%     https://github.com/ludwich66/Bluetooth-DMM
%   - riktw, "AN9002_info" (multimeter.py): digit segment order, decimal
%     point, sign and unit bit tests.
%     https://github.com/riktw/AN9002_info
%   - bendtherules, decoder gist: confirmation of the XOR key and of the
%     mV/V flag behaviour.
%     https://gist.github.com/bendtherules/4500b2c02ef6bc2f236828ed22af8844
% No code was copied from these projects; the MATLAB implementation is
% original.
classdef AnengAN9002 < handle
    properties
        address;
        name;
        v;                      % ble object
        notifyChar;             % FFF0/FFF4 characteristic
        lastReading = [];       % most recent decoded reading
        readingFcn = [];        % called with each reading while streaming
        streaming = false;
    end

    properties (Constant)
        deviceName  = 'Bluetooth DMM';
        serviceUUID = 'FFF0';
        charUUID    = 'FFF4';
        xorKey      = uint8([65 33 115 85 162 193 50 113 102 170 59]);  % 41 21 73 55 A2 C1 32 71 66 AA 3B
        header      = uint8([90 165]);                                  % 5A A5 after XOR
    end

    methods
        function obj = AnengAN9002(varargin)
            if numel(varargin) == 0
                obj.address = AnengAN9002.findAddress();
            else
                obj.address = char(varargin{1});
            end
            obj.v = ble(obj.address);
            obj.name = char(obj.v.Name);
            obj.address = char(obj.v.Address);
            obj.notifyChar = characteristic(obj.v, obj.serviceUUID, obj.charUUID);
            subscribe(obj.notifyChar);
        end

        function r = read(obj)
            % Waits for the next packet and returns the decoded struct,
            % see decode() for the fields.
            % The meter can take a moment to start sending after connecting,
            % so retry for a few seconds before giving up.
            t0 = tic;
            while true
                try
                    [data, ts] = read(obj.notifyChar);
                    break
                catch err
                    if toc(t0) > 5
                        rethrow(err);
                    end
                    pause(0.2);
                end
            end
            r = AnengAN9002.decode(data);
            r.Time = ts;
            obj.lastReading = r;
        end

        function [value, unit] = readValue(obj)
            % Returns the reading as a number in base units, i.e. 12.34 mV
            % comes back as 0.01234. Inf on overload, NaN if the display
            % is not a number. unit is the base unit ('V', 'A', ...).
            r = obj.read();
            value = r.Scaled;
            unit = r.BaseUnit;
        end

        function tt = log(obj, duration)
            % Records readings for duration seconds, returns a timetable.
            wasStreaming = obj.streaming;
            if wasStreaming
                obj.stop();
            end
            readings = [];
            t0 = tic;
            while toc(t0) < duration
                r = obj.read();
                if r.Valid
                    readings = [readings; r]; %#ok<AGROW>
                end
            end
            if wasStreaming
                obj.start();
            end
            if isempty(readings)
                tt = timetable.empty;
                return
            end
            tt = timetable([readings.Time]', [readings.Value]', [readings.Scaled]', ...
                {readings.Unit}', {readings.Display}', ...
                'VariableNames', {'Value', 'Scaled', 'Unit', 'Display'});
        end

        function start(obj, varargin)
            % Streams readings in the background. obj.start(fcn) calls
            % fcn(reading) for every packet, lastReading is always updated.
            if numel(varargin) > 0
                obj.readingFcn = varargin{1};
            end
            obj.notifyChar.DataAvailableFcn = @(src, ~) obj.onData(src);
            obj.streaming = true;
        end

        function stop(obj)
            if ~isempty(obj.notifyChar) && isvalid(obj.notifyChar)
                obj.notifyChar.DataAvailableFcn = [];
            end
            obj.streaming = false;
        end

        function watch(obj, varargin)
            % Prints the decoded packet bits each time they change. Use it
            % to work out which bit drives which LCD symbol.
            if numel(varargin) == 0
                duration = 30;
            else
                duration = varargin{1};
            end
            fprintf('%-12s  %s\n', 'display', 'byte3    byte4    byte5    byte6    byte7    byte8    byte9    byte10');
            last = [];
            t0 = tic;
            while toc(t0) < duration
                r = obj.read();
                if ~isequal(r.Bytes, last) && r.Valid
                    bits = strjoin(cellstr(dec2bin(r.Bytes(4:11), 8)), ' ');
                    fprintf('%-12s  %s\n', r.Display, bits);
                    last = r.Bytes;
                end
            end
        end

        function onData(obj, src)
            % Notification callback used while streaming.
            try
                [data, ts] = read(src, 'oldest');
                r = AnengAN9002.decode(data);
                r.Time = ts;
                obj.lastReading = r;
                if ~isempty(obj.readingFcn) && r.Valid
                    obj.readingFcn(r);
                end
            catch err
                warning('AnengAN9002:callback', '%s', err.message);
            end
        end

        function bool = deInit(obj)
            if ~isempty(obj.v) && isvalid(obj.v)
                obj.stop();
                try
                    unsubscribe(obj.notifyChar);
                catch
                end
                obj.notifyChar = [];
                obj.v = [];
                bool = 1;
            else
                bool = 0;
            end
        end

        function delete(obj)
            % So that clear also disconnects.
            obj.deInit();
        end
    end

    methods (Static)
        function address = findAddress()
            list = blelist('Name', AnengAN9002.deviceName);
            if isempty(list)
                error('No "%s" found. Is the meter on with Bluetooth enabled?', AnengAN9002.deviceName);
            end
            address = char(list.Address(1));
        end

        function r = decode(data)
            % Decodes one raw 11-byte notification packet.
            %   r.Valid    packet had the right length and header
            %   r.Text     the four LCD digits with sign and decimal point
            %   r.Value    number in displayed units (Inf on overload, NaN if not numeric)
            %   r.Unit     displayed unit with prefix, i.e. 'mV'
            %   r.Scaled   value in base units (V, A, ohm, F, Hz, ...)
            %   r.BaseUnit unit without prefix
            %   r.Display  Text and Unit (plus DC or AC) as one string
            %   r.Overload true when the meter shows OL
            %   r.Flags    LCD annunciators
            %   r.Bytes    packet after XOR decoding
            %
            % Packet layout after XOR (bit 7 = MSB):
            %   bytes 0-1  header 5A A5          byte 2  meter type
            %   byte 3     [a f e | minus | flags]
            %   bytes 4-6  [a f e | point | b g c d]   point sits before the digit
            %   byte 7     [flags          | b g c d]
            %   bytes 8-10 unit and mode symbols
            % A digit's a,f,e segments are in the top 3 bits of one byte
            % and its b,g,c,d segments in the low 4 bits of the next.

            data = uint8(data(:)');
            r = struct('Valid', false, 'Time', NaT, 'Text', '', 'Value', NaN, ...
                'Unit', '', 'Scaled', NaN, 'BaseUnit', '', 'Display', '', ...
                'Overload', false, 'Flags', struct, 'Bytes', data);
            if numel(data) ~= numel(AnengAN9002.xorKey)
                return
            end
            b = bitxor(data, AnengAN9002.xorKey);
            r.Bytes = b;
            if ~isequal(b(1:2), AnengAN9002.header)
                return
            end
            r.Valid = true;
            bit = @(byteIdx, k) logical(bitget(b(byteIdx + 1), k + 1));  % 0-based byte and bit

            % Digits
            txt = '';
            if bit(3, 4)
                txt = '-';
            end
            for d = 1:4
                hi = bitshift(b(d + 3), -5);            % a f e
                lo = bitand(b(d + 4), 15);              % b g c d
                if d > 1 && bit(d + 2, 4)
                    txt = [txt '.']; %#ok<AGROW>
                end
                txt = [txt AnengAN9002.segmentChar(bitor(bitshift(hi, 4), lo))]; %#ok<AGROW>
            end
            r.Text = txt;
            r.Overload = any(txt == 'L');
            if r.Overload
                r.Value = Inf;
            else
                r.Value = str2double(strrep(txt, ' ', ''));   % NaN if not numeric
            end

            % Unit
            prefix = '';
            base = '';
            if bit(9, 4)                       % volts
                base = 'V';
                if bit(9, 5), prefix = 'm'; end
            elseif bit(9, 7)                   % amps
                base = 'A';
                if bit(10, 3), prefix = 'm'; elseif bit(10, 2), prefix = 'µ'; end
            elseif bit(9, 1)                   % ohms
                base = 'Ω';
                if bit(9, 3), prefix = 'M'; elseif bit(9, 2), prefix = 'k'; end
            elseif bit(9, 0)                   % hertz
                base = 'Hz';
                if bit(9, 3), prefix = 'M'; elseif bit(9, 2), prefix = 'k'; end
            elseif bit(8, 4)                   % farads
                base = 'F';
                % bit 5 = µ and bit 7 = n are confirmed on the meter (the
                % published notes had bit 5 as m). m on bit 6 is by
                % elimination, no mF reading has been seen.
                if bit(8, 5), prefix = 'µ'; elseif bit(8, 7), prefix = 'n'; elseif bit(8, 6), prefix = 'm'; end
            elseif bit(7, 6)
                base = '°C';
            elseif bit(7, 5)
                base = '°F';
            end
            r.BaseUnit = base;
            r.Unit = [prefix base];
            switch prefix
                case 'n', k = 1e-9;
                case 'µ', k = 1e-6;
                case 'm', k = 1e-3;
                case 'k', k = 1e3;
                case 'M', k = 1e6;
                otherwise, k = 1;
            end
            r.Scaled = r.Value * k;

            % Annunciators. DC, AC and Auto are confirmed on the meter, Diode
            % is from the published notes. The rest (hold, relative,
            % min/max, continuity, battery, %) live in byte 3 bits 0-2,
            % byte 7 bits 4 and 7, byte 8 bits 0-2 and byte 10 bit 1 but
            % are not mapped yet, use watch() to find them.
            r.Flags = struct( ...
                'DC',    bit(9, 6), ...
                'AC',    bit(8, 3), ...
                'Auto',  bit(10, 0), ...
                'Diode', bit(3, 3));

            mode = '';
            if r.Flags.DC
                mode = ' DC';
            elseif r.Flags.AC
                mode = ' AC';
            end
            r.Display = strtrim([txt ' ' r.Unit mode]);
        end

        function c = segmentChar(code)
            % 7-bit segment code, MSB to LSB: a f e b g c d
            switch code
                case 123, c = '0';
                case 10,  c = '1';
                case 93,  c = '2';
                case 79,  c = '3';
                case 46,  c = '4';
                case 103, c = '5';
                case 119, c = '6';
                case 74,  c = '7';
                case 127, c = '8';
                case 111, c = '9';
                case 0,   c = ' ';
                case 4,   c = '-';
                case 49,  c = 'L';
                case 117, c = 'E';
                case 116, c = 'F';
                case 59,  c = 'U';
                case 22,  c = 'n';
                case 23,  c = 'o';
                case 20,  c = 'r';
                case 126, c = 'A';
                case 19,  c = 'u';
                case 53,  c = 't';
                case 62,  c = 'H';
                case 124, c = 'P';
                case 113, c = 'C';
                case 31,  c = 'd';
                case 55,  c = 'b';
                otherwise, c = '?';
            end
        end
    end
end

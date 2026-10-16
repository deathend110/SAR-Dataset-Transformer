function signal60 = sarflow_load_echo_block(manifest_row, S60, block_width, cache_trajectory)
%LOAD_ECHO_BLOCK 读取清单指定的180MHz轨迹连续块并转换为60MHz。
% manifest_row提供文件、变量名和CStart；persistent缓存避免重复读同一轨迹。
% 输出固定为S60.nrn×block_width复回波，供H/L两分支共同使用。
persistent cached_path cached_raw
if nargin<4,cache_trajectory=true;end
file_path = string(manifest_row.FilePath(1));
if ~cache_trajectory || isempty(cached_path) || cached_path ~= file_path
    variable_name = char(manifest_row.EchoVariable(1));
    loaded = load(file_path, variable_name);
    if ~isfield(loaded, variable_name)
        error('scenePercentiles:EchoVariableMissing', ...
            '回波文件缺少变量%s：%s', variable_name, file_path);
    end
    raw = loaded.(variable_name);
    if cache_trajectory
        cached_raw = raw;
        cached_path = file_path;
    end
else
    raw = cached_raw;
end
start_index = manifest_row.CStart(1);          % 当前2224列块的首列
stop_index = start_index + block_width - 1;   % 当前块的末列
if stop_index > size(raw, 2)
    error('scenePercentiles:EchoBlockRange', ...
        '轨迹%s无法裁出指定连续块。', file_path);
end
signal60 = raw(1:3:end, start_index:stop_index);
if size(signal60, 1) < S60.nrn
    error('scenePercentiles:EchoRows', ...
        '降至60MHz后的距离维长度不足。');
end
signal60 = signal60(1:S60.nrn, :);
end

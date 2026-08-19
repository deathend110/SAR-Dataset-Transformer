function bandwidth = resolve_azimuth_bandwidth(S60)
%RESOLVE_AZIMUTH_BANDWIDTH 按Ba、Bd、Da优先级解析方位带宽。
if isfield(S60, 'Ba')
    bandwidth = S60.Ba;
elseif isfield(S60, 'Bd')
    bandwidth = S60.Bd;
elseif isfield(S60, 'Da')
    bandwidth = 2 * S60.v / S60.Da;
else
    error('rangeSFT:AzimuthBandwidth', ...
        'FS60参数必须包含Ba、Bd或Da。');
end
end

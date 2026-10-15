function threshold = build_2dsft_threshold( ...
        signal_up, grid, parameters, S60, carrier)
%BUILD_2DSFT_THRESHOLD 在上采样网格上构造二维单频复SFT阈值。
% fast-time对应距离维，slow-time对应方位维；两方向相位相加后取复指数。
sigma_hat = sqrt(2 / pi) * mean(abs(signal_up(:)));
amplitude = sigma_hat / (10 ^ (parameters.STR_dB / 20));
if nargin < 5 || isempty(carrier)
    carrier = build_2dsft_carrier(grid, parameters, S60);
elseif ~isequal(size(carrier), size(signal_up))
    error('rangeSFT:CarrierSize', ...
        '预计算SFT载波尺寸必须与上采样回波一致。');
end
threshold = amplitude * carrier;
end

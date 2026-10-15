function [grid_h, grid_l] = resolve_pair_grids( ...
        pair, sequence, S60, nyquist_margin)
%RESOLVE_PAIR_GRIDS 解析H/L实际网格并检查共同Nyquist上限。
input_size = [sequence.signal_height, sequence.block_width];
grid_h = resolve_range_grid(pair.H.q_total, input_size, S60);
grid_l = resolve_range_grid(pair.L.q_total, input_size, S60);
azimuth_bandwidth = resolve_azimuth_bandwidth(S60);

fr_limit = nyquist_margin * min(grid_h.Fs_up, grid_l.Fs_up) ...
    / (2 * S60.B);
fa_limit = nyquist_margin * min(grid_h.PRF_up, grid_l.PRF_up) ...
    / (2 * azimuth_bandwidth);
fr = pair.H.threshold.fr_over_Br;
fa = pair.H.threshold.fa_over_Ba;
if fr >= fr_limit || fa >= fa_limit
    error('rangeSFT:SFTNyquistViolation', ...
        ['SFT频率必须满足fr/Br<%.12g、fa/Ba<%.12g；' ...
        '当前为%.12g、%.12g。'], fr_limit, fa_limit, fr, fa);
end
end

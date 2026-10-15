function [grid_h, grid_l] = resolve_pair_grids( ...
        pair, sequence, S60, nyquist_margin)
%RESOLVE_PAIR_GRIDS 解析实际单分支或H/L网格，检查严格Nyquist上限。
input_size = [sequence.signal_height, sequence.block_width];
if isfield(pair,'single')
    grid_h=resolve_range_grid(pair.single.q_total,input_size,S60);
    grid_l=[];
    fs=grid_h.Fs_up;prf=grid_h.PRF_up;threshold=pair.single.threshold;
else
    grid_h=resolve_range_grid(pair.H.q_total,input_size,S60);
    grid_l=resolve_range_grid(pair.L.q_total,input_size,S60);
    fs=min(grid_h.Fs_up,grid_l.Fs_up);prf=min(grid_h.PRF_up,grid_l.PRF_up);
    threshold=pair.H.threshold;
end
fr_limit=nyquist_margin*fs/(2*S60.B);
fa_limit=nyquist_margin*prf/(2*resolve_azimuth_bandwidth(S60));
fr=threshold.fr_over_Br;fa=threshold.fa_over_Ba;
if fr >= fr_limit || fa >= fa_limit
    error('rangeSFT:SFTNyquistViolation', ...
        ['SFT频率必须满足fr/Br<%.12g、fa/Ba<%.12g；' ...
        '当前为%.12g、%.12g。'], fr_limit, fa_limit, fr, fa);
end
end

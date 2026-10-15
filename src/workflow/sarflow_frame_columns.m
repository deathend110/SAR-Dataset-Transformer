function columns = sarflow_frame_columns(sequence_cfg, frame_idx)
%FRAME_COLUMNS 返回第frame_idx帧在2224列连续块中的1200列索引。
% frame_idx使用MATLAB的1~9编号；首列按128步长线性移动。
start_idx = 1 + (frame_idx - 1) * sequence_cfg.step;
columns = start_idx:start_idx + sequence_cfg.signal_width - 1;
end

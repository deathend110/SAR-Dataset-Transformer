function mask = build_hlh_mask(sequence)
%BUILD_HLH_MASK 构造2224列连续RC上的H-L-H空间选择掩膜。
% 有效逻辑区为H(512)-L(512)-H(512)，两端各扩展344列。
% true选择对齐后的RC_H，false选择RC_L；边界应固定为两个。
logic_mask = false(1, sequence.logic_length);
logic_mask(1:512) = true;
logic_mask(1025:1536) = true;
full_mask = [ ...
    repmat(logic_mask(1), 1, sequence.valid_margin), ...
    logic_mask, ...
    repmat(logic_mask(end), 1, sequence.valid_margin)];
if numel(full_mask) ~= sequence.block_width
    error('scenePercentiles:HLHMaskLength', ...
        'H-L-H完整掩膜长度与连续回波块不一致。');
end
mask = struct("logic", logic_mask, "full", full_mask, ...
    "boundaries", find(diff(full_mask) ~= 0));
end

function [mixed, info, aligned_h, raw_l] = mix_sequence_rc( ...
        signal, S60, pair, mask, buffer, carrier_h, carrier_l, pre_h, pre_l)
%MIX_SEQUENCE_RC 正式统计、参数筛选与生产共用H/L量化、对齐与混合。
if nargin<8,pre_h=[];end
if nargin<9,pre_l=[];end
raw_h=generate_range_2dsft_rc(signal,S60,pair.H,carrier_h,pre_h);
raw_l=generate_range_2dsft_rc(signal,S60,pair.L,carrier_l,pre_l);
[mixed,info]=align_and_mix_rc(raw_h,raw_l,mask,buffer);
if nargout>=3,aligned_h=raw_h*info.scale_factor;end
end

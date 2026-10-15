function [rc, info, first, second] = sarflow_sequence_rc( ...
        signal,S60,acquisition,sequence,buffer,carrier,other_carrier,pre,other_pre)
%SARFLOW_SEQUENCE_RC 搜索、统计和生产共享完整连续块的RC采集。
% 固定Q不构建H/L掩膜，也不调用能量对齐；第二个分支始终为空。
if nargin<8,pre=[];end
if nargin<9,other_pre=[];end
if isfield(acquisition,'single')
    rc=generate_range_2dsft_rc(signal,S60,acquisition.single,carrier,pre);
    first=rc;second=[];
    info=struct("scale_factor",NaN,"boundary_jump_db",NaN);
else
    mask=sarflow_build_hlh_mask(sequence);
    [rc,info,first,second]=sarflow_mix_sequence_rc(signal,S60,acquisition, ...
        mask.full,buffer,carrier,other_carrier,pre,other_pre);
end
end

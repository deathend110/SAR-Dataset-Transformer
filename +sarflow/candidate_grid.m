function candidates = candidate_grid(cfg, S60, qh, ql, anchor)
%CANDIDATE_GRID 使用真实整数采样尺寸生成严格合法的粗/细网格。
if nargin < 5, anchor = []; end
p = struct("Method", "Range_2D_SFT", "QHigh", qh, "QLow", ql, ...
    "STRdB", 0, "FrOverBr", 0, "FaOverBa", 0, "Phi0", cfg.search.phi0);
[h,l] = resolve_pair_grids(make_range_sft_pair(p), cfg.sequence, S60, cfg.nyquist_margin);
fr_limit = cfg.nyquist_margin * min(h.Fs_up,l.Fs_up)/(2*S60.B);
fa_limit = cfg.nyquist_margin * min(h.PRF_up,l.PRF_up)/(2*resolve_azimuth_bandwidth(S60));
if isempty(anchor)
    sv = cfg.search.STR_grid; rv = cfg.search.fr_grid; av = cfg.search.fa_grid;
    stage = "coarse";
else
    sv = anchor.STRdB + cfg.search.fine_STR_offsets;
    rv = anchor.FrOverBr + cfg.search.fine_frequency_offsets;
    av = anchor.FaOverBa + cfg.search.fine_frequency_offsets;
    stage = "fine";
end
sv = unique(round(sv,10)); rv = unique(round(rv,10)); av = unique(round(av,10));
rv = rv(rv>=0 & rv<fr_limit & rv<=max(cfg.search.fr_grid));
av = av(av>=0 & av<fa_limit & av<=max(cfg.search.fa_grid));
if isempty(sv)||isempty(rv)||isempty(av), error('sarflow:EmptyGrid','没有合法候选。'); end
[a,b,c] = ndgrid(sv,rv,av); n = numel(a);
candidates = table(repmat(stage,n,1),repmat(qh,n,1),repmat(ql,n,1), ...
    a(:),b(:),c(:),repmat(cfg.search.phi0,n,1), ...
    'VariableNames', ["Stage","QHigh","QLow","STRdB","FrOverBr","FaOverBa","Phi0"]);
protocol = sarflow.statistics("build_protocol",cfg,S60, ...
    cfg.stats.blocks_per_file,cfg.low_percentile,cfg.high_percentile,cfg.sequence.roi_size,cfg.energy_buffer);
candidates.ParameterKey = strings(n,1);
for k=1:n
    p = sarflow.statistics("parameter_struct",candidates(k,:));
    candidates.ParameterKey(k) = sarflow.statistics("make_parameter_key",p,protocol);
end
end

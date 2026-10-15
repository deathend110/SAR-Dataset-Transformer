function candidates = sarflow_candidate_grid(cfg, S60, qh, ql, anchor)
%CANDIDATE_GRID 使用真实整数采样尺寸生成严格合法的粗/细网格。
if nargin < 4, ql=[]; end
if nargin < 5, anchor = []; end
fixed=sarflow_is_fixed(cfg);
p = struct("Method", "Range_2D_SFT", "QHigh", qh, "QLow", ql, ...
    "STRdB", 0, "FrOverBr", 0, "FaOverBa", 0, "Phi0", cfg.search.phi0);
if fixed,p=rmfield(p,{'QHigh','QLow'});p.Q=qh;end
[h,l] = resolve_pair_grids(make_range_sft_pair(p), cfg.sequence, S60, cfg.nyquist_margin);
fs=h.Fs_up;prf=h.PRF_up;
if ~fixed,fs=min(fs,l.Fs_up);prf=min(prf,l.PRF_up);end
fr_limit=cfg.nyquist_margin*fs/(2*S60.B);
fa_limit=cfg.nyquist_margin*prf/(2*resolve_azimuth_bandwidth(S60));
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
if fixed
    candidates=table(repmat(stage,n,1),repmat(qh,n,1),a(:),b(:),c(:), ...
        repmat(cfg.search.phi0,n,1),'VariableNames',["Stage",sarflow_parameter_columns(true)]);
else
    candidates=table(repmat(stage,n,1),repmat(qh,n,1),repmat(ql,n,1), ...
        a(:),b(:),c(:),repmat(cfg.search.phi0,n,1), ...
        'VariableNames',["Stage",sarflow_parameter_columns(false)]);
end
protocol = sarflow_statistics("build_protocol",cfg,S60, ...
    cfg.stats.blocks_per_file,cfg.low_percentile,cfg.high_percentile,cfg.sequence.roi_size,cfg.energy_buffer);
candidates.ParameterKey = strings(n,1);
for k=1:n
    p = sarflow_statistics("parameter_struct",candidates(k,:));
    candidates.ParameterKey(k) = sarflow_statistics("make_parameter_key",p,protocol);
end
end

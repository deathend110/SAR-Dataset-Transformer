function bytes = sarflow_search_cache_budget(cfg)
%SARFLOW_SEARCH_CACHE_BUDGET 老配置未含执行选项时仍使用8GiB缓存。
gb=8;
if isfield(cfg,'search_runtime'),gb=cfg.search_runtime.cache_gb;end
if ~isnumeric(gb)||~isscalar(gb)||~isfinite(gb)||gb<=0
    error('sarflow:SearchCacheBudget','search_runtime.cache_gb必须为有限正数。');
end
bytes=double(gb)*1024^3;
end

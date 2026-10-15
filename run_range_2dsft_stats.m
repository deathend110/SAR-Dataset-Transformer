function varargout = run_range_2dsft_stats(varargin)
%RUN_RANGE_2DSFT_STATS 阶段入口；具体实现位于src/workflow。
if nargin==0,cfg=range_2dsft_config();else,cfg=varargin{1};end
setup_range_2dsft_paths(cfg);
[varargout{1:nargout}] = sarflow_stats_impl(varargin{:});
end

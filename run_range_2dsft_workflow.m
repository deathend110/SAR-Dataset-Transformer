function varargout = run_range_2dsft_workflow(varargin)
%RUN_RANGE_2DSFT_WORKFLOW 阶段入口；具体实现位于src/workflow。
if nargin==0,cfg=range_2dsft_config();else,cfg=varargin{1};end
directory_guard=setup_range_2dsft_paths(cfg); %#ok<NASGU>
[varargout{1:nargout}] = sarflow_workflow_impl(varargin{:});
end

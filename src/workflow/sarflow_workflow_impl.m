function output = sarflow_workflow_impl(cfg)
%RUN_RANGE_2DSFT_WORKFLOW 独立阶段执行；默认只预检，all按顺序运行全部阶段。
if nargin==0,cfg=range_2dsft_config();end
allowed=["preflight","search","confirm","stats","generate","evaluate","all"];
if ~isscalar(string(cfg.stage))||~ismember(string(cfg.stage),allowed)
    error('sarflow:Stage','未知执行阶段。');
end
directory_guard=setup_range_2dsft_paths(cfg); %#ok<NASGU>
record=sarflow_prepare_run(cfg);p=sarflow_paths(cfg);
output=struct("paths",p,"record",record);
if cfg.stage=="preflight",return;end
stages=string(cfg.stage);
if cfg.stage=="all",stages=["search","confirm","stats","generate","evaluate"];end
for stage=stages
    if stage=="search"
        output.locked=run_range_2dsft_search(cfg);
        continue;
    end
    locked=sarflow_read_lock(cfg,record);
    cfg.provenance=struct("run_record",fullfile(p.protocol,"run_record.mat"), ...
        "locked_file",p.lock,"locked_parameters",locked, ...
        "confirmation_file",fullfile(p.confirmation,"confirmation.mat"), ...
        "role","parameter_confirmation_only_not_model_test_split");
    switch stage
        case "confirm"
            output.confirmation=run_range_2dsft_confirm(cfg);
        case "stats"
            require_confirmation(p,record,locked);
            parameters=locked(:,sarflow_parameter_columns(sarflow_is_fixed(cfg)));
            run_range_2dsft_stats(cfg,parameters);
            write_marker(p,"stats",record,locked);
        case "generate"
            require_marker(p,"stats",record,locked);
            for k=1:height(locked)
                parameters=sarflow_statistics("parameter_struct",locked(k,:));
                run_range_2dsft_generate(cfg,parameters);
            end
            write_marker(p,"generate",record,locked);
        case "evaluate"
            require_marker(p,"generate",record,locked);
            for k=1:height(locked)
                run_range_2dsft_evaluate(cfg,locked.ParameterKey(k));
            end
            write_marker(p,"evaluate",record,locked);
    end
end
end

function require_confirmation(p,~,locked)
path=fullfile(p.confirmation,"confirmation.mat");
if ~isfile(path),error('sarflow:Prerequisite','请先完成confirm阶段。');end
x=load(path);
if ~isfield(x,'complete')||~isequal(x.complete,true)
    error('sarflow:ConfirmationMismatch','确认阶段尚未完成。');
end
sarflow_check_parameters(x.locked,locked,"确认锁定参数");
end

function write_marker(p,stage,record,locked)
sarflow_atomic_save(fullfile(p.checkpoints,"workflow",stage+"_complete.mat"), ...
    struct("record",record,"locked",locked,"complete",true));
end

function require_marker(p,stage,~,locked)
path=fullfile(p.checkpoints,"workflow",stage+"_complete.mat");
if ~isfile(path),error('sarflow:Prerequisite','请先完成%s阶段。',stage);end
x=load(path);
if ~isfield(x,'complete')||~isequal(x.complete,true)
    error('sarflow:PrerequisiteMismatch','前置阶段尚未完成。');
end
sarflow_check_parameters(x.locked,locked,"前置阶段参数");
end

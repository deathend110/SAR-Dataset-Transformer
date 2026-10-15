function report = sarflow_migrate_layout(cfg,mode)
%SARFLOW_MIGRATE_LAYOUT 按精确映射迁移小型MAT引用；不读取、移动或重写PNG。
p=sarflow_paths(cfg);directory=fullfile(p.root,"migration");
items=jsondecode(fileread(fullfile(directory,"file_mapping.json")));
root=string(java.io.File(char(cfg.repo_root)).getCanonicalPath());
for k=1:numel(items)
    for field=["source","target"]
        path=string(java.io.File(char(items(k).(field))).getCanonicalPath());
        if ~startsWith(lower(path),lower(root+string(filesep)))
            error('sarflow:MigrationPath','迁移路径必须在本仓库内。');
        end
    end
end
report=struct("files",numel(items),"mode",mode);
if mode=="preview",disp(struct2table(items));return;end
if mode=="rollback"
    for k=1:numel(items)
        original=backup_path(directory,items,k);
        source=string(items(k).source);target=string(items(k).target);
        if ~isfolder(fileparts(source)),mkdir(fileparts(source));end
        copyfile(original,source,'f');
        if ~strcmpi(source,target)&&isfile(target),delete(target);end
    end
    state=struct("completed",0,"status","rolled_back");
    sarflow_atomic_save(fullfile(directory,"migration_state.mat"),struct("state",state));
    report.status="rolled_back";return;
end
if mode~="apply",error('sarflow:MigrationMode','只支持preview、apply、rollback。');end
state_path=fullfile(directory,"migration_state.mat");
if isfile(state_path)
    previous=load(state_path,'state');
    if string(previous.state.status)=="complete",report.status="already_complete";return;end
end
for k=1:numel(items)
    source=string(items(k).source);target=string(items(k).target);
    if ~isfile(target)
        if ~isfolder(fileparts(target)),mkdir(fileparts(target));end
        copyfile(source,target);
    end
end
% 写入前完成所有来源核对；迁移只改变明确的路径和来源字段。
inventory=sarflow_statistics("build_scene_manifest",cfg,cfg.stats.blocks_per_file);
S60=load(cfg.parameter_file_60);
protocol=sarflow_statistics("build_protocol",cfg,S60,cfg.stats.blocks_per_file, ...
    cfg.low_percentile,cfg.high_percentile,cfg.sequence.roi_size,cfg.energy_buffer);
jobs=cell(numel(items),1);
for k=1:numel(items)
    [~,~,ext]=fileparts(items(k).target);
    if ext~=".mat",continue;end
    x=load(backup_path(directory,items,k));
    if isfield(x,'scene_stats')
        s=x.scene_stats;
        expected=inventory(inventory.Scene==string(s.scene_name),:);
        if ~isequaln(s.source_manifest,expected)||~same_protocol(s.protocol,protocol)
            error('sarflow:MigrationStats','场景%s的源清单或成像协议不一致。',s.scene_name);
        end
        s.protocol.parameter_file_60=cfg.parameter_file_60;
        x.scene_stats=s;jobs{k}=x;
    elseif isfield(x,'dataset_metadata')
        meta=x.dataset_metadata;sig=meta.signature;
        verified=sig;
        for j=1:numel(sig.normalization_sources)
            source=sig.normalization_sources(j);old=load(source.StatsFile,'scene_stats');s=old.scene_stats;
            idx=find(string({s.entries.parameter_key})==string(sig.parameter_key));
            if numel(idx)~=1||string(s.entries(idx).updated_at)~=string(source.EntryUpdatedAt)|| ...
                    ~same_protocol(s.protocol,sig.normalization_protocol)|| ...
                    ~isequaln(s.entries(idx).parameters,sig.parameters)|| ...
                    ~isequaln(s.source_manifest,inventory(inventory.Scene==string(s.scene_name),:))
                error('sarflow:MigrationDataset','数据集%s的统计条目无法核验。',sig.parameter_key);
            end
            % 场景文件追加其他参数可更新整体时间，但目标条目与共享GT保持原值。
            verified.normalization_sources(j).SceneUpdatedAt=s.updated_at;
        end
        snap=sarflow_normalization_snapshot(verified);
        for j=1:numel(snap),snap(j).protocol.parameter_file_60=cfg.parameter_file_60;end
        sig.script=fullfile(cfg.repo_root,"run_range_2dsft_generate");
        sig.stats_root=p.stats;
        sig.normalization_protocol.parameter_file_60=cfg.parameter_file_60;
        for j=1:numel(sig.normalization_sources)
            oldpath=string(sig.normalization_sources(j).StatsFile);
            idx=find(strcmpi(string({items.source}),oldpath),1);
            if isempty(idx),error('sarflow:MigrationSource','缺少统计文件映射。');end
            sig.normalization_sources(j).StatsFile=string(items(idx).target);
            sig.normalization_sources(j).SceneUpdatedAt=verified.normalization_sources(j).SceneUpdatedAt;
        end
        sig.normalization_snapshot=snap;sig.workflow=struct();
        meta.signature=sig;x.dataset_metadata=meta;jobs{k}=x;
    end
end
% 评估记录指向同一份经核验的数据集metadata，指标与已完成行保持不变。
for k=1:numel(items)
    [~,~,ext]=fileparts(items(k).target);if ext~=".mat",continue;end
    x=load(backup_path(directory,items,k));
    if isfield(x,'signature')&&isfield(x,'results_table')
        key=string(x.signature.parameter_key);
        meta=find_dataset(jobs,key);
        names=sequence_names(fullfile(cfg.dataset_root,key));
        if ~isequaln(string(x.signature.sequence_names(:)),names)|| ...
                ~isequaln(sort(string(x.results_table.SequenceName)),names)
            error('sarflow:MigrationEvaluation','评估断点的序列清单不一致。');
        end
        x.signature.script=fullfile(cfg.repo_root,"run_range_2dsft_evaluate");
        x.signature.dataset_signature=meta.signature;jobs{k}=x;
    elseif isfield(x,'evaluation_metadata')
        meta=find_dataset(jobs,string(x.evaluation_metadata.parameter_key));
        x.evaluation_metadata.script=fullfile(cfg.repo_root,"run_range_2dsft_evaluate");
        x.evaluation_metadata.dataset_signature=meta.signature;jobs{k}=x;
    end
end
state=struct("completed",0,"status","prepared");
sarflow_atomic_save(fullfile(directory,"migration_state.mat"),struct("state",state));
try
    for k=1:numel(items)
        if ~isempty(jobs{k}),sarflow_atomic_save(string(items(k).target),jobs{k});end
        state.completed=k;sarflow_atomic_save(fullfile(directory,"migration_state.mat"),struct("state",state));
    end
catch err
    sarflow_migrate_layout(cfg,"rollback");rethrow(err);
end
state.status="complete";sarflow_atomic_save(fullfile(directory,"migration_state.mat"),struct("state",state));
report.status="complete";
fprintf('目录引用迁移完成：%d个文件；未读取或改写PNG。\n',numel(items));
end

function path=backup_path(directory,items,k)
[~,name,ext]=fileparts(items(k).source);
path=fullfile(directory,"originals",sprintf('%03d_%s%s',k-1,name,ext));
end

function yes=same_protocol(a,b)
for field=["parameter_file_60","workflow"]
    if isfield(a,field),a=rmfield(a,field);end
    if isfield(b,field),b=rmfield(b,field);end
end
yes=isequaln(a,b);
end

function meta=find_dataset(jobs,key)
for k=1:numel(jobs)
    if ~isempty(jobs{k})&&isfield(jobs{k},'dataset_metadata')&& ...
            string(jobs{k}.dataset_metadata.signature.parameter_key)==key
        meta=jobs{k}.dataset_metadata;return;
    end
end
error('sarflow:MigrationMetadata','找不到数据集%s的迁移metadata。',key);
end

function names=sequence_names(root)
a=dir(fullfile(root,"LQ"));a=string({a([a.isdir]).name}).';a=a(a~="."&a~="..");
b=dir(fullfile(root,"GT"));b=string({b([b.isdir]).name}).';b=b(b~="."&b~="..");
if ~isequal(sort(a),sort(b)),error('sarflow:MigrationPairs','LQ/GT目录不配对。');end
names=sort(a);
end

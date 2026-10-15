function snapshot = sarflow_normalization_snapshot(signature)
%SARFLOW_NORMALIZATION_SNAPSHOT 保存实际统计值，避免仅凭参数键复用不同数据。
if isfield(signature,'normalization_snapshot')
    snapshot=signature.normalization_snapshot;
    return;
end
sources=signature.normalization_sources;
snapshot=struct([]);
for k=1:numel(sources)
    x=load(sources(k).StatsFile,'scene_stats');s=x.scene_stats;
    indices=find(string({s.entries.parameter_key})==string(signature.parameter_key));
    if numel(indices)~=1,error('sarflow:SnapshotEntry','统计条目缺失或重复。');end
    entry=s.entries(indices);
    % 旧metadata未保存快照时，必须确认来源文件仍是当时的版本。
    if string(s.updated_at)~=string(sources(k).SceneUpdatedAt)|| ...
            string(entry.updated_at)~=string(sources(k).EntryUpdatedAt)
        error('sarflow:SnapshotSourceChanged','原归一化统计已改变，无法确认旧PNG的生产口径。');
    end
    protocol=s.protocol;
    if isfield(protocol,'workflow'),protocol=rmfield(protocol,'workflow');end
    names={'Modality','VMin','VMax','ImageCount','PixelCount', ...
        'LowPercentile','HighPercentile','Method'};
    item=struct('scene',s.scene_name,'source_manifest',s.source_manifest, ...
        'protocol',protocol,'parameters',entry.parameters, ...
        'effective_sampling',entry.effective_sampling, ...
        'input',keep_fields(entry.input_stats,names),'gt',keep_fields(s.gt,names));
    if isempty(snapshot),snapshot=item;else,snapshot(end+1)=item;end %#ok<AGROW>
end
end

function out=keep_fields(value,names)
if ~all(isfield(value,names)),error('sarflow:SnapshotStats','归一化统计字段不完整。');end
out=struct();
for k=1:numel(names),out.(names{k})=value.(names{k});end
end

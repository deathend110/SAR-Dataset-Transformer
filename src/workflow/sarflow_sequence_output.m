function status = sarflow_sequence_output(paths, key, name)
%SARFLOW_SEQUENCE_OUTPUT 完整序列复用；有提交断点的序列可继续完成目录提交。
final_lq=fullfile(paths.dataset,key,"LQ",name);
final_gt=fullfile(paths.dataset,key,"GT",name);
if complete(final_lq)&&complete(final_gt),status="complete";return;end
checkpoint=fullfile(paths.checkpoints,"generation",key,name+".mat");
if isfile(checkpoint)
    x=load(checkpoint,'state');state=x.state;
    if ~isequaln(state.sequence_name,string(name))||~isequaln(state.parameter_key,string(key))
        error('sarflow:SequenceCheckpoint','序列提交断点不匹配。');
    end
    stage=fullfile(paths.cache,"generation",key,name);
    if ~complete(final_gt)
        if isfolder(final_gt)||~complete(fullfile(stage,"GT"))
            error('sarflow:SequenceIncomplete','GT提交状态不完整。');
        end
        movefile(fullfile(stage,"GT"),final_gt);
    end
    if ~complete(final_lq)
        if isfolder(final_lq)||~complete(fullfile(stage,"LQ"))
            error('sarflow:SequenceIncomplete','LQ提交状态不完整。');
        end
        movefile(fullfile(stage,"LQ"),final_lq);
    end
    state.phase="complete";
    sarflow_atomic_save(checkpoint,struct("state",state));
    if isfolder(stage),rmdir(stage);end % 只移除提交后的空缓存目录。
    status="complete";
elseif isfolder(final_lq)||isfolder(final_gt)
    error('sarflow:SequenceIncomplete','存在无提交断点的残缺序列：%s',name);
else
    status="missing";
end
end

function yes=complete(folder)
yes=false;
if ~isfolder(folder),return;end
files=dir(fullfile(folder,"*.png"));
yes=isequal(sort(string({files.name})),compose('%03d.png',0:8));
end

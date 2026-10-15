function sarflow_commit_sequence(paths,key,name,lq,gt,metadata)
%SARFLOW_COMMIT_SEQUENCE 临时图像仅写cache，保存提交断点后再移动到最终目录。
if ~isequal(size(lq),size(gt))||size(lq,3)~=9||~isa(lq,'uint8')||~isa(gt,'uint8')
    error('sarflow:SequenceType','LQ/GT必须是同尺寸uint8九帧序列。');
end
if sarflow_sequence_output(paths,key,name)=="complete",return;end
context=fullfile(paths.checkpoints,"generation",key,"metadata.mat");
if isfile(context)
    old=load(context,'signature');
    if ~isequaln(old.signature,metadata)
        error('sarflow:CheckpointMismatch','生成断点的生产配置不一致。');
    end
else
    sarflow_atomic_save(context,struct("signature",metadata));
end
for role=["LQ","GT"]
    folder=fullfile(paths.dataset,key,role);
    if ~isfolder(folder),mkdir(folder);end
end
stage=fullfile(paths.cache,"generation",key,name);
for role=["LQ","GT"]
    folder=fullfile(stage,role);
    if ~isfolder(folder),mkdir(folder);end
    images=lq;if role=="GT",images=gt;end
    for k=1:9,imwrite(images(:,:,k),fullfile(folder,sprintf('%03d.png',k-1)));end
end
state=struct("parameter_key",string(key),"sequence_name",string(name),"phase","staged");
sarflow_atomic_save(fullfile(paths.checkpoints,"generation",key,name+".mat"),struct("state",state));
sarflow_sequence_output(paths,key,name);
end

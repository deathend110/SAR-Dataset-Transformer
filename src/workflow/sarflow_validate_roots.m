function sarflow_validate_roots(cfg)
%SARFLOW_VALIDATE_ROOTS 数据、结果与代码目录不能互相嵌套；生成缓存要求同卷。
d=string(java.io.File(char(cfg.dataset_root)).getCanonicalPath());
r=string(java.io.File(char(cfg.results_root)).getCanonicalPath());
c=string(java.io.File(char(fullfile(cfg.repo_root,"src"))).getCanonicalPath());
paths=[d,r,c];
for a=1:numel(paths)
    for b=a+1:numel(paths)
        if strcmpi(paths(a),paths(b))||startsWith(lower(paths(a)),lower(paths(b)+string(filesep)))|| ...
                startsWith(lower(paths(b)),lower(paths(a)+string(filesep)))
            error('sarflow:RootOverlap','代码、数据集和辅助结果目录必须独立。');
        end
    end
end
if ispc
    vd=java.nio.file.Paths.get(char(d),javaArray('java.lang.String',0)).getRoot();
    vr=java.nio.file.Paths.get(char(r),javaArray('java.lang.String',0)).getRoot();
    if ~strcmpi(string(vd.toString()),string(vr.toString()))
        error('sarflow:StagingVolume','生成缓存与数据集必须位于同一卷。');
    end
end
end

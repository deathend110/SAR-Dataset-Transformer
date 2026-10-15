function sarflow_atomic_save(path, payload)
%ATOMIC_SAVE 同目录临时写入，成功后再替换，不声明未落盘的进度。
folder = string(fileparts(path));
if ~isfolder(folder), mkdir(folder); end
scratch = string(path) + ".tmp.mat";
save(scratch, '-struct', 'payload', '-v7.3');
[ok, msg] = movefile(scratch, path, 'f');
if ~ok, error('sarflow:AtomicSave', '%s', msg); end
end
